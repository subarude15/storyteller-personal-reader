//
//  SessionTracker.swift
//  ink+amp
//
//  Ported from Enve Book Player (AGPL-3.0-only):
//  https://github.com/opisaac9001/Enve-Book-Player
//  Original: ios/enve/Services/ListeningStats/ListeningStatsTracker.swift
//  Modifications: local-only; no Audiobookshelf progress sync; wired to
//  Silveran player/reader via PunkRallyStatsEvents + SessionTrackerWiring.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Observation
import SilveranAppleWidgets
import SilveranKit

/// Tracks reading/listening sessions locally and computes home/Stats aggregates.
/// Local recording always works offline; `StatsSyncCoordinator` merges a shared
/// Storyteller blob (same account as place sync) so phone ↔ iPad share totals.
@MainActor
@Observable
final class SessionTracker {
    static let shared = SessionTracker()

    private let sessionsKey = "punkRally.stats.sessions.v1"
    private let finishedKey = "punkRally.stats.finished.v1"
    private let streakDaysKey = "punkRally.stats.streakDays.v2"
    private let legacyStreakDaysKey = "punkRally.stats.streakDays.v1"

    private var sessions: [PRMediaSession] = []
    private var finished: [PRFinishedBook] = []
    private var archivedActivityDays: Set<ReadingMotivationActivityDay> = []

    /// Bumped whenever aggregates change so SwiftUI refreshes.
    private(set) var revision: Int = 0

    /// Active (unclosed) session, if any.
    private var activeSession: PRMediaSession?

    private var saveTask: Task<Void, Never>?
    /// Session-owned motivation cadence (streak publish + optional reminders).
    /// Not Home-owned. Cancelled on end, including under-30s short sessions.
    private var motivationReconcileTask: Task<Void, Never>?
    /// Last streak values pushed to the Continue widget from this process.
    private var lastPublishedWidgetStreakDays: Int?
    private var lastPublishedWidgetStreakDayKey: String?

    private init() {
        load()
    }

    // MARK: - Public API

    var allSessions: [PRMediaSession] {
        sessions
    }

    var allFinished: [PRFinishedBook] {
        finished
    }

    /// Shared calculation input, including the active session's real elapsed time.
    func motivationSessionRecords(at now: Date = Date()) -> [InkampStatsSessionRecord] {
        var records = sessions.map(Self.toSyncSession)
        if let activeSession, ReadingMotivationCalculations.isRecordableSession(
            duration: now.timeIntervalSince(activeSession.startedAt)
        ) {
            records.append(
                InkampStatsSessionRecord(
                    id: activeSession.id,
                    kind: activeSession.kind == .reading ? .reading : .listening,
                    mediaID: activeSession.mediaID,
                    mediaTitle: activeSession.mediaTitle,
                    startedAt: activeSession.startedAt,
                    endedAt: now,
                    durationSeconds: now.timeIntervalSince(activeSession.startedAt),
                    endProgress: activeSession.endProgress
                )
            )
        }
        return records
    }

    func motivationArchivedActivityDays() -> [ReadingMotivationActivityDay] {
        archivedActivityDays.sorted { $0.id < $1.id }
    }

    /// Begin a session for a media item.
    func startSession(kind: PRMediaSession.Kind, mediaID: String, mediaTitle: String) {
        if let active = activeSession, active.mediaID == mediaID, active.kind == kind {
            return
        }
        closeActiveIfNeeded()
        activeSession = PRMediaSession(
            kind: kind,
            mediaID: mediaID,
            mediaTitle: mediaTitle,
            startedAt: Date()
        )
        revision &+= 1
        startMotivationCadenceLoopIfNeeded()
    }

    /// End the active session and record its duration.
    /// When `mediaID` is set, only ends if it matches the active session (avoids
    /// races when a book card dismiss overlaps a newly started podcast).
    func endSession(mediaID: String? = nil, progress: Double? = nil) {
        guard let active = activeSession else { return }
        if let mediaID, active.mediaID != mediaID { return }
        let ended = Date()
        let duration = ended.timeIntervalSince(active.startedAt)

        // Only record sessions of meaningful length (≥ 30 seconds).
        guard ReadingMotivationCalculations.isRecordableSession(duration: duration) else {
            activeSession = nil
            revision &+= 1
            stopMotivationCadenceLoopAndRefresh(publishStreak: false)
            return
        }

        var session = active
        session.endedAt = ended
        session.durationSeconds = duration
        session.endProgress = progress
        sessions.append(session)
        activeSession = nil

        if let progress, progress >= 0.95 {
            recordFinished(mediaID: session.mediaID, mediaTitle: session.mediaTitle)
        }
        revision &+= 1
        scheduleSave()
        StatsSyncCoordinator.shared.scheduleSyncAfterLocalChange()
        stopMotivationCadenceLoopAndRefresh(publishStreak: true)
    }

    /// Restart periodic motivation cadence when an active session survives
    /// foreground restore or notification opt-in mid-session.
    func syncMotivationReconcileLoop() {
        if activeSession != nil {
            startMotivationCadenceLoopIfNeeded()
            // Foreground restore: publish immediately if already retained.
            publishAuthoritativeStreakIfNeeded()
        } else {
            motivationReconcileTask?.cancel()
            motivationReconcileTask = nil
        }
    }

    /// Title for an in-flight or recent session (podcast finish labeling).
    func activeMediaTitle(for mediaID: String) -> String? {
        if let active = activeSession, active.mediaID == mediaID {
            return active.mediaTitle
        }
        return sessions.last(where: { $0.mediaID == mediaID })?.mediaTitle
    }

    /// Note that a book finished (progress hit 100%).
    func recordFinished(mediaID: String, mediaTitle: String) {
        guard !finished.contains(where: { $0.mediaID == mediaID }) else { return }
        finished.append(PRFinishedBook(mediaID: mediaID, mediaTitle: mediaTitle, finishedAt: Date()))
        revision &+= 1
        scheduleSave()
        StatsSyncCoordinator.shared.scheduleSyncAfterLocalChange()
        Task { await ReadingMotivationStore.shared.refreshNotifications() }
    }

    /// Export local ledger for Storyteller Stats blob.
    func exportSyncDocument() -> InkampStatsSyncDocument {
        InkampStatsSyncDocument(
            updatedAt: Date(),
            sessions: sessions.map(Self.toSyncSession),
            finished: finished.map(Self.toSyncFinished)
        )
    }

    /// Apply merged remote∪local document. Caller already ran StatsSyncMerge.
    func applyMergedSyncDocument(_ document: InkampStatsSyncDocument) {
        sessions = document.sessions.map(Self.fromSyncSession)
        finished = document.finished.map(Self.fromSyncFinished)
        revision &+= 1
        persist()
        Task { await ReadingMotivationStore.shared.refreshNotifications() }
    }

    /// Prune sessions older than 1 year to keep storage small.
    func pruneOldSessions() {
        let now = Date()
        let calendar = ReadingMotivationCalculations.normalizedLocalCalendar(from: .current)
        let cutoff = calendar.date(byAdding: .year, value: -1, to: now) ?? now
        archivedActivityDays = ReadingMotivationCalculations.archiveExpiredActivityDays(
            sessions: sessions.map(Self.toSyncSession),
            before: cutoff,
            existing: archivedActivityDays,
            calendar: calendar,
            now: now
        )
        sessions.removeAll { $0.endedAt < cutoff }
        persist()
    }

    /// Compute the full stats snapshot (includes live active session time).
    var snapshot: PRStatsSnapshot {
        let calendar = ReadingMotivationCalculations.normalizedLocalCalendar(from: .current)
        let now = Date()
        let records = motivationSessionRecords(at: now)
        let days = ReadingMotivationCalculations.dailyTotals(
            sessions: records, calendar: calendar, now: now
        )
        let today = calendar.startOfDay(for: now)
        let todaySeconds = days.first(where: { $0.day == today })?.seconds ?? 0
        let weekSeconds = ReadingMotivationCalculations.weeklyReceipt(
            sessions: records,
            finished: finished.map(Self.toSyncFinished),
            weekOffset: 0,
            calendar: calendar,
            now: now
        ).seconds
        let streakDays = ReadingMotivationCalculations.streaks(
            sessions: records,
            calendar: calendar,
            now: now,
            archivedActivityDays: motivationArchivedActivityDays()
        ).current

        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        let finished30d = finished.filter { $0.finishedAt >= thirtyDaysAgo }.count

        let allDurations = records.compactMap { session -> TimeInterval? in
            let span = session.endedAt.timeIntervalSince(session.startedAt)
            guard session.durationSeconds.isFinite, session.durationSeconds > 0, span > 0 else { return nil }
            return min(session.durationSeconds, span)
        }
        let avgSession = allDurations.isEmpty
            ? 0
            : allDurations.reduce(0, +) / Double(allDurations.count)

        let recentDays = (0..<7).reversed().map { offset -> PRDailyAggregate in
            let day = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            let activity = days.first(where: { $0.day == day })
            return PRDailyAggregate(
                day: day,
                listenSeconds: activity?.listeningSeconds ?? 0,
                readSeconds: activity?.readingSeconds ?? 0
            )
        }

        return PRStatsSnapshot(
            todaySeconds: todaySeconds,
            weekSeconds: weekSeconds,
            streakDays: streakDays,
            finishedBooks30d: finished30d,
            averageSessionSeconds: avgSession,
            recentDays: recentDays
        )
    }

    // MARK: - Persistence

    private func load() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: sessionsKey),
            let decoded = try? JSONDecoder().decode([PRMediaSession].self, from: data)
        {
            sessions = decoded
        }
        if let data = defaults.data(forKey: finishedKey),
            let decoded = try? JSONDecoder().decode([PRFinishedBook].self, from: data)
        {
            finished = decoded
        }
        if let data = defaults.data(forKey: streakDaysKey),
            let decoded = try? JSONDecoder().decode(Set<ReadingMotivationActivityDay>.self, from: data)
        {
            archivedActivityDays = decoded
        } else if let data = defaults.data(forKey: legacyStreakDaysKey),
            let legacy = try? JSONDecoder().decode(Set<Date>.self, from: data)
        {
            let now = Date()
            let calendar = ReadingMotivationCalculations.normalizedLocalCalendar(from: .current)
            let cutoff = calendar.date(byAdding: .year, value: -1, to: now) ?? now
            archivedActivityDays = ReadingMotivationCalculations.migrateLegacyActivityDays(
                staleDates: legacy,
                sessions: sessions.map(Self.toSyncSession),
                before: cutoff,
                calendar: calendar,
                now: now
            )
            persist()
            defaults.removeObject(forKey: legacyStreakDaysKey)
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.25))
            self?.persist()
        }
    }

    private func persist() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(sessions) {
            defaults.set(data, forKey: sessionsKey)
        }
        if let data = try? JSONEncoder().encode(finished) {
            defaults.set(data, forKey: finishedKey)
        }
        if let data = try? JSONEncoder().encode(archivedActivityDays) {
            defaults.set(data, forKey: streakDaysKey)
        }
    }

    // MARK: - Helpers

    private func closeActiveIfNeeded() {
        guard activeSession != nil else { return }
        endSession()
    }

    private func startMotivationCadenceLoopIfNeeded() {
        motivationReconcileTask?.cancel()
        guard ReadingMotivationActiveSessionReconcilePolicy.shouldRunCadence(
            hasActiveSession: activeSession != nil
        ) else {
            motivationReconcileTask = nil
            return
        }
        motivationReconcileTask = Task { @MainActor [weak self] in
            let interval = ReadingMotivationActiveSessionReconcilePolicy.tickIntervalSeconds
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                guard ReadingMotivationActiveSessionReconcilePolicy.shouldRunCadence(
                    hasActiveSession: self.activeSession != nil
                ) else { return }
                // Authoritative streak at retention / day change — independent of reminders.
                self.publishAuthoritativeStreakIfNeeded()
                if ReadingMotivationActiveSessionReconcilePolicy.shouldReconcileNotificationsOnTick(
                    notificationsEnabled: ReadingMotivationStore.shared.settings.notificationsEnabled
                ) {
                    // Uses motivationSessionRecords(at:) live elapsed via refresh path.
                    await ReadingMotivationStore.shared.refreshNotifications()
                }
            }
        }
    }

    private func stopMotivationCadenceLoopAndRefresh(publishStreak: Bool) {
        motivationReconcileTask?.cancel()
        motivationReconcileTask = nil
        if publishStreak {
            publishAuthoritativeStreakIfNeeded()
        }
        Task { await ReadingMotivationStore.shared.refreshNotifications() }
    }

    /// Push current streak+activity anchor into the shared Continue snapshot.
    /// Runs from SessionTracker lifecycle (not a Home-only timer) so the widget
    /// stays honest while Home is off-screen. Arbitrary iOS suspension can still
    /// delay ticks until foreground restore.
    private func publishAuthoritativeStreakIfNeeded(now: Date = Date()) {
        let calendar = ReadingMotivationCalculations.normalizedLocalCalendar(from: .current)
        let records = motivationSessionRecords(at: now)
        let effectiveElapsed: TimeInterval
        if let active = activeSession {
            effectiveElapsed = now.timeIntervalSince(active.startedAt)
        } else if let last = sessions.last {
            // Retained end path: closed session already appended.
            effectiveElapsed = last.durationSeconds
        } else {
            return
        }
        let streakDays = ReadingMotivationCalculations.streaks(
            sessions: records,
            calendar: calendar,
            now: now,
            archivedActivityDays: motivationArchivedActivityDays()
        ).current
        let activityDayKey = ReadingMotivationCalculations.streakActivityDayKey(
            sessions: records,
            calendar: calendar,
            now: now,
            archivedActivityDays: motivationArchivedActivityDays()
        )
        guard ReadingMotivationActiveSessionReconcilePolicy.shouldPublishAuthoritativeStreak(
            sessionElapsed: effectiveElapsed,
            streakDays: streakDays,
            activityDayKey: activityDayKey,
            lastPublishedStreakDays: lastPublishedWidgetStreakDays,
            lastPublishedActivityDayKey: lastPublishedWidgetStreakDayKey
        ) else { return }
        guard ContinueWidgetSnapshotStore.updateAuthoritativeStreak(
            streakDays: streakDays,
            streakActivityDayKey: activityDayKey
        ) else { return }
        lastPublishedWidgetStreakDays = streakDays
        lastPublishedWidgetStreakDayKey = activityDayKey
    }

    private static func toSyncSession(_ session: PRMediaSession) -> InkampStatsSessionRecord {
        InkampStatsSessionRecord(
            id: session.id,
            kind: session.kind == .reading ? .reading : .listening,
            mediaID: session.mediaID,
            mediaTitle: session.mediaTitle,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            durationSeconds: session.durationSeconds,
            endProgress: session.endProgress
        )
    }

    private static func fromSyncSession(_ record: InkampStatsSessionRecord) -> PRMediaSession {
        PRMediaSession(
            id: record.id,
            kind: record.kind == .reading ? .reading : .listening,
            mediaID: record.mediaID,
            mediaTitle: record.mediaTitle,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            durationSeconds: record.durationSeconds,
            endProgress: record.endProgress
        )
    }

    private static func toSyncFinished(_ book: PRFinishedBook) -> InkampStatsFinishedRecord {
        InkampStatsFinishedRecord(
            mediaID: book.mediaID,
            mediaTitle: book.mediaTitle,
            finishedAt: book.finishedAt
        )
    }

    private static func fromSyncFinished(_ record: InkampStatsFinishedRecord) -> PRFinishedBook {
        PRFinishedBook(
            mediaID: record.mediaID,
            mediaTitle: record.mediaTitle,
            finishedAt: record.finishedAt
        )
    }
}
