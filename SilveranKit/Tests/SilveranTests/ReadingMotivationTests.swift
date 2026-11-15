import Foundation
import SilveranAppleWidgets
import SilveranKit
import Testing

private actor TestMotivationScheduler: ReadingMotivationNotificationScheduling {
    var status: ReadingMotivationNotificationAuthorization = .authorized
    var requests: [String: ReadingMotivationNotificationRequest] = [:]
    var delivered: Set<String> = []
    var authorizationRequests = 0

    func authorization() async -> ReadingMotivationNotificationAuthorization { status }
    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        return status == .authorized
    }
    func schedule(_ request: ReadingMotivationNotificationRequest) async throws {
        requests[request.identifier] = request
    }
    func cancelPending(identifier: String) async { requests.removeValue(forKey: identifier) }
    func deliveredIdentifiers() async -> Set<String> { delivered }
    func removeDelivered(identifiers: Set<String>) async { delivered.subtract(identifiers) }
    func pendingCount() -> Int { requests.count }
    func setAuthorization(_ value: ReadingMotivationNotificationAuthorization) { status = value }
    func authorizationRequestCount() -> Int { authorizationRequests }
}

private actor TestMotivationStateStore: ReadingMotivationNotificationStateStoring {
    var state: ReadingMotivationNotificationState
    init(_ state: ReadingMotivationNotificationState = .empty) { self.state = state }
    func load() async -> ReadingMotivationNotificationState { state }
    func save(_ state: ReadingMotivationNotificationState) async { self.state = state }
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
        #expect(state.pendingKind == .pace)
        #expect(state.pendingDeliveryDate == nil)
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
        let today = date(2026, 11, 15)
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
        let now = date(2026, 11, 15)
        let recent = [
            session(start: date(2026, 11, 13), end: date(2026, 11, 13, 13)),
            session(start: date(2026, 11, 14), end: date(2026, 11, 14, 13)),
        ]
        let streak = ReadingMotivationCalculations.streaks(
            sessions: recent,
            calendar: calendar,
            now: now,
            archivedActivityDays: [date(2026, 11, 12)]
        )
        #expect(streak.current == 2)
        #expect(streak.longest == 3)
    }

    @Test func weeklyReceiptUsesLocalMondayWeekAndDedupesTitles() {
        let now = date(2026, 11, 15)
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
        let now = date(2026, 11, 15)
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
            sessions: [], mediaID: "book-1", progress: 0.5, totalUnits: 7200,
            playbackRate: 1.5, calendar: calendar, now: dstStart
        )
        guard case .estimate(let dstFinish, _) = dstEstimate else {
            Issue.record("Expected a playback estimate across the DST boundary")
            return
        }
        #expect(calendar.component(.hour, from: dstFinish) == 3)
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
        let pending = ReadingMotivationNotificationState(pendingKind: .pace, pendingDayKey: "2026-11-15")
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
            dayKey: "2026-11-16", at: date(2026, 11, 15, 23), calendar: calendar
        )
        #expect(await storage.load().consumedDayKey == "2026-11-15")
        #expect(await storage.load().pendingDayKey == nil)
    }
}
