import Foundation
import Testing
import UniformTypeIdentifiers

@testable import SilveranKit

@Suite("Storyteller book upload")
struct StorytellerBookUploadTests {
    @Test func unauthorizedDestinationsAreExcluded() {
        let story = source("story", kind: .storyteller, canUpload: true)
        let folder = source("folder", kind: .localFolder, canUpload: true)
        let locked = source("locked", kind: .storyteller, canUpload: false)

        #expect(
            !StorytellerUploadDestinations.isListed(
                story,
                uploadPermittedSourceIDs: [story.id],
                storytellerAccess: .denied,
            )
        )
        #expect(
            !StorytellerUploadDestinations.isListed(
                story,
                uploadPermittedSourceIDs: [story.id],
                storytellerAccess: .needsReconnect,
            )
        )
        #expect(
            StorytellerUploadDestinations.isListed(
                story,
                uploadPermittedSourceIDs: [],
                storytellerAccess: .allowed,
            )
        )
        #expect(
            !StorytellerUploadDestinations.isListed(
                story,
                uploadPermittedSourceIDs: [],
                storytellerAccess: .denied,
            )
        )
        #expect(
            StorytellerUploadDestinations.isListed(
                folder,
                uploadPermittedSourceIDs: [],
                storytellerAccess: .denied,
            )
        )
        #expect(
            !StorytellerUploadDestinations.isListed(
                locked,
                uploadPermittedSourceIDs: [locked.id],
                storytellerAccess: .allowed,
            )
        )
    }

    @Test func deniedOrExpiredPermissionDoesNotUploadOrAllocate() async {
        let transport = FakeTransport()
        await transport.setAccess(.denied)
        let files = FakeFileSystem()
        let ids = UUIDSource()
        let coordinator = StorytellerBookUploadCoordinator(makeUUID: ids.next)
        let state = await coordinator.upload(
            sourceID: "story",
            isStoryteller: true,
            files: [file("Book.epub", format: .ebook)],
            transport: transport,
            fileSystem: files,
            sleep: { _ in },
        )
        #expect(blocked(state))
        #expect(await coordinator.bookUUID == nil)
        #expect(await transport.accessCount == 1)
        #expect(await transport.uploadedIDs.isEmpty)
        #expect(await files.stageCount == 0)

        await transport.setAccess(.needsReconnect)
        let again = await coordinator.upload(
            sourceID: "story",
            isStoryteller: true,
            files: [file("Book.epub", format: .ebook)],
            transport: transport,
            fileSystem: files,
            sleep: { _ in },
        )
        #expect(blocked(again))
        #expect(await coordinator.bookUUID == nil)
        #expect(await transport.uploadedIDs.isEmpty)
    }

    @Test func retryKeepsTheSameBookUUIDAndSkipsFinishedFiles() async {
        let transport = FakeTransport()
        let first = file("01.mp3", format: .audiobook)
        let second = file("02.mp3", format: .audiobook)
        await transport.fail(second.id)
        let files = FakeFileSystem()
        let ids = UUIDSource()
        let coordinator = StorytellerBookUploadCoordinator(makeUUID: ids.next)
        let partial = await upload(
            coordinator,
            files: [first, second],
            transport: transport,
            fileSystem: files,
        )
        #expect(isPartial(partial))
        let uuid = await coordinator.bookUUID
        #expect(uuid != nil)
        #expect(await coordinator.completedAssetIDs == [first.id])
        #expect(await transport.uploadedIDs == [first.id, second.id])

        await transport.fail(nil)
        let bookID = BookID(sourceID: "story", uuid: uuid ?? "")
        await transport.enqueue(StorytellerUploadedBookSnapshot(bookID: bookID, readaloudStatus: nil))
        let finished = await upload(
            coordinator,
            files: [first, second],
            transport: transport,
            fileSystem: files,
        )
        #expect(finished == .bookVisible(bookID))
        #expect(await coordinator.bookUUID == uuid)
        #expect(ids.count == 1)
        #expect(await transport.uploadedIDs == [first.id, second.id, second.id])
        #expect(await coordinator.completedAssetIDs == [first.id, second.id])
    }

    @Test func doubleSubmissionCreatesOneOperation() async {
        let transport = FakeTransport()
        await transport.setDelayAccess(true)
        let ids = UUIDSource()
        let coordinator = StorytellerBookUploadCoordinator(makeUUID: ids.next)
        let book = file("Book.epub", format: .ebook)
        async let first = upload(coordinator, files: [book], transport: transport, fileSystem: FakeFileSystem())
        async let second = upload(coordinator, files: [book], transport: transport, fileSystem: FakeFileSystem())
        for _ in 0..<40 {
            if await transport.accessCount >= 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        try? await Task.sleep(for: .milliseconds(20))
        await transport.releaseAccess()
        _ = await (first, second)
        #expect(ids.count == 1)
        #expect(await transport.accessCount == 1)
        #expect(await transport.uploadedIDs == [book.id])
    }

    @Test func cancellationStopsLaterFilesAndCleansStaging() async {
        let transport = FakeTransport()
        let gate = CancelGate()
        await transport.arm { gate.cancel = true }
        let files = FakeFileSystem()
        let first = file("01.m4b", format: .audiobook)
        let second = file("02.m4b", format: .audiobook)
        let coordinator = StorytellerBookUploadCoordinator()
        let state = await upload(
            coordinator,
            files: [first, second],
            transport: transport,
            fileSystem: files,
            isCancelled: { gate.cancel },
        )
        #expect(state == .cancelled(partialOnServer: true))
        #expect(await transport.uploadedIDs == [first.id])
        #expect(await coordinator.completedAssetIDs == [first.id])
        #expect(await files.removed.count == await files.staged.count)
        #expect(await files.staged.count == 2)
    }

    @Test func stagingBalancesSecurityScopeAndLeavesTheOriginal() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("Book.epub")
        let payload = Data("not-the-real-epub".utf8)
        try payload.write(to: original)
        let spy = AccessSpy(allow: true)
        let staged = try StorytellerUploadFileStaging.stage(original, access: spy)
        #expect(spy.starts == 1)
        #expect(spy.stops == 1)
        #expect(try Data(contentsOf: staged) == payload)
        #expect(try Data(contentsOf: original) == payload)
        StorytellerUploadFileStaging.removeStaged(staged)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(FileManager.default.fileExists(atPath: original.path))

        let refused = AccessSpy(allow: false)
        let unscoped = try StorytellerUploadFileStaging.stage(original, access: refused)
        #expect(refused.starts == 1)
        #expect(refused.stops == 0)
        StorytellerUploadFileStaging.removeStaged(unscoped)
        #expect(FileManager.default.fileExists(atPath: original.path))
    }

    @Test func failedStageStillReleasesScope() {
        let spy = AccessSpy(allow: true)
        let missing = URL(fileURLWithPath: "/tmp/storyteller-upload-missing-\(UUID().uuidString).epub")
        #expect(throws: StorytellerUploadStagingError.self) {
            try StorytellerUploadFileStaging.stage(missing, access: spy)
        }
        #expect(spy.starts == 1)
        #expect(spy.stops == 1)
    }

    @Test func unsupportedAndEmptyFilesNeverTouchTheNetwork() async {
        #expect(
            StorytellerUploadFileValidation.issue(
                role: .ebook,
                filename: "Empty.epub",
                byteCount: 0,
                typeIdentifier: UTType.epub.identifier,
            ) != nil
        )
        let pdfIssue = StorytellerUploadFileValidation.issue(
            role: .ebook,
            filename: "Notes.pdf",
            byteCount: 20,
            typeIdentifier: UTType.pdf.identifier,
        )
        #expect(pdfIssue != nil)
        #expect(pdfIssue?.contains("PDF") == true)
        #expect(
            StorytellerUploadFileValidation.issue(
                role: .audiobook,
                filename: "Talk.m4b",
                byteCount: 20,
                typeIdentifier: nil,
            ) == nil
        )
        #expect(
            StorytellerUploadFileValidation.issue(
                role: .audiobook,
                filename: "Book.zip",
                byteCount: 40,
                typeIdentifier: UTType.zip.identifier,
            ) == nil
        )
        let transport = FakeTransport()
        let coordinator = StorytellerBookUploadCoordinator(makeUUID: { "should-not-run" })
        let state = await upload(
            coordinator,
            files: [file("Empty.epub", format: .ebook, bytes: 0)],
            transport: transport,
            fileSystem: FakeFileSystem(),
        )
        #expect(blocked(state))
        #expect(await transport.accessCount == 0)
        #expect(await transport.uploadedIDs.isEmpty)
        #expect(await coordinator.bookUUID == nil)
    }

    @Test func pickerTypesIncludeZipAndAudiobookPackages() {
        let ebook = StorytellerUploadFileValidation.pickerContentTypes(for: .ebook)
        #expect(ebook.contains(.epub))
        let audio = StorytellerUploadFileValidation.pickerContentTypes(for: .audiobook)
        #expect(audio.contains(.mpeg4Audio))
        #expect(audio.contains(.mp3))
        #expect(audio.contains(.audio))
        #expect(audio.contains(.zip))
    }

    @Test func checkLibraryPollsWithoutReuploading() async {
        let transport = FakeTransport()
        let log = StateLog()
        let ids = UUIDSource(value: "check-book")
        let coordinator = StorytellerBookUploadCoordinator(makeUUID: ids.next)
        let book = file("Book.epub", format: .ebook)
        let expected = BookID(sourceID: "story", uuid: "check-book")
        let first = await upload(
            coordinator,
            files: [book],
            transport: transport,
            fileSystem: FakeFileSystem(),
            maxBookPolls: 1,
            onState: { log.add($0) },
        )
        #expect(first == .stillProcessing(expectedBookID: expected))
        #expect(await transport.uploadedIDs == [book.id])

        await transport.enqueue(StorytellerUploadedBookSnapshot(bookID: expected, readaloudStatus: nil))
        let checked = await coordinator.checkLibrary(
            sourceID: "story",
            isStoryteller: true,
            files: [book],
            transport: transport,
            maxBookPolls: 2,
            sleep: { _ in },
            onState: { log.add($0) },
        )
        #expect(checked == .bookVisible(expected))
        #expect(await transport.uploadedIDs == [book.id])
        #expect(!log.states.suffix(4).contains(where: {
            if case .uploading = $0 { return true }
            return false
        }))
        #expect(log.states.contains(.processing))
        #expect(ids.count == 1)
    }

    @Test func checkLibraryWithoutPriorUploadFailsClosed() async {
        let coordinator = StorytellerBookUploadCoordinator(makeUUID: { "unused" })
        let transport = FakeTransport()
        let state = await coordinator.checkLibrary(
            sourceID: "story",
            isStoryteller: true,
            files: [file("Book.epub", format: .ebook)],
            transport: transport,
            sleep: { _ in },
        )
        #expect(
            state == .failed(message: "Nothing to check yet. Upload the book first.", bookID: nil)
        )
        #expect(await transport.uploadedIDs.isEmpty)
        #expect(await transport.accessCount == 0)
    }

    @Test func uploadCompletionIsNotVisibilityAndTimeoutStaysPending() async {
        let transport = FakeTransport()
        let log = StateLog()
        let ids = UUIDSource(value: "pending-book")
        let coordinator = StorytellerBookUploadCoordinator(makeUUID: ids.next)
        let state = await upload(
            coordinator,
            files: [file("Book.epub", format: .ebook)],
            transport: transport,
            fileSystem: FakeFileSystem(),
            maxBookPolls: 2,
            onState: { log.add($0) },
        )
        let expected = BookID(sourceID: "story", uuid: "pending-book")
        #expect(state == .stillProcessing(expectedBookID: expected))
        #expect(state.confirmedBookID == nil)
        #expect(log.states.contains(.uploadComplete))
        #expect(log.states.contains(.processing))
        #expect(!log.states.contains(.bookVisible(expected)))
    }

    @Test func visibleRecordIsSuccessWithThatBookID() async {
        let ids = UUIDSource(value: "visible-book")
        let expected = BookID(sourceID: "story", uuid: "visible-book")
        let transport = FakeTransport()
        await transport.enqueue(
            StorytellerUploadedBookSnapshot(bookID: BookID(sourceID: "story", uuid: "other"), readaloudStatus: nil)
        )
        await transport.enqueue(StorytellerUploadedBookSnapshot(bookID: expected, readaloudStatus: nil))
        let coordinator = StorytellerBookUploadCoordinator(makeUUID: ids.next)
        let state = await upload(
            coordinator,
            files: [file("Book.epub", format: .ebook)],
            transport: transport,
            fileSystem: FakeFileSystem(),
            maxBookPolls: 2,
        )
        #expect(state == .bookVisible(expected))
        #expect(state.confirmedBookID == expected)
    }

    @Test func ebookOnlyAudiobookOnlyAndBothKeepAlignmentRules() async {
        let ebook = file("Book.epub", format: .ebook)
        let audio = file("Book.m4b", format: .audiobook)
        let readaloud = file("Aligned.epub", format: .readaloud)

        let ebookOnly = await runFormats([ebook], status: nil)
        #expect(ebookOnly.state == .bookVisible(ebookOnly.bookID))
        #expect(await ebookOnly.transport.uploadedIDs == [ebook.id])
        #expect(await ebookOnly.transport.alignmentStarts == 0)
        #expect(await ebookOnly.transport.fileBacked)

        let audioOnly = await runFormats([audio], status: nil)
        #expect(audioOnly.state == .bookVisible(audioOnly.bookID))
        #expect(await audioOnly.transport.uploadedIDs == [audio.id])
        #expect(await audioOnly.transport.alignmentStarts == 0)

        let both = await runFormats([ebook, audio], status: "ALIGNED")
        #expect(both.state == .readaloudReady(both.bookID))
        #expect(await both.transport.alignmentStarts == 1)
        #expect(await both.transport.attachedIDs.isEmpty)

        let withFile = await runFormats([ebook, audio, readaloud], status: "PROCESSING")
        #expect(withFile.state == .readaloudProcessing(withFile.bookID))
        #expect(await withFile.transport.attachedIDs == [readaloud.id])
        #expect(await withFile.transport.alignmentStarts == 0)

        #expect(
            StorytellerUploadAlignment.shouldQueueReadaloud(
                isStoryteller: true,
                hasEbook: true,
                hasAudiobook: true,
                hasReadaloudFile: false,
            )
        )
        #expect(
            !StorytellerUploadAlignment.shouldQueueReadaloud(
                isStoryteller: true,
                hasEbook: true,
                hasAudiobook: true,
                hasReadaloudFile: true,
            )
        )
        #expect(
            !StorytellerUploadAlignment.shouldQueueReadaloud(
                isStoryteller: false,
                hasEbook: true,
                hasAudiobook: true,
                hasReadaloudFile: false,
            )
        )
        #expect(StorytellerReadaloudUploadStatus.phase("ALIGNED") == .ready)
        #expect(StorytellerReadaloudUploadStatus.phase("aligned") == .ready)
        #expect(StorytellerReadaloudUploadStatus.phase("PROCESSING") == .processing)
        #expect(StorytellerReadaloudUploadStatus.phase("QUEUED") == .queued)
        #expect(StorytellerReadaloudUploadStatus.phase("ERROR") == .failed)
        #expect(StorytellerReadaloudUploadStatus.phase(nil) == .absent)
    }

    @Test func alignmentTimeoutDoesNotClaimReady() async {
        let result = await runFormats(
            [file("Book.epub", format: .ebook), file("Book.mp3", format: .audiobook)],
            status: "QUEUED",
            alignmentPolls: 2,
        )
        #expect(result.state == .readaloudQueued(result.bookID))
        if case .readaloudReady = result.state {
            Issue.record("queued readaloud was reported ready")
        }
    }

    @Test func inMemoryAssetsStayAvailableAndFileAssetsKeepTheirURL() {
        let memory = StorytellerUploadAsset(
            format: .ebook,
            filename: "Book.epub",
            data: Data([1, 2, 3]),
        )
        #expect(memory.fileURL == nil)
        #expect(memory.payloadByteCount == 3)
        #expect(memory.withFilename("Other.epub").data == Data([1, 2, 3]))

        let url = URL(fileURLWithPath: "/tmp/Book.m4b")
        let backed = StorytellerUploadAsset(
            format: .audiobook,
            filename: "Book.m4b",
            fileURL: url,
            byteCount: 80,
        )
        let renamed = backed.withFilename("Other.m4b")
        #expect(backed.data.isEmpty)
        #expect(renamed.fileURL == url)
        #expect(renamed.payloadByteCount == 80)
        #expect(renamed.uploadIdentity == "audiobook|Other.m4b")
    }

    private func upload(
        _ coordinator: StorytellerBookUploadCoordinator,
        files: [StorytellerUploadRequestFile],
        transport: FakeTransport,
        fileSystem: FakeFileSystem,
        maxBookPolls: Int = 3,
        maxAlignmentPolls: Int = 2,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        onState: @escaping @Sendable (StorytellerBookUploadState) -> Void = { _ in },
    ) async -> StorytellerBookUploadState {
        await coordinator.upload(
            sourceID: "story",
            isStoryteller: true,
            files: files,
            transport: transport,
            fileSystem: fileSystem,
            maxBookPolls: maxBookPolls,
            maxAlignmentPolls: maxAlignmentPolls,
            sleep: { _ in },
            isCancelled: isCancelled,
            onState: onState,
        )
    }

    private func runFormats(
        _ files: [StorytellerUploadRequestFile],
        status: String?,
        alignmentPolls: Int = 1,
    ) async -> FormatRun {
        let ids = UUIDSource(value: UUID().uuidString)
        let bookID = BookID(sourceID: "story", uuid: ids.value)
        let transport = FakeTransport()
        await transport.enqueue(StorytellerUploadedBookSnapshot(bookID: bookID, readaloudStatus: status))
        let coordinator = StorytellerBookUploadCoordinator(makeUUID: ids.next)
        let state = await upload(
            coordinator,
            files: files,
            transport: transport,
            fileSystem: FakeFileSystem(),
            maxAlignmentPolls: alignmentPolls,
        )
        return FormatRun(state: state, bookID: bookID, transport: transport)
    }

    private func source(_ id: String, kind: BookSourceKind, canUpload: Bool) -> BookSourceRecord {
        BookSourceRecord(
            id: id,
            name: id,
            kind: kind,
            capabilities: BookSourceCapabilities(
                canEditMetadata: false,
                canManageMedia: false,
                canProcessReadaloud: false,
                canUploadBooks: canUpload,
                canSyncProgress: false,
            ),
        )
    }

    private func file(
        _ name: String,
        format: StorytellerBookFormat,
        bytes: Int64 = 32,
    ) -> StorytellerUploadRequestFile {
        let role: StorytellerUploadFileRole =
            switch format {
                case .ebook: .ebook
                case .audiobook: .audiobook
                case .readaloud: .readaloud
            }
        return StorytellerUploadRequestFile(
            format: format,
            filename: name,
            byteCount: bytes,
            contentType: StorytellerUploadFileValidation.contentType(for: role, filename: name),
            typeIdentifier: format == .ebook || format == .readaloud ? UTType.epub.identifier : nil,
            fileURL: URL(fileURLWithPath: "/tmp/\(name)"),
        )
    }

    private func blocked(_ state: StorytellerBookUploadState) -> Bool {
        if case .blocked = state { return true }
        return false
    }

    private func isPartial(_ state: StorytellerBookUploadState) -> Bool {
        if case .partial = state { return true }
        return false
    }
}

private struct FormatRun {
    let state: StorytellerBookUploadState
    let bookID: BookID
    let transport: FakeTransport
}

private final class UUIDSource: @unchecked Sendable {
    private let lock = NSLock()
    private var issued = 0
    let value: String

    init(value: String = "book-1") {
        self.value = value
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return issued
    }

    var next: @Sendable () -> String {
        { [self] in
            self.lock.lock()
            self.issued += 1
            self.lock.unlock()
            return self.value
        }
    }
}

private final class CancelGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var cancel: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}

private final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [StorytellerBookUploadState] = []
    var states: [StorytellerBookUploadState] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func add(_ state: StorytellerBookUploadState) {
        lock.lock()
        stored.append(state)
        lock.unlock()
    }
}

private final class AccessSpy: SecurityScopedFileAccess, @unchecked Sendable {
    let allow: Bool
    private let lock = NSLock()
    private(set) var starts = 0
    private(set) var stops = 0

    init(allow: Bool) {
        self.allow = allow
    }

    func startAccessing(_ url: URL) -> Bool {
        lock.lock()
        starts += 1
        lock.unlock()
        return allow
    }

    func stopAccessing(_ url: URL) {
        lock.lock()
        stops += 1
        lock.unlock()
    }
}

private actor FakeTransport: StorytellerBookUploadTransport {
    private var accessValue = StorytellerBookCreateAccess.allowed
    private(set) var accessCount = 0
    private(set) var uploadedIDs: [String] = []
    private(set) var attachedIDs: [String] = []
    private(set) var alignmentStarts = 0
    private(set) var fileBacked = true
    private var failingID: String?
    private var snapshots: [StorytellerUploadedBookSnapshot?] = []
    private var delayAccess = false
    private var accessGate: CheckedContinuation<Void, Never>?
    private var onUpload: (@Sendable () -> Void)?

    func setAccess(_ access: StorytellerBookCreateAccess) {
        accessValue = access
    }

    func setDelayAccess(_ delay: Bool) {
        delayAccess = delay
    }

    func fail(_ id: String?) {
        failingID = id
    }

    func enqueue(_ snapshot: StorytellerUploadedBookSnapshot?) {
        snapshots.append(snapshot)
    }

    func releaseAccess() {
        accessGate?.resume()
        accessGate = nil
    }

    func arm(_ hook: @escaping @Sendable () -> Void) {
        onUpload = hook
    }

    func access(for sourceID: BookSourceID) async -> StorytellerBookCreateAccess {
        accessCount += 1
        if delayAccess {
            await withCheckedContinuation { continuation in
                accessGate = continuation
            }
        }
        return accessValue
    }

    func uploadFile(
        _ asset: StorytellerUploadAsset,
        bookID: BookID,
        directoryFileCount: Int,
        audioFileCount: Int,
        onProgress: @escaping @Sendable (Double) -> Void,
    ) async -> StorytellerFileUploadResult {
        if asset.fileURL == nil || !asset.data.isEmpty {
            fileBacked = false
        }
        uploadedIDs.append(asset.uploadIdentity)
        onUpload?()
        let status: StorytellerFileUploadResult.Status =
            asset.uploadIdentity == failingID ? .failed : .uploaded
        return StorytellerFileUploadResult(identity: asset.uploadIdentity, status: status)
    }

    func attachReadaloud(
        _ asset: StorytellerUploadAsset,
        bookID: BookID,
        onProgress: @escaping @Sendable (Double) -> Void,
    ) async -> StorytellerFileUploadResult {
        attachedIDs.append(asset.uploadIdentity)
        return StorytellerFileUploadResult(identity: asset.uploadIdentity, status: .uploaded)
    }

    func snapshot(bookID: BookID) async -> StorytellerUploadedBookSnapshot? {
        guard !snapshots.isEmpty else { return nil }
        return snapshots.removeFirst()
    }

    func startAlignment(bookID: BookID) async -> Bool {
        alignmentStarts += 1
        return true
    }
}

private actor FakeFileSystem: StorytellerUploadFileSystem {
    private(set) var stageCount = 0
    private(set) var staged: [URL] = []
    private(set) var removed: [URL] = []

    func stage(_ url: URL) throws -> URL {
        stageCount += 1
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
            "storyteller-upload-test-\(stageCount)-\(url.lastPathComponent)"
        )
        staged.append(destination)
        return destination
    }

    func removeStaged(_ url: URL) {
        removed.append(url)
    }
}
