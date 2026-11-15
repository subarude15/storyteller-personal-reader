import Foundation
import SilveranAppleWidgets
import SilveranKit
import Testing

private final class TestMotivationClock: ReadingMotivationClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(_ instant: Date) { self.instant = instant }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    func advance(to date: Date) {
        lock.lock()
        instant = date
        lock.unlock()
    }
}

private actor TestMotivationScheduler: ReadingMotivationNotificationScheduling {
    var status: ReadingMotivationNotificationAuthorization = .authorized
    var requests: [String: ReadingMotivationNotificationRequest] = [:]
    var delivered: [String: Date] = [:]
    var authorizationRequests = 0
    var scheduleCallCount = 0
    var pauseNextSchedule = false
    var pausedScheduleEntered = false
    var scheduleStartWaiter: CheckedContinuation<Void, Never>?
    var scheduleRelease: CheckedContinuation<Void, Never>?
    var pauseNextCancel = false
    var pausedCancelEntered = false
    var cancelStartWaiter: CheckedContinuation<Void, Never>?
    var cancelRelease: CheckedContinuation<Void, Never>?
    var pauseNextRemove = false
    var pausedRemoveEntered = false
    var removeStartWaiter: CheckedContinuation<Void, Never>?
    var removeRelease: CheckedContinuation<Void, Never>?
    var pauseNextPendingIdentifiers = false
    var pausedPendingIdentifiersEntered = false
    var pendingIdentifiersStartWaiter: CheckedContinuation<Void, Never>?
    var pendingIdentifiersRelease: CheckedContinuation<Void, Never>?
    var failNextSchedule = false

    func authorization() async -> ReadingMotivationNotificationAuthorization { status }
    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        return status == .authorized
    }
    func schedule(_ request: ReadingMotivationNotificationRequest) async throws {
        scheduleCallCount += 1
        if pauseNextSchedule {
            pauseNextSchedule = false
            pausedScheduleEntered = true
            scheduleStartWaiter?.resume()
            scheduleStartWaiter = nil
            await withCheckedContinuation { scheduleRelease = $0 }
            pausedScheduleEntered = false
        }
        if failNextSchedule {
            failNextSchedule = false
            throw TestMotivationScheduleError.expectedFailure
        }
        requests[request.identifier] = request
    }
    func cancelPending(identifier: String) async {
        if pauseNextCancel {
            pauseNextCancel = false
            pausedCancelEntered = true
            cancelStartWaiter?.resume()
            cancelStartWaiter = nil
            await withCheckedContinuation { cancelRelease = $0 }
            pausedCancelEntered = false
        }
        requests.removeValue(forKey: identifier)
    }
    func pendingIdentifiers() async -> Set<String> {
        if pauseNextPendingIdentifiers {
            pauseNextPendingIdentifiers = false
            pausedPendingIdentifiersEntered = true
            pendingIdentifiersStartWaiter?.resume()
            pendingIdentifiersStartWaiter = nil
            await withCheckedContinuation { pendingIdentifiersRelease = $0 }
            pausedPendingIdentifiersEntered = false
        }
        return Set(requests.keys)
    }
    func deliveredNotifications() async -> [String: Date] { delivered }
    func removeDelivered(identifiers: Set<String>) async {
        if pauseNextRemove {
            pauseNextRemove = false
            pausedRemoveEntered = true
            removeStartWaiter?.resume()
            removeStartWaiter = nil
            await withCheckedContinuation { removeRelease = $0 }
            pausedRemoveEntered = false
        }
        for identifier in identifiers { delivered.removeValue(forKey: identifier) }
    }
    func pendingCount() -> Int { requests.count }
    func scheduleCalls() -> Int { scheduleCallCount }
    func setAuthorization(_ value: ReadingMotivationNotificationAuthorization) { status = value }
    func authorizationRequestCount() -> Int { authorizationRequests }
    func setDelivered(identifier: String, at date: Date) { delivered[identifier] = date }
    func pauseNextScheduleCall() { pauseNextSchedule = true }
    func waitForPausedSchedule() async {
        if pausedScheduleEntered { return }
        await withCheckedContinuation { scheduleStartWaiter = $0 }
    }
    func resumePausedSchedule() {
        scheduleRelease?.resume()
        scheduleRelease = nil
    }
    func pauseNextCancelCall() { pauseNextCancel = true }
    func waitForPausedCancel() async {
        if pausedCancelEntered { return }
        await withCheckedContinuation { cancelStartWaiter = $0 }
    }
    func resumePausedCancel() {
        cancelRelease?.resume()
        cancelRelease = nil
    }
    func pauseNextRemoveCall() { pauseNextRemove = true }
    func waitForPausedRemove() async {
        if pausedRemoveEntered { return }
        await withCheckedContinuation { removeStartWaiter = $0 }
    }
    func resumePausedRemove() {
        removeRelease?.resume()
        removeRelease = nil
    }
    func pauseNextPendingIdentifiersCall() { pauseNextPendingIdentifiers = true }
    func waitForPausedPendingIdentifiers() async {
        if pausedPendingIdentifiersEntered { return }
        await withCheckedContinuation { pendingIdentifiersStartWaiter = $0 }
    }
    func resumePausedPendingIdentifiers() {
        pendingIdentifiersRelease?.resume()
        pendingIdentifiersRelease = nil
    }
    func clearDelivered() { delivered.removeAll() }
    func failNextScheduleCall() { failNextSchedule = true }
    func pendingKind(for identifier: String) -> ReadingMotivationNotificationKind? {
        requests[identifier]?.kind
    }
    func pendingDate(for identifier: String) -> Date? { requests[identifier]?.deliveryDate }
}

private actor TestMotivationStateStore: ReadingMotivationNotificationStateStoring {
    var state: ReadingMotivationNotificationState
    var loadCount = 0
    var pauseNextLoad = false
    var pausedLoadEntered = false
    var loadStartWaiter: CheckedContinuation<Void, Never>?
    var loadRelease: CheckedContinuation<Void, Never>?

    init(_ state: ReadingMotivationNotificationState = .empty) { self.state = state }
    func load() async -> ReadingMotivationNotificationState {
        loadCount += 1
        if pauseNextLoad {
            pauseNextLoad = false
            pausedLoadEntered = true
            loadStartWaiter?.resume()
            loadStartWaiter = nil
            await withCheckedContinuation { loadRelease = $0 }
            pausedLoadEntered = false
        }
        return state
    }
    func save(_ state: ReadingMotivationNotificationState) async { self.state = state }
    func pauseNextLoadCall() { pauseNextLoad = true }
    func waitForPausedLoad() async {
        if pausedLoadEntered { return }
        await withCheckedContinuation { loadStartWaiter = $0 }
    }
    func resumePausedLoad() {
        loadRelease?.resume()
        loadRelease = nil
    }
    func reads() -> Int { loadCount }
}

private enum TestMotivationScheduleError: Error {
    case expectedFailure
}

private actor TestMotivationSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signaled = true
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.resume() }
    }

    func wait() async {
        guard !signaled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@Suite("Reading motivation calculations")
struct ReadingMotivationTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/New_York")!
        value.firstWeekday = 2
        value.minimumDaysInFirstWeek = 4
        return value
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func session(
        id: UUID = UUID(),
        mediaID: String = "book-1",
        start: Date,
        end: Date,
        duration: TimeInterval? = nil,
        progress: Double? = nil,
        kind: InkampStatsSessionRecord.Kind = .reading
    ) -> InkampStatsSessionRecord {
        InkampStatsSessionRecord(
            id: id,
            kind: kind,
            mediaID: mediaID,
            mediaTitle: mediaID,
            startedAt: start,
            endedAt: end,
            durationSeconds: duration ?? end.timeIntervalSince(start),
            endProgress: progress,
        )
    }

    /// Fixed-date coordinator fixtures must inject a fake clock; the system clock
    /// makes `max(fixtureNow, clock.now())` wall-time dependent.
    private func makeCoordinator(
        scheduler: TestMotivationScheduler,
        stateStore: TestMotivationStateStore = TestMotivationStateStore(),
        now: Date,
        clock: TestMotivationClock? = nil
    ) -> (ReadingMotivationNotificationCoordinator, TestMotivationClock) {
        let clock = clock ?? TestMotivationClock(now)
        let coordinator = ReadingMotivationNotificationCoordinator(
            scheduler: scheduler, stateStore: stateStore, clock: clock
        )
        return (coordinator, clock)
    }

    @Test func liveAndEndedSessionRetentionHaveIdenticalBoundary() {
        #expect(!ReadingMotivationCalculations.isRecordableSession(duration: 29.999))
        #expect(ReadingMotivationCalculations.isRecordableSession(duration: 30))
        #expect(ReadingMotivationCalculations.isRecordableSession(duration: 31))
        #expect(!ReadingMotivationCalculations.isRecordableSession(duration: .nan))
        #expect(!ReadingMotivationCalculations.isRecordableSession(duration: .infinity))
    }

    @Test func ingestionPersistsActualDayBeforeCancellationCanSuspend() async throws {
        let actualNow = date(2026, 11, 16, 0)
        let scheduler = TestMotivationScheduler()
        let storage = TestMotivationStateStore(.init(
            pendingKind: .rescue, pendingDayKey: "2026-11-15",
            pendingDeliveryDate: date(2026, 11, 15, 20)
        ))
        await scheduler.setDelivered(identifier: "reading-motivation.2026-11-15", at: actualNow)
        let (coordinator, _) = makeCoordinator(scheduler: scheduler, stateStore: storage, now: actualNow)
        await scheduler.pauseNextCancelCall()
        let ingesting = Task {
            try await coordinator.reconcile(candidates: [], enabled: true, now: actualNow, calendar: calendar)
        }
        await scheduler.waitForPausedCancel()
        let crashCheckpoint = await storage.load()
        #expect(crashCheckpoint.hasConsumedDayKey("2026-11-15"))
        #expect(crashCheckpoint.hasConsumedDayKey("2026-11-16"))
        await scheduler.clearDelivered()
        await scheduler.resumePausedCancel()
        _ = try await ingesting.value
        let (restarted, _) = makeCoordinator(
            scheduler: scheduler, stateStore: TestMotivationStateStore(crashCheckpoint), now: actualNow
        )
        #expect(try await restarted.reconcile(
            candidates: [.init(kind: .pace, deliveryDate: date(2026, 11, 16, 12))],
            enabled: true, now: actualNow, calendar: calendar
        ) == .none)
    }

    @Test func trailingPlateauAndMissingCheckpointsCountObservedWork() {
        let now = date(2026, 11, 15, 12)
        for trailingProgress: Double? in [0.2, nil] {
            let records = [
                session(start: date(2026, 11, 15, 0), end: date(2026, 11, 15, 1), progress: 0.1),
                session(start: date(2026, 11, 15, 1), end: date(2026, 11, 15, 2), progress: 0.2),
                session(start: date(2026, 11, 15, 2), end: now, progress: trailingProgress)
            ]
            let projection = ReadingMotivationCalculations.projectedFinish(
                sessions: records, mediaID: "book-1", progress: 0.2, totalUnits: 100,
                playbackRate: nil, calendar: calendar, now: now
            )
            guard case .estimate(let finish, _) = projection else {
                Issue.record("Expected an estimate from observed checkpoint work")
                continue
            }
            // Ten units / eleven hours: remaining eighty units take eighty-eight hours.
            #expect(abs(finish.timeIntervalSince(now) - 316_800) <= 1)
        }
    }

    @Test func knownPositivePlaybackRatesAreNotSilentlyClamped() {
        let now = date(2026, 11, 15)
        for rate in [0.1, 8.0] {
            let timing = ContinueWidgetTiming.calculate(
                progress: 0, elapsedSeconds: 0, durationSeconds: 160, rate: rate
            )
            #expect(timing?.remainingWallSeconds == 160 / rate)
            let projection = ReadingMotivationCalculations.projectedFinish(
                sessions: [], mediaID: "book-1", progress: 0, totalUnits: 160,
                playbackRate: rate, calendar: calendar, now: now
            )
            guard case .estimate(let finish, _) = projection else {
                Issue.record("Expected known-rate projection")
                continue
            }
            #expect(finish.timeIntervalSince(now) == 160 / rate)
        }
    }

    @Test func explicitDeliveryPersistsActualDayBeforeSuspendingCancellation() async throws {
        let actualNow = date(2026, 11, 16, 0)
        let scheduler = TestMotivationScheduler()
        let storage = TestMotivationStateStore(.init(
            pendingKind: .rescue, pendingDayKey: "2026-11-15",
            pendingDeliveryDate: date(2026, 11, 15, 20)
        ))
        let (coordinator, _) = makeCoordinator(scheduler: scheduler, stateStore: storage, now: actualNow)
        await scheduler.pauseNextCancelCall()
        let marking = Task {
            await coordinator.markDelivered(
                dayKey: "2026-11-15", deliveredAt: actualNow, calendar: calendar
            )
        }
        await scheduler.waitForPausedCancel()
        let crashCheckpoint = await storage.load()
        #expect(crashCheckpoint.hasConsumedDayKey("2026-11-15"))
        #expect(crashCheckpoint.hasConsumedDayKey("2026-11-16"))
        await scheduler.clearDelivered()
        await scheduler.resumePausedCancel()
        await marking.value
        let (restarted, _) = makeCoordinator(
            scheduler: scheduler, stateStore: TestMotivationStateStore(crashCheckpoint), now: actualNow
        )
        #expect(try await restarted.reconcile(
            candidates: [.init(kind: .pace, deliveryDate: date(2026, 11, 16, 12))],
            enabled: true, now: actualNow, calendar: calendar
        ) == .none)
    }

    @Test func settingsMigrateMissingValuesToExplicitDefaults() throws {
        let oldData = Data(#"{"notificationsEnabled":false}"#.utf8)
        let value = try JSONDecoder().decode(ReadingMotivationSettings.self, from: oldData)
        #expect(value.dailyReadingGoalMinutes == 30)
        #expect(value.dailyListeningGoalMinutes == 30)
        #expect(value.pinnedStats == ReadingMotivationSettings.defaultPinnedStats)
        #expect(!value.notificationsEnabled)
    }

    @Test func dailySummaryHasPublicValidatedInitializer() {
        let day = ReadingMotivationDay(day: date(2026, 11, 15), readingSeconds: .nan, listeningSeconds: -3)
        #expect(day.readingSeconds == 0)
        #expect(day.listeningSeconds == 0)
    }

    @Test func settingsRejectZeroGoalsAndBoundPinnedStats() throws {
        let data = Data(#"{"dailyReadingGoalMinutes":0,"dailyListeningGoalMinutes":-1,"pinnedStats":["todayReading","todayReading","weekTotal","currentStreak","longestStreak"]}"#.utf8)
        let value = try JSONDecoder().decode(ReadingMotivationSettings.self, from: data)
        #expect(value.dailyReadingGoalMinutes == 30)
        #expect(value.dailyListeningGoalMinutes == 30)
        #expect(value.pinnedStats == [.todayReading, .weekTotal, .currentStreak])
    }

    @Test func notificationLedgerDecodesBeforeDeliveryDateWasAdded() throws {
        let data = Data(#"{"consumedDayKey":"2026-11-14","pendingKind":"pace","pendingDayKey":"2026-11-15"}"#.utf8)
        let state = try JSONDecoder().decode(ReadingMotivationNotificationState.self, from: data)
        #expect(state.consumedDayKey == "2026-11-14")
        #expect(state.hasConsumedDayKey("2026-11-14"))
        #expect(state.pendingKind == .pace)
        #expect(state.pendingDeliveryDate == nil)
    }

    @Test func consumedDayLedgerIsBoundedAndKeepsRecentDays() {
        var state = ReadingMotivationNotificationState()
        let start = date(2025, 1, 1)
        for offset in 0..<450 {
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            state.consume(dayKey: ReadingMotivationNotificationPolicy.localDayKey(day, calendar: calendar))
        }
        #expect(state.consumedDayKeys.count == 400)
        #expect(state.hasConsumedDayKey("2026-03-26"))
        #expect(!state.hasConsumedDayKey("2025-01-01"))
    }

    @Test func dayBucketsSplitMidnightAndDedupeSyncedSessions() {
        let start = date(2026, 3, 7, 23)
        let end = date(2026, 3, 8, 1)
        let record = session(start: start, end: end)
        let totals = ReadingMotivationCalculations.dailyTotals(
            sessions: [record, record], calendar: calendar, now: end
        )
        #expect(totals.count == 2)
        #expect(totals[0].seconds == 3600)
        #expect(totals[1].seconds == 3600)
    }

    @Test func dayBucketsRespectDSTAndDiscardInvalidDuration() {
        let start = date(2026, 3, 8, 1)
        let end = date(2026, 3, 8, 4)
        let valid = session(start: start, end: end)
        let invalid = session(start: start, end: end, duration: .nan)
        let totals = ReadingMotivationCalculations.dailyTotals(
            sessions: [valid, invalid], calendar: calendar, now: end
        )
        #expect(totals.count == 1)
        #expect(totals[0].seconds == 2 * 3600)
    }

    @Test func streaksUseLocalCalendarDaysAndHandleYesterdayAndOutOfOrderRows() {
        let today = date(2026, 11, 15, 14)
        let sessions = [
            session(start: date(2026, 11, 13), end: date(2026, 11, 13, 13)),
            session(start: date(2026, 11, 15), end: date(2026, 11, 15, 13)),
            session(start: date(2026, 11, 14), end: date(2026, 11, 14, 13)),
        ]
        let streak = ReadingMotivationCalculations.streaks(
            sessions: sessions, calendar: calendar, now: today
        )
        #expect(streak.current == 3)
        #expect(streak.longest == 3)
        let yesterdayOnly = ReadingMotivationCalculations.streaks(
            sessions: [sessions[2]], calendar: calendar, now: today
        )
        #expect(yesterdayOnly.current == 1)
    }

    @Test func archivedActivityDaysPreserveLongestStreakAfterSessionPruning() {
        let now = date(2026, 11, 15, 14)
        let recent = [
            session(start: date(2026, 11, 13), end: date(2026, 11, 13, 13)),
            session(start: date(2026, 11, 14), end: date(2026, 11, 14, 13)),
        ]
        let streak = ReadingMotivationCalculations.streaks(
            sessions: recent,
            calendar: calendar,
            now: now,
            archivedActivityDays: [ReadingMotivationActivityDay(
                date: date(2026, 11, 12), calendar: calendar
            )]
        )
        // Nov12 archived + Nov13/14 sessions, now=Nov15 → yesterday grace keeps current=3.
        #expect(streak.current == 3)
        #expect(streak.longest == 3)
    }

    @Test func archivedLocalDayDoesNotRebucketAcrossTravelDayBoundary() {
        var losAngeles = calendar
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let newYorkDay = ReadingMotivationActivityDay(
            date: date(2026, 3, 8, 12), calendar: calendar
        )
        let laNow = losAngeles.date(
            from: DateComponents(year: 2026, month: 3, day: 8, hour: 18)
        )!
        let laSession = session(
            mediaID: "travel-book",
            start: laNow.addingTimeInterval(-3600),
            end: laNow
        )
        let streak = ReadingMotivationCalculations.streaks(
            sessions: [laSession],
            calendar: losAngeles,
            now: laNow,
            archivedActivityDays: [newYorkDay]
        )
        #expect(newYorkDay.timeZoneIdentifier == "America/New_York")
        #expect(streak.current == 1)
        #expect(streak.longest == 1)
    }

    @Test func archivedActivityDayKeysRemainConsecutiveAcrossDSTAndRepeatedImports() {
        let days = [
            ReadingMotivationActivityDay(date: date(2026, 3, 7), calendar: calendar),
            ReadingMotivationActivityDay(date: date(2026, 3, 8), calendar: calendar),
            ReadingMotivationActivityDay(date: date(2026, 3, 9), calendar: calendar),
        ]
        let importedTwice = Set(days + days)
        let streak = ReadingMotivationCalculations.streaks(
            sessions: [], calendar: calendar, now: date(2026, 3, 9, 14),
            archivedActivityDays: Array(importedTwice)
        )
        #expect(importedTwice.count == 3)
        #expect(streak.current == 3)
        #expect(streak.longest == 3)
    }

    @Test func pruneDoesNotPersistTwoIdentitiesForSameCalendarDayAfterTravel() {
        var losAngeles = calendar
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let archivedNewYork = ReadingMotivationActivityDay(
            date: date(2026, 3, 8, 12), calendar: calendar
        )
        let start = losAngeles.date(
            from: DateComponents(year: 2026, month: 3, day: 8, hour: 10)
        )!
        let end = start.addingTimeInterval(3600)
        let laSession = session(mediaID: "travel-book", start: start, end: end)
        let archived = ReadingMotivationCalculations.archiveExpiredActivityDays(
            sessions: [laSession], before: date(2026, 3, 9), existing: [archivedNewYork],
            calendar: losAngeles, now: date(2026, 3, 10)
        )
        #expect(archived.count == 1)
        #expect(archived.first?.dayKey == archivedNewYork.dayKey)
    }

    @Test func archivedDaysAreAddedOnlyForExpiredSessionsAndRepeatedPrunesAreIdempotent() {
        let now = date(2026, 11, 15, 14)
        let cutoff = date(2026, 11, 14, 12)
        let expired = session(start: date(2026, 11, 13), end: date(2026, 11, 13, 13))
        let retained = session(start: date(2026, 11, 14), end: date(2026, 11, 14, 13))
        let first = ReadingMotivationCalculations.archiveExpiredActivityDays(
            sessions: [expired, retained], before: cutoff, existing: [],
            calendar: calendar, now: now
        )
        #expect(first.map(\.dayKey) == ["2026-11-13"])
        let repeated = ReadingMotivationCalculations.archiveExpiredActivityDays(
            sessions: [expired, retained, expired], before: cutoff, existing: first,
            calendar: calendar, now: now
        )
        #expect(repeated == first)
    }

    @Test func legacyDateArchiveMigrationRebuildsFromSessionsAndFreezesOldKeys() {
        let now = date(2026, 11, 15, 14)
        let cutoff = date(2026, 11, 14)
        let retained = session(start: date(2026, 11, 13), end: date(2026, 11, 13, 13))
        let staleDateMarkers: Set<Date> = [
            calendar.startOfDay(for: date(2026, 11, 13)),
        ]
        let migrated = ReadingMotivationCalculations.migrateLegacyActivityDays(
            staleDates: staleDateMarkers,
            sessions: [retained],
            before: cutoff,
            calendar: calendar,
            now: now
        )
        #expect(migrated.map(\.dayKey) == ["2026-11-13"])
        #expect(migrated.first?.timeZoneIdentifier == "America/New_York")
    }

    @Test func sourceLessLegacyMarkerKeepsStableUTCIdentityAfterTravel() {
        var kiribati = calendar
        kiribati.timeZone = TimeZone(identifier: "Pacific/Kiritimati")!
        let oldMarker = kiribati.startOfDay(for: date(2024, 2, 2))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let migrated = ReadingMotivationCalculations.migrateLegacyActivityDays(
            staleDates: [oldMarker],
            sessions: [],
            before: date(2026, 11, 15),
            calendar: calendar,
            now: date(2026, 11, 15, 14)
        )
        #expect(migrated.count == 1)
        #expect(migrated.first?.dayKey == ReadingMotivationActivityDay(
            date: oldMarker, calendar: utc
        ).dayKey)
        #expect(migrated.first?.timeZoneIdentifier == "legacy-UTC")
    }

    @Test func weeklyReceiptUsesLocalMondayWeekAndDedupesTitles() {
        let now = date(2026, 11, 15, 14)
        let sessions = [
            session(start: date(2026, 11, 9), end: date(2026, 11, 9, 13)),
            session(start: date(2026, 11, 15), end: date(2026, 11, 15, 13), kind: .listening),
            session(start: date(2026, 11, 16), end: date(2026, 11, 16, 13)),
        ]
        let finished = [
            InkampStatsFinishedRecord(mediaID: "one", mediaTitle: "One", finishedAt: date(2026, 11, 11)),
            InkampStatsFinishedRecord(mediaID: "one", mediaTitle: "One", finishedAt: date(2026, 11, 12)),
            InkampStatsFinishedRecord(mediaID: "two", mediaTitle: "Two", finishedAt: date(2026, 11, 8)),
        ]
        let receipt = ReadingMotivationCalculations.weeklyReceipt(
            sessions: sessions, finished: finished, weekOffset: 0, calendar: calendar, now: now
        )
        #expect(receipt.minutes == 120)
        #expect(receipt.activityDays == 2)
        #expect(receipt.completedTitles == 1)
        let prior = ReadingMotivationCalculations.weeklyReceipt(
            sessions: sessions, finished: finished, weekOffset: -1, calendar: calendar, now: now
        )
        #expect(prior.minutes == 0)
        #expect(prior.activityDays == 0)
    }

    @Test func weeklyReceiptSplitsSessionsAtLocalWeekRollover() {
        let record = session(
            start: date(2026, 11, 15, 23),
            end: date(2026, 11, 16, 1)
        )
        let now = date(2026, 11, 16, 12)
        let current = ReadingMotivationCalculations.weeklyReceipt(
            sessions: [record], finished: [], weekOffset: 0, calendar: calendar, now: now
        )
        let prior = ReadingMotivationCalculations.weeklyReceipt(
            sessions: [record], finished: [], weekOffset: -1, calendar: calendar, now: now
        )
        #expect(current.minutes == 60)
        #expect(prior.minutes == 60)
        #expect(current.activityDays == 1)
        #expect(prior.activityDays == 1)
    }

    @Test func priorWeekReceiptStreakClipsSundayToMondaySessionAtWeekEnd() {
        // Sunday night → Monday morning: totals already split, but streak at the
        // prior-week reference must keep Sunday's clipped portion.
        let crossWeek = session(
            start: date(2026, 11, 15, 22),
            end: date(2026, 11, 16, 2)
        )
        let earlier = session(
            start: date(2026, 11, 14, 12),
            end: date(2026, 11, 14, 13)
        )
        let mondayNoon = date(2026, 11, 16, 12)
        let prior = ReadingMotivationCalculations.weeklyReceipt(
            sessions: [earlier, crossWeek],
            finished: [],
            weekOffset: -1,
            calendar: calendar,
            now: mondayNoon
        )
        let current = ReadingMotivationCalculations.weeklyReceipt(
            sessions: [earlier, crossWeek],
            finished: [],
            weekOffset: 0,
            calendar: calendar,
            now: mondayNoon
        )
        #expect(prior.activityDays == 2)
        #expect(prior.minutes == 180)
        #expect(prior.streakDays == 2)
        #expect(current.activityDays == 1)
        #expect(current.minutes == 120)
        #expect(current.streakDays == 3)

        // Future-only activity at real-now still rejected (no fabricated progress).
        let futureOnly = session(
            start: date(2026, 11, 16, 18),
            end: date(2026, 11, 16, 19)
        )
        let live = ReadingMotivationCalculations.streaks(
            sessions: [futureOnly], calendar: calendar, now: mondayNoon
        )
        #expect(live.current == 0)
        #expect(live.longest == 0)
    }

    @Test func finishEstimateRequiresObservedPaceAndHandlesFinishedAndInvalidRates() {
        let now = date(2026, 11, 15, 14)
        let sessions = [
            session(start: date(2026, 11, 13), end: date(2026, 11, 13, 13), progress: 0.1),
            session(start: date(2026, 11, 14), end: date(2026, 11, 14, 13), progress: 0.2),
        ]
        let estimate = ReadingMotivationCalculations.projectedFinish(
            sessions: sessions,
            mediaID: "book-1",
            progress: 0.2,
            totalUnits: 300,
            playbackRate: nil,
            calendar: calendar,
            now: now,
        )
        guard case .estimate(let finishDate, _) = estimate else {
            Issue.record("Expected estimate from two real progress checkpoints")
            return
        }
        #expect(abs(finishDate.timeIntervalSince(now) - 8 * 3600) < 1)
        #expect(ReadingMotivationCalculations.projectedFinish(
            sessions: [], mediaID: "book-1", progress: 0.2, totalUnits: 300,
            playbackRate: nil, calendar: calendar, now: now
        ) == nil)
        let stalled = [
            session(start: date(2026, 11, 13), end: date(2026, 11, 13, 13), progress: 0.2),
            session(start: date(2026, 11, 14), end: date(2026, 11, 14, 13), progress: 0.2),
        ]
        #expect(ReadingMotivationCalculations.projectedFinish(
            sessions: stalled, mediaID: "book-1", progress: 0.3, totalUnits: 300,
            playbackRate: nil, calendar: calendar, now: now
        ) == nil)
        #expect(ReadingMotivationCalculations.projectedFinish(
            sessions: [], mediaID: "book-1", progress: 1, totalUnits: 300,
            playbackRate: nil, calendar: calendar, now: now
        ) == .finished)
        #expect(ReadingMotivationCalculations.projectedFinish(
            sessions: [], mediaID: "book-1", progress: 0.2, totalUnits: 300,
            playbackRate: .infinity, calendar: calendar, now: now
        ) == nil)
    }

    @Test func projectedFinishNearCompletionEstimatesRemainingNotFinished() {
        let now = date(2026, 11, 15, 14)
        // 99.5% with known length + playback rate still has remaining content.
        let nearComplete = ReadingMotivationCalculations.projectedFinish(
            sessions: [],
            mediaID: "book-1",
            progress: 0.995,
            totalUnits: 1000,
            playbackRate: 1,
            calendar: calendar,
            now: now
        )
        guard case .estimate(let finish, let basis) = nearComplete else {
            Issue.record("Expected remaining estimate at 99.5%, not finished")
            return
        }
        #expect(abs(finish.timeIntervalSince(now) - 5) < 0.01)
        #expect(basis.contains("1"))
        #expect(ReadingMotivationCalculations.projectedFinish(
            sessions: [], mediaID: "book-1", progress: 0.995, totalUnits: nil,
            playbackRate: 1, calendar: calendar, now: now
        ) == nil)
        #expect(ReadingMotivationCalculations.projectedFinish(
            sessions: [], mediaID: "book-1", progress: 1, totalUnits: nil,
            playbackRate: 1, calendar: calendar, now: now
        ) == .finished)
        #expect(ReadingMotivationCalculations.projectedFinish(
            sessions: [], mediaID: "book-1", progress: 1.0, totalUnits: 1000,
            playbackRate: 1, calendar: calendar, now: now
        ) == .finished)
    }

    @Test func projectedFinishCountsPlateauAndMissingCheckpointsBetweenProgress() {
        let now = date(2026, 11, 15, 14)
        // 0.1 → 0.1 → 0.2: stalled middle hour still belongs to the interval.
        let plateau = [
            session(start: date(2026, 11, 13), end: date(2026, 11, 13, 13), progress: 0.1),
            session(start: date(2026, 11, 14), end: date(2026, 11, 14, 13), progress: 0.1),
            session(start: date(2026, 11, 15), end: date(2026, 11, 15, 13), progress: 0.2),
        ]
        let estimate = ReadingMotivationCalculations.projectedFinish(
            sessions: plateau, mediaID: "book-1", progress: 0.2, totalUnits: 300,
            playbackRate: nil, calendar: calendar, now: now
        )
        guard case .estimate(let finish, _) = estimate else {
            Issue.record("Expected plateau interval to establish pace")
            return
        }
        // 0.1 of 300 units over 2h → 15 units/h; remaining 240 units → 16h.
        #expect(abs(finish.timeIntervalSince(now) - 16 * 3600) < 1)

        let withMissingMid = [
            session(start: date(2026, 11, 13), end: date(2026, 11, 13, 13), progress: 0.1),
            session(start: date(2026, 11, 14), end: date(2026, 11, 14, 13), progress: nil),
            session(start: date(2026, 11, 15), end: date(2026, 11, 15, 13), progress: 0.2),
        ]
        guard case .estimate(let missingFinish, _) = ReadingMotivationCalculations.projectedFinish(
            sessions: withMissingMid, mediaID: "book-1", progress: 0.2, totalUnits: 300,
            playbackRate: nil, calendar: calendar, now: now
        ) else {
            Issue.record("Expected missing mid-checkpoint work to count")
            return
        }
        #expect(abs(missingFinish.timeIntervalSince(now) - 16 * 3600) < 1)

        let regression = [
            session(start: date(2026, 11, 13), end: date(2026, 11, 13, 13), progress: 0.3),
            session(start: date(2026, 11, 14), end: date(2026, 11, 14, 13), progress: 0.1),
        ]
        #expect(ReadingMotivationCalculations.projectedFinish(
            sessions: regression, mediaID: "book-1", progress: 0.1, totalUnits: 300,
            playbackRate: nil, calendar: calendar, now: now
        ) == nil)
    }

    @Test func clippedSessionProjectionClearsFutureCheckpoints() {
        let historicalNow = date(2026, 11, 14, 12)
        let early = session(
            start: date(2026, 11, 13), end: date(2026, 11, 13, 13), progress: 0.1
        )
        // Ends after the historical reference with a later-only checkpoint of 0.5.
        let crossing = session(
            start: date(2026, 11, 14, 10),
            end: date(2026, 11, 14, 16),
            progress: 0.5
        )
        let withoutFuture = ReadingMotivationCalculations.projectedFinish(
            sessions: [early, crossing],
            mediaID: "book-1",
            progress: 0.1,
            totalUnits: 300,
            playbackRate: nil,
            calendar: calendar,
            now: historicalNow
        )
        // Clipped crossing keeps time but clears endProgress, so no second checkpoint.
        #expect(withoutFuture == nil)

        let afterCrossingEnds = ReadingMotivationCalculations.projectedFinish(
            sessions: [early, crossing],
            mediaID: "book-1",
            progress: 0.5,
            totalUnits: 300,
            playbackRate: nil,
            calendar: calendar,
            now: date(2026, 11, 14, 17)
        )
        guard case .estimate(let finish, _) = afterCrossingEnds else {
            Issue.record("Expected pace once the future checkpoint is actually observed")
            return
        }
        // 0.4 of 300 over 6h → 20 units/h; remaining 150 → 7.5h.
        #expect(abs(finish.timeIntervalSince(date(2026, 11, 14, 17)) - 7.5 * 3600) < 1)
    }

    @Test func knownAudioRateProducesWallClockFinishEstimate() {
        let now = date(2026, 11, 15)
        let estimate = ReadingMotivationCalculations.projectedFinish(
            sessions: [], mediaID: "book-1", progress: 0.5, totalUnits: 7200,
            playbackRate: 1.5, calendar: calendar, now: now
        )
        guard case .estimate(let finish, let basis) = estimate else {
            Issue.record("Expected known-duration playback estimate")
            return
        }
        #expect(finish.timeIntervalSince(now) == 2400)
        #expect(basis.contains("1.5×"))
        #expect(ReadingMotivationCalculations.projectedFinish(
            sessions: [], mediaID: "book-1", progress: 0.5, totalUnits: nil,
            playbackRate: 1.5, calendar: calendar, now: now
        ) == nil)
        let dstStart = date(2026, 3, 8, 1)
        let dstEstimate = ReadingMotivationCalculations.projectedFinish(
            sessions: [], mediaID: "book-1", progress: 0.5, totalUnits: 10_800,
            playbackRate: 1, calendar: calendar, now: dstStart
        )
        guard case .estimate(let dstFinish, _) = dstEstimate else {
            Issue.record("Expected a playback estimate across the DST boundary")
            return
        }
        let expectedDSTFinish = dstStart.addingTimeInterval(5_400)
        #expect(dstFinish == expectedDSTFinish)
        #expect(calendar.component(.hour, from: dstFinish) == 3)
        #expect(calendar.component(.minute, from: dstFinish) == 30)
    }

    @Test func projectedFinishRejectsIntMaxRoundingTrapAndExtremePace() {
        let now = date(2026, 11, 15, 14)
        // remaining / rate == Double(Int.max) rounds to 2^63 — old guard passed, Int trapped.
        #expect(ReadingMotivationCalculations.projectedFinish(
            sessions: [], mediaID: "book-1", progress: 0,
            totalUnits: Double(Int.max), playbackRate: 1,
            calendar: calendar, now: now
        ) == nil)
        #expect(ReadingMotivationCalculations.projectedFinish(
            sessions: [], mediaID: "book-1", progress: 0,
            totalUnits: 0x1p63, playbackRate: 1,
            calendar: calendar, now: now
        ) == nil)
        // Adjacent representable value below 2^63 must not trap; calendar may still
        // refuse an absurd finish date, which is preferable to a fabricated one.
        let adjacent = ReadingMotivationCalculations.projectedFinish(
            sessions: [], mediaID: "book-1", progress: 0,
            totalUnits: 0x1p63.nextDown, playbackRate: 1,
            calendar: calendar, now: now
        )
        if case .estimate(let finish, _) = adjacent {
            #expect(finish.timeIntervalSince1970.isFinite)
        }
        let safeSeconds = 1_000_000.0
        guard case .estimate(let safeFinish, _) = ReadingMotivationCalculations.projectedFinish(
            sessions: [], mediaID: "book-1", progress: 0,
            totalUnits: safeSeconds, playbackRate: 1,
            calendar: calendar, now: now
        ) else {
            Issue.record("Expected finite estimate for a representable duration")
            return
        }
        #expect(safeFinish.timeIntervalSince(now) == safeSeconds)

        // Near-zero observed pace → huge remaining seconds → nil, not a trap/fake date.
        let tinyPace = [
            session(start: date(2026, 11, 13), end: date(2026, 11, 13, 12), duration: 1, progress: 0.0),
            session(
                start: date(2026, 11, 14), end: date(2026, 11, 14, 12), duration: 1,
                progress: Double.leastNormalMagnitude
            ),
        ]
        #expect(ReadingMotivationCalculations.projectedFinish(
            sessions: tinyPace, mediaID: "book-1", progress: 0.01, totalUnits: 1_000_000,
            playbackRate: nil, calendar: calendar, now: now
        ) == nil)
    }

    @Test func widgetTimingClampsOvershootAndAppliesSpeed() {
        let timing = ContinueWidgetTiming.calculate(
            progress: 0.4, elapsedSeconds: 80, durationSeconds: 100, rate: 2
        )
        #expect(timing?.elapsedSeconds == 80)
        #expect(timing?.remainingWallSeconds == 10)
        #expect(ContinueWidgetTiming.calculate(
            progress: .nan, elapsedSeconds: .nan, durationSeconds: 100, rate: 1
        ) == nil)
        #expect(ContinueWidgetTiming.calculate(
            progress: 0.5, elapsedSeconds: -2, durationSeconds: 0, rate: 1
        ) == nil)
        #expect(ContinueWidgetTiming.calculate(
            progress: 0.5, elapsedSeconds: 150, durationSeconds: 100, rate: 1
        )?.remainingWallSeconds == 0)
    }

    @Test func widgetTimingRetainsKnownElapsedWhenDurationUnknown() {
        let knownElapsed = ContinueWidgetTiming.calculate(
            progress: 0.4, elapsedSeconds: 900, durationSeconds: nil, rate: 1
        )
        #expect(knownElapsed?.elapsedSeconds == 900)
        #expect(knownElapsed?.remainingWallSeconds == nil)
        // Do not fabricate elapsed from progress when total is absent.
        #expect(ContinueWidgetTiming.calculate(
            progress: 0.5, elapsedSeconds: nil, durationSeconds: nil, rate: 1
        ) == nil)
        #expect(ContinueWidgetTiming.calculate(
            progress: nil, elapsedSeconds: nil, durationSeconds: nil, rate: nil
        ) == nil)
        #expect(ContinueWidgetTiming.calculate(
            progress: 0.2, elapsedSeconds: .nan, durationSeconds: nil, rate: 1
        ) == nil)
        #expect(ContinueWidgetTiming.calculate(
            progress: 0.2, elapsedSeconds: .infinity, durationSeconds: nil, rate: 1
        ) == nil)

        let timed = ContinueWidgetSnapshot(
            title: "Book", kind: .audiobook, progress: 0.4,
            elapsedSeconds: 900, durationSeconds: nil, rate: 1
        )
        #expect(timed.elapsedText == "15m")
        #expect(timed.lengthText == nil)
        #expect(timed.elapsedLengthText == "15m elapsed")
        #expect(timed.remainingText == nil)
        #expect(timed.progressCaption?.contains("15m elapsed") == true)

        let ebook = ContinueWidgetSnapshot(
            title: "Book", kind: .ebook, progress: 0.4,
            elapsedSeconds: 900, durationSeconds: nil
        )
        #expect(ebook.elapsedText == nil)
        #expect(ebook.elapsedLengthText == nil)
    }

    @Test func liveAudioProjectionUsesMatchingCurrentTimingRatherThanStoredFraction() {
        let now = date(2026, 11, 15, 12)
        let live = AudioSessionSnapshot(
            kind: .podcast("episode"), title: "Episode", author: nil,
            isPlaying: true, chapterLabel: nil, bookProgress: 0.2, playbackRate: 2,
            elapsedSeconds: 80, durationSeconds: 100
        )
        let result = ReadingMotivationCalculations.projectedAudioFinish(
            snapshot: live, expectedMediaID: "podcast/episode", calendar: calendar, now: now
        )
        guard case .estimate(let finish, _) = result else {
            Issue.record("Expected live audio projection")
            return
        }
        #expect(finish.timeIntervalSince(now) == 10)
        #expect(ReadingMotivationCalculations.projectedAudioFinish(
            snapshot: live, expectedMediaID: "podcast/another", calendar: calendar, now: now
        ) == nil)
        let unknown = AudioSessionSnapshot(
            kind: .podcast("episode"), title: "Episode", author: nil,
            isPlaying: true, chapterLabel: nil, bookProgress: 0.2, playbackRate: 2,
            elapsedSeconds: 80, durationSeconds: 0
        )
        #expect(ReadingMotivationCalculations.projectedAudioFinish(
            snapshot: unknown, expectedMediaID: "podcast/episode", calendar: calendar, now: now
        ) == nil)
    }

    @Test func dismissedLegacyUndatedPendingIntentCannotInstallAgainToday() async throws {
        let now = date(2026, 11, 15, 12)
        let storage = TestMotivationStateStore(ReadingMotivationNotificationState(
            pendingKind: .rescue, pendingDayKey: "2026-11-15"
        ))
        let scheduler = TestMotivationScheduler()
        let (coordinator, _) = makeCoordinator(scheduler: scheduler, stateStore: storage, now: now)
        _ = try await coordinator.reconcile(
            candidates: [ReadingMotivationNotificationCandidate(
                kind: .rescue, deliveryDate: date(2026, 11, 15, 20)
            )], enabled: true, now: now, calendar: calendar,
            preferenceRevision: 1, requestRevision: 1
        )
        #expect(await scheduler.scheduleCalls() == 0)
        #expect(await scheduler.pendingCount() == 0)
        let persisted = await storage.load()
        #expect(persisted.hasConsumedDayKey("2026-11-15"))
    }

    @Test func oldWidgetSnapshotDecodesWithoutNewMotivationFields() throws {
        let oldJSON = Data(#"{"generatedAt":"2026-11-15T17:00:00Z","title":"Book","isPlaying":false,"progress":0.5}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(ContinueWidgetSnapshot.self, from: oldJSON)
        #expect(snapshot.title == "Book")
        #expect(snapshot.elapsedText == nil)
        #expect(snapshot.remainingText == nil)
        #expect(snapshot.streakActivityDayKey == nil)
    }

    @Test func widgetStreakExpiresOnDayRolloverWithTodayYesterdayGrace() {
        let activityDay = "2026-11-14"
        let snapshot = ContinueWidgetSnapshot(
            generatedAt: date(2026, 11, 16, 8),
            title: "Book",
            streakDays: 5,
            streakActivityDayKey: activityDay
        )
        // Same activity day
        #expect(snapshot.resolvingStreak(at: date(2026, 11, 14, 21), calendar: calendar).streakDays == 5)
        // Yesterday grace
        #expect(snapshot.resolvingStreak(at: date(2026, 11, 15, 9), calendar: calendar).streakDays == 5)
        // Two local days later — expired even though generatedAt is "today"
        #expect(snapshot.resolvingStreak(at: date(2026, 11, 16, 9), calendar: calendar).streakDays == 0)

        // Audio-style republish keeps the activity anchor, not generatedAt.
        let afterAudio = ContinueWidgetSnapshot(
            generatedAt: date(2026, 11, 16, 22),
            title: "Book",
            progress: 0.55,
            streakDays: 5,
            streakActivityDayKey: activityDay
        )
        #expect(afterAudio.streakActivityDayKey == activityDay)
        #expect(afterAudio.resolvingStreak(at: date(2026, 11, 16, 22), calendar: calendar).streakDays == 0)

        // DST spring-forward local day still uses calendar day keys.
        let dstAnchor = ContinueWidgetSnapshot(
            generatedAt: date(2026, 3, 9, 12),
            title: "Book",
            streakDays: 2,
            streakActivityDayKey: "2026-03-08"
        )
        #expect(dstAnchor.resolvingStreak(at: date(2026, 3, 9, 12), calendar: calendar).streakDays == 2)
        #expect(dstAnchor.resolvingStreak(at: date(2026, 3, 10, 12), calendar: calendar).streakDays == 0)

        // Old snapshot without activity key: generatedAt day is the legacy anchor.
        let legacy = ContinueWidgetSnapshot(
            generatedAt: date(2026, 11, 14, 18),
            title: "Book",
            streakDays: 3
        )
        #expect(legacy.streakActivityDayKey == nil)
        #expect(legacy.resolvingStreak(at: date(2026, 11, 15, 10), calendar: calendar).streakDays == 3)
        #expect(legacy.resolvingStreak(at: date(2026, 11, 16, 10), calendar: calendar).streakDays == 0)
    }

    @Test func widgetKeepsElapsedLengthButMarksUnknownSpeedHonestly() {
        let snapshot = ContinueWidgetSnapshot(
            title: "Book", kind: .audiobook, progress: 0.5,
            durationSeconds: 7200, rate: nil
        )
        #expect(snapshot.elapsedLengthText == "1h / 2h")
        #expect(snapshot.remainingText == nil)
        #expect(snapshot.remainingStatusText == "Remaining time unknown")
    }

    @Test func snapshotDropsNonFiniteValuesBeforePersistence() throws {
        let snapshot = ContinueWidgetSnapshot(
            title: "Book", progress: .nan, elapsedSeconds: .infinity,
            durationSeconds: .infinity, rate: .nan
        )
        #expect(snapshot.progress == nil)
        #expect(snapshot.elapsedSeconds == nil)
        #expect(snapshot.durationSeconds == nil)
        #expect(snapshot.rate == nil)
        _ = try JSONEncoder().encode(snapshot)
    }

    @Test func notificationArbitrationIsStrictAndConsumesOnePerLocalDay() {
        let now = date(2026, 11, 15, 18)
        let delivery = date(2026, 11, 15, 20)
        let candidates = [
            ReadingMotivationNotificationCandidate(kind: .receipt, deliveryDate: delivery),
            ReadingMotivationNotificationCandidate(kind: .pace, deliveryDate: delivery),
            ReadingMotivationNotificationCandidate(kind: .rescue, deliveryDate: delivery),
        ]
        let decision = ReadingMotivationNotificationPolicy.decide(
            candidates: candidates, state: .empty, enabled: true, authorized: true,
            now: now, calendar: calendar
        )
        #expect(decision == .schedule(kind: .rescue, dayKey: "2026-11-15"))
        let state = ReadingMotivationNotificationState(pendingKind: .receipt, pendingDayKey: "2026-11-15")
        #expect(ReadingMotivationNotificationPolicy.decide(
            candidates: candidates, state: state, enabled: true, authorized: true,
            now: now, calendar: calendar
        ) == .replacePending(kind: .rescue, dayKey: "2026-11-15"))
        let consumed = ReadingMotivationNotificationState(consumedDayKey: "2026-11-15")
        #expect(ReadingMotivationNotificationPolicy.decide(
            candidates: candidates, state: consumed, enabled: true, authorized: true,
            now: now, calendar: calendar
        ) == .none)
    }

    @Test func notificationCandidatesUseQuietTimeAndRealGoalProgress() {
        let now = date(2026, 11, 15, 18)
        let quiet = ReadingMotivationNotificationPolicy.quietDeliveryDate(
            on: now, hour: 20, minute: 30, calendar: calendar
        )!
        let candidates = ReadingMotivationNotificationPolicy.candidates(
            now: now,
            quietDeliveryDate: quiet,
            readingSeconds: 0,
            readingGoalSeconds: 3600,
            listeningSeconds: 0,
            listeningGoalSeconds: 0,
            activityDaysThisWeek: 2,
            calendar: calendar
        )
        #expect(Set(candidates.map(\.kind)) == Set([.rescue, .pace, .receipt]))
        #expect(ReadingMotivationNotificationPolicy.decide(
            candidates: candidates, state: .empty, enabled: true, authorized: true,
            now: now, calendar: calendar
        ) == .schedule(kind: .rescue, dayKey: "2026-11-15"))

        let metGoal = ReadingMotivationNotificationPolicy.candidates(
            now: now, quietDeliveryDate: quiet,
            readingSeconds: 3600, readingGoalSeconds: 3600,
            listeningSeconds: 0, listeningGoalSeconds: 0,
            activityDaysThisWeek: 2, calendar: calendar
        )
        #expect(metGoal.map(\.kind) == [.receipt])
        #expect(ReadingMotivationNotificationPolicy.candidates(
            now: now, quietDeliveryDate: date(2026, 11, 15, 17),
            readingSeconds: 0, readingGoalSeconds: 3600,
            listeningSeconds: 0, listeningGoalSeconds: 0,
            activityDaysThisWeek: 2, calendar: calendar
        ).isEmpty)
    }

    @Test func independentReadingAndListeningGoalsDoNotSuppressEachOther() {
        let now = date(2026, 11, 15, 18)
        let quiet = ReadingMotivationNotificationPolicy.quietDeliveryDate(
            on: now, hour: 20, minute: 30, calendar: calendar
        )!
        // 30m goals each; 60m listening / 0 reading must still nudge reading.
        let listeningOnly = ReadingMotivationNotificationPolicy.candidates(
            now: now, quietDeliveryDate: quiet,
            readingSeconds: 0, readingGoalSeconds: 1800,
            listeningSeconds: 3600, listeningGoalSeconds: 1800,
            activityDaysThisWeek: 0, calendar: calendar
        )
        #expect(Set(listeningOnly.map(\.kind)) == Set([.rescue, .pace]))
        #expect(ReadingMotivationNotificationPolicy.decide(
            candidates: listeningOnly, state: .empty, enabled: true, authorized: true,
            now: now, calendar: calendar
        ) == .schedule(kind: .rescue, dayKey: "2026-11-15"))

        let readingOnly = ReadingMotivationNotificationPolicy.candidates(
            now: now, quietDeliveryDate: quiet,
            readingSeconds: 3600, readingGoalSeconds: 1800,
            listeningSeconds: 0, listeningGoalSeconds: 1800,
            activityDaysThisWeek: 0, calendar: calendar
        )
        #expect(Set(readingOnly.map(\.kind)) == Set([.rescue, .pace]))

        let bothMet = ReadingMotivationNotificationPolicy.candidates(
            now: now, quietDeliveryDate: quiet,
            readingSeconds: 1800, readingGoalSeconds: 1800,
            listeningSeconds: 1800, listeningGoalSeconds: 1800,
            activityDaysThisWeek: 0, calendar: calendar
        )
        #expect(bothMet.isEmpty)

        #expect(ReadingMotivationNotificationPolicy.decide(
            candidates: listeningOnly, state: .empty, enabled: false, authorized: true,
            now: now, calendar: calendar
        ) == .none)
        #expect(ReadingMotivationNotificationPolicy.decide(
            candidates: listeningOnly, state: .empty, enabled: true, authorized: false,
            now: now, calendar: calendar
        ) == .none)
        let consumed = ReadingMotivationNotificationState(consumedDayKey: "2026-11-15")
        #expect(ReadingMotivationNotificationPolicy.decide(
            candidates: listeningOnly, state: consumed, enabled: true, authorized: true,
            now: now, calendar: calendar
        ) == .none)
    }

    @Test func morningLaunchSchedulesQuietTimeCandidateWithoutFurtherInteraction() async throws {
        let morning = date(2026, 11, 15, 8)
        let quiet = ReadingMotivationNotificationPolicy.quietDeliveryDate(
            on: morning, hour: 20, minute: 30, calendar: calendar
        )!
        let candidates = ReadingMotivationNotificationPolicy.candidates(
            now: morning,
            quietDeliveryDate: quiet,
            readingSeconds: 0,
            readingGoalSeconds: 3600,
            listeningSeconds: 0,
            listeningGoalSeconds: 0,
            activityDaysThisWeek: 0,
            calendar: calendar
        )
        #expect(Set(candidates.map(\.kind)) == Set([.rescue, .pace]))
        #expect(candidates.allSatisfy { $0.deliveryDate == quiet })

        let scheduler = TestMotivationScheduler()
        let storage = TestMotivationStateStore()
        let (coordinator, _) = makeCoordinator(scheduler: scheduler, stateStore: storage, now: morning)
        #expect(try await coordinator.reconcile(
            candidates: candidates, enabled: true, now: morning, calendar: calendar,
            preferenceRevision: 1, requestRevision: 1
        ) == .schedule(kind: .rescue, dayKey: "2026-11-15"))
        #expect(await scheduler.pendingCount() == 1)
        #expect(await scheduler.pendingKind(for: "reading-motivation.2026-11-15") == .rescue)
        #expect(await scheduler.pendingDate(for: "reading-motivation.2026-11-15") == quiet)

        // Later progress that meets the goal cancels the pending quiet-time request.
        let afterGoal = ReadingMotivationNotificationPolicy.candidates(
            now: date(2026, 11, 15, 12),
            quietDeliveryDate: quiet,
            readingSeconds: 3600,
            readingGoalSeconds: 3600,
            listeningSeconds: 0,
            listeningGoalSeconds: 0,
            activityDaysThisWeek: 0,
            calendar: calendar
        )
        #expect(afterGoal.isEmpty)
        #expect(try await coordinator.reconcile(
            candidates: afterGoal, enabled: true, now: date(2026, 11, 15, 12), calendar: calendar,
            preferenceRevision: 1, requestRevision: 2
        ) == .cancelPending)
        #expect(await scheduler.pendingCount() == 0)
    }

    @Test func obsoleteRescueEligibilityYieldsToCurrentPaceCandidate() async throws {
        let now = date(2026, 11, 15, 18)
        let quiet = ReadingMotivationNotificationPolicy.quietDeliveryDate(
            on: now, hour: 20, minute: 30, calendar: calendar
        )!
        let scheduler = TestMotivationScheduler()
        let (coordinator, _) = makeCoordinator(scheduler: scheduler, now: now)
        let morningCandidates = ReadingMotivationNotificationPolicy.candidates(
            now: date(2026, 11, 15, 8),
            quietDeliveryDate: quiet,
            readingSeconds: 0,
            readingGoalSeconds: 3600,
            listeningSeconds: 0,
            listeningGoalSeconds: 0,
            activityDaysThisWeek: 0,
            calendar: calendar
        )
        #expect(try await coordinator.reconcile(
            candidates: morningCandidates, enabled: true, now: now, calendar: calendar,
            preferenceRevision: 1, requestRevision: 1
        ) == .schedule(kind: .rescue, dayKey: "2026-11-15"))
        #expect(await scheduler.pendingKind(for: "reading-motivation.2026-11-15") == .rescue)

        // Half the goal met: rescue no longer eligible, pace still is.
        let progressed = ReadingMotivationNotificationPolicy.candidates(
            now: now,
            quietDeliveryDate: quiet,
            readingSeconds: 2000,
            readingGoalSeconds: 3600,
            listeningSeconds: 0,
            listeningGoalSeconds: 0,
            activityDaysThisWeek: 0,
            calendar: calendar
        )
        #expect(Set(progressed.map(\.kind)) == Set([.pace]))
        #expect(try await coordinator.reconcile(
            candidates: progressed, enabled: true, now: now, calendar: calendar,
            preferenceRevision: 1, requestRevision: 2
        ) == .replacePending(kind: .pace, dayKey: "2026-11-15"))
        #expect(await scheduler.pendingKind(for: "reading-motivation.2026-11-15") == .pace)
    }

    @Test func quietTimeResolvesOnTheLocalDSTCalendarDay() {
        let now = date(2026, 3, 8, 1)
        let quiet = ReadingMotivationNotificationPolicy.quietDeliveryDate(
            on: now, hour: 2, minute: 30, calendar: calendar
        )
        #expect(quiet.map { calendar.isDate($0, inSameDayAs: now) } == true)
    }

    @Test func notificationPolicyHandlesRepeatDisabledDeniedAndDayRollover() {
        let now = date(2026, 11, 15, 18)
        let candidate = ReadingMotivationNotificationCandidate(
            kind: .pace, deliveryDate: date(2026, 11, 15, 20)
        )
        let pending = ReadingMotivationNotificationState(
            pendingKind: .pace,
            pendingDayKey: "2026-11-15",
            pendingDeliveryDate: candidate.deliveryDate
        )
        #expect(ReadingMotivationNotificationPolicy.decide(
            candidates: [candidate], state: pending, enabled: true, authorized: true,
            now: now, calendar: calendar
        ) == .none)
        #expect(ReadingMotivationNotificationPolicy.decide(
            candidates: [candidate], state: pending, enabled: false, authorized: true,
            now: now, calendar: calendar
        ) == .cancelPending)
        #expect(ReadingMotivationNotificationPolicy.decide(
            candidates: [candidate], state: pending, enabled: true, authorized: false,
            now: now, calendar: calendar
        ) == .cancelPending)
        let tomorrow = date(2026, 11, 16, 18)
        let nextCandidate = ReadingMotivationNotificationCandidate(
            kind: .receipt, deliveryDate: date(2026, 11, 16, 20)
        )
        #expect(ReadingMotivationNotificationPolicy.decide(
            candidates: [nextCandidate], state: pending, enabled: true, authorized: true,
            now: tomorrow, calendar: calendar
        ) == .schedule(kind: .receipt, dayKey: "2026-11-16"))
        let quietDate = calendar.date(byAdding: .hour, value: 4, to: now)!
        #expect(ReadingMotivationNotificationPolicy.localDayKey(quietDate, calendar: calendar) == "2026-11-15")
    }

    @Test func injectedSchedulerAndPersistedLedgerPreventRepeatAcrossRestarts() async throws {
        let now = date(2026, 11, 15, 18)
        let dayKey = "2026-11-15"
        let candidate = ReadingMotivationNotificationCandidate(
            kind: .rescue, deliveryDate: date(2026, 11, 15, 20)
        )
        let scheduler = TestMotivationScheduler()
        let storage = TestMotivationStateStore()
        let (first, clock) = makeCoordinator(scheduler: scheduler, stateStore: storage, now: now)
        #expect(try await first.reconcile(
            candidates: [candidate], enabled: true, now: now, calendar: calendar
        ) == .schedule(kind: .rescue, dayKey: dayKey))
        #expect(try await first.reconcile(
            candidates: [candidate], enabled: true, now: now, calendar: calendar
        ) == .none)
        #expect(await scheduler.pendingCount() == 1)

        let (afterRestart, _) = makeCoordinator(scheduler: scheduler, stateStore: storage, now: now, clock: clock)
        #expect(try await afterRestart.reconcile(
            candidates: [candidate], enabled: true, now: now, calendar: calendar
        ) == .none)
        let afterDeliveryTime = date(2026, 11, 15, 21)
        #expect(try await afterRestart.reconcile(
            candidates: [candidate], enabled: true, now: afterDeliveryTime, calendar: calendar
        ) == .none)
        #expect(await storage.load().consumedDayKey == dayKey)
        #expect(await scheduler.pendingCount() == 0)
    }

    @Test func injectedSchedulerReplacesOnlyWithHigherPriorityAndCancelsWhenDisabled() async throws {
        let now = date(2026, 11, 15, 18)
        let delivery = date(2026, 11, 15, 20)
        let scheduler = TestMotivationScheduler()
        let (coordinator, _) = makeCoordinator(scheduler: scheduler, now: now)
        let receipt = ReadingMotivationNotificationCandidate(kind: .receipt, deliveryDate: delivery)
        let rescue = ReadingMotivationNotificationCandidate(kind: .rescue, deliveryDate: delivery)
        #expect(try await coordinator.reconcile(
            candidates: [receipt], enabled: true, now: now, calendar: calendar
        ) == .schedule(kind: .receipt, dayKey: "2026-11-15"))
        #expect(try await coordinator.reconcile(
            candidates: [receipt, rescue], enabled: true, now: now, calendar: calendar
        ) == .replacePending(kind: .rescue, dayKey: "2026-11-15"))
        #expect(await scheduler.pendingCount() == 1)
        #expect(try await coordinator.reconcile(
            candidates: [rescue], enabled: false, now: now, calendar: calendar
        ) == .cancelPending)
        #expect(await scheduler.pendingCount() == 0)
    }

    @Test func permissionIsRequestedOnlyByExplicitOptInAction() async {
        let scheduler = TestMotivationScheduler()
        let (coordinator, _) = makeCoordinator(scheduler: scheduler, now: date(2026, 11, 15, 18))
        await scheduler.setAuthorization(.denied)
        #expect(!(await coordinator.requestPermission()))
        #expect(await scheduler.authorizationRequestCount() == 0)
        await scheduler.setAuthorization(.notDetermined)
        #expect(!(await coordinator.requestPermission()))
        #expect(await scheduler.authorizationRequestCount() == 1)
    }

    @Test func deliveryLedgerUsesCurrentLocalDayAfterTimezoneRollover() async {
        let scheduler = TestMotivationScheduler()
        let storage = TestMotivationStateStore(
            ReadingMotivationNotificationState(
                pendingKind: .receipt,
                pendingDayKey: "2026-11-16",
                pendingDeliveryDate: date(2026, 11, 16, 8)
            )
        )
        let (coordinator, _) = makeCoordinator(
            scheduler: scheduler, stateStore: storage, now: date(2026, 11, 15, 23)
        )
        await coordinator.markDelivered(
            dayKey: "2026-11-16", deliveredAt: date(2026, 11, 15, 23), calendar: calendar
        )
        #expect(await storage.load().consumedDayKey == "2026-11-15")
        #expect(await storage.load().pendingDayKey == nil)
    }

    @Test func concurrentFirstTransactionsLoadLedgerOnlyOnce() async throws {
        let now = date(2026, 11, 15, 18)
        let cal = calendar
        let candidate = ReadingMotivationNotificationCandidate(
            kind: .receipt, deliveryDate: date(2026, 11, 15, 20)
        )
        let storage = TestMotivationStateStore(
            ReadingMotivationNotificationState(consumedDayKey: "2026-11-14")
        )
        await storage.pauseNextLoadCall()
        let scheduler = TestMotivationScheduler()
        let (coordinator, _) = makeCoordinator(scheduler: scheduler, stateStore: storage, now: now)

        let first = Task {
            try await coordinator.reconcile(
                candidates: [candidate], enabled: true, now: now, calendar: cal,
                preferenceRevision: 1, requestRevision: 1
            )
        }
        await storage.waitForPausedLoad()
        let secondStarted = TestMotivationSignal()
        let second = Task {
            await secondStarted.signal()
            return try await coordinator.reconcile(
                candidates: [candidate], enabled: true, now: now, calendar: cal,
                preferenceRevision: 1, requestRevision: 2
            )
        }
        await secondStarted.wait()
        await Task.yield()
        await storage.resumePausedLoad()

        #expect(try await first.value == .schedule(kind: .receipt, dayKey: "2026-11-15"))
        #expect(try await second.value == .none)
        #expect(await storage.reads() == 1)
        #expect(await storage.load().hasConsumedDayKey("2026-11-14"))
        #expect(await scheduler.pendingCount() == 1)
    }

    @Test func concurrentOptOutWinsAfterSuspendedScheduleAndRejectsStaleRefresh() async throws {
        let now = date(2026, 11, 15, 18)
        let cal = calendar
        let candidate = ReadingMotivationNotificationCandidate(
            kind: .rescue, deliveryDate: date(2026, 11, 15, 20)
        )
        let scheduler = TestMotivationScheduler()
        await scheduler.pauseNextScheduleCall()
        let storage = TestMotivationStateStore()
        let (coordinator, _) = makeCoordinator(scheduler: scheduler, stateStore: storage, now: now)

        let enabled = Task {
            try await coordinator.reconcile(
                candidates: [candidate], enabled: true, now: now, calendar: cal,
                preferenceRevision: 1, requestRevision: 1
            )
        }
        await scheduler.waitForPausedSchedule()
        let disabledStarted = TestMotivationSignal()
        let disabled = Task {
            await disabledStarted.signal()
            return try await coordinator.reconcile(
                candidates: [], enabled: false, now: now, calendar: cal,
                preferenceRevision: 2, requestRevision: 2
            )
        }
        await disabledStarted.wait()
        await Task.yield()
        await scheduler.resumePausedSchedule()

        #expect(try await enabled.value == .schedule(kind: .rescue, dayKey: "2026-11-15"))
        #expect(try await disabled.value == .cancelPending)
        #expect(await scheduler.pendingCount() == 0)
        #expect(await storage.load().pendingKind == nil)
        #expect(try await coordinator.reconcile(
            candidates: [candidate], enabled: true, now: now, calendar: cal,
            preferenceRevision: 1, requestRevision: 3
        ) == .none)
        #expect(await scheduler.pendingCount() == 0)
    }

    @Test func concurrentPriorityTransactionsLeaveHighestPriorityInstalled() async throws {
        let now = date(2026, 11, 15, 18)
        let cal = calendar
        let delivery = date(2026, 11, 15, 20)
        let receipt = ReadingMotivationNotificationCandidate(kind: .receipt, deliveryDate: delivery)
        let rescue = ReadingMotivationNotificationCandidate(kind: .rescue, deliveryDate: delivery)
        let scheduler = TestMotivationScheduler()
        await scheduler.pauseNextScheduleCall()
        let (coordinator, _) = makeCoordinator(scheduler: scheduler, now: now)
        let lower = Task {
            try await coordinator.reconcile(
                candidates: [receipt], enabled: true, now: now, calendar: cal,
                preferenceRevision: 1, requestRevision: 1
            )
        }
        await scheduler.waitForPausedSchedule()
        let higherStarted = TestMotivationSignal()
        let higher = Task {
            await higherStarted.signal()
            return try await coordinator.reconcile(
                candidates: [receipt, rescue], enabled: true, now: now, calendar: cal,
                preferenceRevision: 1, requestRevision: 2
            )
        }
        await higherStarted.wait()
        await Task.yield()
        await scheduler.resumePausedSchedule()

        #expect(try await lower.value == .schedule(kind: .receipt, dayKey: "2026-11-15"))
        #expect(try await higher.value == .replacePending(kind: .rescue, dayKey: "2026-11-15"))
        #expect(await scheduler.pendingCount() == 1)
        #expect(await scheduler.pendingKind(for: "reading-motivation.2026-11-15") == .rescue)
        #expect(try await coordinator.reconcile(
            candidates: [receipt], enabled: true, now: now, calendar: calendar,
            preferenceRevision: 1, requestRevision: 1
        ) == .none)
        #expect(await scheduler.pendingKind(for: "reading-motivation.2026-11-15") == .rescue)
    }

    @Test func deliveryDuringSuspendedScheduleConsumesThatDayAndCancelsIt() async throws {
        let now = date(2026, 11, 15, 18)
        let cal = calendar
        let dayKey = "2026-11-15"
        let deliveredAt = date(2026, 11, 15, 20)
        let candidate = ReadingMotivationNotificationCandidate(
            kind: .pace, deliveryDate: date(2026, 11, 15, 20)
        )
        let scheduler = TestMotivationScheduler()
        await scheduler.pauseNextScheduleCall()
        let storage = TestMotivationStateStore()
        let (coordinator, _) = makeCoordinator(scheduler: scheduler, stateStore: storage, now: now)
        let scheduling = Task {
            try await coordinator.reconcile(
                candidates: [candidate], enabled: true, now: now, calendar: cal,
                preferenceRevision: 1, requestRevision: 1
            )
        }
        await scheduler.waitForPausedSchedule()
        let deliveryStarted = TestMotivationSignal()
        let delivered = Task {
            await deliveryStarted.signal()
            await coordinator.markDelivered(
                dayKey: dayKey, deliveredAt: deliveredAt, calendar: cal
            )
        }
        await deliveryStarted.wait()
        await Task.yield()
        await scheduler.resumePausedSchedule()

        _ = try await scheduling.value
        await delivered.value
        #expect(await storage.load().hasConsumedDayKey(dayKey))
        #expect(await storage.load().pendingKind == nil)
        #expect(await scheduler.pendingCount() == 0)
    }

    @Test func scheduleFailureClearsPendingStateAndAllowsRetry() async throws {
        let now = date(2026, 11, 15, 18)
        let candidate = ReadingMotivationNotificationCandidate(
            kind: .pace, deliveryDate: date(2026, 11, 15, 20)
        )
        let scheduler = TestMotivationScheduler()
        await scheduler.failNextScheduleCall()
        let storage = TestMotivationStateStore()
        let (coordinator, _) = makeCoordinator(scheduler: scheduler, stateStore: storage, now: now)
        do {
            _ = try await coordinator.reconcile(
                candidates: [candidate], enabled: true, now: now, calendar: calendar,
                preferenceRevision: 1, requestRevision: 1
            )
            Issue.record("Expected injected scheduler failure")
        } catch TestMotivationScheduleError.expectedFailure {
            #expect(await storage.load().pendingKind == nil)
        }
        #expect(try await coordinator.reconcile(
            candidates: [candidate], enabled: true, now: now, calendar: calendar,
            preferenceRevision: 1, requestRevision: 2
        ) == .schedule(kind: .pace, dayKey: "2026-11-15"))
        #expect(await scheduler.pendingCount() == 1)
    }

    @Test func deliveredYesterdayDoesNotConsumeTodayAndOldTapUsesDeliveryDate() async throws {
        let yesterday = "2026-11-14"
        let today = "2026-11-15"
        let scheduler = TestMotivationScheduler()
        await scheduler.setDelivered(
            identifier: ReadingMotivationNotificationCoordinator.identifier(for: yesterday),
            at: date(2026, 11, 14, 20)
        )
        let storage = TestMotivationStateStore(
            ReadingMotivationNotificationState(
                pendingKind: .receipt, pendingDayKey: yesterday,
                pendingDeliveryDate: date(2026, 11, 14, 20)
            )
        )
        let now = date(2026, 11, 15, 18)
        let (coordinator, _) = makeCoordinator(scheduler: scheduler, stateStore: storage, now: now)
        let candidate = ReadingMotivationNotificationCandidate(
            kind: .pace, deliveryDate: date(2026, 11, 15, 20)
        )
        #expect(try await coordinator.reconcile(
            candidates: [candidate], enabled: true, now: now, calendar: calendar,
            preferenceRevision: 1, requestRevision: 1
        ) == .schedule(kind: .pace, dayKey: today))
        let afterFirstLaunch = await storage.load()
        #expect(afterFirstLaunch.hasConsumedDayKey(yesterday))
        #expect(!afterFirstLaunch.hasConsumedDayKey(today))
        #expect(afterFirstLaunch.pendingDayKey == today)
        #expect(await scheduler.deliveredNotifications().isEmpty)

        await coordinator.markDelivered(
            dayKey: yesterday, deliveredAt: date(2026, 11, 14, 20), calendar: calendar
        )
        let afterOldTap = await storage.load()
        #expect(afterOldTap.hasConsumedDayKey(yesterday))
        #expect(!afterOldTap.hasConsumedDayKey(today))
        #expect(afterOldTap.pendingDayKey == today)
        #expect(await scheduler.pendingCount() == 1)
    }

    @Test func consumedDayHistorySurvivesJumpForwardAndBack() async throws {
        let scheduler = TestMotivationScheduler()
        let storage = TestMotivationStateStore()
        let (coordinator, _) = makeCoordinator(
            scheduler: scheduler, stateStore: storage, now: date(2026, 11, 15, 18)
        )
        let today = ReadingMotivationNotificationCandidate(
            kind: .rescue, deliveryDate: date(2026, 11, 15, 20)
        )
        #expect(try await coordinator.reconcile(
            candidates: [today], enabled: true, now: date(2026, 11, 15, 18), calendar: calendar,
            preferenceRevision: 1, requestRevision: 1
        ) == .schedule(kind: .rescue, dayKey: "2026-11-15"))
        await coordinator.markDelivered(
            dayKey: "2026-11-15", deliveredAt: date(2026, 11, 15, 20), calendar: calendar
        )
        let tomorrow = ReadingMotivationNotificationCandidate(
            kind: .receipt, deliveryDate: date(2026, 11, 16, 20)
        )
        #expect(try await coordinator.reconcile(
            candidates: [tomorrow], enabled: true, now: date(2026, 11, 16, 18), calendar: calendar,
            preferenceRevision: 1, requestRevision: 2
        ) == .schedule(kind: .receipt, dayKey: "2026-11-16"))
        #expect(try await coordinator.reconcile(
            candidates: [today], enabled: true, now: date(2026, 11, 15, 18), calendar: calendar,
            preferenceRevision: 1, requestRevision: 3
        ) == .cancelPending)
        #expect(await storage.load().hasConsumedDayKey("2026-11-15"))
        #expect(await storage.load().pendingDayKey == nil)
        #expect(await scheduler.pendingCount() == 0)
    }

    @Test func sameKindPendingQuietTimeChangeReschedulesWithoutDowngrade() {
        let now = date(2026, 11, 15, 18)
        let oldState = ReadingMotivationNotificationState(
            pendingKind: .rescue,
            pendingDayKey: "2026-11-15",
            pendingDeliveryDate: date(2026, 11, 15, 20)
        )
        let changedCandidates = [
            ReadingMotivationNotificationCandidate(kind: .rescue, deliveryDate: date(2026, 11, 15, 21)),
            ReadingMotivationNotificationCandidate(kind: .pace, deliveryDate: date(2026, 11, 15, 21)),
        ]
        #expect(ReadingMotivationNotificationPolicy.decide(
            candidates: changedCandidates, state: oldState, enabled: true, authorized: true,
            now: now, calendar: calendar
        ) == .replacePending(kind: .rescue, dayKey: "2026-11-15"))
    }

    @Test func quietTimeChangeReschedulesSameKindAndKeepsHigherPriority() async throws {
        let now = date(2026, 11, 15, 18)
        let scheduler = TestMotivationScheduler()
        let (coordinator, _) = makeCoordinator(scheduler: scheduler, now: now)
        let firstQuiet = date(2026, 11, 15, 20)
        let laterQuiet = date(2026, 11, 15, 21)
        let rescue = ReadingMotivationNotificationCandidate(kind: .rescue, deliveryDate: firstQuiet)
        #expect(try await coordinator.reconcile(
            candidates: [rescue], enabled: true, now: now, calendar: calendar,
            preferenceRevision: 1, requestRevision: 1
        ) == .schedule(kind: .rescue, dayKey: "2026-11-15"))
        let updated = [
            ReadingMotivationNotificationCandidate(kind: .pace, deliveryDate: laterQuiet),
            ReadingMotivationNotificationCandidate(kind: .rescue, deliveryDate: laterQuiet),
        ]
        #expect(try await coordinator.reconcile(
            candidates: updated, enabled: true, now: now, calendar: calendar,
            preferenceRevision: 2, requestRevision: 2
        ) == .replacePending(kind: .rescue, dayKey: "2026-11-15"))
        #expect(await scheduler.pendingCount() == 1)
        #expect(await scheduler.pendingKind(for: "reading-motivation.2026-11-15") == .rescue)
        #expect(await scheduler.pendingDate(for: "reading-motivation.2026-11-15") == laterQuiet)
    }

    @Test func lateDeliveryDuringReplacementCancelConsumesDayWithoutReinstall() async throws {
        let start = date(2026, 11, 15, 18)
        let delivery = date(2026, 11, 15, 20)
        let dayKey = "2026-11-15"
        let clock = TestMotivationClock(start)
        let scheduler = TestMotivationScheduler()
        let storage = TestMotivationStateStore()
        let (coordinator, _) = makeCoordinator(
            scheduler: scheduler, stateStore: storage, now: start, clock: clock
        )
        let receipt = ReadingMotivationNotificationCandidate(kind: .receipt, deliveryDate: delivery)
        let rescue = ReadingMotivationNotificationCandidate(kind: .rescue, deliveryDate: delivery)
        #expect(try await coordinator.reconcile(
            candidates: [receipt], enabled: true, now: start, calendar: calendar,
            preferenceRevision: 1, requestRevision: 1
        ) == .schedule(kind: .receipt, dayKey: dayKey))
        #expect(await scheduler.pendingCount() == 1)

        await scheduler.pauseNextCancelCall()
        let replacing = Task {
            try await coordinator.reconcile(
                candidates: [receipt, rescue], enabled: true, now: start, calendar: calendar,
                preferenceRevision: 1, requestRevision: 2
            )
        }
        await scheduler.waitForPausedCancel()
        // OS delivers the OLD request while replacement is awaiting cancel.
        clock.advance(to: delivery.addingTimeInterval(30))
        await scheduler.setDelivered(
            identifier: ReadingMotivationNotificationCoordinator.identifier(for: dayKey),
            at: delivery
        )
        await scheduler.resumePausedCancel()

        let decision = try await replacing.value
        #expect(decision == .cancelPending || decision == .none)
        #expect(await storage.load().hasConsumedDayKey(dayKey))
        #expect(await storage.load().pendingKind == nil)
        #expect(await scheduler.pendingCount() == 0)

        // Max one motivational notification per day: no replacement after late delivery.
        #expect(try await coordinator.reconcile(
            candidates: [rescue], enabled: true, now: clock.now(), calendar: calendar,
            preferenceRevision: 1, requestRevision: 3
        ) == .none)
        #expect(await scheduler.pendingCount() == 0)
    }

    @Test func deliveryDismissedDuringCancellationStillConsumesDayAfterRestart() async throws {
        let start = date(2026, 11, 15, 18)
        let delivery = date(2026, 11, 15, 20)
        let dayKey = "2026-11-15"
        let clock = TestMotivationClock(start)
        let scheduler = TestMotivationScheduler()
        let storage = TestMotivationStateStore()
        let (coordinator, _) = makeCoordinator(
            scheduler: scheduler, stateStore: storage, now: start, clock: clock
        )
        #expect(try await coordinator.reconcile(
            candidates: [.init(kind: .rescue, deliveryDate: delivery)],
            enabled: true, now: start, calendar: calendar, requestRevision: 1
        ) == .schedule(kind: .rescue, dayKey: dayKey))
        await scheduler.pauseNextCancelCall()
        let cancelling = Task {
            try await coordinator.reconcile(
                candidates: [], enabled: true, now: start,
                calendar: calendar, requestRevision: 2
            )
        }
        await scheduler.waitForPausedCancel()
        clock.advance(to: delivery.addingTimeInterval(30))
        await scheduler.setDelivered(
            identifier: ReadingMotivationNotificationCoordinator.identifier(for: dayKey), at: delivery
        )
        // The user dismisses OS evidence while cancellation is still suspended.
        await scheduler.clearDelivered()
        await scheduler.resumePausedCancel()
        #expect(try await cancelling.value == .cancelPending)
        #expect(await storage.load().hasConsumedDayKey(dayKey))
        let (restarted, _) = makeCoordinator(
            scheduler: scheduler, stateStore: storage, now: clock.now(), clock: clock
        )
        #expect(try await restarted.reconcile(
            candidates: [.init(kind: .rescue, deliveryDate: date(2026, 11, 15, 21))],
            enabled: true, now: clock.now(), calendar: calendar, requestRevision: 3
        ) == .none)
        #expect(await scheduler.pendingCount() == 0)
    }

    @Test func ingestDeliveredPersistsConsumedDaysBeforeRemoveAndSurvivesCrashAtRemoval() async throws {
        let requestDay = "2026-11-15"
        let actualDay = "2026-11-16"
        let now = date(2026, 11, 16, 8)
        let deliveredAt = date(2026, 11, 16, 0)
        let scheduler = TestMotivationScheduler()
        let storage = TestMotivationStateStore(
            ReadingMotivationNotificationState(
                pendingKind: .rescue,
                pendingDayKey: requestDay,
                pendingDeliveryDate: date(2026, 11, 15, 20)
            )
        )
        await scheduler.setDelivered(
            identifier: ReadingMotivationNotificationCoordinator.identifier(for: requestDay),
            at: deliveredAt
        )
        let (coordinator, _) = makeCoordinator(scheduler: scheduler, stateStore: storage, now: now)
        await scheduler.pauseNextRemoveCall()

        let ingesting = Task {
            try await coordinator.reconcile(
                candidates: [], enabled: true, now: now, calendar: calendar,
                preferenceRevision: 1, requestRevision: 1
            )
        }
        await scheduler.waitForPausedRemove()
        // Durable ledger must already contain requested + actual days before OS evidence drops.
        let midCrash = await storage.load()
        #expect(midCrash.hasConsumedDayKey(requestDay))
        #expect(midCrash.hasConsumedDayKey(actualDay))
        #expect(midCrash.pendingDayKey == nil)

        // Crash at removal: abandon in-flight reconcile, clear OS evidence, restart.
        ingesting.cancel()
        await scheduler.clearDelivered()
        await scheduler.resumePausedRemove()
        _ = try? await ingesting.value

        let (restarted, _) = makeCoordinator(scheduler: scheduler, stateStore: storage, now: now)
        let nextQuiet = ReadingMotivationNotificationPolicy.quietDeliveryDate(
            on: now, hour: 20, minute: 30, calendar: calendar
        )!
        let nextCandidates = ReadingMotivationNotificationPolicy.candidates(
            now: now,
            quietDeliveryDate: nextQuiet,
            readingSeconds: 0,
            readingGoalSeconds: 3600,
            listeningSeconds: 0,
            listeningGoalSeconds: 0,
            activityDaysThisWeek: 0,
            calendar: calendar
        )
        #expect(try await restarted.reconcile(
            candidates: nextCandidates, enabled: true, now: now, calendar: calendar,
            preferenceRevision: 1, requestRevision: 1
        ) == .none)
        #expect(await storage.load().hasConsumedDayKey(requestDay))
        #expect(await storage.load().hasConsumedDayKey(actualDay))
        #expect(await scheduler.pendingCount() == 0)
    }

    @Test func liveInProgressElapsedMeetingGoalCancelsPendingBeforeQuietTime() async throws {
        let morning = date(2026, 11, 15, 8)
        let quiet = ReadingMotivationNotificationPolicy.quietDeliveryDate(
            on: morning, hour: 20, minute: 30, calendar: calendar
        )!
        let scheduler = TestMotivationScheduler()
        let storage = TestMotivationStateStore()
        let (coordinator, clock) = makeCoordinator(
            scheduler: scheduler, stateStore: storage, now: morning
        )
        let morningCandidates = ReadingMotivationNotificationPolicy.candidates(
            now: morning,
            quietDeliveryDate: quiet,
            readingSeconds: 0,
            readingGoalSeconds: 1800,
            listeningSeconds: 0,
            listeningGoalSeconds: 0,
            activityDaysThisWeek: 0,
            calendar: calendar
        )
        #expect(try await coordinator.reconcile(
            candidates: morningCandidates, enabled: true, now: morning, calendar: calendar,
            preferenceRevision: 1, requestRevision: 1
        ) == .schedule(kind: .rescue, dayKey: "2026-11-15"))
        #expect(await scheduler.pendingCount() == 1)

        // Active-session tick: live in-progress elapsed (SessionTracker.motivationSessionRecords)
        // meets the reading goal before quiet time.
        let now = date(2026, 11, 15, 12)
        clock.advance(to: now)
        let liveRecords = [
            session(start: date(2026, 11, 15, 10), end: now, kind: .reading)
        ]
        let todayStart = calendar.startOfDay(for: now)
        let todayProgress = ReadingMotivationCalculations.dailyTotals(
            sessions: liveRecords, calendar: calendar, now: now
        ).first(where: { $0.day == todayStart })
        #expect((todayProgress?.readingSeconds ?? 0) >= 1800)
        let afterLive = ReadingMotivationNotificationPolicy.candidates(
            now: now,
            quietDeliveryDate: quiet,
            readingSeconds: todayProgress?.readingSeconds ?? 0,
            readingGoalSeconds: 1800,
            listeningSeconds: todayProgress?.listeningSeconds ?? 0,
            listeningGoalSeconds: 0,
            activityDaysThisWeek: 0,
            calendar: calendar
        )
        #expect(afterLive.isEmpty)
        #expect(try await coordinator.reconcile(
            candidates: afterLive, enabled: true, now: now, calendar: calendar,
            preferenceRevision: 1, requestRevision: 2
        ) == .cancelPending)
        #expect(await scheduler.pendingCount() == 0)

        // Repeated tick / end must not reinstall or duplicate.
        #expect(try await coordinator.reconcile(
            candidates: afterLive, enabled: true, now: now, calendar: calendar,
            preferenceRevision: 1, requestRevision: 3
        ) == .none)
        #expect(try await coordinator.reconcile(
            candidates: afterLive, enabled: true, now: now, calendar: calendar,
            preferenceRevision: 1, requestRevision: 4
        ) == .none)
        #expect(await scheduler.pendingCount() == 0)
    }

    @Test func activeSessionReconcileCadenceGuardsOptInAndRequiresLiveSession() {
        #expect(
            ReadingMotivationActiveSessionReconcilePolicy.shouldRunCadence(hasActiveSession: true)
        )
        #expect(
            !ReadingMotivationActiveSessionReconcilePolicy.shouldRunCadence(hasActiveSession: false)
        )
        #expect(
            ReadingMotivationActiveSessionReconcilePolicy.shouldReconcileNotificationsOnTick(
                notificationsEnabled: true
            )
        )
        #expect(
            !ReadingMotivationActiveSessionReconcilePolicy.shouldReconcileNotificationsOnTick(
                notificationsEnabled: false
            )
        )
        // Notification reconcile still requires both opt-in and live session.
        #expect(
            ReadingMotivationActiveSessionReconcilePolicy.shouldReconcileOnTick(
                notificationsEnabled: true, hasActiveSession: true
            )
        )
        #expect(
            !ReadingMotivationActiveSessionReconcilePolicy.shouldReconcileOnTick(
                notificationsEnabled: false, hasActiveSession: true
            )
        )
        #expect(
            !ReadingMotivationActiveSessionReconcilePolicy.shouldReconcileOnTick(
                notificationsEnabled: true, hasActiveSession: false
            )
        )
        #expect(ReadingMotivationActiveSessionReconcilePolicy.tickIntervalSeconds == 30)

        #expect(
            ReadingMotivationActiveSessionReconcilePolicy.shouldPublishAuthoritativeStreak(
                sessionElapsed: 30, streakDays: 1, activityDayKey: "2026-11-15",
                lastPublishedStreakDays: nil, lastPublishedActivityDayKey: nil
            )
        )
        #expect(
            !ReadingMotivationActiveSessionReconcilePolicy.shouldPublishAuthoritativeStreak(
                sessionElapsed: 29.9, streakDays: 1, activityDayKey: "2026-11-15",
                lastPublishedStreakDays: nil, lastPublishedActivityDayKey: nil
            )
        )
        #expect(
            !ReadingMotivationActiveSessionReconcilePolicy.shouldPublishAuthoritativeStreak(
                sessionElapsed: 60, streakDays: 2, activityDayKey: "2026-11-15",
                lastPublishedStreakDays: 2, lastPublishedActivityDayKey: "2026-11-15"
            )
        )
        #expect(
            ReadingMotivationActiveSessionReconcilePolicy.shouldPublishAuthoritativeStreak(
                sessionElapsed: 60, streakDays: 2, activityDayKey: "2026-11-16",
                lastPublishedStreakDays: 2, lastPublishedActivityDayKey: "2026-11-15"
            )
        )
        #expect(
            ReadingMotivationActiveSessionReconcilePolicy.shouldPublishAuthoritativeStreak(
                sessionElapsed: 60, streakDays: 3, activityDayKey: "2026-11-15",
                lastPublishedStreakDays: 2, lastPublishedActivityDayKey: "2026-11-15"
            )
        )
    }

    @Test func restartWithPhantomPendingInstallsMissingOSRequestOnce() async throws {
        let now = date(2026, 11, 15, 18)
        let delivery = date(2026, 11, 15, 20)
        let dayKey = "2026-11-15"
        let candidate = ReadingMotivationNotificationCandidate(kind: .rescue, deliveryDate: delivery)
        let scheduler = TestMotivationScheduler()
        // Crash: ledger saved pending before schedule installed the OS request.
        let storage = TestMotivationStateStore(
            ReadingMotivationNotificationState(
                pendingKind: .rescue,
                pendingDayKey: dayKey,
                pendingDeliveryDate: delivery
            )
        )
        let (restarted, _) = makeCoordinator(scheduler: scheduler, stateStore: storage, now: now)
        #expect(try await restarted.reconcile(
            candidates: [candidate], enabled: true, now: now, calendar: calendar
        ) == .schedule(kind: .rescue, dayKey: dayKey))
        #expect(await scheduler.pendingCount() == 1)
        #expect(await scheduler.scheduleCalls() == 1)
        #expect(await scheduler.pendingKind(for: ReadingMotivationNotificationCoordinator.identifier(for: dayKey)) == .rescue)

        // Identical pending already in OS remains idempotent.
        #expect(try await restarted.reconcile(
            candidates: [candidate], enabled: true, now: now, calendar: calendar
        ) == .none)
        #expect(await scheduler.scheduleCalls() == 1)
        #expect(await scheduler.pendingCount() == 1)
    }

    @Test func expiredOrDeliveredPhantomPendingNeverReinstalls() async throws {
        let now = date(2026, 11, 15, 21)
        let dayKey = "2026-11-15"
        let scheduler = TestMotivationScheduler()
        let storage = TestMotivationStateStore(
            ReadingMotivationNotificationState(
                pendingKind: .pace,
                pendingDayKey: dayKey,
                pendingDeliveryDate: date(2026, 11, 15, 20)
            )
        )
        let (coordinator, _) = makeCoordinator(scheduler: scheduler, stateStore: storage, now: now)
        #expect(try await coordinator.reconcile(
            candidates: [.init(kind: .pace, deliveryDate: date(2026, 11, 15, 20))],
            enabled: true, now: now, calendar: calendar
        ) == .none)
        #expect(await scheduler.scheduleCalls() == 0)
        #expect(await scheduler.pendingCount() == 0)
        #expect(await storage.load().hasConsumedDayKey(dayKey))

        let deliveredStorage = TestMotivationStateStore(
            ReadingMotivationNotificationState(
                pendingKind: .rescue,
                pendingDayKey: "2026-11-16",
                pendingDeliveryDate: date(2026, 11, 16, 20)
            )
        )
        await scheduler.setDelivered(
            identifier: ReadingMotivationNotificationCoordinator.identifier(for: "2026-11-16"),
            at: date(2026, 11, 16, 20)
        )
        let deliveryNow = date(2026, 11, 16, 18)
        let (deliveredCoordinator, clock) = makeCoordinator(
            scheduler: scheduler, stateStore: deliveredStorage, now: deliveryNow
        )
        clock.advance(to: deliveryNow)
        #expect(try await deliveredCoordinator.reconcile(
            candidates: [.init(kind: .rescue, deliveryDate: date(2026, 11, 16, 20))],
            enabled: true, now: deliveryNow, calendar: calendar
        ) == .none)
        #expect(await scheduler.scheduleCalls() == 0)
        #expect(await deliveredStorage.load().hasConsumedDayKey("2026-11-16"))
    }

    @Test func pendingInspectionSuspensionConsumesDeliveryBeforeReinstall() async throws {
        let now = date(2026, 11, 15, 18)
        let delivery = date(2026, 11, 15, 20)
        let dayKey = "2026-11-15"
        let identifier = ReadingMotivationNotificationCoordinator.identifier(for: dayKey)
        let candidate = ReadingMotivationNotificationCandidate(kind: .rescue, deliveryDate: delivery)
        let scheduler = TestMotivationScheduler()
        let storage = TestMotivationStateStore(
            ReadingMotivationNotificationState(
                pendingKind: .rescue,
                pendingDayKey: dayKey,
                pendingDeliveryDate: delivery
            )
        )
        let (coordinator, clock) = makeCoordinator(
            scheduler: scheduler, stateStore: storage, now: now
        )
        await scheduler.pauseNextPendingIdentifiersCall()
        let recovering = Task {
            try await coordinator.reconcile(
                candidates: [candidate], enabled: true, now: now, calendar: calendar
            )
        }
        await scheduler.waitForPausedPendingIdentifiers()
        // Delivery lands while pending inspection is suspended.
        await scheduler.setDelivered(identifier: identifier, at: delivery)
        clock.advance(to: delivery)
        await scheduler.resumePausedPendingIdentifiers()
        #expect(try await recovering.value == .none)
        #expect(await scheduler.scheduleCalls() == 0)
        #expect(await storage.load().hasConsumedDayKey(dayKey))
        #expect(await storage.load().pendingKind == nil)
    }
}
