import Foundation

/// One-shot story-position handoff for an intentional format switch.
///
/// Destination players consume this **before** `bestRestorePosition` / PSA /
/// metadata restore so a flushed source locator (wrong shape) or a stale
/// destination checkpoint cannot override the translated place. In-memory only —
/// no Storyteller write. Keyed by book ID (one pending open at a time).
public struct FormatSwitchHandoff: Sendable, Equatable {
    public let bookID: BookID
    public let category: LocalMediaCategory
    public let locator: BookLocator
    public let progression: Double
    public let precision: StoryPositionPrecision
    public let createdAt: Date

    public init(
        bookID: BookID,
        category: LocalMediaCategory,
        locator: BookLocator,
        progression: Double,
        precision: StoryPositionPrecision,
        createdAt: Date = Date(),
    ) {
        self.bookID = bookID
        self.category = category
        self.locator = locator
        self.progression = progression
        self.precision = precision
        self.createdAt = createdAt
    }
}

public actor FormatSwitchHandoffStore {
    public static let shared = FormatSwitchHandoffStore()

    private var pending: [String: FormatSwitchHandoff] = [:]

    public init() {}

    private static func key(bookID: BookID) -> String {
        "\(bookID.sourceID)|\(bookID.uuid)"
    }

    /// Replace any prior handoff for this book (supports rapid re-switch).
    public func set(_ handoff: FormatSwitchHandoff) {
        pending[Self.key(bookID: handoff.bookID)] = handoff
        debugLog(
            "[FormatSwitchHandoff] set \(handoff.bookID) \(handoff.category.rawValue) prog=\(handoff.progression) precision=\(handoff.precision.rawValue)"
        )
    }

    /// Returns and clears the pending handoff when category matches (or category is nil).
    public func consume(
        bookID: BookID,
        category: LocalMediaCategory? = nil,
    ) -> FormatSwitchHandoff? {
        let key = Self.key(bookID: bookID)
        guard let handoff = pending[key] else { return nil }
        if let category, handoff.category != category {
            return nil
        }
        pending.removeValue(forKey: key)
        debugLog(
            "[FormatSwitchHandoff] consume \(bookID) \(handoff.category.rawValue) prog=\(handoff.progression)"
        )
        return handoff
    }

    public func peek(bookID: BookID) -> FormatSwitchHandoff? {
        pending[Self.key(bookID: bookID)]
    }

    public func clear(bookID: BookID) {
        pending.removeValue(forKey: Self.key(bookID: bookID))
    }

    public func clearAll() {
        pending.removeAll()
    }
}
