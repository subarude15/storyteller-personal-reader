import Foundation

public protocol BookFormatLinkCache: Sendable {
    func load(sourceID: BookSourceID) async -> BookFormatLinkDocument
    func save(sourceID: BookSourceID, document: BookFormatLinkDocument) async
}

public protocol BookFormatLinkTransport: Sendable {
    func fetchDocument(sourceID: BookSourceID) async -> BookFormatLinkFetchResult
    func pushDocument(sourceID: BookSourceID, document: BookFormatLinkDocument) async -> BookFormatLinkPushResult
    func startAlignment(bookID: BookID, restart: AlignmentRestartMode) async -> Bool
}

public struct UserDefaultsBookFormatLinkCache: BookFormatLinkCache, @unchecked Sendable {
    // UserDefaults is thread-safe. Linux's SDK does not mark it Sendable.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load(sourceID: BookSourceID) async -> BookFormatLinkDocument {
        guard let data = defaults.data(forKey: Self.key(sourceID)) else {
            return .empty
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(BookFormatLinkDocument.self, from: data)) ?? .empty
    }

    public func save(sourceID: BookSourceID, document: BookFormatLinkDocument) async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(document) else { return }
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
        document: BookFormatLinkDocument,
    ) async -> BookFormatLinkPushResult {
        await BookServiceActor.shared.pushInkampBookFormatLinksDocument(document, sourceID: sourceID)
    }

    public func startAlignment(bookID: BookID, restart: AlignmentRestartMode) async -> Bool {
        await BookServiceActor.shared.startAlignment(for: bookID, restart: restart)
    }
}

public actor BookFormatLinkCoordinator {
    public static let shared = BookFormatLinkCoordinator()

    private let cache: any BookFormatLinkCache
    private let transport: any BookFormatLinkTransport
    private var inFlight = false

    public init(
        cache: any BookFormatLinkCache = UserDefaultsBookFormatLinkCache(),
        transport: any BookFormatLinkTransport = StorytellerBookFormatLinkTransport(),
    ) {
        self.cache = cache
        self.transport = transport
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
            case .document(let remote):
                let merged = BookFormatLinkMerge.merge(local: local, remote: remote)
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
            case .document(let remote):
                base = BookFormatLinkMerge.merge(local: local, remote: remote)
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

        switch await transport.pushDocument(sourceID: sourceID, document: proposed) {
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
            case .document(let remote):
                remoteBase = BookFormatLinkMerge.merge(local: local, remote: remote)
        }

        guard let existing = remoteBase.activeLinks.first(where: { $0.members.contains(bookID) }) else {
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

        switch await transport.pushDocument(sourceID: sourceID, document: proposed) {
            case .failure(let reason):
                return .failed(BookFormatLinkMerge.failure(forTransportReason: reason))
            case .success:
                await cache.save(sourceID: sourceID, document: proposed)
                return .unlinked(proposed)
        }
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
                message: "Storyteller queued Readaloud alignment again. It is not ready for Read & Listen yet.",
            )
        )
    }
}
