import Foundation
import UniformTypeIdentifiers

// Storyteller `POST`/`PATCH /api/v2/books/upload` is Tus 1.0 and requires `bookCreate`.
// Finish moves the file to `UPLOADS_DIR/<bookUuid>/<filename>` and scans with that
// `bookUuidHint`, so the same UUID updates the existing row instead of creating another
// book. Current servers defer the scan until `totalFiles` importable files are in that
// directory; older servers read `totalAudioFiles` on audio files. A matching Upload-Offset
// means the finish handler ran. It does not mean the library list already shows the row.
// Re-PATCH of the same filename overwrites that slot, so a retry skips finished files.
// Mid-byte Tus resume is not used: Storyteller's create/finish path was verified to take a
// full PATCH from `Upload-Offset: 0`, and inventing HEAD/partial offsets would invent
// server behavior. Resume is file-level via `completedAssetIDs` + a stable book UUID.
// Nothing here deletes a partial server book. `/upload/finalize` can relocate whatever is
// left in that directory onto an existing audiobook, including an empty directory, so it
// is not called.

public enum StorytellerBookCreateAccess: Equatable, Sendable {
    case allowed
    case denied
    case needsReconnect
}

public struct StorytellerFileUploadResult: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case uploaded
        case failed
        case unauthorized
        case cancelled
    }

    public let identity: String
    public let status: Status

    public init(identity: String, status: Status) {
        self.identity = identity
        self.status = status
    }
}

public struct StorytellerUploadedBookSnapshot: Equatable, Sendable {
    public let bookID: BookID
    public let readaloudStatus: String?

    public init(bookID: BookID, readaloudStatus: String?) {
        self.bookID = bookID
        self.readaloudStatus = readaloudStatus
    }
}

public enum StorytellerReadaloudUploadPhase: Equatable, Sendable {
    case queued
    case processing
    case ready
    case failed
    case absent
}

public enum StorytellerReadaloudUploadStatus {
    /// Same labels Storyteller writes on the book. Ready is only `ALIGNED`.
    public static func phase(_ status: String?) -> StorytellerReadaloudUploadPhase {
        switch status?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
            case "QUEUED":
                .queued
            case "PROCESSING":
                .processing
            case "ALIGNED":
                .ready
            case "ERROR", "STOPPED":
                .failed
            case nil, "":
                .absent
            default:
                .absent
        }
    }
}

public enum StorytellerUploadAlignment {
    /// Ebook + audiobook on Storyteller, and the user did not already pick a readaloud EPUB.
    public static func shouldQueueReadaloud(
        isStoryteller: Bool,
        hasEbook: Bool,
        hasAudiobook: Bool,
        hasReadaloudFile: Bool,
    ) -> Bool {
        isStoryteller && hasEbook && hasAudiobook && !hasReadaloudFile
    }
}

public enum StorytellerUploadFileRole: Equatable, Sendable {
    case ebook
    case audiobook
    case readaloud
}

public struct StorytellerUploadRequestFile: Equatable, Sendable, Identifiable {
    public let format: StorytellerBookFormat
    public let filename: String
    public let byteCount: Int64
    public let contentType: String
    public let typeIdentifier: String?
    public let fileURL: URL

    public var id: String { "\(format.rawValue)|\(filename)" }

    public var role: StorytellerUploadFileRole {
        switch format {
            case .ebook: .ebook
            case .audiobook: .audiobook
            case .readaloud: .readaloud
        }
    }

    public init(
        format: StorytellerBookFormat,
        filename: String,
        byteCount: Int64,
        contentType: String,
        typeIdentifier: String?,
        fileURL: URL,
    ) {
        self.format = format
        self.filename = filename
        self.byteCount = byteCount
        self.contentType = contentType
        self.typeIdentifier = typeIdentifier
        self.fileURL = fileURL
    }
}

public enum StorytellerUploadFileValidation {
    /// Extensions Storyteller's media-types table treats as audio or an audio archive.
    public static let audiobookExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "mp4", "aac", "ogg", "oga", "mogg", "opus",
        "wav", "aiff", "flac", "alac", "weba", "zip", "audiobook",
    ]

    public static func contentType(for role: StorytellerUploadFileRole, filename: String) -> String {
        switch role {
            case .ebook, .readaloud:
                return "application/epub+zip"
            case .audiobook:
                switch (filename as NSString).pathExtension.lowercased() {
                    case "m4a", "m4b", "mp4":
                        return "audio/mp4"
                    case "aac":
                        return "audio/aac"
                    case "ogg", "oga", "mogg":
                        return "audio/ogg"
                    case "opus":
                        return "audio/opus"
                    case "wav":
                        return "audio/wav"
                    case "flac":
                        return "audio/flac"
                    case "aiff":
                        return "audio/aiff"
                    case "zip", "audiobook":
                        return "application/zip"
                    default:
                        return "audio/mpeg"
                }
        }
    }

    /// Nil when the file may be sent. Uses extension, UTType, and size. Does not touch the network.
    public static func issue(
        role: StorytellerUploadFileRole,
        filename: String,
        byteCount: Int64,
        typeIdentifier: String?,
    ) -> String? {
        let displayName = filename.isEmpty ? "This file" : filename
        guard byteCount > 0 else {
            return "\(displayName) is empty. Choose a file that isn’t empty."
        }
        let type = typeIdentifier.flatMap(UTType.init)
        switch role {
            case .ebook, .readaloud:
                guard acceptsEpub(filename: filename, type: type) else {
                    if isPDF(filename: filename, type: type) {
                        return
                            "\(displayName) is a PDF. Storyteller ebooks have to be EPUB files."
                    }
                    return "\(displayName) isn’t an EPUB. Storyteller ebooks have to be EPUB files."
                }
            case .audiobook:
                guard acceptsAudiobook(filename: filename, type: type) else {
                    return
                        "\(displayName) isn’t a supported audiobook. Use M4B, M4A, MP3, or another audio file Storyteller accepts."
                }
        }
        return nil
    }

    public static func issues(in files: [StorytellerUploadRequestFile]) -> String? {
        guard !files.isEmpty else {
            return "Choose an ebook, an audiobook, or both."
        }
        var seen: Set<String> = []
        for file in files {
            if !seen.insert(file.id).inserted {
                return "Two selected \(file.role == .audiobook ? "audiobook" : "EPUB") files have the same name. Rename one and try again."
            }
            if let issue = issue(
                role: file.role,
                filename: file.filename,
                byteCount: file.byteCount,
                typeIdentifier: file.typeIdentifier,
            ) {
                return issue
            }
        }
        return nil
    }

    /// Content types for the Files / Open panel. Broader than a single extension filter so
    /// zip / `.audiobook` packages Storyteller accepts still appear; validation still rejects
    /// unsupported picks before any network call.
    public static func pickerContentTypes(for role: StorytellerUploadFileRole) -> [UTType] {
        switch role {
            case .ebook, .readaloud:
                return [.epub]
            case .audiobook:
                var types: [UTType] = [.mpeg4Audio, .mp3, .audio, .zip]
                if let m4b = UTType(filenameExtension: "m4b") {
                    types.append(m4b)
                }
                if let audiobook = UTType(filenameExtension: "audiobook") {
                    types.append(audiobook)
                }
                return types
        }
    }

    private static func acceptsEpub(filename: String, type: UTType?) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        if let type, contradictsBook(type) { return false }
        if type?.conforms(to: .epub) == true { return true }
        return ext == "epub"
    }

    private static func isPDF(filename: String, type: UTType?) -> Bool {
        if type?.conforms(to: .pdf) == true { return true }
        return (filename as NSString).pathExtension.lowercased() == "pdf"
    }

    private static func acceptsAudiobook(filename: String, type: UTType?) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        if let type, type.conforms(to: .pdf) || type.conforms(to: .plainText) || type.conforms(to: .image) {
            return false
        }
        if audiobookExtensions.contains(ext) { return true }
        guard let type else { return false }
        return type.conforms(to: .mp3) || type.conforms(to: .mpeg4Audio) || type.conforms(to: .audio)
            || type.conforms(to: .zip)
    }

    private static func contradictsBook(_ type: UTType) -> Bool {
        if type.conforms(to: .epub) { return false }
        return type.conforms(to: .pdf) || type.conforms(to: .plainText) || type.conforms(to: .image)
            || type.conforms(to: .audio)
    }
}

public enum StorytellerUploadDestinations {
    /// Storyteller rows need a confirmed `bookCreate` allow. `uploadPermittedSourceIDs` is the
    /// shared set, but its menu helper treats an unknown session as allowed. This sheet does not.
    /// Local folders keep their existing always-available behavior.
    public static func isListed(
        _ source: BookSourceRecord,
        uploadPermittedSourceIDs: Set<BookSourceID>,
        storytellerAccess: StorytellerBookCreateAccess,
    ) -> Bool {
        guard source.capabilities.canUploadBooks else { return false }
        switch source.kind {
            case .localFolder:
                return true
            case .storyteller:
                // Denied ids drop out of uploadPermittedSourceIDs. An unknown session
                // stays in that set for menus; this sheet still requires a confirmed allow.
                if !uploadPermittedSourceIDs.contains(source.id), storytellerAccess != .allowed {
                    return false
                }
                return storytellerAccess == .allowed
        }
    }
}

public protocol SecurityScopedFileAccess: Sendable {
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

public struct SystemSecurityScopedFileAccess: SecurityScopedFileAccess {
    public init() {}

    public func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    public func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

public struct StorytellerUploadStagingError: Error, LocalizedError {
    public init() {}

    public var errorDescription: String? {
        "Couldn’t prepare the file for upload."
    }
}

public enum StorytellerUploadInspection: Equatable, Sendable {
    case file(StorytellerUploadRequestFile)
    case rejected(String)
}

public enum StorytellerUploadFileStaging {
    /// Copies into a temp directory while security scope is held, then releases it.
    /// Does not modify `url`.
    public static func stage(
        _ url: URL,
        access: any SecurityScopedFileAccess = SystemSecurityScopedFileAccess(),
        fileManager: FileManager = .default,
    ) throws -> URL {
        let started = access.startAccessing(url)
        defer {
            if started { access.stopAccessing(url) }
        }
        let directory =
            fileManager.temporaryDirectory
            .appendingPathComponent("storyteller-upload", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let name = url.lastPathComponent.isEmpty ? "upload" : url.lastPathComponent
        let destination = directory.appendingPathComponent(name)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.copyItem(at: url, to: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: directory)
            throw StorytellerUploadStagingError()
        }
    }

    public static func removeStaged(_ url: URL, fileManager: FileManager = .default) {
        let directory = url.deletingLastPathComponent()
        if directory.deletingLastPathComponent().lastPathComponent == "storyteller-upload" {
            try? fileManager.removeItem(at: directory)
        } else {
            try? fileManager.removeItem(at: url)
        }
    }

    public static func inspect(
        role: StorytellerUploadFileRole,
        url: URL,
        access: any SecurityScopedFileAccess = SystemSecurityScopedFileAccess(),
    ) -> StorytellerUploadInspection {
        let started = access.startAccessing(url)
        defer {
            if started { access.stopAccessing(url) }
        }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isRegularFileKey])
        let isRegular = values?.isRegularFile ?? url.isFileURL
        guard isRegular else {
            return .rejected("\(url.lastPathComponent) isn’t a file Storyteller can import.")
        }
        let byteCount = Int64(values?.fileSize ?? 0)
        let typeIdentifier = values?.contentType?.identifier
        let filename = url.lastPathComponent
        if let issue = StorytellerUploadFileValidation.issue(
            role: role,
            filename: filename,
            byteCount: byteCount,
            typeIdentifier: typeIdentifier,
        ) {
            return .rejected(issue)
        }
        let format: StorytellerBookFormat =
            switch role {
                case .ebook: .ebook
                case .audiobook: .audiobook
                case .readaloud: .readaloud
            }
        return .file(
            StorytellerUploadRequestFile(
                format: format,
                filename: filename,
                byteCount: byteCount,
                contentType: StorytellerUploadFileValidation.contentType(for: role, filename: filename),
                typeIdentifier: typeIdentifier,
                fileURL: url,
            )
        )
    }
}

public protocol StorytellerUploadFileSystem: Sendable {
    func stage(_ url: URL) throws -> URL
    func removeStaged(_ url: URL)
}

public struct SystemStorytellerUploadFileSystem: StorytellerUploadFileSystem {
    public init() {}

    public func stage(_ url: URL) throws -> URL {
        try StorytellerUploadFileStaging.stage(url)
    }

    public func removeStaged(_ url: URL) {
        StorytellerUploadFileStaging.removeStaged(url)
    }
}

public protocol StorytellerBookUploadTransport: Sendable {
    func access(for sourceID: BookSourceID) async -> StorytellerBookCreateAccess
    func uploadFile(
        _ asset: StorytellerUploadAsset,
        bookID: BookID,
        directoryFileCount: Int,
        audioFileCount: Int,
        onProgress: @escaping @Sendable (Double) -> Void,
    ) async -> StorytellerFileUploadResult
    func attachReadaloud(
        _ asset: StorytellerUploadAsset,
        bookID: BookID,
        onProgress: @escaping @Sendable (Double) -> Void,
    ) async -> StorytellerFileUploadResult
    func snapshot(bookID: BookID) async -> StorytellerUploadedBookSnapshot?
    func startAlignment(bookID: BookID) async -> Bool
}

public struct LiveStorytellerBookUploadTransport: StorytellerBookUploadTransport {
    public init() {}

    public func access(for sourceID: BookSourceID) async -> StorytellerBookCreateAccess {
        await BookServiceActor.shared.storytellerBookCreateAccess(sourceID: sourceID)
    }

    public func uploadFile(
        _ asset: StorytellerUploadAsset,
        bookID: BookID,
        directoryFileCount: Int,
        audioFileCount: Int,
        onProgress: @escaping @Sendable (Double) -> Void,
    ) async -> StorytellerFileUploadResult {
        await BookServiceActor.shared.uploadStorytellerFile(
            asset,
            bookID: bookID,
            directoryFileCount: directoryFileCount,
            audioFileCount: audioFileCount,
            onProgress: onProgress,
        )
    }

    public func attachReadaloud(
        _ asset: StorytellerUploadAsset,
        bookID: BookID,
        onProgress: @escaping @Sendable (Double) -> Void,
    ) async -> StorytellerFileUploadResult {
        await BookServiceActor.shared.attachStorytellerReadaloud(
            asset,
            bookID: bookID,
            onProgress: onProgress,
        )
    }

    public func snapshot(bookID: BookID) async -> StorytellerUploadedBookSnapshot? {
        await BookServiceActor.shared.storytellerBookSnapshot(bookID: bookID)
    }

    public func startAlignment(bookID: BookID) async -> Bool {
        await BookServiceActor.shared.startAlignment(for: bookID)
    }
}

public enum StorytellerBookUploadState: Equatable, Sendable {
    case idle
    case preparing
    case uploading(fraction: Double)
    case uploadComplete
    case processing
    case bookVisible(BookID)
    case readaloudQueued(BookID)
    case readaloudProcessing(BookID)
    case readaloudReady(BookID)
    case stillProcessing(expectedBookID: BookID)
    case partial(message: String)
    case failed(message: String, bookID: BookID?)
    case cancelled(partialOnServer: Bool)
    case blocked(message: String)

    public var confirmedBookID: BookID? {
        switch self {
            case .bookVisible(let id), .readaloudQueued(let id), .readaloudProcessing(let id),
                .readaloudReady(let id):
                return id
            case .failed(_, let id):
                return id
            case .idle, .preparing, .uploading, .uploadComplete, .processing, .stillProcessing,
                .partial, .cancelled, .blocked:
                return nil
        }
    }

    public var statusTitle: String {
        switch self {
            case .idle:
                return "Ready"
            case .preparing:
                return "Preparing file"
            case .uploading:
                return "Uploading"
            case .uploadComplete:
                return "Upload complete"
            case .processing:
                return "Storyteller is processing"
            case .bookVisible:
                return "Book is in your library"
            case .readaloudQueued:
                return "Readaloud queued"
            case .readaloudProcessing:
                return "Readaloud processing"
            case .readaloudReady:
                return "Readaloud ready"
            case .stillProcessing:
                return "Storyteller is still processing"
            case .partial:
                return "Partial upload"
            case .failed:
                return "Failed"
            case .cancelled:
                return "Cancelled"
            case .blocked:
                return "Can’t upload"
        }
    }

    public var statusDetail: String {
        switch self {
            case .idle:
                return "Review the files, then upload them to Storyteller."
            case .preparing:
                return "Copying the file so it can upload without loading it all into memory."
            case .uploading(let fraction):
                return "\(Int((min(max(fraction, 0), 1)) * 100)) percent sent."
            case .uploadComplete:
                return "The bytes are on Storyteller. Checking that the book record exists."
            case .processing:
                return "Storyteller is importing the book. This is not the same as the upload finishing."
            case .bookVisible:
                return "Storyteller created the book. It will show up on your other devices after they refresh."
            case .readaloudQueued:
                return "The book is in your library. Read & Listen stays queued until Storyteller reports ALIGNED."
            case .readaloudProcessing:
                return "The book is in your library. Read & Listen is still processing and is not ready yet."
            case .readaloudReady:
                return "Storyteller reports this Read & Listen book as ALIGNED."
            case .stillProcessing:
                return
                    "Storyteller is still processing. The book should appear in your library after you refresh. The upload was not rolled back."
            case .partial(let message), .failed(let message, _), .blocked(let message):
                return message
            case .cancelled(let partial):
                if partial {
                    return
                        "Upload cancelled. Storyteller may already have part of this book. Files it already accepted were left in place."
                }
                return "Upload cancelled before Storyteller accepted any files."
        }
    }

    public var fraction: Double? {
        if case .uploading(let fraction) = self { return fraction }
        return nil
    }
}

public actor StorytellerBookUploadCoordinator {
    public private(set) var bookUUID: String?
    public private(set) var completedAssetIDs: Set<String> = []
    public private(set) var state: StorytellerBookUploadState = .idle
    private var submitting = false
    private let makeUUID: @Sendable () -> String

    public init(makeUUID: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.makeUUID = makeUUID
    }

    /// Drops the operation id. Only for an intentionally new book.
    public func resetForNewBook() {
        guard !submitting else { return }
        bookUUID = nil
        completedAssetIDs = []
        state = .idle
    }

    public static func defaultSleep(_ attempt: Int) async {
        let seconds = min(attempt + 1, 4)
        try? await Task.sleep(for: .seconds(seconds))
    }

    public func upload(
        sourceID: BookSourceID,
        isStoryteller: Bool,
        files: [StorytellerUploadRequestFile],
        transport: any StorytellerBookUploadTransport,
        fileSystem: any StorytellerUploadFileSystem,
        maxBookPolls: Int = 12,
        maxAlignmentPolls: Int = 10,
        sleep: @escaping @Sendable (Int) async -> Void = StorytellerBookUploadCoordinator.defaultSleep,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled },
        onState: @escaping @Sendable (StorytellerBookUploadState) -> Void = { _ in },
    ) async -> StorytellerBookUploadState {
        if submitting { return state }
        submitting = true
        defer { submitting = false }

        if let issue = StorytellerUploadFileValidation.issues(in: files) {
            return note(.blocked(message: issue), onState: onState)
        }

        if isStoryteller {
            switch await transport.access(for: sourceID) {
                case .allowed:
                    break
                case .denied:
                    return note(permissionBlock(denied: true), onState: onState)
                case .needsReconnect:
                    return note(permissionBlock(denied: false), onState: onState)
            }
        }

        if bookUUID == nil {
            bookUUID = makeUUID()
        }
        guard let bookUUID else {
            return note(.failed(message: "Couldn’t start the upload.", bookID: nil), onState: onState)
        }
        let bookID = BookID(sourceID: sourceID, uuid: bookUUID)

        if isCancelled() {
            return note(cancelledState(), onState: onState)
        }

        let pending = files.filter { !completedAssetIDs.contains($0.id) }
        var staged: [(StorytellerUploadRequestFile, URL)] = []
        defer {
            for item in staged {
                fileSystem.removeStaged(item.1)
            }
        }

        if !pending.isEmpty {
            _ = note(.preparing, onState: onState)
            for file in pending {
                if isCancelled() { return note(cancelledState(), onState: onState) }
                do {
                    staged.append((file, try fileSystem.stage(file.fileURL)))
                } catch {
                    return note(
                        stopped("Couldn’t prepare \(file.filename) for upload."),
                        onState: onState,
                    )
                }
            }
        }

        let phase1 = files.filter { $0.format == .ebook || $0.format == .audiobook }
        let audioCount = files.filter { $0.format == .audiobook }.count
        let directoryFileCount = max(phase1.count, 1)
        let totalBytes = files.reduce(Int64(0)) { $0 + max($1.byteCount, 0) }
        var finishedBytes = files.filter { completedAssetIDs.contains($0.id) }.reduce(Int64(0)) {
            $0 + max($1.byteCount, 0)
        }

        let phase1Pending = staged.filter { $0.0.format != .readaloud }
        for (file, url) in phase1Pending {
            if isCancelled() { return note(cancelledState(), onState: onState) }
            let fileBytes = file.byteCount
            let sentBefore = finishedBytes
            _ = note(
                .uploading(fraction: Self.progressFraction(sent: sentBefore, total: totalBytes)),
                onState: onState,
            )
            let asset = stagedAsset(file, url: url)
            let result = await transport.uploadFile(
                asset,
                bookID: bookID,
                directoryFileCount: directoryFileCount,
                audioFileCount: audioCount,
                onProgress: { progress in
                    onState(
                        .uploading(
                            fraction: Self.progressFraction(
                                sent: sentBefore + Self.scaledBytes(progress, of: fileBytes),
                                total: totalBytes,
                            )
                        )
                    )
                },
            )
            switch result.status {
                case .uploaded:
                    completedAssetIDs.insert(file.id)
                    finishedBytes += file.byteCount
                case .cancelled:
                    return note(cancelledState(), onState: onState)
                case .unauthorized:
                    return note(reconnectFailure(), onState: onState)
                case .failed:
                    return note(uploadFailure(file: file), onState: onState)
            }
        }

        if let readaloud = files.first(where: { $0.format == .readaloud }),
            !completedAssetIDs.contains(readaloud.id),
            let url = staged.first(where: { $0.0.id == readaloud.id })?.1
        {
            if isCancelled() { return note(cancelledState(), onState: onState) }
            let asset = stagedAsset(readaloud, url: url)
            let fileBytes = readaloud.byteCount
            let sentBefore = finishedBytes
            let result: StorytellerFileUploadResult
            let report: @Sendable (Double) -> Void = { progress in
                onState(
                    .uploading(
                        fraction: Self.progressFraction(
                            sent: sentBefore + Self.scaledBytes(progress, of: fileBytes),
                            total: totalBytes,
                        )
                    )
                )
            }
            if phase1.isEmpty {
                result = await transport.uploadFile(
                    asset,
                    bookID: bookID,
                    directoryFileCount: 1,
                    audioFileCount: 0,
                    onProgress: report,
                )
            } else {
                result = await transport.attachReadaloud(
                    asset,
                    bookID: bookID,
                    onProgress: report,
                )
            }
            switch result.status {
                case .uploaded:
                    completedAssetIDs.insert(readaloud.id)
                case .cancelled:
                    return note(cancelledState(), onState: onState)
                case .unauthorized:
                    return note(reconnectFailure(), onState: onState)
                case .failed:
                    return note(uploadFailure(file: readaloud), onState: onState)
            }
        }

        if isCancelled() { return note(cancelledState(), onState: onState) }

        if !pending.isEmpty {
            _ = note(.uploadComplete, onState: onState)
        }
        return await waitForLibrary(
            bookID: bookID,
            files: files,
            isStoryteller: isStoryteller,
            transport: transport,
            maxBookPolls: maxBookPolls,
            maxAlignmentPolls: maxAlignmentPolls,
            sleep: sleep,
            isCancelled: isCancelled,
            onState: onState,
        )
    }

    /// Poll Storyteller for a book that already finished transferring. Used by Check again.
    /// Does not re-upload bytes or mint a new UUID.
    public func checkLibrary(
        sourceID: BookSourceID,
        isStoryteller: Bool,
        files: [StorytellerUploadRequestFile],
        transport: any StorytellerBookUploadTransport,
        maxBookPolls: Int = 12,
        maxAlignmentPolls: Int = 10,
        sleep: @escaping @Sendable (Int) async -> Void = StorytellerBookUploadCoordinator.defaultSleep,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled },
        onState: @escaping @Sendable (StorytellerBookUploadState) -> Void = { _ in },
    ) async -> StorytellerBookUploadState {
        if submitting { return state }
        submitting = true
        defer { submitting = false }

        guard let bookUUID else {
            return note(
                .failed(message: "Nothing to check yet. Upload the book first.", bookID: nil),
                onState: onState,
            )
        }
        let bookID = BookID(sourceID: sourceID, uuid: bookUUID)
        if isCancelled() {
            return note(cancelledState(), onState: onState)
        }
        return await waitForLibrary(
            bookID: bookID,
            files: files,
            isStoryteller: isStoryteller,
            transport: transport,
            maxBookPolls: maxBookPolls,
            maxAlignmentPolls: maxAlignmentPolls,
            sleep: sleep,
            isCancelled: isCancelled,
            onState: onState,
        )
    }

    private func waitForLibrary(
        bookID: BookID,
        files: [StorytellerUploadRequestFile],
        isStoryteller: Bool,
        transport: any StorytellerBookUploadTransport,
        maxBookPolls: Int,
        maxAlignmentPolls: Int,
        sleep: @Sendable (Int) async -> Void,
        isCancelled: @Sendable () -> Bool,
        onState: @Sendable (StorytellerBookUploadState) -> Void,
    ) async -> StorytellerBookUploadState {
        _ = note(.processing, onState: onState)

        let shouldAlign = StorytellerUploadAlignment.shouldQueueReadaloud(
            isStoryteller: isStoryteller,
            hasEbook: files.contains { $0.format == .ebook },
            hasAudiobook: files.contains { $0.format == .audiobook },
            hasReadaloudFile: files.contains { $0.format == .readaloud },
        )

        for attempt in 0..<max(maxBookPolls, 1) {
            if isCancelled() { return note(cancelledState(), onState: onState) }
            if let snapshot = await transport.snapshot(bookID: bookID), snapshot.bookID == bookID {
                return await observeVisible(
                    snapshot,
                    shouldAlign: shouldAlign,
                    hasReadaloudFile: files.contains { $0.format == .readaloud },
                    transport: transport,
                    maxAlignmentPolls: maxAlignmentPolls,
                    sleep: sleep,
                    isCancelled: isCancelled,
                    onState: onState,
                )
            }
            if attempt + 1 < maxBookPolls {
                await sleep(attempt)
            }
        }
        return note(.stillProcessing(expectedBookID: bookID), onState: onState)
    }

    private func observeVisible(
        _ first: StorytellerUploadedBookSnapshot,
        shouldAlign: Bool,
        hasReadaloudFile: Bool,
        transport: any StorytellerBookUploadTransport,
        maxAlignmentPolls: Int,
        sleep: @Sendable (Int) async -> Void,
        isCancelled: @Sendable () -> Bool,
        onState: @Sendable (StorytellerBookUploadState) -> Void,
    ) async -> StorytellerBookUploadState {
        if !shouldAlign {
            return note(stateForVisibleBook(first, hasReadaloudFile: hasReadaloudFile), onState: onState)
        }
        guard await transport.startAlignment(bookID: first.bookID) else {
            return note(
                .failed(
                    message:
                        "Storyteller has the book, but Readaloud didn’t start. Open the book and try again from there. The files were not uploaded again.",
                    bookID: first.bookID,
                ),
                onState: onState,
            )
        }
        var latest = stateForAlignment(phase: .queued, bookID: first.bookID)
        _ = note(latest, onState: onState)
        for attempt in 0..<max(maxAlignmentPolls, 1) {
            if isCancelled() { return note(cancelledState(), onState: onState) }
            let snapshot = await transport.snapshot(bookID: first.bookID) ?? first
            let phase = StorytellerReadaloudUploadStatus.phase(snapshot.readaloudStatus)
            switch phase {
                case .ready:
                    return note(.readaloudReady(first.bookID), onState: onState)
                case .failed:
                    return note(
                        .failed(
                            message:
                                "Readaloud failed on Storyteller. The book is still in your library. Continue tries Readaloud again and does not create another book.",
                            bookID: first.bookID,
                        ),
                        onState: onState,
                    )
                case .queued, .absent:
                    latest = .readaloudQueued(first.bookID)
                    _ = note(latest, onState: onState)
                case .processing:
                    latest = .readaloudProcessing(first.bookID)
                    _ = note(latest, onState: onState)
            }
            if attempt + 1 < maxAlignmentPolls {
                await sleep(attempt)
            }
        }
        return latest
    }

    private func stateForVisibleBook(
        _ snapshot: StorytellerUploadedBookSnapshot,
        hasReadaloudFile: Bool,
    ) -> StorytellerBookUploadState {
        guard hasReadaloudFile else { return .bookVisible(snapshot.bookID) }
        switch StorytellerReadaloudUploadStatus.phase(snapshot.readaloudStatus) {
            case .ready:
                return .readaloudReady(snapshot.bookID)
            case .queued:
                return .readaloudQueued(snapshot.bookID)
            case .processing:
                return .readaloudProcessing(snapshot.bookID)
            case .failed:
                return .failed(
                    message: "Storyteller has the book, but the readaloud file did not finish importing.",
                    bookID: snapshot.bookID,
                )
            case .absent:
                return .bookVisible(snapshot.bookID)
        }
    }

    private func stateForAlignment(
        phase: StorytellerReadaloudUploadPhase,
        bookID: BookID,
    ) -> StorytellerBookUploadState {
        switch phase {
            case .ready: .readaloudReady(bookID)
            case .processing: .readaloudProcessing(bookID)
            case .queued, .absent, .failed: .readaloudQueued(bookID)
        }
    }

    private func stagedAsset(_ file: StorytellerUploadRequestFile, url: URL) -> StorytellerUploadAsset {
        StorytellerUploadAsset(
            format: file.format,
            filename: file.filename,
            fileURL: url,
            byteCount: file.byteCount,
            contentType: file.contentType,
            deleteFileWhenFinished: true,
        )
    }

    private func cancelledState() -> StorytellerBookUploadState {
        .cancelled(partialOnServer: !completedAssetIDs.isEmpty)
    }

    private func stopped(_ message: String) -> StorytellerBookUploadState {
        if completedAssetIDs.isEmpty {
            return .failed(message: message, bookID: nil)
        }
        return .partial(message: partialPrefix + message)
    }

    private func uploadFailure(file: StorytellerUploadRequestFile) -> StorytellerBookUploadState {
        stopped("Couldn’t upload \(file.filename). Your selected files are still here.")
    }

    private func reconnectFailure() -> StorytellerBookUploadState {
        stopped(
            "Storyteller asked you to reconnect or doesn’t allow this upload. Your selected files are still here."
        )
    }

    private func permissionBlock(denied: Bool) -> StorytellerBookUploadState {
        let message =
            denied
            ? "This Storyteller account can’t create books. Ask for upload permission, then try again. Your selected files are still here."
            : "Storyteller isn’t connected. Reconnect, then try again. Your selected files are still here."
        if completedAssetIDs.isEmpty {
            return .blocked(message: message)
        }
        return .partial(message: partialPrefix + message)
    }

    private nonisolated static func scaledBytes(_ fraction: Double, of total: Int64) -> Int64 {
        Int64((min(max(fraction, 0), 1) * Double(total)).rounded(.down))
    }

    private nonisolated static func progressFraction(sent: Int64, total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(max(Double(sent) / Double(total), 0), 1)
    }

    private var partialPrefix: String {
        "Storyteller may already have part of this book. Continue upload uses the same book and skips files that finished. "
    }

    @discardableResult
    private func note(
        _ next: StorytellerBookUploadState,
        onState: @Sendable (StorytellerBookUploadState) -> Void,
    ) -> StorytellerBookUploadState {
        state = next
        onState(next)
        return next
    }
}
