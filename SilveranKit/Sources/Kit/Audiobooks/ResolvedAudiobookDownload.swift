import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Offline copies of a matched provider audiobook. Still one work, one player.
// DownloadManager imports a Storyteller format into the library, so it is the wrong pipe.

public enum ResolvedAudiobookIdentity {
    public static func key(
        workID: String,
        provider: AudiobookProviderKind,
        providerItemID: String,
    ) -> String {
        "\(workID)|\(provider.rawValue)|\(providerItemID)"
    }

    public static func directory(
        root: URL,
        workID: String,
        provider: AudiobookProviderKind,
        providerItemID: String,
    ) -> URL {
        root
            .appendingPathComponent(encodedIdentityPathComponent(workID), isDirectory: true)
            .appendingPathComponent(provider.rawValue, isDirectory: true)
            .appendingPathComponent(encodedIdentityPathComponent(providerItemID), isDirectory: true)
    }
}

public enum ResolvedAudiobookDownloadPhase: Equatable, Sendable {
    case notDownloaded
    case preparing
    case downloading
    case downloaded
    case failed
    case partial
}

public struct ResolvedAudiobookDownloadSnapshot: Equatable, Sendable {
    public var phase: ResolvedAudiobookDownloadPhase
    public var completedChapters: Int
    public var totalChapters: Int
    public var fraction: Double?
    public var message: String?

    public init(
        phase: ResolvedAudiobookDownloadPhase,
        completedChapters: Int = 0,
        totalChapters: Int = 0,
        fraction: Double? = nil,
        message: String? = nil,
    ) {
        self.phase = phase
        self.completedChapters = completedChapters
        self.totalChapters = totalChapters
        self.fraction = fraction
        self.message = message
    }
}

public struct ResolvedAudiobookDownloadProgress: Equatable, Sendable {
    public var completedChapters: Int
    public var totalChapters: Int
    public var receivedBytes: Int64
    public var expectedBytes: Int64?

    public var fraction: Double? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        return min(max(Double(receivedBytes) / Double(expectedBytes), 0), 1)
    }
}

public struct ResolvedAudiobookManifest: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public var schema: Int
    public var workID: String
    public var provider: AudiobookProviderKind
    public var providerItemID: String
    public var title: String
    public var author: String
    public var narrator: String?
    public var language: String?
    public var artworkFileName: String?
    public var artworkURL: URL?
    public var downloadedAt: Date
    public var chapters: [Chapter]

    public struct Chapter: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var order: Int
        public var fileName: String
        public var duration: TimeInterval?
        public var remoteURL: URL
    }
}

public struct ResolvedAudiobookPlaybackChoice: Sendable {
    public var metadata: AudiobookMetadata
    public var artworkURL: URL?
    public var isLocal: Bool
}

public enum ResolvedAudiobookDownloadError: Error, Equatable, Sendable {
    case nothingToDownload
    case badResponse
    case chapterFailed(String)
}

public protocol ResolvedAudiobookFetching: Sendable {
    func contentLength(of url: URL) async -> Int64?
    func download(_ url: URL, to destination: URL) async throws
}

extension ResolvedAudiobookFetching {
    public func contentLength(of url: URL) async -> Int64? { nil }
}

public struct LiveResolvedAudiobookFetcher: ResolvedAudiobookFetching {
    public init() {}

    public func contentLength(of url: URL) async -> Int64? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "HEAD"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            http.expectedContentLength > 0
        else { return nil }
        return http.expectedContentLength
    }

    public func download(_ url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (temp, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: temp)
            throw ResolvedAudiobookDownloadError.badResponse
        }
        let folder = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        do {
            try FileManager.default.moveItem(at: temp, to: destination)
        } catch {
            try FileManager.default.copyItem(at: temp, to: destination)
            try? FileManager.default.removeItem(at: temp)
        }
    }

    private static let userAgent = "inkamp/audiobook-download"
}

public struct ResolvedAudiobookLibrary: Sendable {
    public static let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "mp4", "wav"]

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func itemDirectory(
        workID: String,
        provider: AudiobookProviderKind,
        providerItemID: String,
    ) -> URL {
        ResolvedAudiobookIdentity.directory(
            root: root,
            workID: workID,
            provider: provider,
            providerItemID: providerItemID,
        )
    }

    public func phase(
        workID: String,
        provider: AudiobookProviderKind,
        providerItemID: String,
    ) -> ResolvedAudiobookDownloadPhase {
        let directory = itemDirectory(
            workID: workID,
            provider: provider,
            providerItemID: providerItemID,
        )
        if let manifest = loadManifest(at: directory), isComplete(manifest, directory: directory) {
            return .downloaded
        }
        if directoryHasAudio(directory) { return .partial }
        return .notDownloaded
    }

    public func loadManifest(
        workID: String,
        provider: AudiobookProviderKind,
        providerItemID: String,
    ) -> ResolvedAudiobookManifest? {
        loadManifest(
            at: itemDirectory(workID: workID, provider: provider, providerItemID: providerItemID)
        )
    }

    public func playbackChoice(
        workID: String,
        audiobook: ResolvedAudiobook,
    ) -> ResolvedAudiobookPlaybackChoice? {
        let directory = itemDirectory(
            workID: workID,
            provider: audiobook.provider,
            providerItemID: audiobook.providerItemID,
        )
        guard let manifest = loadManifest(at: directory),
            manifest.workID == workID,
            manifest.provider == audiobook.provider,
            manifest.providerItemID == audiobook.providerItemID,
            isComplete(manifest, directory: directory)
        else { return nil }
        var files: [String: URL] = [:]
        for chapter in manifest.chapters {
            guard let url = safeChild(directory, chapter.fileName) else { return nil }
            files[chapter.id] = url
        }
        guard let metadata = audiobook.playbackMetadata(localFiles: files) else { return nil }
        return ResolvedAudiobookPlaybackChoice(
            metadata: metadata,
            artworkURL: artworkURL(manifest: manifest, directory: directory),
            isLocal: metadata.tracks.allSatisfy(\.url.isFileURL),
        )
    }

    public func offlineAudiobooks(workID: String) -> [ResolvedAudiobook] {
        let workDir = root.appendingPathComponent(
            encodedIdentityPathComponent(workID),
            isDirectory: true,
        )
        guard
            let providers = try? FileManager.default.contentsOfDirectory(
                at: workDir,
                includingPropertiesForKeys: nil,
            )
        else { return [] }
        var results: [ResolvedAudiobook] = []
        for providerDir in providers {
            guard AudiobookProviderKind(rawValue: providerDir.lastPathComponent) != nil else {
                continue
            }
            guard
                let items = try? FileManager.default.contentsOfDirectory(
                    at: providerDir,
                    includingPropertiesForKeys: nil,
                )
            else { continue }
            for itemDir in items {
                guard let manifest = loadManifest(at: itemDir),
                    manifest.workID == workID,
                    let audiobook = audiobook(from: manifest, directory: itemDir)
                else { continue }
                results.append(audiobook)
            }
        }
        return results.sorted { $0.providerItemID < $1.providerItemID }
    }

    public func remove(
        workID: String,
        provider: AudiobookProviderKind,
        providerItemID: String,
    ) throws {
        let directory = itemDirectory(
            workID: workID,
            provider: provider,
            providerItemID: providerItemID,
        ).standardizedFileURL
        guard isInsideRoot(directory) else { return }
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    func loadManifest(at directory: URL) -> ResolvedAudiobookManifest? {
        let url = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ResolvedAudiobookManifest.self, from: data)
    }

    func isComplete(_ manifest: ResolvedAudiobookManifest, directory: URL) -> Bool {
        guard manifest.schema == ResolvedAudiobookManifest.currentSchema, !manifest.chapters.isEmpty
        else { return false }
        for chapter in manifest.chapters {
            guard let url = safeChild(directory, chapter.fileName), isValidAudio(url) else {
                return false
            }
        }
        return true
    }

    func isValidAudio(_ url: URL) -> Bool {
        Self.audioExtensions.contains(url.pathExtension.lowercased()) && fileSize(url) > 0
    }

    func fileSize(_ url: URL) -> Int64 {
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
            let size = values.fileSize,
            size > 0
        {
            return Int64(size)
        }
        // resource values sometimes report 0 for a file that was just written
        if let number = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber {
            return number.int64Value
        }
        return 0
    }

    func safeChild(_ directory: URL, _ relative: String) -> URL? {
        if relative.isEmpty || relative.hasPrefix("/") || relative.contains("..") { return nil }
        let url = directory.appendingPathComponent(relative).standardizedFileURL
        let base = directory.standardizedFileURL.path
        guard url.path.hasPrefix(base + "/"), isInsideRoot(url) else { return nil }
        return url
    }

    func audiobook(
        from manifest: ResolvedAudiobookManifest,
        directory: URL,
    ) -> ResolvedAudiobook? {
        guard isComplete(manifest, directory: directory) else { return nil }
        let chapters = manifest.chapters.sorted { $0.order < $1.order }.compactMap {
            chapter -> ResolvedAudiobookChapter? in
            guard let url = safeChild(directory, chapter.fileName) else { return nil }
            return ResolvedAudiobookChapter(
                id: chapter.id,
                title: chapter.title,
                order: chapter.order,
                playbackURL: url,
                duration: chapter.duration,
            )
        }
        guard chapters.count == manifest.chapters.count else { return nil }
        let duration = chapters.compactMap(\.duration).reduce(0, +)
        return ResolvedAudiobook(
            provider: manifest.provider,
            providerItemID: manifest.providerItemID,
            title: manifest.title,
            author: manifest.author,
            narrator: manifest.narrator,
            language: manifest.language,
            duration: duration > 0 ? duration : nil,
            chapterCount: chapters.count,
            artworkURL: artworkURL(manifest: manifest, directory: directory),
            description: nil,
            sourceURL: nil,
            chapters: chapters,
            match: AudiobookMatchEvidence(
                confidence: .exact,
                reasons: ["Downloaded on this device"],
            ),
        )
    }

    private func artworkURL(manifest: ResolvedAudiobookManifest, directory: URL) -> URL? {
        if let name = manifest.artworkFileName,
            let file = safeChild(directory, name),
            fileSize(file) > 0
        {
            return file
        }
        return manifest.artworkURL
    }

    private func directoryHasAudio(_ directory: URL) -> Bool {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles],
            )
        else { return false }
        for case let url as URL in enumerator {
            let resolved = url.standardizedFileURL
            guard isInsideRoot(resolved) else { continue }
            if isValidAudio(resolved) { return true }
        }
        return false
    }

    private func isInsideRoot(_ url: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }
}

public enum ResolvedAudiobookDownloadJob {
    public static func run(
        audiobook: ResolvedAudiobook,
        workID: String,
        library: ResolvedAudiobookLibrary,
        fetcher: any ResolvedAudiobookFetching,
    ) -> AsyncThrowingStream<ResolvedAudiobookDownloadProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await perform(
                        audiobook: audiobook,
                        workID: workID,
                        library: library,
                        fetcher: fetcher,
                        emit: { continuation.yield($0) },
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func perform(
        audiobook: ResolvedAudiobook,
        workID: String,
        library: ResolvedAudiobookLibrary,
        fetcher: any ResolvedAudiobookFetching,
        emit: @Sendable (ResolvedAudiobookDownloadProgress) -> Void,
    ) async throws {
        let playable = audiobook.chapters.sorted { $0.order < $1.order }.filter { chapter in
            let scheme = chapter.playbackURL.scheme?.lowercased()
            return scheme == "https" || scheme == "http"
        }
        guard !playable.isEmpty else { throw ResolvedAudiobookDownloadError.nothingToDownload }

        let itemDir = library.itemDirectory(
            workID: workID,
            provider: audiobook.provider,
            providerItemID: audiobook.providerItemID,
        )
        let staging = itemDir.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(
            at: staging.appendingPathComponent("chapters", isDirectory: true),
            withIntermediateDirectories: true,
        )

        var expected: Int64 = 0
        var expectedKnown = true
        var planned: [(chapter: ResolvedAudiobookChapter, relative: String, staged: URL)] = []
        for (index, chapter) in playable.enumerated() {
            let ext = chapter.playbackURL.pathExtension.lowercased()
            guard ResolvedAudiobookLibrary.audioExtensions.contains(ext) else {
                throw ResolvedAudiobookDownloadError.chapterFailed(chapter.title)
            }
            let relative = String(format: "chapters/%03d.%@", index, ext)
            let staged = staging.appendingPathComponent(relative)
            planned.append((chapter, relative, staged))
            if library.isValidAudio(staged) || library.isValidAudio(published(itemDir, relative)) {
                continue
            }
            if let length = await fetcher.contentLength(of: chapter.playbackURL), length > 0 {
                expected += length
            } else {
                expectedKnown = false
            }
        }
        for item in planned {
            let existing = library.isValidAudio(item.staged) ? item.staged : published(itemDir, item.relative)
            if library.isValidAudio(existing) {
                expected += library.fileSize(existing)
            }
        }

        var received: Int64 = 0
        var completed = 0
        var saved: [ResolvedAudiobookManifest.Chapter] = []
        func emitProgress() {
            emit(
                ResolvedAudiobookDownloadProgress(
                    completedChapters: completed,
                    totalChapters: planned.count,
                    receivedBytes: received,
                    expectedBytes: expectedKnown ? expected : nil,
                )
            )
        }
        emitProgress()

        for item in planned {
            try Task.checkCancellation()
            let existing = library.isValidAudio(item.staged) ? item.staged : published(itemDir, item.relative)
            if library.isValidAudio(existing) {
                received += library.fileSize(existing)
                completed += 1
                saved.append(manifestChapter(item.chapter, relative: item.relative))
                emitProgress()
                continue
            }
            try? FileManager.default.removeItem(at: item.staged)
            do {
                try await fetcher.download(item.chapter.playbackURL, to: item.staged)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: item.staged)
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                try? FileManager.default.removeItem(at: item.staged)
                throw CancellationError()
            } catch {
                try? FileManager.default.removeItem(at: item.staged)
                throw ResolvedAudiobookDownloadError.chapterFailed(item.chapter.title)
            }
            guard library.isValidAudio(item.staged) else {
                try? FileManager.default.removeItem(at: item.staged)
                throw ResolvedAudiobookDownloadError.chapterFailed(item.chapter.title)
            }
            received += library.fileSize(item.staged)
            completed += 1
            saved.append(manifestChapter(item.chapter, relative: item.relative))
            emitProgress()
        }

        var artworkFileName: String?
        if let artworkURL = audiobook.artworkURL {
            let stagedArt = staging.appendingPathComponent("artwork.bin")
            do {
                try await fetcher.download(artworkURL, to: stagedArt)
                if library.fileSize(stagedArt) > 0 {
                    artworkFileName = "artwork.jpg"
                } else {
                    try? FileManager.default.removeItem(at: stagedArt)
                }
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: stagedArt)
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                try? FileManager.default.removeItem(at: stagedArt)
                throw CancellationError()
            } catch {
                try? FileManager.default.removeItem(at: stagedArt)
            }
        }

        let manifest = ResolvedAudiobookManifest(
            schema: ResolvedAudiobookManifest.currentSchema,
            workID: workID,
            provider: audiobook.provider,
            providerItemID: audiobook.providerItemID,
            title: audiobook.title,
            author: audiobook.author,
            narrator: audiobook.narrator,
            language: audiobook.language,
            artworkFileName: artworkFileName,
            artworkURL: audiobook.artworkURL,
            downloadedAt: Date(),
            chapters: saved,
        )
        try publish(manifest: manifest, staging: staging, itemDir: itemDir, library: library)
    }

    private static func published(_ itemDir: URL, _ relative: String) -> URL {
        itemDir.appendingPathComponent(relative)
    }

    private static func manifestChapter(
        _ chapter: ResolvedAudiobookChapter,
        relative: String,
    ) -> ResolvedAudiobookManifest.Chapter {
        ResolvedAudiobookManifest.Chapter(
            id: chapter.id,
            title: chapter.title,
            order: chapter.order,
            fileName: relative,
            duration: chapter.duration,
            remoteURL: chapter.playbackURL,
        )
    }

    private static func publish(
        manifest: ResolvedAudiobookManifest,
        staging: URL,
        itemDir: URL,
        library: ResolvedAudiobookLibrary,
    ) throws {
        let manager = FileManager.default
        let chaptersDest = itemDir.appendingPathComponent("chapters", isDirectory: true)
        try manager.createDirectory(at: chaptersDest, withIntermediateDirectories: true)
        let stagedChapters = staging.appendingPathComponent("chapters", isDirectory: true)
        if let files = try? manager.contentsOfDirectory(at: stagedChapters, includingPropertiesForKeys: nil) {
            for file in files where library.isValidAudio(file) {
                let dest = chaptersDest.appendingPathComponent(file.lastPathComponent)
                if manager.fileExists(atPath: dest.path) {
                    try manager.removeItem(at: dest)
                }
                try manager.moveItem(at: file, to: dest)
            }
        }
        if manifest.artworkFileName != nil {
            let from = staging.appendingPathComponent("artwork.bin")
            let dest = itemDir.appendingPathComponent("artwork.jpg")
            if manager.fileExists(atPath: from.path) {
                if manager.fileExists(atPath: dest.path) {
                    try manager.removeItem(at: dest)
                }
                try? manager.moveItem(at: from, to: dest)
            }
        }
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: itemDir.appendingPathComponent("manifest.json"), options: .atomic)
        try? manager.removeItem(at: staging)
    }
}

public actor ResolvedAudiobookDownloads {
    public static let shared = ResolvedAudiobookDownloads(root: nil, fetcher: LiveResolvedAudiobookFetcher())

    private let rootOverride: URL?
    private let fetcher: any ResolvedAudiobookFetching
    private var tasks: [String: Task<Void, Never>] = [:]
    private var live: [String: ResolvedAudiobookDownloadSnapshot] = [:]
    private var listeners: [UUID: Listener] = [:]

    public init(root: URL?, fetcher: any ResolvedAudiobookFetching) {
        self.rootOverride = root
        self.fetcher = fetcher
    }

    public func updates(
        for workID: String
    ) -> AsyncStream<[String: ResolvedAudiobookDownloadSnapshot]> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.register(id, workID: workID, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unregister(id) }
            }
        }
    }

    public func start(workID: String, audiobook: ResolvedAudiobook) {
        let key = ResolvedAudiobookIdentity.key(
            workID: workID,
            provider: audiobook.provider,
            providerItemID: audiobook.providerItemID,
        )
        guard tasks[key] == nil else { return }
        let library = self.library
        if library.phase(
            workID: workID,
            provider: audiobook.provider,
            providerItemID: audiobook.providerItemID,
        ) == .downloaded {
            live[key] = ResolvedAudiobookDownloadSnapshot(phase: .downloaded)
            broadcast(workID)
            return
        }
        live[key] = ResolvedAudiobookDownloadSnapshot(phase: .preparing)
        broadcast(workID)
        let fetcher = self.fetcher
        tasks[key] = Task {
            let stream = ResolvedAudiobookDownloadJob.run(
                audiobook: audiobook,
                workID: workID,
                library: library,
                fetcher: fetcher,
            )
            do {
                for try await progress in stream {
                    await self.record(
                        key,
                        workID: workID,
                        snapshot: ResolvedAudiobookDownloadSnapshot(
                            phase: .downloading,
                            completedChapters: progress.completedChapters,
                            totalChapters: progress.totalChapters,
                            fraction: progress.fraction,
                        ),
                    )
                }
                // AsyncThrowingStream can finish without throwing when the consumer Task
                // is cancelled; do not treat that as a successful download.
                try Task.checkCancellation()
                await self.record(
                    key,
                    workID: workID,
                    snapshot: ResolvedAudiobookDownloadSnapshot(phase: .downloaded),
                    finished: true,
                )
            } catch is CancellationError {
                await self.recordResting(key, workID: workID, audiobook: audiobook)
            } catch {
                await self.record(
                    key,
                    workID: workID,
                    snapshot: ResolvedAudiobookDownloadSnapshot(
                        phase: .failed,
                        message: errorMessage(error),
                    ),
                    finished: true,
                )
            }
        }
    }

    public func cancel(workID: String, audiobook: ResolvedAudiobook) {
        let key = ResolvedAudiobookIdentity.key(
            workID: workID,
            provider: audiobook.provider,
            providerItemID: audiobook.providerItemID,
        )
        tasks[key]?.cancel()
    }

    public func remove(workID: String, audiobook: ResolvedAudiobook) throws {
        let key = ResolvedAudiobookIdentity.key(
            workID: workID,
            provider: audiobook.provider,
            providerItemID: audiobook.providerItemID,
        )
        tasks[key]?.cancel()
        tasks[key] = nil
        try library.remove(
            workID: workID,
            provider: audiobook.provider,
            providerItemID: audiobook.providerItemID,
        )
        live[key] = ResolvedAudiobookDownloadSnapshot(phase: .notDownloaded)
        broadcast(workID)
    }

    public func playback(
        workID: String,
        audiobook: ResolvedAudiobook,
    ) -> ResolvedAudiobookPlaybackChoice? {
        library.playbackChoice(workID: workID, audiobook: audiobook)
    }

    public func offlineResults(workID: String) -> [ResolvedAudiobook] {
        library.offlineAudiobooks(workID: workID)
    }

    private var library: ResolvedAudiobookLibrary {
        ResolvedAudiobookLibrary(root: rootOverride ?? Self.defaultRoot())
    }

    private static func defaultRoot() -> URL {
        SilveranPlatform.applicationSupportDirectory()
            .appendingPathComponent("ResolvedAudiobooks", isDirectory: true)
    }

    private struct Listener {
        var workID: String
        var continuation: AsyncStream<[String: ResolvedAudiobookDownloadSnapshot]>.Continuation
    }

    private func register(
        _ id: UUID,
        workID: String,
        continuation: AsyncStream<[String: ResolvedAudiobookDownloadSnapshot]>.Continuation,
    ) {
        listeners[id] = Listener(workID: workID, continuation: continuation)
        continuation.yield(states(for: workID))
    }

    private func unregister(_ id: UUID) {
        listeners[id] = nil
    }

    private func record(
        _ key: String,
        workID: String,
        snapshot: ResolvedAudiobookDownloadSnapshot,
        finished: Bool = false,
    ) {
        live[key] = snapshot
        if finished { tasks[key] = nil }
        broadcast(workID)
    }

    private func recordResting(_ key: String, workID: String, audiobook: ResolvedAudiobook) {
        let phase = library.phase(
            workID: workID,
            provider: audiobook.provider,
            providerItemID: audiobook.providerItemID,
        )
        live[key] = ResolvedAudiobookDownloadSnapshot(phase: phase)
        tasks[key] = nil
        broadcast(workID)
    }

    private func states(for workID: String) -> [String: ResolvedAudiobookDownloadSnapshot] {
        var result: [String: ResolvedAudiobookDownloadSnapshot] = [:]
        let prefix = workID + "|"
        let workDir = library.root.appendingPathComponent(
            encodedIdentityPathComponent(workID),
            isDirectory: true,
        )
        if let providers = try? FileManager.default.contentsOfDirectory(
            at: workDir,
            includingPropertiesForKeys: nil,
        ) {
            for providerDir in providers {
                guard let provider = AudiobookProviderKind(rawValue: providerDir.lastPathComponent)
                else { continue }
                guard
                    let items = try? FileManager.default.contentsOfDirectory(
                        at: providerDir,
                        includingPropertiesForKeys: nil,
                    )
                else { continue }
                for itemDir in items {
                    guard let itemID = decodedIdentityPathComponent(itemDir.lastPathComponent) else {
                        continue
                    }
                    let key = ResolvedAudiobookIdentity.key(
                        workID: workID,
                        provider: provider,
                        providerItemID: itemID,
                    )
                    result[key] = ResolvedAudiobookDownloadSnapshot(
                        phase: library.phase(
                            workID: workID,
                            provider: provider,
                            providerItemID: itemID,
                        )
                    )
                }
            }
        }
        for (key, snapshot) in live where key.hasPrefix(prefix) {
            result[key] = snapshot
        }
        return result
    }

    private func broadcast(_ workID: String) {
        let snapshot = states(for: workID)
        for listener in listeners.values where listener.workID == workID {
            listener.continuation.yield(snapshot)
        }
    }

    private func errorMessage(_ error: Error) -> String {
        guard let download = error as? ResolvedAudiobookDownloadError else {
            return "The download didn't finish."
        }
        switch download {
            case .nothingToDownload:
                return "This audiobook has no downloadable chapters."
            case .badResponse:
                return "The download server rejected a chapter."
            case .chapterFailed(let title):
                return "Couldn't download \(title)."
        }
    }
}
