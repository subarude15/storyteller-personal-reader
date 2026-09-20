import Foundation

/// Compact local preferences for Request Activity notifications.
/// Separate from `SilveranGlobalConfig` — local-only, no secrets, no server sync.
public struct RequestNotificationSettingsSnapshot: Equatable, Sendable {
    public var enabled: Bool
    public var notifyAvailable: Bool
    public var notifyNeedsAttention: Bool

    public init(
        enabled: Bool = false,
        notifyAvailable: Bool = true,
        notifyNeedsAttention: Bool = true,
    ) {
        self.enabled = enabled
        self.notifyAvailable = notifyAvailable
        self.notifyNeedsAttention = notifyNeedsAttention
    }

    public var allowsAvailable: Bool { enabled && notifyAvailable }
    public var allowsNeedsAttention: Bool { enabled && notifyNeedsAttention }
}

public enum RequestNotificationSettings {
    public static let enabledKey = "punkRally.requestNotifications.enabled"
    public static let notifyAvailableKey = "punkRally.requestNotifications.notifyAvailable"
    public static let notifyNeedsAttentionKey = "punkRally.requestNotifications.notifyNeedsAttention"

    public static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Defaults to true when unset.
    public static var notifyAvailable: Bool {
        get {
            guard UserDefaults.standard.object(forKey: notifyAvailableKey) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: notifyAvailableKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: notifyAvailableKey) }
    }

    /// Defaults to true when unset.
    public static var notifyNeedsAttention: Bool {
        get {
            guard UserDefaults.standard.object(forKey: notifyNeedsAttentionKey) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: notifyNeedsAttentionKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: notifyNeedsAttentionKey) }
    }

    public static var current: RequestNotificationSettingsSnapshot {
        RequestNotificationSettingsSnapshot(
            enabled: enabled,
            notifyAvailable: notifyAvailable,
            notifyNeedsAttention: notifyNeedsAttention,
        )
    }
}
