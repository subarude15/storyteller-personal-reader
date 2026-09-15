//
//  SessionTracker.swift
//  ink+amp
//
//  Ported from Enve Book Player (AGPL-3.0-only):
//  https://github.com/opisaac9001/Enve-Book-Player
//  Original: ios/enve/Services/ListeningStats/ListeningStatsTracker.swift
//  Modifications: local-only; no Audiobookshelf progress sync; listens to
//  Silveran player/reader events (wired in the next milestone).
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Observation

/// Tracks reading/listening sessions locally and computes home/Stats aggregates.
/// Data lives on-device only — matches the ink+amp privacy stance.
@MainActor
@Observable
final class SessionTracker {
    static let shared = SessionTracker()

    private let sessionsKey = "punkRally.stats.sessions.v1"
    private let finishedKey = "punkRally.stats.finished.v1"

    private var sessions: [PRMediaSession] = []
    private var finished: [PRFinishedBook] = []

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

    /// Begin a session for a media item.
    func startSession(kind: PRMediaSession.Kind, mediaID: String, mediaTitle: String) {
        closeActiveIfNeeded()
        activeSession = PRMediaSession(
            kind: kind,
            mediaID: mediaID,
            mediaTitle: mediaTitle,
            startedAt: Date()
        )
    }

    /// End the active session and record its duration.
    func endSession(progress: Double? = nil) {
        guard let active = activeSession else { return }
        let ended = Date()
        let duration = ended.timeIntervalSince(active.startedAt)

        // Only record sessions of meaningful length (≥ 30 seconds).
        guard duration >= 30 else {
            activeSession = nil
            return
        }

        var session = active
        session.endedAt = ended
        session.durationSeconds = duration
        session.endProgress = progress
        sessions.append(session)
        activeSession = nil
        scheduleSave()
    }

    /// Note that a book finished (progress hit 100%).
    func recordFinished(mediaID: String, mediaTitle: String) {
        guard !finished.contains(where: { $0.mediaID == mediaID }) else { return }
        finished.append(PRFinishedBook(mediaID: mediaID, mediaTitle: mediaTitle, finishedAt: Date()))
        scheduleSave()
    }

    /// Prune sessions older than 1 year to keep storage small.
    func pruneOldSessions() {
        let cutoff = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
        sessions.removeAll { $0.endedAt < cutoff }
        scheduleSave()
    }

    /// Compute the full stats snapshot.
    var snapshot: PRStatsSnapshot {
        let calendar = Calendar.current
        let now = Date()

        func startOfDay(_ date: Date) -> Date {
            calendar.startOfDay(for: date)
        }

        let todayStart = startOfDay(now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart

        let todaySeconds = sessions
            .filter { $0.endedAt >= todayStart }
            .reduce(0) { $0 + $1.durationSeconds }

        let weekSeconds = sessions
            .filter { $0.endedAt >= weekStart }
            .reduce(0) { $0 + $1.durationSeconds }

        let streakDays = computeStreak(calendar: calendar, today: todayStart)

        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        let finished30d = finished.filter { $0.finishedAt >= thirtyDaysAgo }.count

        let avgSession = sessions.isEmpty
            ? 0
            : sessions.map(\.durationSeconds).reduce(0, +) / Double(sessions.count)

        let recentDays = (0..<7).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: todayStart) ?? todayStart
            return PRDailyAggregate(
                day: day,
                listenSeconds: sessionsForDay(day, kind: .listening, calendar: calendar),
                readSeconds: sessionsForDay(day, kind: .reading, calendar: calendar)
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
    }

    // MARK: - Helpers

    private func sessionsForDay(_ day: Date, kind: PRMediaSession.Kind, calendar: Calendar) -> TimeInterval {
        sessions
            .filter { calendar.isDate($0.endedAt, inSameDayAs: day) && $0.kind == kind }
            .reduce(0) { $0 + $1.durationSeconds }
    }

    private func computeStreak(calendar: Calendar, today: Date) -> Int {
        // Count consecutive days (ending today or yesterday) with any session.
        let daysWithSessions = Set(
            sessions.map { calendar.startOfDay(for: $0.endedAt) }
        )

        var streak = 0
        var cursor = today
        if !daysWithSessions.contains(cursor) {
            // Allow streak to persist if today hasn't started yet, but yesterday counted.
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor),
                daysWithSessions.contains(yesterday)
            else { return 0 }
            cursor = yesterday
        }

        while daysWithSessions.contains(cursor) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return streak
    }

    private func closeActiveIfNeeded() {
        guard activeSession != nil else { return }
        endSession()
    }
}