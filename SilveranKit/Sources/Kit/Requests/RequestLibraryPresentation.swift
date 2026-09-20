import Foundation

/// Books-library request filter. Presentation only — does not change request state.
public enum RequestLibraryFilter: String, Equatable, Hashable, Sendable, CaseIterable {
    case all
    case requests
    case needsAttention
    case availableInLibrary

    public var label: String {
        switch self {
            case .all: "All Books"
            case .requests: "Requests"
            case .needsAttention: "Needs Attention"
            case .availableInLibrary: "Available in Library"
        }
    }

    public var emptyMessage: String? {
        switch self {
            case .all: nil
            case .requests: "No active book requests"
            case .needsAttention: "Nothing needs attention"
            case .availableInLibrary: "No requested books are in your library yet"
        }
    }
}

public enum RequestLibraryBadgeKind: Equatable, Sendable {
    case needsAttention
    case inProgress
    case ready
}

/// Compact card badge. Human labels only — no provider IDs or backend errors.
public struct RequestLibraryBadgeState: Equatable, Sendable {
    public var label: String
    public var systemImage: String
    public var kind: RequestLibraryBadgeKind
    public var accessibilityLabel: String

    public init(
        label: String,
        systemImage: String,
        kind: RequestLibraryBadgeKind,
        accessibilityLabel: String,
    ) {
        self.label = label
        self.systemImage = systemImage
        self.kind = kind
        self.accessibilityLabel = accessibilityLabel
    }
}

/// A tracked request that is not matched to a library book. Not a fake `BookMetadata` row.
public struct RequestLibraryPendingRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var author: String
    public var formatsLabel: String
    public var badge: RequestLibraryBadgeState

    public init(
        id: String,
        title: String,
        author: String,
        formatsLabel: String,
        badge: RequestLibraryBadgeState,
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.formatsLabel = formatsLabel
        self.badge = badge
    }
}

public struct RequestLibraryChipSummary: Equatable, Sendable {
    public var activeCount: Int
    public var attentionCount: Int

    public init(activeCount: Int = 0, attentionCount: Int = 0) {
        self.activeCount = activeCount
        self.attentionCount = attentionCount
    }

    /// In-progress + needs attention. Completed/recent rows do not inflate this.
    public var showsCount: Bool { activeCount > 0 }
    public var showsAttention: Bool { attentionCount > 0 }
}

/// In-memory book → request lookup. Built once per reload; card queries are O(1).
public struct RequestLibraryPresentationIndex: Equatable, Sendable {
    public var chip: RequestLibraryChipSummary
    private var byCanonicalID: [String: RequestActivityItem]
    private var byISBN: [String: RequestActivityItem]
    private var byTitleAuthor: [String: RequestActivityItem]
    private var pending: [RequestLibraryPendingRow]
    private var now: Date

    public init(
        items: [RequestActivityItem] = [],
        books: [BookMetadata] = [],
        now: Date = Date(),
    ) {
        self.now = now
        var canonical: [String: RequestActivityItem] = [:]
        var isbn: [String: RequestActivityItem] = [:]
        var titleAuthor: [String: RequestActivityItem] = [:]

        for item in items {
            Self.insert(item, into: &canonical, key: item.canonicalWorkID)
            if let ol = RequestLibraryMatcher.normalizeOpenLibraryID(item.openLibraryWorkID) {
                Self.insert(item, into: &canonical, key: ol)
            }
            if let edition = RequestLibraryMatcher.normalizeOpenLibraryID(item.openLibraryEditionID) {
                Self.insert(item, into: &canonical, key: edition)
            }
            if let normalized = RequestLibraryMatcher.normalizeISBN(item.isbn) {
                Self.insert(item, into: &isbn, key: normalized)
            }
            for author in RequestLibraryMatcher.authorCandidates(from: item.author) {
                if let key = RequestLibraryMatcher.titleAuthorKey(title: item.title, authorNames: [author])
                {
                    Self.insert(item, into: &titleAuthor, key: key)
                }
            }
        }

        self.byCanonicalID = canonical
        self.byISBN = isbn
        self.byTitleAuthor = titleAuthor

        var matchedIDs = Set<String>()
        for book in books {
            if let item = Self.lookup(
                book,
                canonical: canonical,
                isbn: isbn,
                titleAuthor: titleAuthor,
            ) {
                matchedIDs.insert(item.id)
            }
        }
        self.pending = items.compactMap { item in
            guard !matchedIDs.contains(item.id) else { return nil }
            guard let badge = Self.badge(for: item, now: now, includeStaleReady: true) else {
                return nil
            }
            return RequestLibraryPendingRow(
                id: item.id,
                title: item.title,
                author: item.author,
                formatsLabel: item.formatsLabel,
                badge: badge,
            )
        }

        let summary = RequestActivityGrouping.librarySummary(items, now: now)
        self.chip = RequestLibraryChipSummary(
            activeCount: summary.inProgressCount + summary.needsAttentionCount,
            attentionCount: summary.needsAttentionCount,
        )
    }

    public func match(book: BookMetadata) -> RequestActivityItem? {
        Self.lookup(
            book,
            canonical: byCanonicalID,
            isbn: byISBN,
            titleAuthor: byTitleAuthor,
        )
    }

    /// Badge for an active match. Stale completed rows return nil so cards stay quiet.
    public func badge(for book: BookMetadata) -> RequestLibraryBadgeState? {
        guard let item = match(book: book) else { return nil }
        return Self.badge(for: item, now: now, includeStaleReady: false)
    }

    public func badge(for item: RequestActivityItem) -> RequestLibraryBadgeState? {
        Self.badge(for: item, now: now, includeStaleReady: false)
    }

    public func includes(book: BookMetadata, filter: RequestLibraryFilter) -> Bool {
        switch filter {
            case .all:
                return true
            case .requests, .needsAttention, .availableInLibrary:
                guard let item = match(book: book) else { return false }
                return Self.itemIncluded(item, filter: filter, now: now)
        }
    }

    public func filteredBooks(
        _ books: [BookMetadata],
        filter: RequestLibraryFilter,
    ) -> [BookMetadata] {
        guard filter != .all else { return books }
        return books.filter { includes(book: $0, filter: filter) }
    }

    public func pendingRows(filter: RequestLibraryFilter) -> [RequestLibraryPendingRow] {
        switch filter {
            case .all:
                return []
            case .requests:
                return pending.filter {
                    $0.badge.kind == .needsAttention || $0.badge.kind == .inProgress
                }
            case .needsAttention:
                return pending.filter { $0.badge.kind == .needsAttention }
            case .availableInLibrary:
                return pending.filter { $0.badge.kind == .ready }
        }
    }

    // MARK: - Lookup

    private static func lookup(
        _ book: BookMetadata,
        canonical: [String: RequestActivityItem],
        isbn: [String: RequestActivityItem],
        titleAuthor: [String: RequestActivityItem],
    ) -> RequestActivityItem? {
        let canonicalKeys = [book.id.description, book.id.uuid]
        for key in canonicalKeys {
            if let hit = canonical[key] { return hit }
        }
        if let ol = RequestLibraryMatcher.normalizeOpenLibraryID(book.id.description),
            let hit = canonical[ol]
        {
            return hit
        }

        let tokens = BookFormatTexts.isbnTokens(in: [book.title, book.subtitle, book.description])
        for token in tokens {
            if let key = RequestLibraryMatcher.normalizeISBN(token), let hit = isbn[key] {
                return hit
            }
        }

        let authors = book.authors?.compactMap(\.name) ?? []
        for author in authors {
            if let key = RequestLibraryMatcher.titleAuthorKey(title: book.title, authorNames: [author]),
                let hit = titleAuthor[key]
            {
                return hit
            }
        }
        return nil
    }

    private static func insert(
        _ item: RequestActivityItem,
        into table: inout [String: RequestActivityItem],
        key: String,
    ) {
        guard !key.isEmpty else { return }
        if let existing = table[key] {
            table[key] = preferred(existing, item)
        } else {
            table[key] = item
        }
    }

    /// Needs Attention beats in-progress beats Ready; ties keep the newer row.
    private static func preferred(
        _ lhs: RequestActivityItem,
        _ rhs: RequestActivityItem,
    ) -> RequestActivityItem {
        let left = priorityRank(lhs)
        let right = priorityRank(rhs)
        if left != right { return left < right ? lhs : rhs }
        return lhs.updatedAt >= rhs.updatedAt ? lhs : rhs
    }

    private static func priorityRank(_ item: RequestActivityItem) -> Int {
        if item.formatStatuses.contains(where: { $0.status.needsAttentionBucket })
            || item.attentionReason != nil
        {
            return 0
        }
        if item.formatStatuses.contains(where: \.status.isInProgress) { return 1 }
        return 2
    }

    public static func badge(
        for item: RequestActivityItem,
        now: Date = Date(),
        includeStaleReady: Bool,
    ) -> RequestLibraryBadgeState? {
        let section = RequestActivityGrouping.section(for: item, now: now)
        switch section {
            case .recent:
                return nil
            case .completed:
                let recent =
                    now.timeIntervalSince(item.updatedAt)
                    <= RequestActivityGrouping.recentCompletionWindow
                if !includeStaleReady && !recent { return nil }
                return readyBadge
            case .needsAttention:
                return RequestLibraryBadgeState(
                    label: "Needs Attention",
                    systemImage: "exclamationmark.triangle",
                    kind: .needsAttention,
                    accessibilityLabel: "Request status: Needs Attention",
                )
            case .inProgress:
                break
        }

        let statuses = item.requestedFormats.compactMap { item.status(for: $0)?.status }
        guard let winner = statuses.min(by: { statusRank($0) < statusRank($1) }) else {
            return nil
        }
        return badge(for: winner)
    }

    public static func itemIncluded(
        _ item: RequestActivityItem,
        filter: RequestLibraryFilter,
        now: Date = Date(),
    ) -> Bool {
        let section = RequestActivityGrouping.section(for: item, now: now)
        switch filter {
            case .all:
                return true
            case .requests:
                switch section {
                    case .needsAttention, .inProgress:
                        return true
                    case .completed:
                        return now.timeIntervalSince(item.updatedAt)
                            <= RequestActivityGrouping.recentCompletionWindow
                    case .recent:
                        return false
                }
            case .needsAttention:
                return section == .needsAttention
            case .availableInLibrary:
                return section == .completed
        }
    }

    private static func badge(for status: RequestActivityStatus) -> RequestLibraryBadgeState {
        switch status {
            case .failed, .needsAttention:
                return RequestLibraryBadgeState(
                    label: "Needs Attention",
                    systemImage: "exclamationmark.triangle",
                    kind: .needsAttention,
                    accessibilityLabel: "Request status: Needs Attention",
                )
            case .searching:
                return progress("Searching", systemImage: "clock")
            case .wanted:
                return progress("Wanted", systemImage: "clock")
            case .requested, .alreadyRequested, .unknown:
                return progress("Requested", systemImage: "clock")
            case .snatched:
                return progress("Snatched", systemImage: "arrow.down.circle")
            case .downloaded, .available, .alreadyAvailable:
                return progress("Available", systemImage: "arrow.down.circle")
            case .availableInLibrary:
                return readyBadge
        }
    }

    private static func progress(
        _ label: String,
        systemImage: String,
    ) -> RequestLibraryBadgeState {
        RequestLibraryBadgeState(
            label: label,
            systemImage: systemImage,
            kind: .inProgress,
            accessibilityLabel: "Request status: \(label)",
        )
    }

    private static let readyBadge = RequestLibraryBadgeState(
        label: "Ready",
        systemImage: "checkmark.circle",
        kind: .ready,
        accessibilityLabel: "Request status: Available in Library",
    )

    /// Lower is more urgent. Needs Attention wins; in-progress beats Ready.
    private static func statusRank(_ status: RequestActivityStatus) -> Int {
        switch status {
            case .failed, .needsAttention: 0
            case .searching: 1
            case .wanted: 2
            case .requested, .alreadyRequested, .unknown: 3
            case .snatched: 4
            case .downloaded, .available, .alreadyAvailable: 5
            case .availableInLibrary: 6
        }
    }
}

/// Rebuilds the presentation index when Request Activity history changes. Read-only.
public final class RequestLibraryIndexRefresher: @unchecked Sendable {
    public private(set) var index: RequestLibraryPresentationIndex
    private let lock = NSLock()
    private let store: RequestActivityStore
    private let books: @Sendable () -> [BookMetadata]
    private let now: @Sendable () -> Date
    private var token: NSObjectProtocol?

    public init(
        store: RequestActivityStore,
        books: @escaping @Sendable () -> [BookMetadata],
        now: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.store = store
        self.books = books
        self.now = now
        self.index = RequestLibraryPresentationIndex(items: store.allItems(), books: books(), now: now())
        token = NotificationCenter.default.addObserver(
            forName: .requestActivityStoreDidChange,
            object: nil,
            queue: nil,
        ) { [weak self] _ in
            self?.reload()
        }
    }

    deinit {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }

    public func reload() {
        let next = RequestLibraryPresentationIndex(
            items: store.allItems(),
            books: books(),
            now: now(),
        )
        lock.lock()
        index = next
        lock.unlock()
    }

    public func currentIndex() -> RequestLibraryPresentationIndex {
        lock.lock()
        defer { lock.unlock() }
        return index
    }
}
