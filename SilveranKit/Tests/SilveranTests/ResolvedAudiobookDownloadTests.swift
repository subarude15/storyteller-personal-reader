import Foundation
import Testing

@testable import SilveranKit

@Suite("Resolved audiobook offline downloads")
struct ResolvedAudiobookDownloadTests {
    private let workID = "work/1"

    private func audiobook(
        chapters: [ResolvedAudiobookChapter]? = nil,
    ) -> ResolvedAudiobook {
        ResolvedAudiobook(
            provider: .librivox,
            providerItemID: "52",
            title: "Pride and Prejudice",
            author: "Jane Austen",
            narrator: "Jane Smith",
            language: "English",
            duration: 320,
            chapterCount: 2,
            artworkURL: URL(string: "https://archive.org/cover.jpg"),
            description: nil,
            sourceURL: nil,
            chapters: chapters ?? [
                ResolvedAudiobookChapter(
                    id: "1",
                    title: "Chapter 01",
                    order: 1,
                    playbackURL: URL(string: "https://archive.org/01.mp3")!,
                    duration: 180,
                ),
                ResolvedAudiobookChapter(
                    id: "2",
                    title: "Chapter 02",
                    order: 2,
                    playbackURL: URL(string: "https://archive.org/02.mp3")!,
                    duration: 140,
                ),
            ],
            match: AudiobookMatchEvidence(confidence: .exact, reasons: ["Title matches"]),
        )
    }

    private func library() throws -> (URL, ResolvedAudiobookLibrary) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolved-audiobooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, ResolvedAudiobookLibrary(root: root))
    }

    private func run(
        _ book: ResolvedAudiobook,
        library: ResolvedAudiobookLibrary,
        fetcher: any ResolvedAudiobookFetching,
    ) async throws -> [ResolvedAudiobookDownloadProgress] {
        var progress: [ResolvedAudiobookDownloadProgress] = []
        let stream = ResolvedAudiobookDownloadJob.run(
            audiobook: book,
            workID: workID,
            library: library,
            fetcher: fetcher,
        )
        for try await item in stream {
            progress.append(item)
        }
        return progress
    }

    @Test func storageIdentityIgnoresTitleAndStaysInsideRoot() {
        let root = URL(fileURLWithPath: "/tmp/resolved-root", isDirectory: true)
        let first = ResolvedAudiobookIdentity.directory(
            root: root,
            workID: "work/1",
            provider: .librivox,
            providerItemID: "52",
        )
        let sameIDsDifferentTitle = ResolvedAudiobookIdentity.directory(
            root: root,
            workID: "work/1",
            provider: .librivox,
            providerItemID: "52",
        )
        let otherItem = ResolvedAudiobookIdentity.directory(
            root: root,
            workID: "work/1",
            provider: .librivox,
            providerItemID: "99",
        )
        #expect(first == sameIDsDifferentTitle)
        #expect(first != otherItem)
        #expect(first.standardizedFileURL.path.hasPrefix(root.path + "/"))
        #expect(!first.pathComponents.contains(".."))
        #expect(decodedIdentityPathComponent(encodedIdentityPathComponent("work/1")) == "work/1")
        #expect(decodedIdentityPathComponent(first.lastPathComponent) == "52")
    }

    @Test func manifestRoundTripAndLocalPlayback() async throws {
        let (root, store) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let book = audiobook()
        let fetcher = ScriptedFetcher(payloads: [
            "https://archive.org/01.mp3": Data("chapter-one".utf8),
            "https://archive.org/02.mp3": Data("chapter-two".utf8),
        ])
        let progress = try await run(book, library: store, fetcher: fetcher)
        #expect(progress.last?.fraction == 1)
        #expect(store.phase(workID: workID, provider: .librivox, providerItemID: "52") == .downloaded)

        let manifest = try #require(store.loadManifest(workID: workID, provider: .librivox, providerItemID: "52"))
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(ResolvedAudiobookManifest.self, from: data)
        #expect(decoded.schema == 1)
        #expect(decoded.workID == workID)
        #expect(decoded.provider == .librivox)
        #expect(decoded.providerItemID == "52")
        #expect(decoded.title == "Pride and Prejudice")
        #expect(decoded.author == "Jane Austen")
        #expect(decoded.narrator == "Jane Smith")
        #expect(decoded.chapters.map(\.title) == ["Chapter 01", "Chapter 02"])
        #expect(decoded.chapters.map(\.fileName) == ["chapters/000.mp3", "chapters/001.mp3"])
        #expect(decoded.artworkFileName == nil)

        let remote = try #require(book.playbackMetadata())
        let choice = try #require(store.playbackChoice(workID: workID, audiobook: book))
        #expect(choice.isLocal)
        #expect(choice.metadata.tracks.allSatisfy(\.url.isFileURL))
        #expect(choice.metadata.chapters.map(\.title) == remote.chapters.map(\.title))
        #expect(choice.metadata.chapters.map(\.startTime) == remote.chapters.map(\.startTime))
        #expect(choice.metadata.tracks.map(\.startTime) == remote.tracks.map(\.startTime))
        #expect(book.globalTime(chapterIndex: 1, position: 12) == remote.chapters[1].startTime + 12)

        let chapter = store.itemDirectory(workID: workID, provider: .librivox, providerItemID: "52")
            .appendingPathComponent("chapters/001.mp3")
        try FileManager.default.removeItem(at: chapter)
        #expect(store.phase(workID: workID, provider: .librivox, providerItemID: "52") == .partial)
        #expect(store.playbackChoice(workID: workID, audiobook: book)?.isLocal == nil)
        let streamed = try #require(book.playbackMetadata())
        #expect(streamed.tracks.allSatisfy { !$0.url.isFileURL })
    }

    @Test func failedChapterDoesNotPublishAndRetrySkipsFinishedFiles() async throws {
        let (root, store) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let book = audiobook()
        let fetcher = ScriptedFetcher(payloads: [
            "https://archive.org/01.mp3": Data("chapter-one".utf8),
            "https://archive.org/02.mp3": Data("chapter-two".utf8),
        ])
        fetcher.fail.insert("https://archive.org/02.mp3")
        await #expect(throws: ResolvedAudiobookDownloadError.chapterFailed("Chapter 02")) {
            _ = try await run(book, library: store, fetcher: fetcher)
        }
        #expect(store.loadManifest(workID: workID, provider: .librivox, providerItemID: "52") == nil)
        #expect(store.phase(workID: workID, provider: .librivox, providerItemID: "52") == .partial)
        let staged = store.itemDirectory(workID: workID, provider: .librivox, providerItemID: "52")
            .appendingPathComponent("staging/chapters/000.mp3")
        #expect(FileManager.default.fileExists(atPath: staged.path))

        fetcher.fail.remove("https://archive.org/02.mp3")
        _ = try await run(book, library: store, fetcher: fetcher)
        #expect(store.phase(workID: workID, provider: .librivox, providerItemID: "52") == .downloaded)
        let calls = fetcher.audioCalls
        #expect(calls.filter { $0.contains("01.mp3") }.count == 1)
        #expect(calls.filter { $0.contains("02.mp3") }.count == 2)
    }

    @Test func cancelLeavesNoManifest() async throws {
        let (root, store) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            let stream = ResolvedAudiobookDownloadJob.run(
                audiobook: audiobook(),
                workID: workID,
                library: store,
                fetcher: HangingFetcher(),
            )
            for try await _ in stream {}
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let outcome = await task.result
        #expect(throws: CancellationError.self) {
            try outcome.get()
        }
        #expect(store.loadManifest(workID: workID, provider: .librivox, providerItemID: "52") == nil)
        #expect(store.phase(workID: workID, provider: .librivox, providerItemID: "52") != .downloaded)
    }

    @Test func removeDeletesOnlyThatCopyAndKeepsResume() async throws {
        let (root, store) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let book = audiobook()
        let fetcher = ScriptedFetcher(payloads: [
            "https://archive.org/01.mp3": Data("a".utf8),
            "https://archive.org/02.mp3": Data("b".utf8),
        ])
        _ = try await run(book, library: store, fetcher: fetcher)

        let sibling = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sibling)
        let other = store.itemDirectory(workID: workID, provider: .librivox, providerItemID: "99")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let otherFile = other.appendingPathComponent("stay.txt")
        try Data("stay".utf8).write(to: otherFile)

        let defaults = UserDefaults(suiteName: "resolved-audiobook-download-tests")!
        defaults.removePersistentDomain(forName: "resolved-audiobook-download-tests")
        let resumes = AudiobookResumeStore(defaults: defaults, key: "resume")
        let saved = AudiobookResumeState(
            workID: workID,
            provider: .librivox,
            providerItemID: "52",
            chapterIndex: 1,
            chapterPosition: 12,
            completed: false,
            updatedAt: Date(),
        )
        resumes.save(saved)
        #expect(
            saved.key
                == ResolvedAudiobookIdentity.key(
                    workID: workID,
                    provider: .librivox,
                    providerItemID: "52",
                )
        )

        try store.remove(workID: workID, provider: .librivox, providerItemID: "52")
        #expect(store.loadManifest(workID: workID, provider: .librivox, providerItemID: "52") == nil)
        #expect(store.phase(workID: workID, provider: .librivox, providerItemID: "52") == .notDownloaded)
        #expect(FileManager.default.fileExists(atPath: sibling.path))
        #expect(FileManager.default.fileExists(atPath: otherFile.path))
        let loaded = resumes.state(workID: workID, provider: .librivox, providerItemID: "52")
        #expect(loaded?.chapterIndex == 1)
        #expect(loaded?.chapterPosition == 12)
        #expect(loaded?.key == saved.key)
        #expect(store.offlineAudiobooks(workID: workID).isEmpty)
    }

    @Test func rejectsUnplayableChapterWithoutPublishing() async throws {
        let (root, store) = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        let book = audiobook(chapters: [
            ResolvedAudiobookChapter(
                id: "1",
                title: "Notes",
                order: 1,
                playbackURL: URL(string: "https://archive.org/notes.txt")!,
                duration: 10,
            )
        ])
        await #expect(throws: ResolvedAudiobookDownloadError.self) {
            _ = try await run(book, library: store, fetcher: ScriptedFetcher(payloads: [:]))
        }
        #expect(store.loadManifest(workID: workID, provider: .librivox, providerItemID: "52") == nil)
    }
}

private final class ScriptedFetcher: ResolvedAudiobookFetching, @unchecked Sendable {
    var payloads: [String: Data]
    var fail = Set<String>()
    private let lock = NSLock()
    private var calls: [String] = []

    init(payloads: [String: Data]) {
        self.payloads = payloads
    }

    var audioCalls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func contentLength(of url: URL) async -> Int64? {
        guard let data = payloads[url.absoluteString], !data.isEmpty else { return nil }
        return Int64(data.count)
    }

    func download(_ url: URL, to destination: URL) async throws {
        lock.lock()
        calls.append(url.absoluteString)
        lock.unlock()
        if fail.contains(url.absoluteString) {
            throw ResolvedAudiobookDownloadError.badResponse
        }
        guard let data = payloads[url.absoluteString], !data.isEmpty else {
            throw ResolvedAudiobookDownloadError.badResponse
        }
        try data.write(to: destination)
    }
}

private struct HangingFetcher: ResolvedAudiobookFetching {
    func download(_ url: URL, to destination: URL) async throws {
        try await Task.sleep(for: .seconds(30))
        try Data("x".utf8).write(to: destination)
    }
}
