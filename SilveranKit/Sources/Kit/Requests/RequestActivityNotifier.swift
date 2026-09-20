import Foundation

#if canImport(UserNotifications)
import UserNotifications
#endif

/// Coordinates transition detection + local notification scheduling.
/// Scheduling always happens outside `RequestActivityStore`'s lock.
public final class RequestActivityNotifier: @unchecked Sendable {
    public static let shared = RequestActivityNotifier()

    private let lock = NSLock()
    private var _scheduler: any RequestNotificationScheduling
    private var _settingsProvider: @Sendable () -> RequestNotificationSettingsSnapshot

    public init(
        scheduler: any RequestNotificationScheduling = RequestActivityNotifier.makeDefaultScheduler(),
        settings: @escaping @Sendable () -> RequestNotificationSettingsSnapshot = {
            RequestNotificationSettings.current
        },
    ) {
        self._scheduler = scheduler
        self._settingsProvider = settings
    }

    public var scheduler: any RequestNotificationScheduling {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _scheduler
        }
        set {
            lock.lock()
            _scheduler = newValue
            lock.unlock()
        }
    }

    public var settingsProvider: @Sendable () -> RequestNotificationSettingsSnapshot {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _settingsProvider
        }
        set {
            lock.lock()
            _settingsProvider = newValue
            lock.unlock()
        }
    }

    /// Detect events and stamp notification metadata. Safe to call under the store lock
    /// (pure + UserDefaults settings read). Does not schedule.
    public func prepare(
        previous: RequestActivityItem?,
        incoming: RequestActivityItem,
    ) -> (item: RequestActivityItem, events: [RequestNotificationEvent]) {
        let settings = settingsProvider()
        let events = RequestActivityTransitionDetector.events(
            previous: previous,
            current: incoming,
            settings: settings,
        )
        let stamped = RequestActivityTransitionDetector.applyingNotificationState(
            incoming,
            events: events,
            previous: previous,
        )
        return (stamped, events)
    }

    /// Deliver events outside any store lock. Never re-enters `RequestActivityStore`.
    public func deliver(_ events: [RequestNotificationEvent]) {
        guard !events.isEmpty else { return }
        let scheduler = self.scheduler
        for event in events {
            scheduler.schedule(event)
        }
    }

    public static func makeDefaultScheduler() -> any RequestNotificationScheduling {
        #if canImport(UserNotifications) && (os(iOS) || os(macOS))
        return UserNotificationsRequestScheduler()
        #else
        return NoOpRequestNotificationScheduler()
        #endif
    }
}

#if canImport(UserNotifications) && (os(iOS) || os(macOS))
/// Live local-notification scheduler. Isolated from SwiftUI.
public struct UserNotificationsRequestScheduler: RequestNotificationScheduling {
    public init() {}

    public func schedule(_ event: RequestNotificationEvent) {
        let content = UNMutableNotificationContent()
        content.title = event.notificationTitle
        content.body = event.notificationBody
        content.sound = .default
        content.userInfo = event.userInfo

        let request = UNNotificationRequest(
            identifier: event.identifier,
            content: content,
            // nil trigger = deliver immediately when authorized.
            trigger: nil,
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                debugLog(
                    "[RequestNotifications] schedule failed id=\(event.identifier) error=\(error.localizedDescription)"
                )
            }
        }
    }
}

/// Authorization helpers for the Settings toggle. Never prompted at launch.
public enum RequestNotificationAuthorization {
    public enum Status: Equatable, Sendable {
        case notDetermined
        case denied
        case authorized
        case provisional
        case ephemeral
        case unknown
    }

    public static func currentStatus() async -> Status {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
            case .notDetermined: return .notDetermined
            case .denied: return .denied
            case .authorized: return .authorized
            case .provisional: return .provisional
            case .ephemeral: return .ephemeral
            @unknown default: return .unknown
        }
    }

    /// Request permission once. Returns whether alerts may be delivered.
    @discardableResult
    public static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound]
            )
        } catch {
            debugLog(
                "[RequestNotifications] authorization failed error=\(error.localizedDescription)"
            )
            return false
        }
    }
}
#endif
