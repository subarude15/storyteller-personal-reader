import Foundation

/// Compact delay choices for automatic provider fallback.
public enum AutomaticFallbackDelay: String, Codable, CaseIterable, Sendable, Identifiable {
    case immediately
    case oneHour
    case sixHours
    case twelveHours
    case twentyFourHours

    public var id: String { rawValue }

    public var label: String {
        switch self {
            case .immediately: return "Immediately"
            case .oneHour: return "1 hour"
            case .sixHours: return "6 hours"
            case .twelveHours: return "12 hours"
            case .twentyFourHours: return "24 hours"
        }
    }

    public var seconds: TimeInterval {
        switch self {
            case .immediately: return 0
            case .oneHour: return 3600
            case .sixHours: return 6 * 3600
            case .twelveHours: return 12 * 3600
            case .twentyFourHours: return 24 * 3600
        }
    }

    public static func preference(from raw: String?) -> AutomaticFallbackDelay {
        guard let raw, let value = AutomaticFallbackDelay(rawValue: raw) else {
            return .sixHours
        }
        return value
    }
}

/// Local-only settings for optional automatic provider fallback.
public struct AutomaticFallbackSettingsSnapshot: Equatable, Sendable {
    public var enabled: Bool
    public var delay: AutomaticFallbackDelay

    public init(enabled: Bool = false, delay: AutomaticFallbackDelay = .sixHours) {
        self.enabled = enabled
        self.delay = delay
    }
}

public enum RequestAutomaticFallbackSettings {
    public static let enabledKey = "punkRally.requestAutomaticFallback.enabled"
    public static let delayKey = "punkRally.requestAutomaticFallback.delay"

    public static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    public static var delay: AutomaticFallbackDelay {
        get {
            AutomaticFallbackDelay.preference(
                from: UserDefaults.standard.string(forKey: delayKey)
            )
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: delayKey) }
    }

    public static var current: AutomaticFallbackSettingsSnapshot {
        AutomaticFallbackSettingsSnapshot(enabled: enabled, delay: delay)
    }
}
