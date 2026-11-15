import Foundation

public enum ReadingMotivationPinnedStat: String, Codable, CaseIterable, Sendable, Hashable {
    case todayReading
    case todayListening
    case weekTotal
    case weekReading
    case weekListening
    case currentStreak
    case longestStreak
    case activityDays
    case finishedTitles

    public var label: String {
        switch self {
            case .todayReading: return "Read today"
            case .todayListening: return "Listened today"
            case .weekTotal: return "This week"
            case .weekReading: return "Read this week"
            case .weekListening: return "Listened this week"
            case .currentStreak: return "Current streak"
            case .longestStreak: return "Longest streak"
            case .activityDays: return "Active days"
            case .finishedTitles: return "Finished titles"
        }
    }
}

/// Device-local goals and presentation preferences. Missing fields use v1 defaults.
public struct ReadingMotivationSettings: Codable, Equatable, Sendable {
    public static let defaultPinnedStats: [ReadingMotivationPinnedStat] = [
        .todayReading, .weekTotal, .currentStreak,
    ]

    public var dailyReadingGoalMinutes: Int
    public var dailyListeningGoalMinutes: Int
    public var pinnedStats: [ReadingMotivationPinnedStat]
    public var notificationsEnabled: Bool
    public var quietHour: Int
    public var quietMinute: Int

    public init(
        dailyReadingGoalMinutes: Int = 30,
        dailyListeningGoalMinutes: Int = 30,
        pinnedStats: [ReadingMotivationPinnedStat] = ReadingMotivationSettings.defaultPinnedStats,
        notificationsEnabled: Bool = false,
        quietHour: Int = 20,
        quietMinute: Int = 30
    ) {
        self.dailyReadingGoalMinutes = Self.validGoal(dailyReadingGoalMinutes) ?? 30
        self.dailyListeningGoalMinutes = Self.validGoal(dailyListeningGoalMinutes) ?? 30
        self.pinnedStats = Self.normalizedPins(pinnedStats)
        self.notificationsEnabled = notificationsEnabled
        self.quietHour = (0...23).contains(quietHour) ? quietHour : 20
        self.quietMinute = (0...59).contains(quietMinute) ? quietMinute : 30
    }

    private enum CodingKeys: String, CodingKey {
        case dailyReadingGoalMinutes
        case dailyListeningGoalMinutes
        case pinnedStats
        case notificationsEnabled
        case quietHour
        case quietMinute
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            dailyReadingGoalMinutes: try values.decodeIfPresent(Int.self, forKey: .dailyReadingGoalMinutes) ?? 30,
            dailyListeningGoalMinutes: try values.decodeIfPresent(Int.self, forKey: .dailyListeningGoalMinutes) ?? 30,
            pinnedStats: try values.decodeIfPresent([ReadingMotivationPinnedStat].self, forKey: .pinnedStats)
                ?? Self.defaultPinnedStats,
            notificationsEnabled: try values.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? false,
            quietHour: try values.decodeIfPresent(Int.self, forKey: .quietHour) ?? 20,
            quietMinute: try values.decodeIfPresent(Int.self, forKey: .quietMinute) ?? 30
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(dailyReadingGoalMinutes, forKey: .dailyReadingGoalMinutes)
        try values.encode(dailyListeningGoalMinutes, forKey: .dailyListeningGoalMinutes)
        try values.encode(pinnedStats, forKey: .pinnedStats)
        try values.encode(notificationsEnabled, forKey: .notificationsEnabled)
        try values.encode(quietHour, forKey: .quietHour)
        try values.encode(quietMinute, forKey: .quietMinute)
    }

    private static func validGoal(_ value: Int) -> Int? {
        (5...240).contains(value) ? value : nil
    }

    private static func normalizedPins(_ values: [ReadingMotivationPinnedStat]) -> [ReadingMotivationPinnedStat] {
        var seen = Set<ReadingMotivationPinnedStat>()
        return values.filter { seen.insert($0).inserted }.prefix(3).map { $0 }
    }
}

public struct ReadingMotivationDay: Equatable, Sendable, Identifiable {
    public var id: Date { day }
    public let day: Date
    public let readingSeconds: TimeInterval
    public let listeningSeconds: TimeInterval

    public init(day: Date, readingSeconds: TimeInterval, listeningSeconds: TimeInterval) {
        self.day = day
        self.readingSeconds = readingSeconds.isFinite && readingSeconds > 0 ? readingSeconds : 0
        self.listeningSeconds = listeningSeconds.isFinite && listeningSeconds > 0 ? listeningSeconds : 0
    }

    public var seconds: TimeInterval { readingSeconds + listeningSeconds }
}

/// Frozen local-calendar date identity for activity already removed from SessionTracker.
public struct ReadingMotivationActivityDay: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let calendarIdentifier: String
    public let timeZoneIdentifier: String

    public var dayKey: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var id: String { dayKey + "|" + calendarIdentifier + "|" + timeZoneIdentifier }

    public init(date: Date, calendar: Calendar, timeZoneIdentifier: String? = nil) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        year = components.year ?? 0
        month = components.month ?? 0
        day = components.day ?? 0
        calendarIdentifier = String(describing: calendar.identifier)
        self.timeZoneIdentifier = timeZoneIdentifier ?? calendar.timeZone.identifier
    }
}

public struct ReadingMotivationStreaks: Equatable, Sendable {
    public let current: Int
    public let longest: Int
}

public struct ReadingMotivationWeeklyReceipt: Equatable, Sendable {
    public let weekStart: Date
    public let readingSeconds: TimeInterval
    public let listeningSeconds: TimeInterval
    public let activityDays: Int
    public let completedTitles: Int
    public let streakDays: Int

    public var seconds: TimeInterval { readingSeconds + listeningSeconds }
    public var minutes: Int { Int((seconds / 60).rounded(.down)) }
}

public enum ReadingMotivationFinishProjection: Equatable, Sendable {
    case finished
    case estimate(date: Date, basis: String)
}

public enum ReadingMotivationCalculations {
    /// Keep live contributions consistent with the existing persisted-session
    /// threshold so a discarded short session cannot create a temporary streak.
    public static func isRecordableSession(duration: TimeInterval) -> Bool {
        duration.isFinite && duration >= 30
    }

    /// Splits real, deduplicated session time across local calendar days.
    public static func dailyTotals(
        sessions: [InkampStatsSessionRecord],
        calendar: Calendar,
        now: Date
    ) -> [ReadingMotivationDay] {
        var totals: [Date: (reading: TimeInterval, listening: TimeInterval)] = [:]
        for session in normalizedSessions(sessions, now: now) {
            let span = session.endedAt.timeIntervalSince(session.startedAt)
            let duration = min(session.durationSeconds, span)
            guard span > 0, duration > 0 else { continue }
            var cursor = session.startedAt
            while cursor < session.endedAt,
                let interval = calendar.dateInterval(of: .day, for: cursor),
                interval.end > cursor
            {
                let segmentEnd = min(session.endedAt, interval.end)
                let seconds = duration * segmentEnd.timeIntervalSince(cursor) / span
                var total = totals[interval.start, default: (0, 0)]
                switch session.kind {
                    case .reading: total.reading += seconds
                    case .listening: total.listening += seconds
                }
                totals[interval.start] = total
                cursor = segmentEnd
            }
        }
        return totals.keys.sorted().compactMap { day in
            guard let value = totals[day] else { return nil }
            return ReadingMotivationDay(
                day: day,
                readingSeconds: value.reading,
                listeningSeconds: value.listening
            )
        }
    }

    public static func streaks(
        sessions: [InkampStatsSessionRecord],
        calendar: Calendar,
        now: Date,
        archivedActivityDays: [ReadingMotivationActivityDay] = []
    ) -> ReadingMotivationStreaks {
        let today = localDayKey(now, calendar: calendar)
        var activeDays = Set(dailyTotals(sessions: sessions, calendar: calendar, now: now).map {
            localDayKey($0.day, calendar: calendar)
        })
        let calendarIdentifier = String(describing: calendar.identifier)
        activeDays.formUnion(archivedActivityDays.filter {
            $0.calendarIdentifier == calendarIdentifier
        }.map(\.dayKey).filter {
                $0 <= today && ordinalDate(for: $0, calendar: calendar) != nil
        })
        guard !activeDays.isEmpty else { return ReadingMotivationStreaks(current: 0, longest: 0) }

        var longest = 0
        var run = 0
        var previous: String?
        for dayKey in activeDays.sorted() {
            if let previous, nextDayKey(after: previous, calendar: calendar) == dayKey {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = dayKey
        }

        var cursor = today
        if !activeDays.contains(cursor) {
            guard let yesterday = previousDayKey(before: today, calendar: calendar),
                activeDays.contains(yesterday)
            else {
                return ReadingMotivationStreaks(current: 0, longest: longest)
            }
            cursor = yesterday
        }
        var current = 0
        while activeDays.contains(cursor) {
            current += 1
            guard let previousDay = previousDayKey(before: cursor, calendar: calendar) else { break }
            cursor = previousDay
        }
        return ReadingMotivationStreaks(current: current, longest: longest)
    }

    public static func archiveExpiredActivityDays(
        sessions: [InkampStatsSessionRecord],
        before cutoff: Date,
        existing: Set<ReadingMotivationActivityDay>,
        calendar: Calendar,
        now: Date
    ) -> Set<ReadingMotivationActivityDay> {
        let expired = normalizedSessions(sessions, now: now).filter { $0.endedAt < cutoff }
        let days = dailyTotals(sessions: expired, calendar: calendar, now: now)
        let existingKeys = Set(existing.map(\.dayKey))
        let additions = days
            .map { ReadingMotivationActivityDay(date: $0.day, calendar: calendar) }
            .filter { !existingKeys.contains($0.dayKey) }
        return existing.union(additions)
    }

    public static func migrateLegacyActivityDays(
        staleDates: Set<Date>,
        sessions: [InkampStatsSessionRecord],
        before cutoff: Date,
        calendar: Calendar,
        now: Date
    ) -> Set<ReadingMotivationActivityDay> {
        // v1 stored local-midnight instants without the source time zone and included
        // still-retained sessions. Rebuild overlapping days from sessions; freeze orphaned
        // markers as UTC date identities so they are never reinterpreted after travel.
        let normalized = normalizedSessions(sessions, now: now)
        var migrated = archiveExpiredActivityDays(
            sessions: sessions,
            before: cutoff,
            existing: [],
            calendar: calendar,
            now: now
        )
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        for marker in staleDates {
            let hasSessionSource = normalized.contains {
                $0.startedAt < marker.addingTimeInterval(25 * 3600) && $0.endedAt > marker
            }
            guard !hasSessionSource else { continue }
            migrated.insert(
                ReadingMotivationActivityDay(
                    date: marker, calendar: utc, timeZoneIdentifier: "legacy-UTC"
                )
            )
        }
        return migrated
    }

    public static func weeklyReceipt(
        sessions: [InkampStatsSessionRecord],
        finished: [InkampStatsFinishedRecord],
        weekOffset: Int,
        calendar: Calendar,
        now: Date,
        archivedActivityDays: [ReadingMotivationActivityDay] = []
    ) -> ReadingMotivationWeeklyReceipt {
        let current = calendar.dateInterval(of: .weekOfYear, for: now)
            ?? DateInterval(start: calendar.startOfDay(for: now), duration: 7 * 24 * 3600)
        let shiftedStart = calendar.date(byAdding: .weekOfYear, value: weekOffset, to: current.start)
            ?? current.start
        let range = calendar.dateInterval(of: .weekOfYear, for: shiftedStart)
            ?? DateInterval(start: shiftedStart, duration: current.duration)
        let days = dailyTotals(sessions: sessions, calendar: calendar, now: now).filter {
            $0.day >= range.start && $0.day < range.end
        }
        let titleIDs = Set(finished.compactMap { record -> String? in
            guard record.finishedAt >= range.start,
                record.finishedAt < range.end,
                record.finishedAt <= now
            else { return nil }
            let id = record.mediaID.trimmingCharacters(in: .whitespacesAndNewlines)
            return id.isEmpty ? nil : id
        })
        let streakReference = min(now, range.end.addingTimeInterval(-1))
        return ReadingMotivationWeeklyReceipt(
            weekStart: range.start,
            readingSeconds: days.reduce(0) { $0 + $1.readingSeconds },
            listeningSeconds: days.reduce(0) { $0 + $1.listeningSeconds },
            activityDays: days.filter { $0.seconds > 0 }.count,
            completedTitles: titleIDs.count,
            streakDays: streaks(
                sessions: sessions,
                calendar: calendar,
                now: streakReference,
                archivedActivityDays: archivedActivityDays
            ).current
        )
    }

    private static func nextDayKey(after key: String, calendar: Calendar) -> String? {
        guard let date = ordinalDate(for: key, calendar: calendar),
            let next = calendar.date(byAdding: .day, value: 1, to: date)
        else { return nil }
        return localDayKey(next, calendar: calendar)
    }

    private static func previousDayKey(before key: String, calendar: Calendar) -> String? {
        guard let date = ordinalDate(for: key, calendar: calendar),
            let previous = calendar.date(byAdding: .day, value: -1, to: date)
        else { return nil }
        return localDayKey(previous, calendar: calendar)
    }

    fileprivate static func ordinalDate(
        for key: String,
        calendar: Calendar
    ) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts[0] > 0 else { return nil }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components) else { return nil }
        let verified = calendar.dateComponents([.year, .month, .day], from: date)
        guard verified.year == parts[0], verified.month == parts[1], verified.day == parts[2] else { return nil }
        return date
    }

    public static func audioMediaID(for snapshot: AudioSessionSnapshot) -> String {
        switch snapshot.kind {
            case .audiobook(let id), .readaloud(let id): return String(describing: id)
            case .podcast(let id): return "podcast/" + id
        }
    }

    /// Use one matching live snapshot atomically, never an old queue fraction
    /// with a new playback rate. Unknown live length remains unknown.
    public static func projectedAudioFinish(
        snapshot: AudioSessionSnapshot,
        expectedMediaID: String,
        calendar: Calendar,
        now: Date
    ) -> ReadingMotivationFinishProjection? {
        guard audioMediaID(for: snapshot) == expectedMediaID,
            snapshot.elapsedSeconds.isFinite, snapshot.elapsedSeconds >= 0
        else { return nil }
        let duration = snapshot.durationSeconds
        let progress = duration.isFinite && duration > 0
            ? min(snapshot.elapsedSeconds / duration, 1) : snapshot.bookProgress
        return projectedFinish(
            sessions: [], mediaID: expectedMediaID, progress: progress,
            totalUnits: duration, playbackRate: snapshot.playbackRate,
            calendar: calendar, now: now
        )
    }

    /// Audio uses its known remaining content and current playback rate. Ebooks
    /// require at least two real progress checkpoints to establish a reading pace.
    public static func projectedFinish(
        sessions: [InkampStatsSessionRecord],
        mediaID: String,
        progress: Double,
        totalUnits: Double?,
        playbackRate: Double?,
        paceKind: InkampStatsSessionRecord.Kind? = nil,
        paceBasis: String = "Based on your recent reading pace",
        calendar: Calendar,
        now: Date
    ) -> ReadingMotivationFinishProjection? {
        guard progress.isFinite, progress >= 0 else { return nil }
        // Only confirmed full progress is finished. Near-complete (e.g. 99.5%)
        // with known length still has remaining content to estimate.
        if progress >= 1 { return .finished }
        guard let totalUnits, totalUnits.isFinite, totalUnits > 0 else { return nil }
        let remaining = totalUnits * (1 - progress)
        guard remaining.isFinite, remaining > 0 else { return nil }

        let seconds: TimeInterval
        let basis: String
        if let playbackRate {
            guard playbackRate.isFinite, playbackRate > 0 else { return nil }
            seconds = remaining / playbackRate
            basis = "At \(String(format: "%.2g", playbackRate))× playback"
        } else {
            // Pace uses wall time across the whole interval between real progress
            // checkpoints, including stalled/rereading sessions and missing mid
            // checkpoints. Only positive advances contribute units; regressions
            // restart the baseline instead of inventing negative pace.
            let observations = normalizedSessions(sessions, now: now)
                .filter { session in
                    session.mediaID == mediaID
                        && (paceKind.map({ session.kind == $0 }) ?? true)
                }
                .sorted { $0.endedAt < $1.endedAt }
            var unitsGained: Double = 0
            var secondsSpent: TimeInterval = 0
            var baselineProgress: Double?
            var pendingSeconds: TimeInterval = 0
            for session in observations {
                let work = min(
                    session.durationSeconds,
                    session.endedAt.timeIntervalSince(session.startedAt)
                )
                guard work.isFinite, work > 0 else { continue }
                let checkpoint: Double? = {
                    guard let progress = session.endProgress,
                        progress.isFinite,
                        progress >= 0,
                        progress <= 1
                    else { return nil }
                    return progress
                }()
                if let progress = checkpoint {
                    if let baseline = baselineProgress {
                        if progress > baseline {
                            unitsGained += totalUnits * (progress - baseline)
                            secondsSpent += pendingSeconds + work
                            baselineProgress = progress
                            pendingSeconds = 0
                        } else if progress < baseline {
                            baselineProgress = progress
                            pendingSeconds = 0
                        } else {
                            pendingSeconds += work
                        }
                    } else {
                        baselineProgress = progress
                        pendingSeconds = 0
                    }
                } else if baselineProgress != nil {
                    pendingSeconds += work
                }
            }
            // Work after the last advancing checkpoint remains observed effort,
            // not free time. Include trailing stalls/missing checkpoints too.
            secondsSpent += pendingSeconds
            guard unitsGained.isFinite, unitsGained > 0, secondsSpent > 0 else { return nil }
            seconds = remaining / (unitsGained / secondsSpent)
            basis = paceBasis
        }
        guard seconds.isFinite, seconds > 0 else { return nil }
        // Double(Int.max) rounds to 2^63; Int(that) traps. Guard the rounded value
        // against the first unrepresentable bound before conversion.
        let roundedUp = seconds.rounded(.up)
        guard roundedUp.isFinite, roundedUp > 0, roundedUp < 0x1p63 else { return nil }
        // Preserve subsecond precision rather than promoting floating-point
        // multiplication noise (e.g. 5.000000000000004) to an extra second.
        let finishDate = now.addingTimeInterval(seconds)
        guard finishDate.timeIntervalSince1970.isFinite else { return nil }
        return .estimate(date: finishDate, basis: basis)
    }

    /// Local calendar day that anchors the current streak for widget dating.
    /// Today if active today, otherwise yesterday when the streak still has grace, else today.
    public static func streakActivityDayKey(
        sessions: [InkampStatsSessionRecord],
        calendar: Calendar,
        now: Date,
        archivedActivityDays: [ReadingMotivationActivityDay] = []
    ) -> String {
        let today = localDayKey(now, calendar: calendar)
        var activeDays = Set(dailyTotals(sessions: sessions, calendar: calendar, now: now).map {
            localDayKey($0.day, calendar: calendar)
        })
        let calendarIdentifier = String(describing: calendar.identifier)
        activeDays.formUnion(archivedActivityDays.filter {
            $0.calendarIdentifier == calendarIdentifier
        }.map(\.dayKey).filter {
            $0 <= today && ordinalDate(for: $0, calendar: calendar) != nil
        })
        if activeDays.contains(today) { return today }
        if let yesterday = previousDayKey(before: today, calendar: calendar),
            activeDays.contains(yesterday)
        {
            return yesterday
        }
        return today
    }

    public static func localDayKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func normalizedSessions(
        _ sessions: [InkampStatsSessionRecord],
        now: Date
    ) -> [InkampStatsSessionRecord] {
        var byID: [UUID: InkampStatsSessionRecord] = [:]
        for session in sessions {
            let id = session.mediaID.trimmingCharacters(in: .whitespacesAndNewlines)
            let originalSpan = session.endedAt.timeIntervalSince(session.startedAt)
            guard !id.isEmpty,
                session.startedAt.timeIntervalSince1970.isFinite,
                session.endedAt.timeIntervalSince1970.isFinite,
                session.startedAt <= session.endedAt,
                session.startedAt <= now,
                session.durationSeconds.isFinite,
                session.durationSeconds > 0,
                originalSpan.isFinite,
                originalSpan > 0
            else { continue }

            var endedAt = session.endedAt
            var duration = min(session.durationSeconds, originalSpan)
            var clippedToNow = false
            if endedAt > now {
                // Historical reference (e.g. prior-week Sunday night): keep the
                // valid earlier portion instead of discarding the whole session.
                let clippedSpan = now.timeIntervalSince(session.startedAt)
                guard clippedSpan.isFinite, clippedSpan > 0 else { continue }
                duration = duration * (clippedSpan / originalSpan)
                endedAt = now
                clippedToNow = true
                guard duration.isFinite, duration > 0 else { continue }
            }

            if let prior = byID[session.id],
                prior.endedAt > endedAt
                    || (prior.endedAt == endedAt && prior.durationSeconds >= duration)
            {
                continue
            }
            var valid = session
            valid.endedAt = endedAt
            valid.durationSeconds = min(duration, endedAt.timeIntervalSince(session.startedAt))
            // endProgress is observed at endedAt. Clipping to a historical "now"
            // must not retain a checkpoint that only existed after that reference.
            if clippedToNow {
                valid.endProgress = nil
            }
            byID[session.id] = valid
        }
        return byID.values.sorted {
            $0.endedAt == $1.endedAt ? $0.id.uuidString < $1.id.uuidString : $0.endedAt < $1.endedAt
        }
    }
}

public struct ContinueWidgetTiming: Equatable, Sendable {
    public let elapsedSeconds: Double
    public let remainingWallSeconds: Double?

    public static func calculate(
        progress: Double?,
        elapsedSeconds: Double?,
        durationSeconds: Double?,
        rate: Double?
    ) -> ContinueWidgetTiming? {
        let knownElapsed: Double? = {
            guard let elapsedSeconds, elapsedSeconds.isFinite, elapsedSeconds >= 0 else { return nil }
            return elapsedSeconds
        }()
        guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else {
            // Independently known elapsed stands alone; never invent from progress
            // when total length is absent. Remaining stays unknown.
            guard let elapsed = knownElapsed else { return nil }
            return ContinueWidgetTiming(elapsedSeconds: elapsed, remainingWallSeconds: nil)
        }
        let duration = durationSeconds
        let elapsed: Double
        if let knownElapsed {
            elapsed = min(knownElapsed, duration)
        } else if let progress, progress.isFinite {
            elapsed = min(max(progress, 0), 1) * duration
        } else {
            return nil
        }
        let remaining: Double?
        if let rate {
            guard rate.isFinite, rate > 0 else { return nil }
            let wallSeconds = max(0, duration - elapsed) / rate
            guard wallSeconds.isFinite else { return nil }
            remaining = wallSeconds
        } else {
            remaining = nil
        }
        return ContinueWidgetTiming(
            elapsedSeconds: elapsed,
            remainingWallSeconds: remaining
        )
    }

    private init(elapsedSeconds: Double, remainingWallSeconds: Double?) {
        self.elapsedSeconds = elapsedSeconds
        self.remainingWallSeconds = remainingWallSeconds
    }
}

public enum ReadingMotivationNotificationKind: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case rescue
    case pace
    case receipt

    public var priority: Int {
        switch self {
            case .rescue: return 3
            case .pace: return 2
            case .receipt: return 1
        }
    }
}

public struct ReadingMotivationNotificationCandidate: Equatable, Sendable {
    public let kind: ReadingMotivationNotificationKind
    public let deliveryDate: Date

    public init(kind: ReadingMotivationNotificationKind, deliveryDate: Date) {
        self.kind = kind
        self.deliveryDate = deliveryDate
    }
}

public struct ReadingMotivationNotificationState: Codable, Equatable, Sendable {
    public var consumedDayKey: String?
    public var consumedDayKeys: Set<String>
    public var pendingKind: ReadingMotivationNotificationKind?
    public var pendingDayKey: String?
    public var pendingDeliveryDate: Date?

    public init(
        consumedDayKey: String? = nil,
        consumedDayKeys: Set<String> = [],
        pendingKind: ReadingMotivationNotificationKind? = nil,
        pendingDayKey: String? = nil,
        pendingDeliveryDate: Date? = nil
    ) {
        self.consumedDayKey = consumedDayKey
        var keys = consumedDayKeys
        if let consumedDayKey { keys.insert(consumedDayKey) }
        self.consumedDayKeys = Self.bounded(keys)
        self.pendingKind = pendingKind
        self.pendingDayKey = pendingDayKey
        self.pendingDeliveryDate = pendingDeliveryDate
    }

    private enum CodingKeys: String, CodingKey {
        case consumedDayKey
        case consumedDayKeys
        case pendingKind
        case pendingDayKey
        case pendingDeliveryDate
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            consumedDayKey: try values.decodeIfPresent(String.self, forKey: .consumedDayKey),
            consumedDayKeys: try values.decodeIfPresent(Set<String>.self, forKey: .consumedDayKeys) ?? [],
            pendingKind: try values.decodeIfPresent(ReadingMotivationNotificationKind.self, forKey: .pendingKind),
            pendingDayKey: try values.decodeIfPresent(String.self, forKey: .pendingDayKey),
            pendingDeliveryDate: try values.decodeIfPresent(Date.self, forKey: .pendingDeliveryDate)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(consumedDayKey, forKey: .consumedDayKey)
        try values.encode(consumedDayKeys, forKey: .consumedDayKeys)
        try values.encodeIfPresent(pendingKind, forKey: .pendingKind)
        try values.encodeIfPresent(pendingDayKey, forKey: .pendingDayKey)
        try values.encodeIfPresent(pendingDeliveryDate, forKey: .pendingDeliveryDate)
    }

    public static let empty = ReadingMotivationNotificationState()

    public func hasConsumedDayKey(_ key: String) -> Bool {
        consumedDayKeys.contains(key) || consumedDayKey == key
    }

    public mutating func consume(dayKey: String) {
        consumedDayKey = dayKey
        consumedDayKeys.insert(dayKey)
        consumedDayKeys = Self.bounded(consumedDayKeys)
    }

    private static func bounded(_ keys: Set<String>) -> Set<String> {
        Set(keys.sorted().suffix(400))
    }
}

public enum ReadingMotivationNotificationDecision: Equatable, Sendable {
    case none
    case cancelPending
    case schedule(kind: ReadingMotivationNotificationKind, dayKey: String)
    case replacePending(kind: ReadingMotivationNotificationKind, dayKey: String)
}

public enum ReadingMotivationNotificationPolicy {
    public static func localDayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public static func quietDeliveryDate(
        on date: Date,
        hour: Int,
        minute: Int,
        calendar: Calendar
    ) -> Date? {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: date,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }

    /// Build same-day candidates from independently evaluated reading/listening
    /// goals; arbitration of a single daily kind happens in `decide`.
    ///
    /// Pace/rescue eligibility uses quiet-time expectations against each configured
    /// goal so over-complete listening cannot suppress an unmet reading goal (and
    /// the converse). A morning launch can still schedule tonight's reminder without
    /// waiting for a later app/session event. Current candidates only — obsolete
    /// higher-priority kinds drop out when progress makes them ineligible.
    public static func candidates(
        now: Date,
        quietDeliveryDate: Date?,
        readingSeconds: Double,
        readingGoalSeconds: Double,
        listeningSeconds: Double,
        listeningGoalSeconds: Double,
        activityDaysThisWeek: Int,
        calendar: Calendar
    ) -> [ReadingMotivationNotificationCandidate] {
        guard let quietDeliveryDate,
            quietDeliveryDate > now,
            localDayKey(quietDeliveryDate, calendar: calendar) == localDayKey(now, calendar: calendar)
        else { return [] }

        let day = calendar.dateInterval(of: .day, for: now)
        let quietFraction = day.map {
            min(max(quietDeliveryDate.timeIntervalSince($0.start) / $0.duration, 0), 1)
        } ?? 0
        var result: [ReadingMotivationNotificationCandidate] = []
        if goalNeedsNudge(
            actualSeconds: readingSeconds, goalSeconds: readingGoalSeconds, fraction: quietFraction
        ) || goalNeedsNudge(
            actualSeconds: listeningSeconds, goalSeconds: listeningGoalSeconds, fraction: quietFraction
        ) {
            result.append(.init(kind: .pace, deliveryDate: quietDeliveryDate))
        }
        if goalNeedsNudge(
            actualSeconds: readingSeconds, goalSeconds: readingGoalSeconds, fraction: 0.5
        ) || goalNeedsNudge(
            actualSeconds: listeningSeconds, goalSeconds: listeningGoalSeconds, fraction: 0.5
        ) {
            result.append(.init(kind: .rescue, deliveryDate: quietDeliveryDate))
        }
        if activityDaysThisWeek > 0,
            let week = calendar.dateInterval(of: .weekOfYear, for: now),
            let lastDay = calendar.date(byAdding: .day, value: -1, to: week.end),
            calendar.isDate(now, inSameDayAs: lastDay)
        {
            result.append(.init(kind: .receipt, deliveryDate: quietDeliveryDate))
        }
        return result
    }

    /// A configured goal (strictly positive finite seconds) still needs a nudge
    /// when actual progress is below the expected fraction. Zero/invalid goals are
    /// ignored so they neither fabricate nor suppress reminders.
    private static func goalNeedsNudge(
        actualSeconds: Double,
        goalSeconds: Double,
        fraction: Double
    ) -> Bool {
        guard goalSeconds.isFinite, goalSeconds > 0,
            actualSeconds.isFinite, actualSeconds >= 0,
            fraction.isFinite, fraction >= 0
        else { return false }
        return actualSeconds < goalSeconds * fraction
    }

    public static func decide(
        candidates: [ReadingMotivationNotificationCandidate],
        state: ReadingMotivationNotificationState,
        enabled: Bool,
        authorized: Bool,
        now: Date,
        calendar: Calendar
    ) -> ReadingMotivationNotificationDecision {
        guard enabled, authorized else {
            return state.pendingKind == nil ? .none : .cancelPending
        }
        let dayKey = localDayKey(now, calendar: calendar)
        let selected = candidates
            .filter {
                $0.deliveryDate > now
                    && localDayKey($0.deliveryDate, calendar: calendar) == dayKey
            }
            .max { $0.kind.priority < $1.kind.priority }

        if state.hasConsumedDayKey(dayKey) {
            return state.pendingKind == nil ? .none : .cancelPending
        }
        guard let selected else {
            return state.pendingKind == nil ? .none : .cancelPending
        }
        if state.pendingDayKey == dayKey, let pendingKind = state.pendingKind {
            if selected.kind == pendingKind, selected.deliveryDate == state.pendingDeliveryDate {
                return .none
            }
            return .replacePending(kind: selected.kind, dayKey: dayKey)
        }
        return .schedule(kind: selected.kind, dayKey: dayKey)
    }
}

public enum ReadingMotivationNotificationAuthorization: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
}

public struct ReadingMotivationNotificationRequest: Equatable, Sendable {
    public let identifier: String
    public let kind: ReadingMotivationNotificationKind
    public let deliveryDate: Date

    public init(identifier: String, kind: ReadingMotivationNotificationKind, deliveryDate: Date) {
        self.identifier = identifier
        self.kind = kind
        self.deliveryDate = deliveryDate
    }
}

/// Session-lifecycle cadence while reading/listening is ongoing (including when
/// Home is not visible). Owns authoritative streak publication and, when opted
/// in, notification reconcile. iOS may suspend or delay timer ticks in the
/// background; foreground restore must restart the loop rather than assuming
/// background delivery.
public enum ReadingMotivationActiveSessionReconcilePolicy: Sendable {
    public static let tickIntervalSeconds: TimeInterval = 30

    /// Cadence runs for any live session — streak publish must not depend on
    /// notification opt-in. Notification eligibility stays gated separately.
    public static func shouldRunCadence(hasActiveSession: Bool) -> Bool {
        hasActiveSession
    }

    public static func shouldReconcileNotificationsOnTick(
        notificationsEnabled: Bool
    ) -> Bool {
        notificationsEnabled
    }

    /// Publish once the live session is retained (≥30s) and streak/anchor is new
    /// or changed (including first retention publish and local-day rollover).
    public static func shouldPublishAuthoritativeStreak(
        sessionElapsed: TimeInterval,
        streakDays: Int,
        activityDayKey: String,
        lastPublishedStreakDays: Int?,
        lastPublishedActivityDayKey: String?
    ) -> Bool {
        guard ReadingMotivationCalculations.isRecordableSession(duration: sessionElapsed)
        else { return false }
        if lastPublishedStreakDays != streakDays { return true }
        if lastPublishedActivityDayKey != activityDayKey { return true }
        return false
    }

    /// Legacy name: notification reconcile only when opted in *and* live.
    public static func shouldReconcileOnTick(
        notificationsEnabled: Bool,
        hasActiveSession: Bool
    ) -> Bool {
        shouldRunCadence(hasActiveSession: hasActiveSession)
            && shouldReconcileNotificationsOnTick(notificationsEnabled: notificationsEnabled)
    }
}

/// Injectable wall clock so reconcile can revalidate time after scheduler awaits.
public protocol ReadingMotivationClock: Sendable {
    func now() -> Date
}

public struct SystemReadingMotivationClock: ReadingMotivationClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// Injectable boundary for the iOS notification center and deterministic tests.
public protocol ReadingMotivationNotificationScheduling: Sendable {
    func authorization() async -> ReadingMotivationNotificationAuthorization
    func requestAuthorization() async -> Bool
    func schedule(_ request: ReadingMotivationNotificationRequest) async throws
    func cancelPending(identifier: String) async
    /// Currently installed pending request identifiers (OS truth, not ledger).
    func pendingIdentifiers() async -> Set<String>
    func deliveredNotifications() async -> [String: Date]
    func removeDelivered(identifiers: Set<String>) async
}

public protocol ReadingMotivationNotificationStateStoring: Sendable {
    func load() async -> ReadingMotivationNotificationState
    func save(_ state: ReadingMotivationNotificationState) async
}

public actor UserDefaultsReadingMotivationNotificationStateStore: ReadingMotivationNotificationStateStoring {
    private let defaults: UserDefaults
    private let key: String

    public init(key: String = "punkRally.motivation.notificationState.v1") {
        defaults = .standard
        self.key = key
    }

    public func load() async -> ReadingMotivationNotificationState {
        guard let data = defaults.data(forKey: key),
            let state = try? JSONDecoder().decode(ReadingMotivationNotificationState.self, from: data)
        else { return .empty }
        return state
    }

    public func save(_ state: ReadingMotivationNotificationState) async {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Serializes permission, pending replacement, and the one-delivery-per-day ledger.
/// The transaction gate orders callers; it does not control OS delivery timing.
public actor ReadingMotivationNotificationCoordinator {
    private let scheduler: any ReadingMotivationNotificationScheduling
    private let stateStore: any ReadingMotivationNotificationStateStoring
    private let clock: any ReadingMotivationClock
    private var state: ReadingMotivationNotificationState = .empty
    private var hasLoadedState = false
    private var transactionActive = false
    private var transactionWaiters: [CheckedContinuation<Void, Never>] = []
    private var latestPreferenceRevision: UInt64 = 0
    private var latestRequestRevision: UInt64 = 0

    public init(
        scheduler: any ReadingMotivationNotificationScheduling,
        stateStore: any ReadingMotivationNotificationStateStoring,
        clock: any ReadingMotivationClock = SystemReadingMotivationClock()
    ) {
        self.scheduler = scheduler
        self.stateStore = stateStore
        self.clock = clock
    }

    /// Called only from the explicit opt-in control, never during app startup.
    public func requestPermission() async -> Bool {
        switch await scheduler.authorization() {
            case .authorized: return true
            case .denied: return false
            case .notDetermined: return await scheduler.requestAuthorization()
        }
    }

    @discardableResult
    public func reconcile(
        candidates: [ReadingMotivationNotificationCandidate],
        enabled: Bool,
        now: Date,
        calendar: Calendar,
        preferenceRevision: UInt64 = 0,
        requestRevision: UInt64 = 0
    ) async throws -> ReadingMotivationNotificationDecision {
        await beginTransaction()
        defer { endTransaction() }
        await loadStateIfNeeded()
        guard preferenceRevision >= latestPreferenceRevision,
            requestRevision >= latestRequestRevision
        else { return .none }
        latestPreferenceRevision = preferenceRevision
        latestRequestRevision = requestRevision

        // Caller `now` is a reference instant; after awaits the injected clock is
        // authoritative so a late OS delivery cannot be followed by a replacement.
        var referenceNow = max(now, clock.now())
        await ingestDelivered(calendar: calendar)
        await consumeExpiredPending(now: referenceNow, calendar: calendar)
        await stateStore.save(state)

        let authorized = await scheduler.authorization() == .authorized
        referenceNow = max(now, clock.now())
        let decision = ReadingMotivationNotificationPolicy.decide(
            candidates: candidates,
            state: state,
            enabled: enabled,
            authorized: authorized,
            now: referenceNow,
            calendar: calendar
        )
        switch decision {
            case .none:
                return try await recoverMissingPendingInstallIfNeeded(
                    candidates: candidates,
                    enabled: enabled,
                    authorized: authorized,
                    now: now,
                    referenceNow: referenceNow,
                    calendar: calendar
                )
            case .cancelPending:
                await abandonPending(referenceNow: referenceNow, calendar: calendar)
                return .cancelPending
            case .schedule(_, let dayKey), .replacePending(_, let dayKey):
                let intendedReplace: Bool = {
                    if case .replacePending = decision { return true }
                    return false
                }()
                await ingestDelivered(calendar: calendar)
                referenceNow = max(now, clock.now())
                await consumeExpiredPending(now: referenceNow, calendar: calendar)
                if state.hasConsumedDayKey(dayKey) {
                    await abandonPending(referenceNow: referenceNow, calendar: calendar)
                    return .cancelPending
                }

                let liveDecision = ReadingMotivationNotificationPolicy.decide(
                    candidates: candidates,
                    state: state,
                    enabled: enabled,
                    authorized: authorized,
                    now: referenceNow,
                    calendar: calendar
                )
                let installKind: ReadingMotivationNotificationKind
                let installDay: String
                switch liveDecision {
                    case .schedule(let liveKind, let liveDay), .replacePending(let liveKind, let liveDay):
                        installKind = liveKind
                        installDay = liveDay
                    case .cancelPending:
                        await abandonPending(referenceNow: referenceNow, calendar: calendar)
                        return .cancelPending
                    case .none:
                        return .none
                }

                if let oldDay = state.pendingDayKey {
                    await scheduler.cancelPending(identifier: Self.identifier(for: oldDay))
                }
                // Cancel awaits do not control OS delivery of the old request.
                await ingestDelivered(calendar: calendar)
                referenceNow = max(now, clock.now())
                await consumeExpiredPending(now: referenceNow, calendar: calendar)
                if state.hasConsumedDayKey(installDay) {
                    clearPendingState()
                    await stateStore.save(state)
                    return .cancelPending
                }
                guard let deliveryDate = candidates.first(where: {
                    $0.kind == installKind
                        && $0.deliveryDate > referenceNow
                        && ReadingMotivationNotificationPolicy.localDayKey(
                            $0.deliveryDate, calendar: calendar
                        ) == installDay
                })?.deliveryDate else {
                    clearPendingState()
                    await stateStore.save(state)
                    return .none
                }
                let request = ReadingMotivationNotificationRequest(
                    identifier: Self.identifier(for: installDay),
                    kind: installKind,
                    deliveryDate: deliveryDate
                )
                state.pendingKind = installKind
                state.pendingDayKey = installDay
                state.pendingDeliveryDate = deliveryDate
                await stateStore.save(state)
                do {
                    try await scheduler.schedule(request)
                } catch {
                    clearPendingState()
                    await stateStore.save(state)
                    throw error
                }
                await ingestDelivered(calendar: calendar)
                referenceNow = max(now, clock.now())
                await consumeExpiredPending(now: referenceNow, calendar: calendar)
                if state.hasConsumedDayKey(installDay) {
                    await abandonPending(referenceNow: referenceNow, calendar: calendar)
                    return .cancelPending
                }
                return intendedReplace
                    ? .replacePending(kind: installKind, dayKey: installDay)
                    : .schedule(kind: installKind, dayKey: installDay)
        }
    }

    public func markDelivered(
        dayKey: String,
        deliveredAt: Date? = nil,
        calendar: Calendar = .current
    ) async {
        await beginTransaction()
        defer { endTransaction() }
        await loadStateIfNeeded()
        guard ReadingMotivationCalculations.ordinalDate(for: dayKey, calendar: calendar) != nil else { return }
        state.consume(dayKey: dayKey)
        let actualDay = deliveredAt.map {
            ReadingMotivationNotificationPolicy.localDayKey($0, calendar: calendar)
        }
        if let actualDay { state.consume(dayKey: actualDay) }
        // Preserve both delivery dates before cancellation can suspend or the
        // user can dismiss the OS evidence during a cross-midnight delivery.
        await stateStore.save(state)
        if state.pendingDayKey == dayKey || state.pendingDayKey == actualDay {
            if let pendingDay = state.pendingDayKey {
                await scheduler.cancelPending(identifier: Self.identifier(for: pendingDay))
            }
            clearPendingState()
        }
        await stateStore.save(state)
        await scheduler.removeDelivered(identifiers: [Self.identifier(for: dayKey)])
    }

    public static func identifier(for dayKey: String) -> String {
        "reading-motivation." + dayKey
    }

    private static func dayKey(from identifier: String, calendar: Calendar) -> String? {
        let prefix = "reading-motivation."
        guard identifier.hasPrefix(prefix) else { return nil }
        let key = String(identifier.dropFirst(prefix.count))
        return ReadingMotivationCalculations.ordinalDate(for: key, calendar: calendar) == nil ? nil : key
    }

    private func beginTransaction() async {
        guard transactionActive else {
            transactionActive = true
            return
        }
        await withCheckedContinuation { transactionWaiters.append($0) }
    }

    private func endTransaction() {
        guard !transactionWaiters.isEmpty else {
            transactionActive = false
            return
        }
        transactionWaiters.removeFirst().resume()
    }

    private func clearPendingState() {
        state.pendingKind = nil
        state.pendingDayKey = nil
        state.pendingDeliveryDate = nil
    }

    /// Crash recovery: ledger may retain a future unconsumed pending intent that
    /// never reached the OS (`save` then terminate before `schedule`). Reinstall
    /// the same stable identifier after revalidating clock/deliveries/expiry.
    private func recoverMissingPendingInstallIfNeeded(
        candidates: [ReadingMotivationNotificationCandidate],
        enabled: Bool,
        authorized: Bool,
        now: Date,
        referenceNow: Date,
        calendar: Calendar
    ) async throws -> ReadingMotivationNotificationDecision {
        guard enabled, authorized,
            let pendingDay = state.pendingDayKey,
            let pendingKind = state.pendingKind,
            let deliveryDate = state.pendingDeliveryDate,
            !state.hasConsumedDayKey(pendingDay),
            deliveryDate > referenceNow
        else { return .none }

        let identifier = Self.identifier(for: pendingDay)
        let osPending = await scheduler.pendingIdentifiers()
        var liveNow = max(now, clock.now())
        await ingestDelivered(calendar: calendar)
        liveNow = max(now, clock.now())
        await consumeExpiredPending(now: liveNow, calendar: calendar)
        await stateStore.save(state)

        guard state.pendingDayKey == pendingDay,
            state.pendingKind == pendingKind,
            state.pendingDeliveryDate == deliveryDate,
            !state.hasConsumedDayKey(pendingDay),
            deliveryDate > liveNow
        else { return .none }

        if osPending.contains(identifier) {
            return .none
        }

        // Re-query after suspension; delivery/dismissal during inspection must win.
        let osPendingAgain = await scheduler.pendingIdentifiers()
        liveNow = max(now, clock.now())
        await ingestDelivered(calendar: calendar)
        liveNow = max(now, clock.now())
        await consumeExpiredPending(now: liveNow, calendar: calendar)
        await stateStore.save(state)

        guard state.pendingDayKey == pendingDay,
            state.pendingKind == pendingKind,
            let stillDelivery = state.pendingDeliveryDate,
            stillDelivery == deliveryDate,
            !state.hasConsumedDayKey(pendingDay),
            stillDelivery > liveNow
        else { return .none }

        if osPendingAgain.contains(identifier) {
            return .none
        }

        // Candidates must still select this identical pending intent.
        let liveDecision = ReadingMotivationNotificationPolicy.decide(
            candidates: candidates,
            state: state,
            enabled: enabled,
            authorized: authorized,
            now: liveNow,
            calendar: calendar
        )
        guard case .none = liveDecision,
            candidates.contains(where: {
                $0.kind == pendingKind
                    && $0.deliveryDate == stillDelivery
                    && $0.deliveryDate > liveNow
                    && ReadingMotivationNotificationPolicy.localDayKey(
                        $0.deliveryDate, calendar: calendar
                    ) == pendingDay
            })
        else { return .none }

        let request = ReadingMotivationNotificationRequest(
            identifier: identifier,
            kind: pendingKind,
            deliveryDate: stillDelivery
        )
        do {
            try await scheduler.schedule(request)
        } catch {
            clearPendingState()
            await stateStore.save(state)
            throw error
        }
        await ingestDelivered(calendar: calendar)
        liveNow = max(now, clock.now())
        await consumeExpiredPending(now: liveNow, calendar: calendar)
        await stateStore.save(state)
        if state.hasConsumedDayKey(pendingDay) {
            await abandonPending(referenceNow: liveNow, calendar: calendar)
            return .cancelPending
        }
        return .schedule(kind: pendingKind, dayKey: pendingDay)
    }

    private func abandonPending(referenceNow: Date, calendar: Calendar) async {
        if let pendingDay = state.pendingDayKey {
            await scheduler.cancelPending(identifier: Self.identifier(for: pendingDay))
        }
        // OS delivery can happen during cancellation, and its alert can already
        // be dismissed. Account for evidence and elapsed fire time before erasing
        // the pending record so a later same-day request cannot duplicate it.
        await ingestDelivered(calendar: calendar)
        await consumeExpiredPending(now: max(referenceNow, clock.now()), calendar: calendar)
        clearPendingState()
        await stateStore.save(state)
    }

    /// Fold OS-delivered motivation notifications into the consumed-day ledger.
    /// Persist requested+actual consumed days before removing OS delivery evidence
    /// so a crash at removal still retains both days after restart (UserDefaults
    /// save is best-effort; not a power-loss durability claim beyond that API).
    private func ingestDelivered(calendar: Calendar) async {
        var deliveredIdentifiers: Set<String> = []
        for (identifier, deliveredAt) in await scheduler.deliveredNotifications() {
            guard let requestDay = Self.dayKey(from: identifier, calendar: calendar) else { continue }
            deliveredIdentifiers.insert(identifier)
            state.consume(dayKey: requestDay)
            let actualDay = ReadingMotivationNotificationPolicy.localDayKey(
                deliveredAt, calendar: calendar
            )
            state.consume(dayKey: actualDay)
            // Persist before *any* scheduler await, not just evidence removal.
            await stateStore.save(state)
            if state.pendingDayKey == requestDay || state.pendingDayKey == actualDay {
                if let pendingDay = state.pendingDayKey {
                    await scheduler.cancelPending(identifier: Self.identifier(for: pendingDay))
                }
                clearPendingState()
            }
        }
        if !deliveredIdentifiers.isEmpty {
            await stateStore.save(state)
            await scheduler.removeDelivered(identifiers: deliveredIdentifiers)
        }
    }

    /// Conservatively consume the day when a pending delivery boundary is already past
    /// (crash/restart gap or await that outlived the scheduled fire time).
    private func consumeExpiredPending(now: Date, calendar: Calendar) async {
        guard let pendingDay = state.pendingDayKey else { return }
        guard let deliveryDate = state.pendingDeliveryDate else {
            // Old persisted intent has no fire boundary. It may already have
            // fired and been dismissed; absence from OS is not non-delivery proof.
            // Prefer losing a reminder over duplicating one on either possible day.
            state.consume(dayKey: pendingDay)
            state.consume(dayKey: ReadingMotivationNotificationPolicy.localDayKey(now, calendar: calendar))
            await stateStore.save(state)
            await scheduler.cancelPending(identifier: Self.identifier(for: pendingDay))
            clearPendingState()
            await stateStore.save(state)
            return
        }
        guard deliveryDate <= now else { return }
        state.consume(dayKey: pendingDay)
        state.consume(
            dayKey: ReadingMotivationNotificationPolicy.localDayKey(deliveryDate, calendar: calendar)
        )
        // If OS evidence was dismissed, a late cross-midnight delivery cannot
        // be distinguished from an on-time one. Suppress another today too.
        state.consume(dayKey: ReadingMotivationNotificationPolicy.localDayKey(now, calendar: calendar))
        await stateStore.save(state)
        await scheduler.cancelPending(identifier: Self.identifier(for: pendingDay))
        clearPendingState()
    }

    private func loadStateIfNeeded() async {
        guard !hasLoadedState else { return }
        state = await stateStore.load()
        hasLoadedState = true
    }
}
