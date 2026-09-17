import Foundation

/// Lightweight mapping between stable Explore identities and imported Storyteller books.
public struct ExploreImportRecord: Codable, Hashable, Sendable {
    public let exploreID: String
    public let storytellerBookID: BookID
    public let importedAt: Date
    public let title: String

    public init(
        exploreID: String,
        storytellerBookID: BookID,
        importedAt: Date = Date(),
        title: String
    ) {
        self.exploreID = exploreID
        self.storytellerBookID = storytellerBookID
        self.importedAt = importedAt
        self.title = title
    }
}

public struct ExploreImportStore: Sendable {
    private static let defaultsKey = "punkRally.exploreImportMap.v1"

    public static let shared = ExploreImportStore()

    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            return suite
        }
        if let group = UserDefaults(suiteName: "group.com.punkrally.reader") {
            return group
        }
        return .standard
    }

    public func record(forExploreID exploreID: String) -> ExploreImportRecord? {
        load().first { $0.exploreID == exploreID }
    }

    public func record(for book: ExploreBook) -> ExploreImportRecord? {
        record(forExploreID: book.id)
    }

    public func isImported(_ book: ExploreBook) -> Bool {
        record(for: book) != nil
    }

    public func save(_ record: ExploreImportRecord) {
        var all = load().filter { $0.exploreID != record.exploreID }
        all.append(record)
        persist(all)
    }

    public func remove(exploreID: String) {
        persist(load().filter { $0.exploreID != exploreID })
    }

    public func load() -> [ExploreImportRecord] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([ExploreImportRecord].self, from: data)) ?? []
    }

    private func persist(_ records: [ExploreImportRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// Local reading progress for ephemeral Explore identities (never sent to Storyteller).
public struct ExploreProgressRecord: Codable, Hashable, Sendable {
    public let exploreID: String
    public var locator: BookLocator?
    public var fraction: Double?
    public var updatedAt: Date

    public init(
        exploreID: String,
        locator: BookLocator? = nil,
        fraction: Double? = nil,
        updatedAt: Date = Date()
    ) {
        self.exploreID = exploreID
        self.locator = locator
        self.fraction = fraction
        self.updatedAt = updatedAt
    }
}

public struct ExploreProgressStore: Sendable {
    private static let defaultsKey = "punkRally.exploreProgress.v1"

    public static let shared = ExploreProgressStore()

    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            return suite
        }
        if let group = UserDefaults(suiteName: "group.com.punkrally.reader") {
            return group
        }
        return .standard
    }

    public func load(exploreID: String) -> ExploreProgressRecord? {
        loadAll()[exploreID]
    }

    public func load(bookID: BookID) -> ExploreProgressRecord? {
        guard ExploreBookIdentity.isExplore(bookID) else { return nil }
        return load(exploreID: "explore.\(bookID.uuid)")
    }

    public func save(exploreID: String, locator: BookLocator?, fraction: Double?) {
        var all = loadAll()
        all[exploreID] = ExploreProgressRecord(
            exploreID: exploreID,
            locator: locator,
            fraction: fraction,
            updatedAt: Date()
        )
        persist(all)
    }

    public func save(bookID: BookID, locator: BookLocator?, fraction: Double?) {
        guard ExploreBookIdentity.isExplore(bookID) else { return }
        save(exploreID: "explore.\(bookID.uuid)", locator: locator, fraction: fraction)
    }

    private func loadAll() -> [String: ExploreProgressRecord] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [:] }
        let records =
            (try? JSONDecoder().decode([ExploreProgressRecord].self, from: data)) ?? []
        return Dictionary(uniqueKeysWithValues: records.map { ($0.exploreID, $0) })
    }

    private func persist(_ map: [String: ExploreProgressRecord]) {
        let records = Array(map.values)
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
