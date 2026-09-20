import Foundation
import SilveranKit

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
        let request = RequestActivityNavigation.request(
            from: response.notification.request.content.userInfo
        )
        // Store before posting so a cold start still has the destination when Home mounts.
        RequestActivityNavigationCoordinator.shared.set(request.destination)
        var userInfo: [AnyHashable: Any] = [:]
        if let requestID = request.destination.requestID {
            userInfo[RequestActivityNavigation.requestIDKey] = requestID
        }
        if let kind = request.kind {
            userInfo[RequestActivityNavigation.kindKey] = kind
        }
        NotificationCenter.default.post(
            name: .punkRallyShowRequestActivity,
            object: nil,
            userInfo: userInfo,
        )
    }
}
#endif
