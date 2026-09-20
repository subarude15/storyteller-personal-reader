import Foundation

/// High-level health of one backend the reading stack depends on.
public enum ServiceHealthStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case healthy
    case warning
    case unavailable
    case disabled
    case localOnly
    case checking

    public var label: String {
        switch self {
            case .healthy: "Healthy"
            case .warning: "Warning"
            case .unavailable: "Unavailable"
            case .disabled: "Disabled"
            case .localOnly: "Local only"
            case .checking: "Checking"
        }
    }

    public var systemImage: String {
        switch self {
            case .healthy: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .unavailable: "xmark.circle.fill"
            case .disabled: "minus.circle"
            case .localOnly: "house.circle"
            case .checking: "arrow.triangle.2.circlepath"
        }
    }

    /// Counts toward Needs Attention. Disabled and Local only never do.
    public var isActionableIssue: Bool {
        switch self {
            case .warning, .unavailable: true
            case .healthy, .disabled, .localOnly, .checking: false
        }
    }

    public var countsAsHealthy: Bool {
        self == .healthy
    }

    public var countsAsWarning: Bool {
        self == .warning
    }

    public var countsAsUnavailable: Bool {
        self == .unavailable
    }
}

public enum ServiceHealthID: String, Codable, Equatable, Sendable, CaseIterable {
    case lazyLibrarian
    case shelfarr
    case librivox
    case storyteller
    case prowlarr
    case jackett
    case bookSearchLAN

    public var displayName: String {
        switch self {
            case .lazyLibrarian: "LazyLibrarian"
            case .shelfarr: "Shelfarr"
            case .librivox: "LibriVox"
            case .storyteller: "Storyteller"
            case .prowlarr: "Prowlarr"
            case .jackett: "Jackett"
            case .bookSearchLAN: "Book Search (LAN-only)"
        }
    }
}

/// Cached / live result for one service. Never stores secrets.
public struct ServiceHealthResult: Codable, Equatable, Sendable, Identifiable {
    public var id: ServiceHealthID { serviceID }
    public var serviceID: ServiceHealthID
    public var displayName: String
    public var status: ServiceHealthStatus
    /// Short primary line shown on the dashboard row.
    public var summary: String
    /// Secondary detail under the summary.
    public var detail: String?
    public var lastChecked: Date?
    public var lastSuccess: Date?
    /// Sanitized host or base URL (no credentials, no query secrets).
    public var sanitizedHost: String?
    public var lastError: String?
    /// Compact technical code for the detail screen (e.g. URLError timedOut).
    public var technicalDetail: String?
    /// Non-sensitive key/value pairs (version, counts, sync age, …).
    public var metadata: [String: String]
    /// Per-indexer rows for Prowlarr/Jackett. Never includes secrets.
    public var indexers: [ServiceIndexerRow]
    public var suggestedAction: String?
    public var isActionableIssue: Bool

    public init(
        serviceID: ServiceHealthID,
        displayName: String? = nil,
        status: ServiceHealthStatus,
        summary: String,
        detail: String? = nil,
        lastChecked: Date? = nil,
        lastSuccess: Date? = nil,
        sanitizedHost: String? = nil,
        lastError: String? = nil,
        technicalDetail: String? = nil,
        metadata: [String: String] = [:],
        indexers: [ServiceIndexerRow] = [],
        suggestedAction: String? = nil,
        isActionableIssue: Bool? = nil,
    ) {
        self.serviceID = serviceID
        self.displayName = displayName ?? serviceID.displayName
        self.status = status
        self.summary = summary
        self.detail = detail
        self.lastChecked = lastChecked
        self.lastSuccess = lastSuccess
        self.sanitizedHost = sanitizedHost
        self.lastError = lastError
        self.technicalDetail = technicalDetail
        self.metadata = metadata
        self.indexers = indexers
        self.suggestedAction = suggestedAction
        self.isActionableIssue = isActionableIssue ?? status.isActionableIssue
    }

    public static func checking(_ serviceID: ServiceHealthID, previous: ServiceHealthResult? = nil)
        -> ServiceHealthResult
    {
        ServiceHealthResult(
            serviceID: serviceID,
            displayName: previous?.displayName,
            status: .checking,
            summary: "Checking…",
            detail: previous?.detail,
            lastChecked: previous?.lastChecked,
            lastSuccess: previous?.lastSuccess,
            sanitizedHost: previous?.sanitizedHost,
            lastError: previous?.lastError,
            technicalDetail: previous?.technicalDetail,
            metadata: previous?.metadata ?? [:],
            indexers: previous?.indexers ?? [],
            suggestedAction: nil,
            isActionableIssue: false,
        )
    }
}

public struct ServiceHealthAttentionItem: Equatable, Sendable, Identifiable {
    public var id: ServiceHealthID { serviceID }
    public var serviceID: ServiceHealthID
    public var serviceName: String
    public var problem: String
    public var suggestedAction: String

    public init(serviceID: ServiceHealthID, problem: String, suggestedAction: String) {
        self.serviceID = serviceID
        self.serviceName = serviceID.displayName
        self.problem = problem
        self.suggestedAction = suggestedAction
    }

    public init(from result: ServiceHealthResult) {
        self.serviceID = result.serviceID
        self.serviceName = result.displayName
        self.problem = result.detail ?? result.summary
        self.suggestedAction = result.suggestedAction ?? "Open settings and verify this service."
    }
}

public struct ServiceHealthSummary: Equatable, Sendable {
    public var healthy: Int
    public var warnings: Int
    public var unavailable: Int

    public init(healthy: Int, warnings: Int, unavailable: Int) {
        self.healthy = healthy
        self.warnings = warnings
        self.unavailable = unavailable
    }

    public init(results: [ServiceHealthResult]) {
        var healthy = 0
        var warnings = 0
        var unavailable = 0
        for result in results {
            // Skip in-flight rows so summary counts stay honest.
            switch result.status {
                case .healthy: healthy += 1
                case .warning: warnings += 1
                case .unavailable: unavailable += 1
                case .disabled, .localOnly, .checking: break
            }
        }
        self.healthy = healthy
        self.warnings = warnings
        self.unavailable = unavailable
    }
}

public enum ServiceIndexerHealth: String, Codable, Equatable, Sendable {
    case healthy
    case failing
    case disabled
    case unknown

    public var label: String {
        switch self {
            case .healthy: "Healthy"
            case .failing: "Failing"
            case .disabled: "Disabled"
            case .unknown: "Unknown"
        }
    }
}

/// One indexer on the service detail screen. No secrets.
public struct ServiceIndexerRow: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var health: ServiceIndexerHealth
    public var detail: String?

    public init(
        id: String,
        name: String,
        enabled: Bool,
        health: ServiceIndexerHealth,
        detail: String? = nil,
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.health = health
        self.detail = detail
    }
}

public enum ServiceHealthAttention {
    /// Actionable issues only. Disabled optional services and LAN-only off-network are excluded.
    public static func items(from results: [ServiceHealthResult]) -> [ServiceHealthAttentionItem] {
        results
            .filter(\.isActionableIssue)
            .map(ServiceHealthAttentionItem.init(from:))
    }
}

public enum ServiceHealthURLSanitizer {
    /// Host + scheme + port, no userinfo / query / fragment.
    public static func sanitize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        guard var components = URLComponents(string: text),
            let host = components.host, !host.isEmpty
        else {
            return text
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.path = ""
        return components.string ?? "\(components.scheme ?? "http")://\(host)"
    }

    public static func relativeAge(from date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        if seconds < 3600 {
            let minutes = seconds / 60
            return "\(minutes) min ago"
        }
        if seconds < 86_400 {
            let hours = seconds / 3600
            return "\(hours) hr ago"
        }
        let days = seconds / 86_400
        return "\(days) day\(days == 1 ? "" : "s") ago"
    }
}
