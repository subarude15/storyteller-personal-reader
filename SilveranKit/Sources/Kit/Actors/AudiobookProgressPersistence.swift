import Foundation

/// Durable recovery checkpoint for Storyteller audiobooks.
/// Independent of Storyteller upload cadence and of sync-history audit entries.
public struct AudiobookRecoveryCheckpoint: Codable, Sendable, Equatable, Hashable {
    public var bookID: BookID
    public var locator: BookLocator
    public var totalProgression: Double
    /// Position event time (unix ms). Used for conflict ordering — not “highest % wins.”
    public var timestamp: Double
    public var reason: String
    public var sessionGeneration: UInt64
    /// Wall-clock write time (unix ms).
    public var updatedAt: Double

    public init(
        bookID: BookID,
        locator: BookLocator,
        totalProgression: Double,
        timestamp: Double,
        reason: String,
        sessionGeneration: UInt64,
        updatedAt: Double = floor(Date().timeIntervalSince1970 * 1_000),
    ) {
        self.bookID = bookID
        self.locator = locator
        self.totalProgression = min(max(totalProgression, 0), 1)
        self.timestamp = timestamp
        self.reason = reason
        self.sessionGeneration = sessionGeneration
        self.updatedAt = updatedAt
    }

    public var progressFraction: Double { totalProgression }
}

/// Meaningful listening-session milestone for Previous Positions UI (~20/book).
/// Not written on every 5–10s recovery checkpoint.
public struct AudiobookListeningMilestone: Codable, Sendable, Equatable, Hashable {
    public var bookID: BookID
    public var locator: BookLocator
    public var totalProgression: Double
    public var timestamp: Double
    public var humanTimestamp: String
    public var locationDescription: String
    public var reason: SyncReason

    public init(
        bookID: BookID,
        locator: BookLocator,
        totalProgression: Double,
        timestamp: Double,
        locationDescription: String,
        reason: SyncReason,
        humanTimestamp: String? = nil,
    ) {
        self.bookID = bookID
        self.locator = locator
        self.totalProgression = min(max(totalProgression, 0), 1)
        self.timestamp = timestamp
        self.humanTimestamp =
            humanTimestamp
            ?? SilveranDate.shortDateTime(Date(timeIntervalSince1970: timestamp / 1_000))
        self.locationDescription = locationDescription
        self.reason = reason
    }

    public var percentLabel: String {
        "\(Int((totalProgression * 100).rounded()))%"
    }
}

/// Soft pointer for paused Now Playing restore across process launches.
public struct AudiobookPausedSessionRecord: Codable, Sendable, Equatable, Hashable {
    public var bookID: BookID
    public var updatedAt: Double
    /// Cleared when user explicitly Stops / Closes / switches media.
    public var eligibleForRestore: Bool

    public init(
        bookID: BookID,
        updatedAt: Double = floor(Date().timeIntervalSince1970 * 1_000),
        eligibleForRestore: Bool = true,
    ) {
        self.bookID = bookID
        self.updatedAt = updatedAt
        self.eligibleForRestore = eligibleForRestore
    }
}

public struct PersistedAudiobookCheckpoints: Codable, Sendable {
    public struct Book: Codable, Sendable {
        public var bookID: BookID
        /// Newest first. Small ring for crash-safe recovery (not UI history).
        public var checkpoints: [AudiobookRecoveryCheckpoint]
    }

    public var books: [Book]

    public init(books: [Book] = []) {
        self.books = books
    }
}

public struct PersistedAudiobookListeningHistory: Codable, Sendable {
    public struct Book: Codable, Sendable {
        public var bookID: BookID
        public var milestones: [AudiobookListeningMilestone]
    }

    public var books: [Book]

    public init(books: [Book] = []) {
        self.books = books
    }
}

public enum ProgressAcceptance: Equatable, Sendable {
    case accept
    case rejectUninitialized
    case rejectUninitializedZero
    case rejectSuspiciousZero(knownProgress: Double)
    case rejectStaleVersusUserAction(userActionTimestamp: Double)
}

public struct ProgressConflictInput: Sendable, Equatable {
    public var incomingProgression: Double
    public var incomingTimestamp: Double
    public var playheadInitialized: Bool
    /// Seek, confirmed restart, history restore, explicit rewind.
    public var isExplicitUserAction: Bool
    public var knownBestProgression: Double?
    public var lastAuthoritativeUserActionTimestamp: Double?

    public init(
        incomingProgression: Double,
        incomingTimestamp: Double,
        playheadInitialized: Bool,
        isExplicitUserAction: Bool,
        knownBestProgression: Double? = nil,
        lastAuthoritativeUserActionTimestamp: Double? = nil,
    ) {
        self.incomingProgression = incomingProgression
        self.incomingTimestamp = incomingTimestamp
        self.playheadInitialized = playheadInitialized
        self.isExplicitUserAction = isExplicitUserAction
        self.knownBestProgression = knownBestProgression
        self.lastAuthoritativeUserActionTimestamp = lastAuthoritativeUserActionTimestamp
    }
}

public enum AudiobookProgressConflict {
    public static let zeroEpsilon: Double = 0.005
    public static let suspiciousKnownThreshold: Double = 0.05
    public static let maxCheckpointsPerBook = 3
    public static let maxListeningMilestonesPerBook = 20
    public static let checkpointIntervalSeconds: TimeInterval = 7
    /// Minimum progression delta before recording another listening milestone.
    public static let milestoneProgressEpsilon: Double = 0.002

    public static func isNearZero(_ progression: Double) -> Bool {
        progression <= zeroEpsilon
    }

    /// Explicit, testable conflict rules for Storyteller audiobook progress writes.
    public static func evaluate(_ input: ProgressConflictInput) -> ProgressAcceptance {
        if !input.playheadInitialized {
            if isNearZero(input.incomingProgression) {
                return .rejectUninitializedZero
            }
            return .rejectUninitialized
        }

        if !input.isExplicitUserAction,
            let userTs = input.lastAuthoritativeUserActionTimestamp,
            input.incomingTimestamp + 0.5 < userTs
        {
            return .rejectStaleVersusUserAction(userActionTimestamp: userTs)
        }

        if isNearZero(input.incomingProgression),
            !input.isExplicitUserAction,
            let known = input.knownBestProgression,
            known >= suspiciousKnownThreshold
        {
            return .rejectSuspiciousZero(knownProgress: known)
        }

        return .accept
    }

    /// Restore by newest valid timestamp — never “highest historical %.”
    public static func preferredRestore(
        candidates: [(progression: Double, timestamp: Double, source: String)]
    ) -> (progression: Double, timestamp: Double, source: String)? {
        let valid = candidates.filter { $0.timestamp > 0 && $0.progression >= 0 && $0.progression <= 1 }
        guard !valid.isEmpty else { return nil }
        return valid.max(by: { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp < rhs.timestamp
            }
            // Tie-break: prefer non-zero over uninitialized-looking zero at same ts.
            if isNearZero(lhs.progression) != isNearZero(rhs.progression) {
                return isNearZero(lhs.progression)
            }
            return false
        })
    }

    public static func appendCheckpoint(
        existing: [AudiobookRecoveryCheckpoint],
        new: AudiobookRecoveryCheckpoint,
    ) -> [AudiobookRecoveryCheckpoint] {
        var next = existing.filter {
            abs($0.timestamp - new.timestamp) > 0.5 || $0.reason != new.reason
        }
        next.insert(new, at: 0)
        if next.count > maxCheckpointsPerBook {
            // Always keep index 0 (latest valid). Drop oldest only.
            next = Array(next.prefix(maxCheckpointsPerBook))
        }
        // Guarantee latest remains even if pruning somehow emptied.
        if next.isEmpty {
            next = [new]
        }
        return next
    }

    public static func appendMilestone(
        existing: [AudiobookListeningMilestone],
        new: AudiobookListeningMilestone,
    ) -> [AudiobookListeningMilestone] {
        if let last = existing.first,
            abs(last.totalProgression - new.totalProgression) < milestoneProgressEpsilon,
            last.reason == new.reason,
            abs(last.timestamp - new.timestamp) < 2_000
        {
            var replaced = existing
            replaced[0] = new
            return replaced
        }
        var next = existing
        next.insert(new, at: 0)
        if next.count > maxListeningMilestonesPerBook {
            next = Array(next.prefix(maxListeningMilestonesPerBook))
        }
        return next
    }

    public static func shouldNavigateToIncomingServer(
        incomingTimestamp: Double,
        lastUserActionTimestamp: Double?,
        autoSyncEnabled: Bool,
    ) -> Bool {
        guard autoSyncEnabled else { return false }
        if let userTs = lastUserActionTimestamp, incomingTimestamp + 0.5 < userTs {
            return false
        }
        return true
    }
}

public enum AudiobookProgressRestoreSource: String, Sendable {
    case checkpoint
    case pendingSync
    case server
    case bookMetadata
    case none
}
