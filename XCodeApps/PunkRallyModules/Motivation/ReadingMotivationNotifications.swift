#if os(iOS)
import Foundation
import SilveranKit
import UserNotifications

extension Notification.Name {
    static let readingMotivationNotificationDelivered = Notification.Name(
        "punkRally.readingMotivation.notificationDelivered"
    )
}

@MainActor
final class ReadingMotivationNotifications {
    static let shared = ReadingMotivationNotifications()

    private let scheduler: UserNotificationScheduler
    private let coordinator: ReadingMotivationNotificationCoordinator

    private init() {
        let scheduler = UserNotificationScheduler()
        self.scheduler = scheduler
        coordinator = ReadingMotivationNotificationCoordinator(
            scheduler: scheduler,
            stateStore: UserDefaultsReadingMotivationNotificationStateStore()
        )
    }

    func install() {
        scheduler.install()
    }

    func requestPermission() async -> Bool {
        await coordinator.requestPermission()
    }

    func isAuthorized() async -> Bool {
        await scheduler.authorization() == .authorized
    }

    func reconcile(
        candidates: [ReadingMotivationNotificationCandidate],
        enabled: Bool,
        now: Date,
        calendar: Calendar
    ) async {
        do {
            try await coordinator.reconcile(
                candidates: candidates, enabled: enabled, now: now, calendar: calendar
            )
        } catch {
            notificationSchedulingFailed()
        }
    }

    func markDelivered(dayKey: String) async {
        await coordinator.markDelivered(dayKey: dayKey)
    }

    private func notificationSchedulingFailed() {
        debugLog("[ReadingMotivation] local notification scheduling failed")
    }
}

private final class UserNotificationScheduler: NSObject,
    ReadingMotivationNotificationScheduling,
    UNUserNotificationCenterDelegate,
    @unchecked Sendable
{
    private let center = UNUserNotificationCenter.current()

    func install() {
        center.delegate = self
    }

    func authorization() async -> ReadingMotivationNotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
            case .authorized, .provisional, .ephemeral: return .authorized
            case .denied: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .denied
        }
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func schedule(_ request: ReadingMotivationNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = "ink+amp"
        content.body = Self.message(for: request.kind)
        content.sound = .default
        content.userInfo["dayKey"] = request.identifier.replacingOccurrences(
            of: "reading-motivation.", with: ""
        )
        var components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: request.deliveryDate
        )
        components.calendar = Calendar.current
        components.timeZone = Calendar.current.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try await center.add(
            UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger)
        )
    }

    func cancelPending(identifier: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    func deliveredIdentifiers() async -> Set<String> {
        await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { notifications in
                continuation.resume(returning: Set(notifications.map(\.request.identifier)))
            }
        }
    }

    func removeDelivered(identifiers: Set<String>) async {
        center.removeDeliveredNotifications(withIdentifiers: Array(identifiers))
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        Self.postDelivered(notification.request.identifier)
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Self.postDelivered(response.notification.request.identifier)
        completionHandler()
    }

    private static func postDelivered(_ identifier: String) {
        let prefix = "reading-motivation."
        guard identifier.hasPrefix(prefix) else { return }
        NotificationCenter.default.post(
            name: .readingMotivationNotificationDelivered,
            object: nil,
            userInfo: ["dayKey": String(identifier.dropFirst(prefix.count))]
        )
    }

    private static func message(for kind: ReadingMotivationNotificationKind) -> String {
        switch kind {
            case .rescue: return "A little reading or listening can still count toward today's goal."
            case .pace: return "There is still time to make a little progress today."
            case .receipt: return "Your week in reading and listening is ready in Stats."
        }
    }
}
#endif
