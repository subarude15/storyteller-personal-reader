#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI

#if os(iOS)
import UIKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

/// Compact Request Notifications controls under Book requests / Book Sources.
struct RequestNotificationsSettingsSection: View {
    @State private var enabled = RequestNotificationSettings.enabled
    @State private var notifyAvailable = RequestNotificationSettings.notifyAvailable
    @State private var notifyNeedsAttention = RequestNotificationSettings.notifyNeedsAttention
    @State private var authorizationStatus: AuthorizationDisplay = .unknown
    @State private var isRequesting = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            Toggle(
                "Notify me about book requests",
                isOn: Binding(
                    get: { enabled },
                    set: { newValue in
                        Task { await setEnabled(newValue) }
                    },
                )
            )
            .disabled(isRequesting)

            if enabled, authorizationStatus == .authorized {
                Toggle(
                    "Ready notifications",
                    isOn: Binding(
                        get: { notifyAvailable },
                        set: { value in
                            notifyAvailable = value
                            RequestNotificationSettings.notifyAvailable = value
                        },
                    )
                )
                Toggle(
                    "Needs attention notifications",
                    isOn: Binding(
                        get: { notifyNeedsAttention },
                        set: { value in
                            notifyNeedsAttention = value
                            RequestNotificationSettings.notifyNeedsAttention = value
                        },
                    )
                )
            }

            if authorizationStatus == .denied {
                #if os(iOS)
                Text("Notifications are disabled in iOS Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                #else
                Text("Notifications are disabled in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }
        } header: {
            Text("Request Notifications")
        } footer: {
            Text(
                "Get notified when requested books become available in your library or need attention."
            )
        }
        .task { await refreshAuthorizationStatus() }
    }

    private enum AuthorizationDisplay: Equatable {
        case notDetermined
        case denied
        case authorized
        case unknown
    }

    @MainActor
    private func setEnabled(_ newValue: Bool) async {
        if !newValue {
            enabled = false
            RequestNotificationSettings.enabled = false
            return
        }

        isRequesting = true
        defer { isRequesting = false }

        #if canImport(UserNotifications)
        let status = await RequestNotificationAuthorization.currentStatus()
        switch status {
            case .denied:
                enabled = false
                RequestNotificationSettings.enabled = false
                authorizationStatus = .denied
                return
            case .authorized, .provisional, .ephemeral:
                enabled = true
                RequestNotificationSettings.enabled = true
                authorizationStatus = .authorized
                return
            case .notDetermined, .unknown:
                let granted = await RequestNotificationAuthorization.requestAuthorization()
                if granted {
                    enabled = true
                    RequestNotificationSettings.enabled = true
                    authorizationStatus = .authorized
                } else {
                    enabled = false
                    RequestNotificationSettings.enabled = false
                    let after = await RequestNotificationAuthorization.currentStatus()
                    authorizationStatus = after == .denied ? .denied : .notDetermined
                }
        }
        #else
        enabled = false
        RequestNotificationSettings.enabled = false
        authorizationStatus = .unknown
        #endif
    }

    @MainActor
    private func refreshAuthorizationStatus() async {
        enabled = RequestNotificationSettings.enabled
        notifyAvailable = RequestNotificationSettings.notifyAvailable
        notifyNeedsAttention = RequestNotificationSettings.notifyNeedsAttention
        #if canImport(UserNotifications)
        switch await RequestNotificationAuthorization.currentStatus() {
            case .denied:
                authorizationStatus = .denied
                if enabled {
                    enabled = false
                    RequestNotificationSettings.enabled = false
                }
            case .authorized, .provisional, .ephemeral:
                authorizationStatus = .authorized
            case .notDetermined:
                authorizationStatus = .notDetermined
            case .unknown:
                authorizationStatus = .unknown
        }
        #endif
    }
}
#endif
