import Foundation
import Observation
import SilveranKit

@MainActor
@Observable
final class ReadingMotivationStore {
    static let shared = ReadingMotivationStore()
    private static let settingsKey = "punkRally.motivation.settings.v1"

    private(set) var settings: ReadingMotivationSettings
    private(set) var notificationMessage = "Reminders are off"
    private(set) var revision = 0
    private var notificationPreferencesRevision: UInt64 = 0
    private var notificationRequestRevision: UInt64 = 0
    private var notificationToggleRevision: UInt64 = 0

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
            let stored = try? JSONDecoder().decode(ReadingMotivationSettings.self, from: data)
        {
            settings = stored
        } else {
            settings = ReadingMotivationSettings()
            save()
        }
    }

    var sessions: [InkampStatsSessionRecord] {
        SessionTracker.shared.motivationSessionRecords()
    }

    var today: ReadingMotivationDay {
        let now = Date()
        let day = Calendar.current.startOfDay(for: now)
        return ReadingMotivationCalculations.dailyTotals(
            sessions: sessions,
            calendar: Calendar.current,
            now: now
        ).first(where: { $0.day == day }) ?? ReadingMotivationDay(
            day: day, readingSeconds: 0, listeningSeconds: 0
        )
    }

    var streaks: ReadingMotivationStreaks {
        ReadingMotivationCalculations.streaks(
            sessions: sessions,
            calendar: Calendar.current,
            now: Date(),
            archivedActivityDays: SessionTracker.shared.motivationArchivedActivityDays()
        )
    }

    func weeklyReceipt(offset: Int = 0) -> ReadingMotivationWeeklyReceipt {
        ReadingMotivationCalculations.weeklyReceipt(
            sessions: sessions,
            finished: SessionTracker.shared.allFinished.map {
                InkampStatsFinishedRecord(
                    mediaID: $0.mediaID, mediaTitle: $0.mediaTitle, finishedAt: $0.finishedAt
                )
            },
            weekOffset: offset,
            calendar: Calendar.current,
            now: Date(),
            archivedActivityDays: SessionTracker.shared.motivationArchivedActivityDays()
        )
    }

    func value(for stat: ReadingMotivationPinnedStat) -> String {
        let receipt = weeklyReceipt()
        switch stat {
            case .todayReading: return Self.durationText(today.readingSeconds)
            case .todayListening: return Self.durationText(today.listeningSeconds)
            case .weekTotal: return Self.durationText(receipt.seconds)
            case .weekReading: return Self.durationText(receipt.readingSeconds)
            case .weekListening: return Self.durationText(receipt.listeningSeconds)
            case .currentStreak: return String(streaks.current) + "d"
            case .longestStreak: return String(streaks.longest) + "d"
            case .activityDays: return String(receipt.activityDays) + "/7"
            case .finishedTitles: return String(receipt.completedTitles)
        }
    }

    func finishProjection(
        for item: HomeMixedItem,
        playbackRate: Double?,
        now: Date = Date()
    ) -> ReadingMotivationFinishProjection? {
        let mediaID: String
        let progress: Double
        let totalUnits: Double?
        let effectiveRate: Double?
        let paceKind: InkampStatsSessionRecord.Kind
        let paceBasis: String
        switch item {
            case .book(let book, _, let fraction, let badge):
                mediaID = String(describing: book.id)
                progress = fraction
                switch badge {
                    case .ebook:
                        totalUnits = book.pageCountValue.map(Double.init)
                        effectiveRate = nil
                        paceKind = .reading
                        paceBasis = "Based on your recent reading pace"
                    case .audiobook, .readaloud:
                        totalUnits = book.durationValue
                        effectiveRate = playbackRate
                        paceKind = .listening
                        paceBasis = "Based on your recent listening pace"
                    case .podcast:
                        return nil
                }
            case .podcast(let entry):
                mediaID = "podcast/" + entry.episodeID
                progress = entry.progress
                totalUnits = entry.durationSeconds
                effectiveRate = playbackRate
                paceKind = .listening
                paceBasis = "Based on your recent listening pace"
        }
        return ReadingMotivationCalculations.projectedFinish(
            sessions: SessionTracker.shared.motivationSessionRecords(at: now),
            mediaID: mediaID,
            progress: progress,
            totalUnits: totalUnits,
            playbackRate: effectiveRate,
            paceKind: paceKind,
            paceBasis: paceBasis,
            calendar: Calendar.current,
            now: now
        )
    }

    func setGoals(reading: Int, listening: Int) {
        notificationPreferencesRevision &+= 1
        settings = ReadingMotivationSettings(
            dailyReadingGoalMinutes: reading,
            dailyListeningGoalMinutes: listening,
            pinnedStats: settings.pinnedStats,
            notificationsEnabled: settings.notificationsEnabled,
            quietHour: settings.quietHour,
            quietMinute: settings.quietMinute
        )
        save()
        Task { await refreshNotifications() }
    }

    func setPinned(_ stat: ReadingMotivationPinnedStat, isPinned: Bool) {
        var pins = settings.pinnedStats
        if isPinned {
            guard !pins.contains(stat), pins.count < 3 else { return }
            pins.append(stat)
        } else {
            pins.removeAll { $0 == stat }
        }
        settings = ReadingMotivationSettings(
            dailyReadingGoalMinutes: settings.dailyReadingGoalMinutes,
            dailyListeningGoalMinutes: settings.dailyListeningGoalMinutes,
            pinnedStats: pins,
            notificationsEnabled: settings.notificationsEnabled,
            quietHour: settings.quietHour,
            quietMinute: settings.quietMinute
        )
        save()
    }

    func setQuietTime(_ date: Date) {
        notificationPreferencesRevision &+= 1
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        settings = ReadingMotivationSettings(
            dailyReadingGoalMinutes: settings.dailyReadingGoalMinutes,
            dailyListeningGoalMinutes: settings.dailyListeningGoalMinutes,
            pinnedStats: settings.pinnedStats,
            notificationsEnabled: settings.notificationsEnabled,
            quietHour: components.hour ?? 20,
            quietMinute: components.minute ?? 30
        )
        save()
        Task { await refreshNotifications() }
    }

    func setNotificationsEnabled(_ enabled: Bool) async -> Bool {
        notificationPreferencesRevision &+= 1
        notificationToggleRevision &+= 1
        let toggleRevision = notificationToggleRevision
        #if os(iOS)
        if enabled {
            let authorized = await ReadingMotivationNotifications.shared.requestPermission()
            guard authorized else {
                if toggleRevision == notificationToggleRevision {
                    notificationMessage = "Permission not granted · check iOS Settings"
                    revision &+= 1
                }
                return false
            }
        }
        #else
        if enabled { return false }
        #endif
        guard toggleRevision == notificationToggleRevision else { return false }
        settings = ReadingMotivationSettings(
            dailyReadingGoalMinutes: settings.dailyReadingGoalMinutes,
            dailyListeningGoalMinutes: settings.dailyListeningGoalMinutes,
            pinnedStats: settings.pinnedStats,
            notificationsEnabled: enabled,
            quietHour: settings.quietHour,
            quietMinute: settings.quietMinute
        )
        notificationMessage = enabled ? "Reminders are on" : "Reminders are off"
        save()
        SessionTracker.shared.syncMotivationReconcileLoop()
        await refreshNotifications()
        return true
    }

    func refreshNotifications(now: Date = Date()) async {
        #if os(iOS)
        notificationRequestRevision &+= 1
        let requestRevision = notificationRequestRevision
        let preferenceRevision = notificationPreferencesRevision
        let calendar = Calendar.current
        let candidates = notificationCandidates(now: now, calendar: calendar)
        await ReadingMotivationNotifications.shared.reconcile(
            candidates: candidates,
            enabled: settings.notificationsEnabled,
            now: now,
            calendar: calendar,
            preferenceRevision: preferenceRevision,
            requestRevision: requestRevision
        )
        let authorized = await ReadingMotivationNotifications.shared.isAuthorized()
        notificationMessage = !settings.notificationsEnabled
            ? "Reminders are off"
            : (authorized ? "Reminders are on" : "Permission not granted · check iOS Settings")
        #else
        notificationMessage = settings.notificationsEnabled
            ? "Local reminders are available on iPhone" : "Reminders are off"
        #endif
    }

    func recordNotificationDelivered(dayKey: String, deliveredAt: Date?) async {
        #if os(iOS)
        await ReadingMotivationNotifications.shared.markDelivered(
            dayKey: dayKey, deliveredAt: deliveredAt
        )
        #else
        _ = dayKey
        _ = deliveredAt
        #endif
    }

    private func notificationCandidates(now: Date, calendar: Calendar) -> [ReadingMotivationNotificationCandidate] {
        guard settings.notificationsEnabled else { return [] }
        let quiet = ReadingMotivationNotificationPolicy.quietDeliveryDate(
            on: now, hour: settings.quietHour, minute: settings.quietMinute, calendar: calendar
        )
        let records = SessionTracker.shared.motivationSessionRecords(at: now)
        let todayStart = calendar.startOfDay(for: now)
        let todayProgress = ReadingMotivationCalculations.dailyTotals(
            sessions: records, calendar: calendar, now: now
        ).first(where: { $0.day == todayStart })
            ?? ReadingMotivationDay(day: todayStart, readingSeconds: 0, listeningSeconds: 0)
        let receipt = ReadingMotivationCalculations.weeklyReceipt(
            sessions: records,
            finished: SessionTracker.shared.allFinished.map {
                InkampStatsFinishedRecord(
                    mediaID: $0.mediaID, mediaTitle: $0.mediaTitle, finishedAt: $0.finishedAt
                )
            },
            weekOffset: 0,
            calendar: calendar,
            now: now,
            archivedActivityDays: SessionTracker.shared.motivationArchivedActivityDays()
        )
        return ReadingMotivationNotificationPolicy.candidates(
            now: now,
            quietDeliveryDate: quiet,
            readingSeconds: todayProgress.readingSeconds,
            readingGoalSeconds: Double(settings.dailyReadingGoalMinutes) * 60,
            listeningSeconds: todayProgress.listeningSeconds,
            listeningGoalSeconds: Double(settings.dailyListeningGoalMinutes) * 60,
            activityDaysThisWeek: receipt.activityDays,
            calendar: calendar
        )
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
        revision &+= 1
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "–" }
        let minutes = max(0, Int(seconds / 60))
        let hours = minutes / 60
        let remainder = minutes % 60
        if seconds > 0, minutes == 0 { return "<1m" }
        if hours > 0 {
            return remainder == 0 ? String(hours) + "h" : String(hours) + "h " + String(remainder) + "m"
        }
        return String(remainder) + "m"
    }
}
