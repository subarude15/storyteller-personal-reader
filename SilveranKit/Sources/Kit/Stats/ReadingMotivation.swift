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

    public var seconds: TimeInterval { readingSeconds + listeningSeconds }
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
        archivedActivityDays: [Date] = []
    ) -> ReadingMotivationStreaks {
        let today = calendar.startOfDay(for: now)
        let activeDays = Set(
            dailyTotals(sessions: sessions, calendar: calendar, now: now).map(\.day)
                + archivedActivityDays.map { calendar.startOfDay(for: $0) }.filter { $0 <= today }
        )
        guard !activeDays.isEmpty else { return ReadingMotivationStreaks(current: 0, longest: 0) }

        var longest = 0
        var run = 0
        var previous: Date?
        for day in activeDays.sorted() {
            if let previous,
                calendar.date(byAdding: .day, value: 1, to: previous) == day
            {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = day
        }

        var cursor = today
        if !activeDays.contains(cursor) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                activeDays.contains(yesterday)
            else {
                return ReadingMotivationStreaks(current: 0, longest: longest)
            }
            cursor = yesterday
        }
        var current = 0
        while activeDays.contains(cursor) {
            current += 1
            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previousDay
        }
        return ReadingMotivationStreaks(current: current, longest: longest)
    }

    public static func weeklyReceipt(
        sessions: [InkampStatsSessionRecord],
        finished: [InkampStatsFinishedRecord],
        weekOffset: Int,
        calendar: Calendar,
        now: Date,
        archivedActivityDays: [Date] = []
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
        if progress >= 0.995 { return .finished }
        guard let totalUnits, totalUnits.isFinite, totalUnits > 0 else { return nil }
        let remaining = totalUnits * (1 - progress)
        guard remaining.isFinite, remaining > 0 else { return nil }

        let seconds: TimeInterval
        let basis: String
        if let playbackRate {
            guard playbackRate.isFinite, playbackRate > 0 else { return nil }
            seconds = remaining / min(playbackRate, 4)
            basis = "At \(String(format: "%.2g", min(playbackRate, 4)))× playback"
        } else {
            let observations = normalizedSessions(sessions, now: now)
                .filter { session in
                    guard session.mediaID == mediaID,
                        paceKind.map({ session.kind == $0 }) ?? true,
                        session.endProgress?.isFinite == true
                    else { return false }
                    return true
                }
                .filter { ($0.endProgress ?? -1) >= 0 && ($0.endProgress ?? 2) <= 1 }
                .sorted { $0.endedAt < $1.endedAt }
            var unitsGained: Double = 0
            var secondsSpent: TimeInterval = 0
            for (previous, current) in zip(observations, observations.dropFirst()) {
                guard let previousProgress = previous.endProgress,
                    let currentProgress = current.endProgress,
                    currentProgress > previousProgress
                else { continue }
                let work = min(current.durationSeconds, current.endedAt.timeIntervalSince(current.startedAt))
                guard work.isFinite, work > 0 else { continue }
                unitsGained += totalUnits * (currentProgress - previousProgress)
                secondsSpent += work
            }
            guard unitsGained.isFinite, unitsGained > 0, secondsSpent > 0 else { return nil }
            seconds = remaining / (unitsGained / secondsSpent)
            basis = paceBasis
        }
        guard seconds.isFinite, seconds > 0 else { return nil }
        guard seconds <= Double(Int.max),
            let finishDate = calendar.date(byAdding: .second, value: Int(seconds.rounded(.up)), to: now)
        else { return nil }
        guard finishDate.timeIntervalSince1970.isFinite else { return nil }
        return .estimate(date: finishDate, basis: basis)
    }

    private static func normalizedSessions(
        _ sessions: [InkampStatsSessionRecord],
        now: Date
    ) -> [InkampStatsSessionRecord] {
        var byID: [UUID: InkampStatsSessionRecord] = [:]
        for session in sessions {
            let id = session.mediaID.trimmingCharacters(in: .whitespacesAndNewlines)
            let span = session.endedAt.timeIntervalSince(session.startedAt)
            guard !id.isEmpty,
                session.startedAt.timeIntervalSince1970.isFinite,
                session.endedAt.timeIntervalSince1970.isFinite,
                session.startedAt <= session.endedAt,
                session.endedAt <= now,
                session.durationSeconds.isFinite,
                session.durationSeconds > 0,
                span.isFinite,
                span > 0
            else { continue }
            if let prior = byID[session.id],
                prior.endedAt > session.endedAt
                    || (prior.endedAt == session.endedAt && prior.durationSeconds >= session.durationSeconds)
            {
                continue
            }
            var valid = session
            valid.durationSeconds = min(session.durationSeconds, span)
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
        guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        let duration = durationSeconds
        let elapsed: Double
        if let elapsedSeconds, elapsedSeconds.isFinite {
            elapsed = min(max(elapsedSeconds, 0), duration)
        } else if let progress, progress.isFinite {
            elapsed = min(max(progress, 0), 1) * duration
        } else {
            return nil
        }
        let remaining: Double?
        if let rate {
            guard rate.isFinite, rate > 0 else { return nil }
            remaining = max(0, duration - elapsed) / min(max(rate, 0.25), 4)
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
    public var pendingKind: ReadingMotivationNotificationKind?
    public var pendingDayKey: String?
    public var pendingDeliveryDate: Date?

    public init(
        consumedDayKey: String? = nil,
        pendingKind: ReadingMotivationNotificationKind? = nil,
        pendingDayKey: String? = nil,
        pendingDeliveryDate: Date? = nil
    ) {
        self.consumedDayKey = consumedDayKey
        self.pendingKind = pendingKind
        self.pendingDayKey = pendingDayKey
        self.pendingDeliveryDate = pendingDeliveryDate
    }

    public static let empty = ReadingMotivationNotificationState()

    public mutating func markDelivered(on date: Date, calendar: Calendar) {
        consumedDayKey = ReadingMotivationNotificationPolicy.localDayKey(date, calendar: calendar)
        pendingKind = nil
        pendingDayKey = nil
        pendingDeliveryDate = nil
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

    /// Build same-day candidates from actual goal progress; arbitration happens in `decide`.
    public static func candidates(
        now: Date,
        quietDeliveryDate: Date?,
        actualSeconds: Double,
        dailyGoalSeconds: Double,
        activityDaysThisWeek: Int,
        calendar: Calendar
    ) -> [ReadingMotivationNotificationCandidate] {
        guard let quietDeliveryDate,
            quietDeliveryDate > now,
            localDayKey(quietDeliveryDate, calendar: calendar) == localDayKey(now, calendar: calendar),
            actualSeconds.isFinite,
            actualSeconds >= 0,
            dailyGoalSeconds.isFinite,
            dailyGoalSeconds > 0
        else { return [] }

        let day = calendar.dateInterval(of: .day, for: now)
        let dayFraction = day.map {
            min(max(now.timeIntervalSince($0.start) / $0.duration, 0), 1)
        } ?? 0
        var result: [ReadingMotivationNotificationCandidate] = []
        if dayFraction >= 0.5, actualSeconds < dailyGoalSeconds * dayFraction {
            result.append(.init(kind: .pace, deliveryDate: quietDeliveryDate))
        }
        let nearQuietTime = quietDeliveryDate.timeIntervalSince(now) <= 3600
        if (dayFraction >= 0.75 || nearQuietTime), actualSeconds < dailyGoalSeconds * 0.5 {
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

        if state.consumedDayKey == dayKey {
            return state.pendingDayKey == dayKey ? .cancelPending : .none
        }
        guard let selected else {
            return state.pendingKind == nil ? .none : .cancelPending
        }
        if state.pendingDayKey == dayKey, let pendingKind = state.pendingKind {
            guard selected.kind.priority > pendingKind.priority else { return .none }
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

/// Injectable boundary for the iOS notification center and deterministic tests.
public protocol ReadingMotivationNotificationScheduling: Sendable {
    func authorization() async -> ReadingMotivationNotificationAuthorization
    func requestAuthorization() async -> Bool
    func schedule(_ request: ReadingMotivationNotificationRequest) async throws
    func cancelPending(identifier: String) async
    func deliveredIdentifiers() async -> Set<String>
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
public actor ReadingMotivationNotificationCoordinator {
    private let scheduler: any ReadingMotivationNotificationScheduling
    private let stateStore: any ReadingMotivationNotificationStateStoring
    private var state: ReadingMotivationNotificationState = .empty
    private var hasLoadedState = false

    public init(
        scheduler: any ReadingMotivationNotificationScheduling,
        stateStore: any ReadingMotivationNotificationStateStoring
    ) {
        self.scheduler = scheduler
        self.stateStore = stateStore
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
        calendar: Calendar
    ) async throws -> ReadingMotivationNotificationDecision {
        await loadStateIfNeeded()
        let currentDay = ReadingMotivationNotificationPolicy.localDayKey(now, calendar: calendar)
        let currentIdentifier = Self.identifier(for: currentDay)
        let delivered = await scheduler.deliveredIdentifiers()
        let pendingWasDelivered = state.pendingDayKey.map {
            delivered.contains(Self.identifier(for: $0))
        } ?? false
        if delivered.contains(currentIdentifier)
            || pendingWasDelivered
            || (state.pendingDayKey == currentDay
                && state.pendingDeliveryDate.map { $0 <= now } == true)
        {
            state.consumedDayKey = currentDay
            state.pendingKind = nil
            state.pendingDayKey = nil
            state.pendingDeliveryDate = nil
            await stateStore.save(state)
            await scheduler.cancelPending(identifier: currentIdentifier)
            await scheduler.removeDelivered(identifiers: [currentIdentifier])
        }

        let authorized = await scheduler.authorization() == .authorized
        let decision = ReadingMotivationNotificationPolicy.decide(
            candidates: candidates,
            state: state,
            enabled: enabled,
            authorized: authorized,
            now: now,
            calendar: calendar
        )
        switch decision {
            case .none:
                break
            case .cancelPending:
                if let dayKey = state.pendingDayKey {
                    await scheduler.cancelPending(identifier: Self.identifier(for: dayKey))
                }
                state.pendingKind = nil
                state.pendingDayKey = nil
                state.pendingDeliveryDate = nil
                await stateStore.save(state)
            case .schedule(let kind, let dayKey), .replacePending(let kind, let dayKey):
                if let oldDay = state.pendingDayKey {
                    await scheduler.cancelPending(identifier: Self.identifier(for: oldDay))
                }
                guard let deliveryDate = candidates.first(where: {
                    $0.kind == kind && $0.deliveryDate > now
                        && ReadingMotivationNotificationPolicy.localDayKey($0.deliveryDate, calendar: calendar) == dayKey
                })?.deliveryDate else { break }
                let request = ReadingMotivationNotificationRequest(
                    identifier: Self.identifier(for: dayKey),
                    kind: kind,
                    deliveryDate: deliveryDate
                )
                state.pendingKind = kind
                state.pendingDayKey = dayKey
                state.pendingDeliveryDate = deliveryDate
                await stateStore.save(state)
                do {
                    try await scheduler.schedule(request)
                } catch {
                    state.pendingKind = nil
                    state.pendingDayKey = nil
                    state.pendingDeliveryDate = nil
                    await stateStore.save(state)
                    throw error
                }
        }
        return decision
    }

    public func markDelivered(
        dayKey: String,
        at date: Date = Date(),
        calendar: Calendar = .current
    ) async {
        await loadStateIfNeeded()
        let localDay = ReadingMotivationNotificationPolicy.localDayKey(date, calendar: calendar)
        state.consumedDayKey = localDay
        if state.pendingDayKey == dayKey || state.pendingDayKey == localDay {
            if let pendingDay = state.pendingDayKey {
                await scheduler.cancelPending(identifier: Self.identifier(for: pendingDay))
            }
            state.pendingKind = nil
            state.pendingDayKey = nil
            state.pendingDeliveryDate = nil
        }
        await stateStore.save(state)
    }

    public static func identifier(for dayKey: String) -> String {
        "reading-motivation." + dayKey
    }

    private func loadStateIfNeeded() async {
        guard !hasLoadedState else { return }
        state = await stateStore.load()
        hasLoadedState = true
    }
}
