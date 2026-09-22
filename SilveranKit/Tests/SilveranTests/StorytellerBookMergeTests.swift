import Foundation
import Testing

@testable import SilveranKit

@Suite("Storyteller book merge")
struct StorytellerBookMergeTests {
    private let ebookUUID = "11111111-1111-1111-1111-111111111111"
    private let audioUUID = "22222222-2222-2222-2222-222222222222"

    @Test func eligibilityRequiresSameSourceEbookAndAudiobookUUIDs() {
        let ebook = mergeBook(uuid: ebookUUID, title: "The Devils", ebook: true)
        let audio = mergeBook(
            uuid: audioUUID,
            title: "The Devils: The Devils, Book 1",
            audiobook: true,
        )
        #expect(StorytellerBookMergeEligibility.isEligible(ebook, audio))

        let otherSource = mergeBook(
            uuid: audioUUID,
            title: "The Devils",
            audiobook: true,
            source: "other-server",
        )
        #expect(!StorytellerBookMergeEligibility.isEligible(ebook, otherSource))

        let twoEbooks = mergeBook(uuid: audioUUID, title: "The Devils", ebook: true)
        #expect(!StorytellerBookMergeEligibility.isEligible(ebook, twoEbooks))

        let twoAudio = mergeBook(uuid: ebookUUID, title: "The Devils", audiobook: true)
        let audio2 = mergeBook(uuid: audioUUID, title: "The Devils", audiobook: true)
        #expect(!StorytellerBookMergeEligibility.isEligible(twoAudio, audio2))

        let missingUUID = mergeBook(uuid: "ebook", title: "The Devils", ebook: true)
        #expect(!StorytellerBookMergeEligibility.isEligible(missingUUID, audio))
    }

    @Test func payloadKeepsEbookMetadataAndAudiobookNarrators() throws {
        let ebook = mergeBook(
            uuid: ebookUUID,
            title: "The Devils",
            authors: ["Joe Abercrombie"],
            language: "en",
            year: "2025",
            ebook: true,
            tags: ["Fantasy"],
        )
        let audio = mergeBook(
            uuid: audioUUID,
            title: "The Devils: The Devils, Book 1",
            authors: ["Joe Abercrombie"],
            narrators: ["Steven Pacey"],
            audiobook: true,
            tags: ["Audio"],
        )
        let request = StorytellerBookMergePayload.request(ebook: ebook, audiobook: audio)
        #expect(request.from == [ebookUUID, audioUUID])
        #expect(request.update.title == "The Devils")
        #expect(request.update.language == "en")
        #expect(request.update.publicationDate == "2025-01-01")
        #expect(request.relations.tags?.sorted() == ["Audio", "Fantasy"])
        let roles = Dictionary(
            uniqueKeysWithValues: (request.relations.creators ?? []).map {
                ($0.role ?? "", $0.name)
            }
        )
        #expect(roles["aut"] == "Joe Abercrombie")
        #expect(roles["nrt"] == "Steven Pacey")

        let data = try StorytellerBookMergePayload.encode(request)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"from\""))
        #expect(json.contains(ebookUUID))
        #expect(json.contains(audioUUID))
        #expect(!json.contains("\"rating\""))
        #expect(!json.contains("\"collections\""))
        #expect(!json.contains("\"series\""))
        #expect(!json.contains("ebook"))
        #expect(!json.contains("audiobook"))
    }

    @Test func preferredProgressUsesNewestTimestamp() {
        let ebookID = BookID(sourceID: "server", uuid: ebookUUID)
        let audioID = BookID(sourceID: "server", uuid: audioUUID)
        let older = BookProgress(
            locator: locator(progress: 0.9),
            timestamp: 10,
            source: .server,
        )
        let newer = BookProgress(
            locator: locator(progress: 0.2),
            timestamp: 20,
            source: .pendingSync,
        )
        let winner = StorytellerBookMergeProgress.preferred(from: [
            ebookID: older,
            audioID: newer,
        ])
        #expect(winner?.timestamp == 20)
        #expect(winner?.progressFraction == 0.2)
    }

    @Test func mergePostsBothUUIDsWithAuthAndDecodesSurvivor() async throws {
        MergeStubURLProtocol.reset()
        MergeStubURLProtocol.bookJSON = mergedBookJSON(uuid: ebookUUID)
        let actor = makeActor()
        let configured = await actor.configureCredentials(
            baseURL: "https://storyteller.test",
            lanURL: "",
            username: "reader",
            password: "secret",
        )
        #expect(configured)

        let ebook = mergeBook(uuid: ebookUUID, title: "The Devils", ebook: true)
        let audio = mergeBook(uuid: audioUUID, title: "The Devils", audiobook: true)
        let result = await actor.mergeBooks(
            StorytellerBookMergePayload.request(ebook: ebook, audiobook: audio)
        )
        guard case .success(let book) = result else {
            Issue.record("expected merge success, got \(result)")
            return
        }
        #expect(book.uuid == ebookUUID)
        #expect(book.sourceID == "server")

        let merge = try #require(
            MergeStubURLProtocol.requests.last { $0.url?.path.hasSuffix("/books/merge") == true }
        )
        #expect(merge.httpMethod == "POST")
        #expect(merge.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        let body = try #require(merge.httpBody ?? MergeStubURLProtocol.lastBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let from = try #require(json["from"] as? [String])
        #expect(Set(from) == [ebookUUID, audioUUID])
        #expect(MergeStubURLProtocol.requests.contains { $0.url?.path.hasSuffix("/token") == true })
    }

    @Test func mergeFailureLeavesLinkProgressAndSkipsAlignment() async {
        let ebook = mergeBook(uuid: ebookUUID, title: "The Devils", ebook: true)
        let audio = mergeBook(uuid: audioUUID, title: "The Devils", audiobook: true)
        let existing = BookFormatLink(
            members: [ebook.id, audio.id],
            primary: ebook.id,
            updatedAt: Date(timeIntervalSince1970: 5),
            removed: false,
        )
        let cache = FormatLinkCacheDouble()
        await cache.save(
            sourceID: "server",
            document: BookFormatLinkDocument(updatedAt: existing.updatedAt, links: [existing]),
        )
        let transport = FormatLinkTransportDouble()
        await transport.setMerge(.failure(.serverRejected))
        let state = MergeStateDouble()
        await state.setSnapshotProgress([
            ebook.id: BookProgress(
                locator: locator(progress: 0.4),
                timestamp: 40,
                source: .pendingSync,
            )
        ])
        let coordinator = BookFormatLinkCoordinator(
            cache: cache,
            transport: transport,
            mergeState: state,
        )
        let outcome = await coordinator.merge(
            sourceID: "server",
            current: ebook,
            other: audio,
            library: [ebook, audio],
        )
        #expect(outcome == .failed(.serverRejected))
        #expect(await transport.mergeCount == 1)
        #expect(await transport.alignmentStarts.isEmpty)
        #expect(await state.applyCount == 0)
        #expect(await cache.load(sourceID: "server").activeLinks.count == 1)
        #expect(await transport.pushCount == 0)
    }

    @Test func successfulMergeRemovesAbsorbedLinkAndKeepsSurvivor() async {
        let ebook = mergeBook(uuid: ebookUUID, title: "The Devils", ebook: true)
        let audio = mergeBook(uuid: audioUUID, title: "The Devils", audiobook: true)
        let existing = BookFormatLink(
            members: [ebook.id, audio.id],
            primary: ebook.id,
            updatedAt: Date(timeIntervalSince1970: 5),
            removed: false,
        )
        let cache = FormatLinkCacheDouble()
        await cache.save(
            sourceID: "server",
            document: BookFormatLinkDocument(updatedAt: existing.updatedAt, links: [existing]),
        )
        let transport = FormatLinkTransportDouble()
        await transport.setMerge(
            .success(mergeBook(uuid: ebookUUID, title: "The Devils", ebook: true, audiobook: true))
        )
        let state = MergeStateDouble()
        let coordinator = BookFormatLinkCoordinator(
            cache: cache,
            transport: transport,
            mergeState: state,
        )
        let outcome = await coordinator.merge(
            sourceID: "server",
            current: ebook,
            other: audio,
            library: [ebook, audio],
        )
        guard case .merged(let document, let status) = outcome else {
            Issue.record("expected merged, got \(outcome)")
            return
        }
        #expect(status.survivingBookID.uuid == ebookUUID)
        #expect(status.absorbedBookIDs.map(\.uuid) == [audioUUID])
        #expect(document.activeLinks.isEmpty)
        #expect(document.links.contains { $0.removed && $0.id == existing.id })
        #expect(await cache.load(sourceID: "server").activeLinks.isEmpty)
        #expect(await transport.mergeRequests.first?.from == [ebookUUID, audioUUID])
    }

    @Test func successfulMergeKeepsLocalTombstoneWhenLinkPushFails() async {
        let ebook = mergeBook(uuid: ebookUUID, title: "The Devils", ebook: true)
        let audio = mergeBook(uuid: audioUUID, title: "The Devils", audiobook: true)
        let existing = BookFormatLink(
            members: [ebook.id, audio.id],
            primary: ebook.id,
            updatedAt: Date(timeIntervalSince1970: 5),
            removed: false,
        )
        let cache = FormatLinkCacheDouble()
        await cache.save(
            sourceID: "server",
            document: BookFormatLinkDocument(updatedAt: existing.updatedAt, links: [existing]),
        )
        let transport = FormatLinkTransportDouble()
        await transport.setMerge(
            .success(mergeBook(uuid: ebookUUID, title: "The Devils", ebook: true, audiobook: true))
        )
        await transport.setPush(.failure(reason: "collection write failed"))
        let coordinator = BookFormatLinkCoordinator(
            cache: cache,
            transport: transport,
            mergeState: MergeStateDouble(),
        )
        let outcome = await coordinator.merge(
            sourceID: "server",
            current: ebook,
            other: audio,
            library: [ebook, audio],
        )
        guard case .merged(let document, _) = outcome else {
            Issue.record("expected merged, got \(outcome)")
            return
        }
        #expect(document.activeLinks.isEmpty)
        #expect(await cache.load(sourceID: "server").activeLinks.isEmpty)
        #expect(await transport.pushCount == 1)
        #expect(await transport.mergeCount == 1)
    }

    @Test func stateMigrationAppliesSnapshotOnlyAfterSuccess() async {
        let ebook = mergeBook(uuid: ebookUUID, title: "The Devils", ebook: true)
        let audio = mergeBook(uuid: audioUUID, title: "The Devils", audiobook: true)
        let transport = FormatLinkTransportDouble()
        await transport.setMerge(
            .success(mergeBook(uuid: ebookUUID, title: "The Devils", ebook: true, audiobook: true))
        )
        let state = MergeStateDouble()
        let progress = BookProgress(
            locator: locator(progress: 0.55),
            timestamp: 99,
            source: .pendingSync,
        )
        await state.setSnapshotProgress([ebook.id: progress])
        await state.setSnapshotHighlights([
            audio.id: [
                Highlight(
                    bookID: audio.id,
                    locator: locator(progress: 0.1),
                    text: "bookmark",
                    color: nil,
                )
            ]
        ])
        let coordinator = BookFormatLinkCoordinator(
            cache: FormatLinkCacheDouble(),
            transport: transport,
            mergeState: state,
        )
        let outcome = await coordinator.merge(
            sourceID: "server",
            current: ebook,
            other: audio,
            library: [ebook, audio],
        )
        guard case .merged(_, let status) = outcome else {
            Issue.record("expected merged, got \(outcome)")
            return
        }
        #expect(await state.snapshotCount == 1)
        #expect(await state.applyCount == 1)
        #expect(await state.appliedSurviving?.uuid == ebookUUID)
        #expect(await state.appliedSnapshot?.progress[ebook.id]?.timestamp == 99)
        #expect(await state.appliedSnapshot?.highlights[audio.id]?.first?.text == "bookmark")
        #expect(status.migrationWarning == nil)
    }

    @Test func alignmentUsesSurvivorOnlyAfterMergeSuccess() async {
        let ebook = mergeBook(uuid: ebookUUID, title: "The Devils", ebook: true)
        let audio = mergeBook(uuid: audioUUID, title: "The Devils", audiobook: true)
        let transport = FormatLinkTransportDouble()
        await transport.setMerge(
            .success(mergeBook(uuid: ebookUUID, title: "The Devils", ebook: true, audiobook: true))
        )
        let coordinator = BookFormatLinkCoordinator(
            cache: FormatLinkCacheDouble(),
            transport: transport,
            mergeState: MergeStateDouble(),
        )
        let outcome = await coordinator.merge(
            sourceID: "server",
            current: audio,
            other: ebook,
            library: [ebook, audio],
        )
        guard case .merged(_, let status) = outcome else {
            Issue.record("expected merged, got \(outcome)")
            return
        }
        #expect(status.alignmentStarted)
        #expect(status.detail == "Read & Listen is processing in Storyteller.")
        #expect(await transport.alignmentStarts.map(\.0.uuid) == [ebookUUID])
        #expect(await transport.alignmentStarts.map(\.1) == [.none])
    }

    @Test func alignmentFailureDoesNotFailTheMerge() async {
        let ebook = mergeBook(uuid: ebookUUID, title: "The Devils", ebook: true)
        let audio = mergeBook(uuid: audioUUID, title: "The Devils", audiobook: true)
        let transport = FormatLinkTransportDouble()
        await transport.setMerge(
            .success(mergeBook(uuid: ebookUUID, title: "The Devils", ebook: true, audiobook: true))
        )
        await transport.setAlignmentResult(false)
        let coordinator = BookFormatLinkCoordinator(
            cache: FormatLinkCacheDouble(),
            transport: transport,
            mergeState: MergeStateDouble(),
        )
        let outcome = await coordinator.merge(
            sourceID: "server",
            current: ebook,
            other: audio,
            library: [ebook, audio],
        )
        guard case .merged(_, let status) = outcome else {
            Issue.record("expected merged, got \(outcome)")
            return
        }
        #expect(status.alignmentStarted == false)
        #expect(
            status.detail
                == "Books merged, but Read & Listen did not start. You can retry alignment from the book."
        )
        #expect(await transport.mergeCount == 1)
    }

    @Test func existingLinkFormatsPathDoesNotMerge() async {
        let ebook = mergeBook(uuid: ebookUUID, title: "The Devils", ebook: true)
        let audio = mergeBook(uuid: audioUUID, title: "The Devils", audiobook: true)
        let transport = FormatLinkTransportDouble()
        let coordinator = BookFormatLinkCoordinator(
            cache: FormatLinkCacheDouble(),
            transport: transport,
            mergeState: MergeStateDouble(),
        )
        let outcome = await coordinator.link(
            sourceID: "server",
            primary: ebook,
            other: audio,
            library: [ebook, audio],
            startAlignment: false,
        )
        guard case .linked(let document, _) = outcome else {
            Issue.record("expected linked, got \(outcome)")
            return
        }
        #expect(document.activeLinks.count == 1)
        #expect(Set(document.activeLinks[0].members) == Set([ebook.id, audio.id]))
        #expect(await transport.mergeCount == 0)
        #expect(await transport.alignmentStarts.isEmpty)
    }

    @Test func deniedMergePermissionDoesNotCallMerge() async {
        let ebook = mergeBook(uuid: ebookUUID, title: "The Devils", ebook: true)
        let audio = mergeBook(uuid: audioUUID, title: "The Devils", audiobook: true)
        let transport = FormatLinkTransportDouble()
        await transport.setCanMerge(false)
        let state = MergeStateDouble()
        let coordinator = BookFormatLinkCoordinator(
            cache: FormatLinkCacheDouble(),
            transport: transport,
            mergeState: state,
        )
        let outcome = await coordinator.merge(
            sourceID: "server",
            current: ebook,
            other: audio,
            library: [ebook, audio],
        )
        #expect(outcome == .failed(.authenticationExpired))
        #expect(await transport.mergeCount == 0)
        #expect(await state.applyCount == 0)
    }
}

private func mergeBook(
    uuid: String,
    title: String,
    authors: [String] = ["Joe Abercrombie"],
    narrators: [String] = [],
    language: String? = nil,
    year: String? = nil,
    ebook: Bool = false,
    audiobook: Bool = false,
    tags: [String] = [],
    source: BookSourceID = "server",
) -> BookMetadata {
    BookMetadata(
        bookID: BookID(sourceID: source, uuid: uuid),
        title: title,
        subtitle: nil,
        description: nil,
        language: language,
        createdAt: nil,
        updatedAt: nil,
        publicationDate: year.map { "\($0)-01-01" },
        authors: authors.map {
            BookCreator(
                uuid: nil,
                id: nil,
                name: $0,
                fileAs: nil,
                role: "aut",
                createdAt: nil,
                updatedAt: nil
            )
        },
        narrators: narrators.isEmpty
            ? nil
            : narrators.map {
                BookCreator(
                    uuid: nil,
                    id: nil,
                    name: $0,
                    fileAs: nil,
                    role: "nrt",
                    createdAt: nil,
                    updatedAt: nil
                )
            },
        creators: nil,
        series: nil,
        tags: tags.map { BookTag(uuid: nil, name: $0, createdAt: nil, updatedAt: nil) },
        collections: nil,
        ebook: ebook
            ? BookAsset(
                uuid: uuid,
                filepath: "\(uuid).epub",
                missing: 0,
                createdAt: nil,
                updatedAt: nil
            ) : nil,
        audiobook: audiobook
            ? BookAsset(
                uuid: uuid,
                filepath: "\(uuid).m4b",
                missing: 0,
                createdAt: nil,
                updatedAt: nil
            ) : nil,
        readaloud: nil,
        status: nil,
        position: nil,
        rating: nil,
    )
}

private func locator(progress: Double) -> BookLocator {
    BookLocator(
        href: "/chap1",
        type: "application/xhtml+xml",
        title: "Chapter 1",
        locations: BookLocator.Locations(
            fragments: nil,
            progression: progress,
            position: nil,
            totalProgression: progress,
            cssSelector: nil,
            partialCfi: nil,
            domRange: nil,
        ),
        text: nil,
    )
}

private func makeActor() -> StorytellerActor {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MergeStubURLProtocol.self]
    return StorytellerActor(
        sourceRecord: BookSourceRecord(
            id: "server",
            name: "Storyteller",
            kind: .storyteller,
            capabilities: .storyteller,
        ),
        session: URLSession(configuration: configuration),
    )
}

private func mergedBookJSON(uuid: String) -> Data {
    Data(
        """
        {"uuid":"\(uuid)","title":"The Devils","ebook":{"filepath":"a.epub","missing":0},"audiobook":{"filepath":"a.m4b","missing":0}}
        """.utf8
    )
}

private actor MergeStateDouble: StorytellerBookMergeStateStore {
    private var progress: [BookID: BookProgress] = [:]
    private var highlights: [BookID: [Highlight]] = [:]
    private(set) var snapshotCount = 0
    private(set) var applyCount = 0
    private(set) var appliedSurviving: BookID?
    private(set) var appliedSnapshot: StorytellerMergeLocalSnapshot?

    func setSnapshotProgress(_ progress: [BookID: BookProgress]) {
        self.progress = progress
    }

    func setSnapshotHighlights(_ highlights: [BookID: [Highlight]]) {
        self.highlights = highlights
    }

    func snapshot(bookIDs: [BookID], links: BookFormatLinkDocument) async
        -> StorytellerMergeLocalSnapshot
    {
        snapshotCount += 1
        return StorytellerMergeLocalSnapshot(
            bookIDs: bookIDs,
            progress: progress,
            highlights: highlights,
            links: links,
        )
    }

    func apply(snapshot: StorytellerMergeLocalSnapshot, surviving: BookID) async -> String? {
        applyCount += 1
        appliedSnapshot = snapshot
        appliedSurviving = surviving
        return nil
    }
}

private final class MergeStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var lastBody: Data?
    static var bookJSON = Data()

    static func reset() {
        lock.lock()
        requests = []
        lastBody = nil
        bookJSON = Data()
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        if let body = request.httpBody ?? bodyFromStream(request.httpBodyStream) {
            Self.lastBody = body
        }
        let path = request.url?.path ?? ""
        let bookJSON = Self.bookJSON
        Self.lock.unlock()

        let data: Data
        if path.hasSuffix("/token") {
            data = Data(
                #"{"access_token":"test-token","token_type":"Bearer","expires_in":3600}"#.utf8
            )
        } else if path.hasSuffix("/books/merge") {
            data = bookJSON
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"],
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func bodyFromStream(_ stream: InputStream?) -> Data? {
    guard let stream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: bufferSize)
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    return data.isEmpty ? nil : data
}
