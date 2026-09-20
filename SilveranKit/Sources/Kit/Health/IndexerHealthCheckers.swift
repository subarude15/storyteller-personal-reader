import Foundation

enum IndexerHealthCopy {
    static let review = "Open details to review affected indexers"

    static func connected(_ count: Int) -> String {
        "Connected · \(count) \(noun(count))"
    }

    static func failingSummary(_ count: Int) -> String {
        "Connected · \(count) \(noun(count)) failing"
    }

    static func failingDetail(failing: Int, enabled: Int) -> String {
        if enabled > 0, failing == enabled {
            return "All enabled indexers are unavailable"
        }
        if failing == 1 { return "1 enabled indexer is failing" }
        return "\(failing) enabled indexers are failing"
    }

    private static func noun(_ count: Int) -> String {
        count == 1 ? "indexer" : "indexers"
    }
}

func rankedIndexerRows(_ rows: [ServiceIndexerRow]) -> [ServiceIndexerRow] {
    rows.enumerated()
        .sorted { lhs, rhs in
            let left = indexerHealthRank(lhs.element.health)
            let right = indexerHealthRank(rhs.element.health)
            if left != right { return left < right }
            return lhs.offset < rhs.offset
        }
        .map(\.element)
}

private func indexerHealthRank(_ health: ServiceIndexerHealth) -> Int {
    switch health {
        case .failing: 0
        case .unknown: 1
        case .healthy: 2
        case .disabled: 3
    }
}

/// Read-only Prowlarr health. Does not search or edit indexers.
public struct ProwlarrHealthChecker: ServiceHealthChecking {
    public var serviceID: ServiceHealthID { .prowlarr }
    private let client: ProwlarrHealthClient

    public init(transport: any DiagnosticHTTPTransport = LiveDiagnosticHTTPTransport()) {
        self.client = ProwlarrHealthClient(transport: transport)
    }

    public func check(settings: ServiceHealthSettingsSnapshot) async -> ServiceHealthResult {
        let now = Date()
        let host = ServiceHealthURLSanitizer.sanitize(settings.prowlarrBaseURL)
        let base = settings.prowlarrBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = settings.prowlarrAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.prowlarrEnabled, !base.isEmpty, !key.isEmpty else {
            return ServiceHealthResult(
                serviceID: .prowlarr,
                status: .disabled,
                summary: "Not configured",
                detail: missingDetail(
                    enabled: settings.prowlarrEnabled,
                    hasBase: !base.isEmpty,
                    hasKey: !key.isEmpty,
                    name: "Prowlarr",
                ),
                lastChecked: now,
                sanitizedHost: host,
                isActionableIssue: false,
            )
        }

        switch await client.probe(baseURL: base, apiKey: key) {
            case .failure(let error):
                return failureResult(error, host: host, now: now, name: "Prowlarr", id: .prowlarr)
            case .success(let snapshot):
                return success(snapshot, host: host, now: now)
        }
    }

    private func success(
        _ snapshot: ProwlarrHealthSnapshot,
        host: String?,
        now: Date,
    ) -> ServiceHealthResult {
        var metadata: [String: String] = [
            "Indexers": String(snapshot.indexers.count),
            "Enabled": String(snapshot.enabledCount),
        ]
        if let version = snapshot.version { metadata["Version"] = version }
        let indexers = rankedIndexerRows(snapshot.indexers)
        if !snapshot.statusReadable {
            metadata["Failing"] = "Unknown"
            return ServiceHealthResult(
                serviceID: .prowlarr,
                status: .healthy,
                summary: IndexerHealthCopy.connected(snapshot.enabledCount),
                detail: "Live indexer status could not be read",
                lastChecked: now,
                lastSuccess: now,
                sanitizedHost: host,
                metadata: metadata,
                indexers: indexers,
                isActionableIssue: false,
            )
        }
        metadata["Failing"] = String(snapshot.failingCount)
        if snapshot.failingCount > 0 {
            return ServiceHealthResult(
                serviceID: .prowlarr,
                status: .warning,
                summary: IndexerHealthCopy.failingSummary(snapshot.failingCount),
                detail: IndexerHealthCopy.failingDetail(
                    failing: snapshot.failingCount,
                    enabled: snapshot.enabledCount,
                ),
                lastChecked: now,
                lastSuccess: now,
                sanitizedHost: host,
                technicalDetail: "indexerFailures",
                metadata: metadata,
                indexers: indexers,
                suggestedAction: IndexerHealthCopy.review,
            )
        }
        return ServiceHealthResult(
            serviceID: .prowlarr,
            status: .healthy,
            summary: IndexerHealthCopy.connected(snapshot.enabledCount),
            lastChecked: now,
            lastSuccess: now,
            sanitizedHost: host,
            metadata: metadata,
            indexers: indexers,
        )
    }
}

/// Read-only Jackett health. Lists configured indexers only — never searches or tests.
public struct JackettHealthChecker: ServiceHealthChecking {
    public var serviceID: ServiceHealthID { .jackett }
    private let client: JackettHealthClient

    public init(transport: any DiagnosticHTTPTransport = LiveDiagnosticHTTPTransport()) {
        self.client = JackettHealthClient(transport: transport)
    }

    public func check(settings: ServiceHealthSettingsSnapshot) async -> ServiceHealthResult {
        let now = Date()
        let host = ServiceHealthURLSanitizer.sanitize(settings.jackettBaseURL)
        let base = settings.jackettBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = settings.jackettAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.jackettEnabled, !base.isEmpty, !key.isEmpty else {
            return ServiceHealthResult(
                serviceID: .jackett,
                status: .disabled,
                summary: "Not configured",
                detail: missingDetail(
                    enabled: settings.jackettEnabled,
                    hasBase: !base.isEmpty,
                    hasKey: !key.isEmpty,
                    name: "Jackett",
                ),
                lastChecked: now,
                sanitizedHost: host,
                isActionableIssue: false,
            )
        }

        switch await client.probe(baseURL: base, apiKey: key) {
            case .failure(let error):
                return failureResult(error, host: host, now: now, name: "Jackett", id: .jackett)
            case .success(let snapshot):
                return success(snapshot, host: host, now: now)
        }
    }

    private func success(
        _ snapshot: JackettHealthSnapshot,
        host: String?,
        now: Date,
    ) -> ServiceHealthResult {
        let failing = snapshot.indexers.filter { $0.enabled && $0.health == .failing }.count
        let indexers = rankedIndexerRows(snapshot.indexers)
        let metadata: [String: String] = [
            "Indexers": String(snapshot.indexers.count),
            "Configured": String(snapshot.configuredCount),
            "Known failing": String(failing),
        ]
        if failing > 0 {
            return ServiceHealthResult(
                serviceID: .jackett,
                status: .warning,
                summary: IndexerHealthCopy.failingSummary(failing),
                detail: IndexerHealthCopy.failingDetail(
                    failing: failing,
                    enabled: snapshot.configuredCount,
                ),
                lastChecked: now,
                lastSuccess: now,
                sanitizedHost: host,
                technicalDetail: "indexerFailures",
                metadata: metadata,
                indexers: indexers,
                suggestedAction: IndexerHealthCopy.review,
            )
        }
        return ServiceHealthResult(
            serviceID: .jackett,
            status: .healthy,
            summary: IndexerHealthCopy.connected(snapshot.configuredCount),
            lastChecked: now,
            lastSuccess: now,
            sanitizedHost: host,
            metadata: metadata,
            indexers: indexers,
            isActionableIssue: false,
        )
    }
}

private func missingDetail(enabled: Bool, hasBase: Bool, hasKey: Bool, name: String) -> String {
    if !enabled { return "\(name) is turned off" }
    if !hasBase { return "Server URL is missing" }
    if !hasKey { return "API key is missing" }
    return "Not configured"
}

private func failureResult(
    _ error: IndexerProbeFailure,
    host: String?,
    now: Date,
    name: String,
    id: ServiceHealthID,
) -> ServiceHealthResult {
    switch error {
        case .unauthorized:
            return ServiceHealthResult(
                serviceID: id,
                status: .unavailable,
                summary: "Authentication failed",
                detail: "Invalid API key",
                lastChecked: now,
                sanitizedHost: host,
                lastError: "Invalid API key",
                technicalDetail: error.technicalDetail,
                suggestedAction: "Check the \(name) API key in Settings",
            )
        case .timeout, .unreachable, .invalidURL:
            let detail = error == .invalidURL ? "Server URL is not valid" : "Server did not respond"
            return ServiceHealthResult(
                serviceID: id,
                status: .unavailable,
                summary: "Could not reach \(name)",
                detail: detail,
                lastChecked: now,
                sanitizedHost: host,
                lastError: detail,
                technicalDetail: error.technicalDetail,
                suggestedAction: "Check the \(name) URL and that the server is running",
            )
        case .malformed, .httpStatus:
            return ServiceHealthResult(
                serviceID: id,
                status: .warning,
                summary: "Unexpected response",
                detail: "Server responded, but the indexer list could not be read",
                lastChecked: now,
                sanitizedHost: host,
                lastError: error.technicalDetail,
                technicalDetail: error.technicalDetail,
                suggestedAction: "Verify the \(name) URL points at the API",
            )
    }
}
