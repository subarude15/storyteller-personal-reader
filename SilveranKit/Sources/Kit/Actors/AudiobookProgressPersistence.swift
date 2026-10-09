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

    public struct AuthoritativeUserAction: Codable, Sendable, Equatable {
        public var bookID: BookID
        public var timestamp: Double

        public init(bookID: BookID, timestamp: Double) {
            self.bookID = bookID
            self.timestamp = timestamp
        }
    }

    public var books: [Book]
    /// Survives process death so deliberate rewinds stay protected after relaunch.
    public var authoritativeUserActions: [AuthoritativeUserAction]

    public init(
        books: [Book] = [],
        authoritativeUserActions: [AuthoritativeUserAction] = [],
    ) {
        self.books = books
        self.authoritativeUserActions = authoritativeUserActions
    }

    enum CodingKeys: String, CodingKey {
        case books
        case authoritativeUserActions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        books = try container.decode([Book].self, forKey: .books)
        authoritativeUserActions =
            try container.decodeIfPresent(
                [AuthoritativeUserAction].self,
                forKey: .authoritativeUserActions,
            ) ?? []
    }
}

public enum CheckpointAppendOutcome: Equatable, Sendable {
    case appended([AudiobookRecoveryCheckpoint])
    case rejectedStale
}

public enum CheckpointSaveResult: Equatable, Sendable {
    case saved
    case rejected(ProgressAcceptance)
    case rejectedStale
    case failed
}

public enum ListeningRestoreResult: Equatable, Sendable {
    case success
    case noActiveBook
    case invalidLocator
    case sessionReplaced
    case seekFailed
    case syncRejected
    case syncFailed
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

/// Track/duration context for turning a historical locator into an exact book time.
/// Absent or incomplete context must yield `nil` — never invent a timestamp.
public struct AudiobookListeningHistoryDisplayContext: Sendable, Equatable {
    public var totalDuration: TimeInterval
    public var trackStartByHref: [String: TimeInterval]

    public init(
        totalDuration: TimeInterval,
        trackStartByHref: [String: TimeInterval] = [:],
    ) {
        self.totalDuration = totalDuration
        self.trackStartByHref = trackStartByHref
    }
}

/// Pure display helpers for Previous Positions (testable, no player side effects).
public enum AudiobookListeningHistoryFormatting {
    /// Exact audiobook position in seconds from historical locator + metadata.
    /// Prefers `t=` track fragment + track start; falls back to progression × duration.
    /// Returns `nil` when the time cannot be determined reliably.
    public static func exactPositionSeconds(
        locator: BookLocator,
        totalProgression: Double,
        context: AudiobookListeningHistoryDisplayContext?,
    ) -> TimeInterval? {
        if let fromTrack = positionSecondsFromTrackFragment(locator: locator, context: context) {
            return fromTrack
        }
        guard let context, context.totalDuration > 0,
            totalProgression.isFinite,
            totalProgression >= 0,
            totalProgression <= 1
        else {
            return nil
        }
        return totalProgression * context.totalDuration
    }

    /// Always `HH:MM:SS`. Returns `nil` when seconds are missing/non-finite.
    public static func formatPositionTimestamp(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }

    /// Localized relative day + time, e.g. `Today, 9:17 PM` / `Yesterday, 9:17 PM` / `Oct 6, 9:17 PM`.
    /// Respects locale and 12/24-hour preferences via `DateFormatter`.
    public static func relativeDayTime(
        _ date: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current,
    ) -> String {
        let time = Self.timeFormatter(locale: locale).string(from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return "Today, \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "Yesterday, \(time)"
        }
        let day = Self.dayFormatter(
            locale: locale,
            calendar: calendar,
            includeYear: calendar.component(.year, from: date) != calendar.component(.year, from: now),
        ).string(from: date)
        return "\(day), \(time)"
    }

    public static func relativeDayTime(
        epochMillis: Double,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current,
    ) -> String {
        relativeDayTime(
            Date(timeIntervalSince1970: epochMillis / 1_000),
            now: now,
            calendar: calendar,
            locale: locale,
        )
    }

    /// Chapter/title fallback when an exact timestamp cannot be shown.
    /// Strips a trailing `, N%` suffix left by older milestone writers.
    public static func fallbackLocationLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let range = trimmed.range(of: #",\s*\d+%$"#, options: .regularExpression) {
            return String(trimmed[..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func positionSecondsFromTrackFragment(
        locator: BookLocator,
        context: AudiobookListeningHistoryDisplayContext?,
    ) -> TimeInterval? {
        guard let context,
            let trackTime = trackFragmentSeconds(locator: locator),
            let start = context.trackStartByHref[locator.href]
        else {
            return nil
        }
        let absolute = start + trackTime
        guard absolute.isFinite, absolute >= 0 else { return nil }
        if context.totalDuration > 0, absolute > context.totalDuration + 1 {
            return nil
        }
        return absolute
    }

    private static func trackFragmentSeconds(locator: BookLocator) -> TimeInterval? {
        guard let fragments = locator.locations?.fragments else { return nil }
        for fragment in fragments {
            let trimmed = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("t=") else { continue }
            let raw = trimmed.dropFirst(2)
            guard let value = Double(raw), value.isFinite, value >= 0 else { continue }
            return value
        }
        return nil
    }

    private static func timeFormatter(locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }

    private static func dayFormatter(
        locale: Locale,
        calendar: Calendar,
        includeYear: Bool,
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate(includeYear ? "MMMdyyyy" : "MMMd")
        return formatter
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
    /// Accidental double-fire window for identical-reason milestones (ms).
    public static let milestoneDuplicateWindowMs: Double = 2_000
    /// Routine pause/background events within this wall-clock window may coalesce (ms).
    public static let milestoneRoutineCoalesceWindowMs: Double = 2 * 60 * 60 * 1_000
    /// Seek landing tolerance in wall-clock seconds (player accuracy), not %.
    /// Must not be implemented as a progression fraction — on long books a
    /// fixed fraction (e.g. 0.0005) balloons to many seconds and defeats the
    /// seconds budget.
    public static let seekToleranceSeconds: TimeInterval = 2.0

    public static func isNearZero(_ progression: Double) -> Bool {
        progression <= zeroEpsilon
    }

    /// Lifecycle pauses that are safe to coalesce when the playhead did not move meaningfully.
    public static func isRoutineListeningMilestoneReason(_ reason: SyncReason) -> Bool {
        switch reason {
            case .appBackgrounding, .userPausedPlayback, .appTerminating:
                return true
            case .userFlippedPage, .userSelectedChapter, .userDraggedSeekBar,
                .userStartedPlayback, .userSkippedForward, .userSkippedBackward,
                .periodicDuringActivePlayback, .periodicWhileReading, .userClosedBook,
                .userRestoredFromHistory, .userConfirmedRestart, .userSwitchedFormat,
                .connectionRestored, .watchReconnected, .relayedFromWatch, .initialLoad,
                .appWokeFromSleep:
                return false
        }
    }

    /// Extract and validate a restore progression from a locator against the
    /// active audiobook's known track/chapter hrefs.
    /// Returns `nil` for missing/out-of-range progression or an href that does
    /// not belong to the open book (unless the generic `"audiobook"` fallback).
    public static func validatedRestoreProgression(
        locator: BookLocator,
        knownHrefs: Set<String>,
    ) -> Double? {
        guard let raw = locator.locations?.totalProgression
            ?? locator.locations?.progression,
            raw.isFinite,
            raw >= 0,
            raw <= 1
        else {
            return nil
        }

        let href = locator.href.trimmingCharacters(in: .whitespacesAndNewlines)
        if href.isEmpty {
            return nil
        }
        // Locators written when track href was unavailable use this fallback.
        if href == "audiobook" {
            return raw
        }
        guard knownHrefs.contains(href) else {
            return nil
        }
        return raw
    }

    /// Equivalent progression width of `seekToleranceSeconds` for a given duration.
    /// Purely informational / for callers that prefer fractions — still seconds-derived.
    public static func seekToleranceFraction(durationSeconds: TimeInterval) -> Double {
        guard durationSeconds > 0 else { return 1 }
        return min(1, seekToleranceSeconds / durationSeconds)
    }

    /// True when the landed playhead is within `seekToleranceSeconds` of target.
    /// Comparison is always in wall-clock seconds, never a fixed %-of-book floor.
    public static func seekLandedWithinTolerance(
        targetProgression: Double,
        landedProgression: Double,
        durationSeconds: TimeInterval,
    ) -> Bool {
        guard durationSeconds > 0,
            targetProgression.isFinite,
            landedProgression.isFinite
        else {
            return false
        }
        let errorSeconds = abs(landedProgression - targetProgression) * durationSeconds
        return errorSeconds <= seekToleranceSeconds
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

    /// Append by **event timestamp**, not wall-clock finish order.
    /// A delayed async write with an older event time cannot become latest unless
    /// it is an explicit user action (seek / restart / history restore).
    public static func appendCheckpoint(
        existing: [AudiobookRecoveryCheckpoint],
        new: AudiobookRecoveryCheckpoint,
        isExplicitUserAction: Bool = false,
    ) -> CheckpointAppendOutcome {
        if let latest = existing.first,
            new.timestamp + 0.5 < latest.timestamp,
            !isExplicitUserAction
        {
            return .rejectedStale
        }

        var next = existing.filter {
            abs($0.timestamp - new.timestamp) > 0.5 || $0.reason != new.reason
        }
        next.append(new)
        next.sort { lhs, rhs in
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp > rhs.timestamp
            }
            return lhs.updatedAt > rhs.updatedAt
        }
        if next.count > maxCheckpointsPerBook {
            // Keep newest-by-event-time; never drop the only remaining entry.
            next = Array(next.prefix(maxCheckpointsPerBook))
        }
        if next.isEmpty {
            next = [new]
        }
        return .appended(next)
    }

    public static func appendMilestone(
        existing: [AudiobookListeningMilestone],
        new: AudiobookListeningMilestone,
    ) -> [AudiobookListeningMilestone] {
        if let last = existing.first, shouldCoalesceListeningMilestone(last: last, new: new) {
            var replaced = existing
            // Prefer the later event clock; out-of-order older writes must not clobber.
            if new.timestamp >= last.timestamp {
                replaced[0] = new
            }
            return replaced
        }
        var next = existing
        next.insert(new, at: 0)
        if next.count > maxListeningMilestonesPerBook {
            next = Array(next.prefix(maxListeningMilestonesPerBook))
        }
        return next
    }

    /// Conservative history cleanup: coalesce routine pause/background spam at the same
    /// playhead, plus accidental same-reason double-fires. Never collapses seeks, chapter
    /// changes, restores, or other meaningful actions. Does not touch the checkpoint ring.
    public static func shouldCoalesceListeningMilestone(
        last: AudiobookListeningMilestone,
        new: AudiobookListeningMilestone,
    ) -> Bool {
        // Compare full-precision progression — never rounded percent labels.
        guard abs(last.totalProgression - new.totalProgression) < milestoneProgressEpsilon else {
            return false
        }
        let deltaMs = abs(last.timestamp - new.timestamp)
        if last.reason == new.reason, deltaMs < milestoneDuplicateWindowMs {
            return true
        }
        guard isRoutineListeningMilestoneReason(last.reason),
            isRoutineListeningMilestoneReason(new.reason),
            deltaMs < milestoneRoutineCoalesceWindowMs
        else {
            return false
        }
        return true
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
