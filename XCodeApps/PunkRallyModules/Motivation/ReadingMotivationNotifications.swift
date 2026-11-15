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
        calendar: Calendar,
        preferenceRevision: UInt64,
        requestRevision: UInt64
    ) async {
        do {
            try await coordinator.reconcile(
                candidates: candidates,
                enabled: enabled,
                now: now,
                calendar: calendar,
                preferenceRevision: preferenceRevision,
                requestRevision: requestRevision
            )
        } catch {
            notificationSchedulingFailed()
        }
    }

    func markDelivered(dayKey: String, deliveredAt: Date?) async {
        await coordinator.markDelivered(dayKey: dayKey, deliveredAt: deliveredAt)
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
    private let delegateLock = NSLock()
    private var forwardingDelegate: (any UNUserNotificationCenterDelegate)?

    private var previousDelegate: (any UNUserNotificationCenterDelegate)? {
        delegateLock.lock()
        defer { delegateLock.unlock() }
        return forwardingDelegate
    }

    func install() {
        guard center.delegate !== self else { return }
        // Preserve the shipped Request Activity delegate. Repeated shell appearances
        // must not replace the forwarding target with ourselves.
        let previous = center.delegate
        delegateLock.lock()
        forwardingDelegate = previous
        delegateLock.unlock()
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
        let calendar = ReadingMotivationCalculations.normalizedLocalCalendar(from: .current)
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute], from: request.deliveryDate
        )
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try await center.add(
            UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger)
        )
    }

    func cancelPending(identifier: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    func pendingIdentifiers() async -> Set<String> {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(returning: Set(requests.map(\.identifier)))
            }
        }
    }

    func deliveredNotifications() async -> [String: Date] {
        await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { notifications in
                var deliveries: [String: Date] = [:]
                for notification in notifications {
                    let identifier = notification.request.identifier
                    deliveries[identifier] = max(deliveries[identifier] ?? .distantPast, notification.date)
                }
                continuation.resume(returning: deliveries)
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
        guard notification.request.identifier.hasPrefix("reading-motivation.") else {
            if let previous = previousDelegate,
                previous.responds(to: #selector(
                    UNUserNotificationCenterDelegate.userNotificationCenter(
                        _:willPresent:withCompletionHandler:
                    )
                ))
            {
                previous.userNotificationCenter?(
                    center, willPresent: notification,
                    withCompletionHandler: completionHandler
                )
            } else {
                completionHandler([])
            }
            return
        }
        Self.postDelivered(notification.request.identifier, deliveredAt: notification.date)
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard response.notification.request.identifier.hasPrefix("reading-motivation.") else {
            if let previous = previousDelegate,
                previous.responds(to: #selector(
                    UNUserNotificationCenterDelegate.userNotificationCenter(
                        _:didReceive:withCompletionHandler:
                    )
                ))
            {
                previous.userNotificationCenter?(
                    center, didReceive: response,
                    withCompletionHandler: completionHandler
                )
            } else {
                completionHandler()
            }
            return
        }
        Self.postDelivered(
            response.notification.request.identifier,
            deliveredAt: response.notification.date
        )
        completionHandler()
    }

    private static func postDelivered(_ identifier: String, deliveredAt: Date) {
        let prefix = "reading-motivation."
        guard identifier.hasPrefix(prefix) else { return }
        NotificationCenter.default.post(
            name: .readingMotivationNotificationDelivered,
            object: nil,
            userInfo: [
                "dayKey": String(identifier.dropFirst(prefix.count)),
                "deliveredAt": deliveredAt,
            ]
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
