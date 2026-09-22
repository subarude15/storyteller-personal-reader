import Foundation

public protocol BookFormatLinkCache: Sendable {
    func load(sourceID: BookSourceID) async -> BookFormatLinkDocument
    func save(sourceID: BookSourceID, document: BookFormatLinkDocument) async
}

public protocol BookFormatLinkTransport: Sendable {
    func fetchDocument(sourceID: BookSourceID) async -> BookFormatLinkFetchResult
    func pushDocument(sourceID: BookSourceID, description: String) async -> BookFormatLinkPushResult
    func startAlignment(bookID: BookID, restart: AlignmentRestartMode) async -> Bool
    func canMergeBooks(sourceID: BookSourceID) async -> Bool
    func mergeBooks(
        sourceID: BookSourceID,
        request: StorytellerBookMergeRequest,
    ) async -> StorytellerBookMergeHTTPResult
}

public struct UserDefaultsBookFormatLinkCache: BookFormatLinkCache, @unchecked Sendable {
    // UserDefaults is thread-safe. Linux's SDK does not mark it Sendable.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load(sourceID: BookSourceID) async -> BookFormatLinkDocument {
        guard let data = defaults.data(forKey: Self.key(sourceID)),
            let raw = String(data: data, encoding: .utf8)
        else {
            return .empty
        }
        return (try? BookFormatLinkMerge.decodeDescription(raw, sourceID: sourceID).document)
            ?? .empty
    }

    public func save(sourceID: BookSourceID, document: BookFormatLinkDocument) async {
        guard let raw = try? BookFormatLinkMerge.encodeDescription(document),
            let data = raw.data(using: .utf8)
        else { return }
        defaults.set(data, forKey: Self.key(sourceID))
    }

    private static func key(_ sourceID: BookSourceID) -> String {
        "punkRally.bookFormatLinks.v1.\(sourceID)"
    }
}

public struct StorytellerBookFormatLinkTransport: BookFormatLinkTransport {
    public init() {}

    public func fetchDocument(sourceID: BookSourceID) async -> BookFormatLinkFetchResult {
        await BookServiceActor.shared.fetchInkampBookFormatLinksDocument(sourceID: sourceID)
    }

    public func pushDocument(
        sourceID: BookSourceID,
        description: String,
    ) async -> BookFormatLinkPushResult {
        await BookServiceActor.shared.pushInkampBookFormatLinksDocument(
            description,
            sourceID: sourceID
        )
    }

    public func startAlignment(bookID: BookID, restart: AlignmentRestartMode) async -> Bool {
        await BookServiceActor.shared.startAlignment(for: bookID, restart: restart)
    }

    public func canMergeBooks(sourceID: BookSourceID) async -> Bool {
        await BookServiceActor.shared.storytellerBookCreateAccess(sourceID: sourceID) == .allowed
    }

    public func mergeBooks(
        sourceID: BookSourceID,
        request: StorytellerBookMergeRequest,
    ) async -> StorytellerBookMergeHTTPResult {
        await BookServiceActor.shared.mergeStorytellerBooks(sourceID: sourceID, request: request)
    }
}

public actor BookFormatLinkCoordinator {
    public static let shared = BookFormatLinkCoordinator()

    private let cache: any BookFormatLinkCache
    private let transport: any BookFormatLinkTransport
    private let mergeState: any StorytellerBookMergeStateStore
    private var inFlight = false

    public init(
        cache: any BookFormatLinkCache = UserDefaultsBookFormatLinkCache(),
        transport: any BookFormatLinkTransport = StorytellerBookFormatLinkTransport(),
        mergeState: any StorytellerBookMergeStateStore = DefaultStorytellerBookMergeStateStore(),
    ) {
        self.cache = cache
        self.transport = transport
        self.mergeState = mergeState
    }

    public func cachedActiveLinks(sourceID: BookSourceID) async -> [BookFormatLink] {
        await cache.load(sourceID: sourceID).activeLinks
    }

    /// Pulls the server document. An unavailable fetch keeps the local cache.
    /// An empty collection does not erase links that were already saved here.
    public func refresh(sourceID: BookSourceID) async -> [BookFormatLink] {
        let local = await cache.load(sourceID: sourceID)
        switch await transport.fetchDocument(sourceID: sourceID) {
            case .unavailable:
                return local.activeLinks
            case .empty:
                if local.activeLinks.isEmpty {
                    await cache.save(sourceID: sourceID, document: .empty)
                    return []
                }
                return local.activeLinks
            case .document(let raw):
                guard let decoded = Self.decoded(raw, sourceID: sourceID) else {
                    return local.activeLinks
                }
                let merged = BookFormatLinkMerge.merge(local: local, remote: decoded.document)
                if decoded.needsRewrite {
                    await self.rewrite(merged, sourceID: sourceID)
                }
                await cache.save(sourceID: sourceID, document: merged)
                return merged.activeLinks
        }
    }

    public func link(
        sourceID: BookSourceID,
        primary: BookMetadata,
        other: BookMetadata,
        library: [BookMetadata],
        startAlignment: Bool,
    ) async -> BookFormatLinkOutcome {
        if inFlight { return .failed(.duplicateSubmission) }
        inFlight = true
        defer { inFlight = false }

        guard library.contains(where: { $0.id == primary.id }),
            library.contains(where: { $0.id == other.id })
        else {
            return .failed(.sourceMissing)
        }
        guard primary.sourceID == sourceID, other.sourceID == sourceID else {
            return .failed(.incompatible)
        }
        guard BookFormatMatcher.isCompatible(other, with: primary) else {
            return .failed(.incompatible)
        }

        let local = await cache.load(sourceID: sourceID)
        if BookFormatMatcher.isLinked(primary.id, links: local.activeLinks)
            || BookFormatMatcher.isLinked(other.id, links: local.activeLinks)
        {
            return .failed(.alreadyLinked)
        }

        let base: BookFormatLinkDocument
        switch await transport.fetchDocument(sourceID: sourceID) {
            case .unavailable(let reason):
                return .failed(BookFormatLinkMerge.failure(forTransportReason: reason))
            case .empty:
                base = local
            case .document(let raw):
                guard let decoded = Self.decoded(raw, sourceID: sourceID) else {
                    return .failed(.serverRejected)
                }
                base = BookFormatLinkMerge.merge(local: local, remote: decoded.document)
        }

        if BookFormatMatcher.isLinked(primary.id, links: base.activeLinks)
            || BookFormatMatcher.isLinked(other.id, links: base.activeLinks)
        {
            await cache.save(sourceID: sourceID, document: base)
            return .failed(.alreadyLinked)
        }

        let now = Date()
        let members = [primary.id, other.id]
        let link = BookFormatLink(
            id: BookFormatLink.identifier(for: members),
            members: members,
            primary: primary.id,
            updatedAt: now,
            removed: false,
        )
        var links = base.links.filter { $0.id != link.id }
        links.append(link)
        let proposed = BookFormatLinkDocument(updatedAt: now, links: links.sorted { $0.id < $1.id })

        switch await push(proposed, sourceID: sourceID) {
            case .failure(let reason):
                return .failed(BookFormatLinkMerge.failure(forTransportReason: reason))
            case .success:
                await cache.save(sourceID: sourceID, document: proposed)
        }

        var alignment = BookFormatAlignment.assess([primary, other])
        if startAlignment, alignment.canStart, let bookID = alignment.bookID {
            let started = await transport.startAlignment(bookID: bookID, restart: .none)
            alignment =
                started
                ? ReadaloudAlignment(
                    phase: .queued,
                    bookID: bookID,
                    canRetry: false,
                    canStart: false,
                    message:
                        "Storyteller queued Readaloud alignment. It is not ready for Read & Listen until the server says so.",
                )
                : ReadaloudAlignment(
                    phase: .failed,
                    bookID: bookID,
                    canRetry: true,
                    canStart: false,
                    message:
                        "The formats are linked, but Storyteller did not start alignment. Read & Listen is not ready.",
                )
        }
        return .linked(proposed, alignment)
    }

    public func unlink(
        sourceID: BookSourceID,
        bookID: BookID,
    ) async -> BookFormatLinkOutcome {
        if inFlight { return .failed(.duplicateSubmission) }
        inFlight = true
        defer { inFlight = false }

        let local = await cache.load(sourceID: sourceID)
        let remoteBase: BookFormatLinkDocument
        switch await transport.fetchDocument(sourceID: sourceID) {
            case .unavailable(let reason):
                return .failed(BookFormatLinkMerge.failure(forTransportReason: reason))
            case .empty:
                remoteBase = local
            case .document(let raw):
                guard let decoded = Self.decoded(raw, sourceID: sourceID) else {
                    return .failed(.serverRejected)
                }
                remoteBase = BookFormatLinkMerge.merge(local: local, remote: decoded.document)
        }

        guard let existing = remoteBase.activeLinks.first(where: { $0.members.contains(bookID) })
        else {
            return .failed(.notLinked)
        }
        let now = Date()
        let tombstone = BookFormatLink(
            id: existing.id,
            members: existing.members,
            primary: existing.primary,
            updatedAt: now,
            removed: true,
        )
        var links = remoteBase.links.filter { $0.id != existing.id }
        links.append(tombstone)
        let proposed = BookFormatLinkDocument(updatedAt: now, links: links.sorted { $0.id < $1.id })

        switch await push(proposed, sourceID: sourceID) {
            case .failure(let reason):
                return .failed(BookFormatLinkMerge.failure(forTransportReason: reason))
            case .success:
                await cache.save(sourceID: sourceID, document: proposed)
                return .unlinked(proposed)
        }
    }

    public func merge(
        sourceID: BookSourceID,
        current: BookMetadata,
        other: BookMetadata,
        library: [BookMetadata],
        canMerge: Bool? = nil,
    ) async -> BookFormatLinkOutcome {
        if inFlight { return .failed(.duplicateSubmission) }
        inFlight = true
        defer { inFlight = false }

        guard library.contains(where: { $0.id == current.id }),
            library.contains(where: { $0.id == other.id })
        else {
            return .failed(.sourceMissing)
        }
        guard StorytellerBookMergeEligibility.isEligible(current, other),
            let pair = StorytellerBookMergePayload.pair(current: current, other: other)
        else {
            return .failed(.incompatible)
        }
        let permitted: Bool
        if let canMerge {
            permitted = canMerge
        } else {
            permitted = await transport.canMergeBooks(sourceID: sourceID)
        }
        guard permitted else {
            return .failed(.authenticationExpired)
        }

        let local = await cache.load(sourceID: sourceID)
        let linksForSnapshot: BookFormatLinkDocument
        switch await transport.fetchDocument(sourceID: sourceID) {
            case .unavailable:
                linksForSnapshot = local
            case .empty:
                linksForSnapshot = local
            case .document(let raw):
                if let decoded = Self.decoded(raw, sourceID: sourceID) {
                    linksForSnapshot = BookFormatLinkMerge.merge(
                        local: local,
                        remote: decoded.document,
                    )
                } else {
                    linksForSnapshot = local
                }
        }
        let snapshot = await mergeState.snapshot(
            bookIDs: [pair.ebook.id, pair.audiobook.id],
            links: linksForSnapshot,
        )
        let request = StorytellerBookMergePayload.request(
            ebook: pair.ebook,
            audiobook: pair.audiobook,
        )

        let mergedBook: BookMetadata
        switch await transport.mergeBooks(sourceID: sourceID, request: request) {
            case .failure(let failure):
                return .failed(failure)
            case .success(let book):
                mergedBook = book
        }

        let survivingID = BookID(sourceID: sourceID, uuid: mergedBook.uuid)
        let absorbedIDs = [pair.ebook.id, pair.audiobook.id].filter { $0 != survivingID }
        let migrationWarning = await mergeState.apply(
            snapshot: snapshot,
            surviving: survivingID,
        )

        let now = Date()
        var links = snapshot.links.links
        var didTombstone = false
        for existing in snapshot.links.activeLinks
        where existing.members.contains(pair.ebook.id)
            || existing.members.contains(pair.audiobook.id)
        {
            links.removeAll { $0.id == existing.id }
            links.append(
                BookFormatLink(
                    id: existing.id,
                    members: existing.members,
                    primary: existing.primary,
                    updatedAt: now,
                    removed: true,
                )
            )
            didTombstone = true
        }
        let proposed = BookFormatLinkDocument(
            updatedAt: didTombstone ? now : snapshot.links.updatedAt,
            links: links.sorted { $0.id < $1.id },
        )
        if didTombstone {
            // Merge already succeeded. Persist the tombstone locally even if the
            // collection push fails so a later refresh cannot resurrect the pair.
            await cache.save(sourceID: sourceID, document: proposed)
            switch await push(proposed, sourceID: sourceID) {
                case .success:
                    break
                case .failure(let reason):
                    debugLog(
                        "[BookFormatLink] merge succeeded but link cleanup failed: \(reason)"
                    )
            }
        }

        let started = await transport.startAlignment(bookID: survivingID, restart: .none)
        let alignment =
            started
            ? ReadaloudAlignment(
                phase: .queued,
                bookID: survivingID,
                canRetry: false,
                canStart: false,
                message: "Read & Listen is processing in Storyteller.",
            )
            : ReadaloudAlignment(
                phase: .failed,
                bookID: survivingID,
                canRetry: true,
                canStart: false,
                message:
                    "Books merged, but Read & Listen did not start. You can retry alignment from the book.",
            )
        return .merged(
            proposed,
            StorytellerBookMergeStatus(
                survivingBookID: survivingID,
                absorbedBookIDs: absorbedIDs,
                alignmentStarted: started,
                alignment: alignment,
                migrationWarning: migrationWarning,
            ),
        )
    }

    public func retryAlignment(members: [BookMetadata]) async -> BookFormatLinkOutcome {
        if inFlight { return .failed(.duplicateSubmission) }
        inFlight = true
        defer { inFlight = false }

        let alignment = BookFormatAlignment.assess(members)
        guard alignment.canRetry, let bookID = alignment.bookID else {
            return .failed(.incompatible)
        }
        let started = await transport.startAlignment(bookID: bookID, restart: .full)
        guard started else {
            return .failed(.serverRejected)
        }
        return .alignment(
            ReadaloudAlignment(
                phase: .queued,
                bookID: bookID,
                canRetry: false,
                canStart: false,
                message:
                    "Storyteller queued Readaloud alignment again. It is not ready for Read & Listen yet.",
            )
        )
    }

    private static func decoded(_ raw: String, sourceID: BookSourceID) -> DecodedBookFormatLinks? {
        try? BookFormatLinkMerge.decodeDescription(raw, sourceID: sourceID)
    }

    /// Encodes schema 2. Encode failure is reported as a rejected push so nothing is marked linked.
    private func push(
        _ document: BookFormatLinkDocument,
        sourceID: BookSourceID,
    ) async -> BookFormatLinkPushResult {
        guard let description = try? BookFormatLinkMerge.encodeDescription(document) else {
            return .failure(reason: "encode failed")
        }
        return await transport.pushDocument(sourceID: sourceID, description: description)
    }

    /// Best-effort rewrite of a schema 1 collection. Failure leaves the resolved links in place.
    private func rewrite(_ document: BookFormatLinkDocument, sourceID: BookSourceID) async {
        guard !document.links.isEmpty else { return }
        _ = await push(document, sourceID: sourceID)
    }
}
