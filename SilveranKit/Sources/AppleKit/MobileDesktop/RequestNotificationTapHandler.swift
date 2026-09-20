import Foundation
import SilveranKit

/// Lightweight pending-navigation flag for Request Activity notification taps.
public enum RequestActivityNavigationPending {
    nonisolated(unsafe) public static var shouldOpen = false
}

#if canImport(UserNotifications) && (os(iOS) || os(macOS))
import UserNotifications

/// Handles Request Activity notification taps. Install once from the host shell.
/// Does not present banners while foregrounded (system default without willPresent).
@MainActor
public enum RequestNotificationTapHandler {
    private static var installed = false

    public static func install() {
        guard !installed else { return }
        installed = true
        UNUserNotificationCenter.current().delegate = RequestNotificationCenterDelegate.shared
    }
}

private final class RequestNotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate,
    @unchecked Sendable
{
    static let shared = RequestNotificationCenterDelegate()

    /// Foreground: do not show an intrusive banner — UI already updates live.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
    ) async -> UNNotificationPresentationOptions {
        []
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
    ) async {
        let info = response.notification.request.content.userInfo
        var userInfo: [AnyHashable: Any] = [:]
        if let requestID = info["requestID"] as? String {
            userInfo["requestID"] = requestID
        }
        if let kind = info["kind"] as? String {
            userInfo["kind"] = kind
        }
        RequestActivityNavigationPending.shouldOpen = true
        NotificationCenter.default.post(
            name: .punkRallyShowRequestActivity,
            object: nil,
            userInfo: userInfo,
        )
    }
}
#endif
