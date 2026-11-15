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
    private let streakDaysKey = "punkRally.stats.streakDays.v1"

    private var sessions: [PRMediaSession] = []
    private var finished: [PRFinishedBook] = []
    private var archivedActivityDays: Set<Date> = []

    /// Bumped whenever aggregates change so SwiftUI refreshes.
    private(set) var revision: Int = 0

    /// Active (unclosed) session, if any.
    private var activeSession: PRMediaSession?

    private var saveTask: Task<Void, Never>?

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
        if let activeSession, now > activeSession.startedAt {
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

    func motivationArchivedActivityDays() -> [Date] {
        archivedActivityDays.sorted()
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
        guard duration >= 30 else {
            activeSession = nil
            revision &+= 1
            return
        }

        var session = active
        session.endedAt = ended
        session.durationSeconds = duration
        session.endProgress = progress
        sessions.append(session)
        activeSession = nil
        archiveActivityDays(at: ended)

        if let progress, progress >= 0.95 {
            recordFinished(mediaID: session.mediaID, mediaTitle: session.mediaTitle)
        }
        revision &+= 1
        scheduleSave()
        StatsSyncCoordinator.shared.scheduleSyncAfterLocalChange()
        Task { await ReadingMotivationStore.shared.refreshNotifications() }
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
        archiveActivityDays()
        revision &+= 1
        persist()
        Task { await ReadingMotivationStore.shared.refreshNotifications() }
    }

    /// Prune sessions older than 1 year to keep storage small.
    func pruneOldSessions() {
        archiveActivityDays()
        let cutoff = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
        sessions.removeAll { $0.endedAt < cutoff }
        scheduleSave()
    }

    /// Compute the full stats snapshot (includes live active session time).
    var snapshot: PRStatsSnapshot {
        let calendar = Calendar.current
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
            let decoded = try? JSONDecoder().decode(Set<Date>.self, from: data)
        {
            archivedActivityDays = decoded
        }
        archiveActivityDays()
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

    private func archiveActivityDays(at now: Date = Date()) {
        let days = ReadingMotivationCalculations.dailyTotals(
            sessions: sessions.map(Self.toSyncSession),
            calendar: Calendar.current,
            now: now
        )
        archivedActivityDays.formUnion(days.map(\.day))
        if let data = try? JSONEncoder().encode(archivedActivityDays) {
            UserDefaults.standard.set(data, forKey: streakDaysKey)
        }
    }

    // MARK: - Helpers

    private func closeActiveIfNeeded() {
        guard activeSession != nil else { return }
        endSession()
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
