import Foundation

/// Notification-worthy Request Activity transitions (local only).
public enum RequestNotificationEvent: Equatable, Sendable {
    case available(requestID: String, title: String, formats: [BookRequestFormat])
    case needsAttention(requestID: String, title: String, formats: [BookRequestFormat])

    public var requestID: String {
        switch self {
            case .available(let id, _, _), .needsAttention(let id, _, _): id
        }
    }

    public var bookTitle: String {
        switch self {
            case .available(_, let title, _), .needsAttention(_, let title, _): title
        }
    }

    public var formats: [BookRequestFormat] {
        switch self {
            case .available(_, _, let formats), .needsAttention(_, _, let formats): formats
        }
    }

    public var kind: Kind {
        switch self {
            case .available: .available
            case .needsAttention: .needsAttention
        }
    }

    public enum Kind: String, Sendable {
        case available
        case needsAttention
    }

    /// Deterministic ID so duplicate schedules replace rather than stack.
    public var identifier: String {
        switch self {
            case .available(let id, _, let formats):
                RequestNotificationIdentifiers.available(requestID: id, formats: formats)
            case .needsAttention(let id, _, _):
                RequestNotificationIdentifiers.attention(requestID: id)
        }
    }

    public var notificationTitle: String {
        switch self {
            case .available: "Book ready"
            case .needsAttention: "Book request needs attention"
        }
    }

    public var notificationBody: String {
        switch self {
            case .available(_, let title, let formats):
                RequestNotificationCopy.availableBody(title: title, formats: formats)
            case .needsAttention(_, let title, let formats):
                RequestNotificationCopy.needsAttentionBody(title: title, formats: formats)
        }
    }

    /// Safe userInfo — request id + kind only. No secrets, URLs, or backend errors.
    public var userInfo: [String: String] {
        [
            "requestID": requestID,
            "kind": kind.rawValue,
        ]
    }
}

public enum RequestNotificationIdentifiers {
    public static func available(requestID: String, formats: [BookRequestFormat]) -> String {
        let sorted = BookRequestFormat.allCases.filter { formats.contains($0) }
        if sorted.count >= 2 {
            return "request.\(requestID).available.both"
        }
        if let format = sorted.first {
            return "request.\(requestID).available.\(format.rawValue)"
        }
        return "request.\(requestID).available"
    }

    public static func attention(requestID: String) -> String {
        "request.\(requestID).attention"
    }
}

public enum RequestNotificationCopy {
    public static func availableBody(title: String, formats: [BookRequestFormat]) -> String {
        let sorted = BookRequestFormat.allCases.filter { formats.contains($0) }
        if sorted.count == 1, let format = sorted.first {
            return "\(title) \(format.rawValue) is now available in your library."
        }
        return "\(title) is now available in your library."
    }

    public static func needsAttentionBody(title: String, formats: [BookRequestFormat]) -> String {
        let sorted = BookRequestFormat.allCases.filter { formats.contains($0) }
        if sorted.count == 1, let format = sorted.first {
            return "\(title) \(format.rawValue) needs attention."
        }
        return "\(title) needs attention."
    }
}

/// Schedules local notifications. Live impl uses UNUserNotificationCenter; tests use a recorder.
public protocol RequestNotificationScheduling: Sendable {
    func schedule(_ event: RequestNotificationEvent)
}

/// No-op scheduler for platforms / tests that do not deliver system notifications.
public struct NoOpRequestNotificationScheduler: RequestNotificationScheduling {
    public init() {}
    public func schedule(_ event: RequestNotificationEvent) {
        _ = event
    }
}

/// Records scheduled events for unit tests — never touches the system notification center.
public final class RecordingRequestNotificationScheduler: RequestNotificationScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [RequestNotificationEvent] = []

    public init() {}

    public var events: [RequestNotificationEvent] {
        lock.lock()
        defer { lock.unlock() }
        return _events
    }

    public func schedule(_ event: RequestNotificationEvent) {
        lock.lock()
        _events.append(event)
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        _events.removeAll()
        lock.unlock()
    }
}
