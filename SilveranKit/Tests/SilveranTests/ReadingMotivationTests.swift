import Foundation
import SilveranAppleWidgets
import SilveranKit
import Testing

private actor TestMotivationScheduler: ReadingMotivationNotificationScheduling {
    var status: ReadingMotivationNotificationAuthorization = .authorized
    var requests: [String: ReadingMotivationNotificationRequest] = [:]
    var delivered: [String: Date] = [:]
    var authorizationRequests = 0
    var pauseNextSchedule = false
    var pausedScheduleEntered = false
    var scheduleStartWaiter: CheckedContinuation<Void, Never>?
    var scheduleRelease: CheckedContinuation<Void, Never>?
    var failNextSchedule = false

    func authorization() async -> ReadingMotivationNotificationAuthorization { status }
    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        return status == .authorized
    }
    func schedule(_ request: ReadingMotivationNotificationRequest) async throws {
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
    func cancelPending(identifier: String) async { requests.removeValue(forKey: identifier) }
    func deliveredNotifications() async -> [String: Date] { delivered }
    func removeDelivered(identifiers: Set<String>) async {
        for identifier in identifiers { delivered.removeValue(forKey: identifier) }
    }
    func pendingCount() -> Int { requests.count }
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
        #expect(streak.current == 2)
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

    @Test func oldWidgetSnapshotDecodesWithoutNewMotivationFields() throws {
        let oldJSON = Data(#"{"generatedAt":"2026-11-15T17:00:00Z","title":"Book","progress":0.5}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(ContinueWidgetSnapshot.self, from: oldJSON)
        #expect(snapshot.title == "Book")
        #expect(snapshot.elapsedText == nil)
        #expect(snapshot.remainingText == nil)
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
            actualSeconds: 0,
            dailyGoalSeconds: 3600,
            activityDaysThisWeek: 2,
            calendar: calendar
        )
        #expect(Set(candidates.map(\.kind)) == Set([.rescue, .pace, .receipt]))
        #expect(ReadingMotivationNotificationPolicy.decide(
            candidates: candidates, state: .empty, enabled: true, authorized: true,
            now: now, calendar: calendar
        ) == .schedule(kind: .rescue, dayKey: "2026-11-15"))

        let metGoal = ReadingMotivationNotificationPolicy.candidates(
            now: now, quietDeliveryDate: quiet, actualSeconds: 3600,
            dailyGoalSeconds: 3600, activityDaysThisWeek: 2, calendar: calendar
        )
        #expect(metGoal.map(\.kind) == [.receipt])
        #expect(ReadingMotivationNotificationPolicy.candidates(
            now: now, quietDeliveryDate: date(2026, 11, 15, 17), actualSeconds: 0,
            dailyGoalSeconds: 3600, activityDaysThisWeek: 2, calendar: calendar
        ).isEmpty)
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
        let first = ReadingMotivationNotificationCoordinator(scheduler: scheduler, stateStore: storage)
        #expect(try await first.reconcile(
            candidates: [candidate], enabled: true, now: now, calendar: calendar
        ) == .schedule(kind: .rescue, dayKey: dayKey))
        #expect(try await first.reconcile(
            candidates: [candidate], enabled: true, now: now, calendar: calendar
        ) == .none)
        #expect(await scheduler.pendingCount() == 1)

        let afterRestart = ReadingMotivationNotificationCoordinator(scheduler: scheduler, stateStore: storage)
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
        let coordinator = ReadingMotivationNotificationCoordinator(
            scheduler: scheduler, stateStore: TestMotivationStateStore()
        )
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
        let coordinator = ReadingMotivationNotificationCoordinator(
            scheduler: scheduler, stateStore: TestMotivationStateStore()
        )
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
        let coordinator = ReadingMotivationNotificationCoordinator(
            scheduler: scheduler, stateStore: storage
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
        let coordinator = ReadingMotivationNotificationCoordinator(scheduler: scheduler, stateStore: storage)

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
        let coordinator = ReadingMotivationNotificationCoordinator(scheduler: scheduler, stateStore: storage)

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
        let coordinator = ReadingMotivationNotificationCoordinator(
            scheduler: scheduler, stateStore: TestMotivationStateStore()
        )
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
        let coordinator = ReadingMotivationNotificationCoordinator(scheduler: scheduler, stateStore: storage)
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
        let coordinator = ReadingMotivationNotificationCoordinator(scheduler: scheduler, stateStore: storage)
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
        let coordinator = ReadingMotivationNotificationCoordinator(scheduler: scheduler, stateStore: storage)
        let candidate = ReadingMotivationNotificationCandidate(
            kind: .pace, deliveryDate: date(2026, 11, 15, 20)
        )
        #expect(try await coordinator.reconcile(
            candidates: [candidate], enabled: true, now: date(2026, 11, 15, 18), calendar: calendar,
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
        let coordinator = ReadingMotivationNotificationCoordinator(scheduler: scheduler, stateStore: storage)
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
        let coordinator = ReadingMotivationNotificationCoordinator(
            scheduler: scheduler, stateStore: TestMotivationStateStore()
        )
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
}
