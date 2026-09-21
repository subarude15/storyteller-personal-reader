import Foundation

/// Read-only Deluge WebUI health probe.
public struct DelugeHealthChecker: ServiceHealthChecking {
    public var serviceID: ServiceHealthID { .deluge }
    private let client: DelugeWebClient

    public init(transport: any DelugeTransport = LiveDelugeTransport()) {
        self.client = DelugeWebClient(transport: transport)
    }

    public init(client: DelugeWebClient) {
        self.client = client
    }

    public func check(settings: ServiceHealthSettingsSnapshot) async -> ServiceHealthResult {
        let now = Date()
        let host = ServiceHealthURLSanitizer.sanitize(settings.delugeBaseURL)
        let enabled = settings.delugeEnabled
        let base = settings.delugeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = settings.delugePassword.trimmingCharacters(in: .whitespacesAndNewlines)

        guard enabled, !base.isEmpty, !password.isEmpty else {
            return ServiceHealthResult(
                serviceID: .deluge,
                status: .disabled,
                summary: "Not configured",
                detail: disabledDetail(enabled: enabled, hasBase: !base.isEmpty, hasPassword: !password.isEmpty),
                lastChecked: now,
                sanitizedHost: host,
                isActionableIssue: false,
            )
        }

        let result = await client.fetchTorrentIndex(baseURL: base, password: password, now: now)
        switch result {
            case .success(let index):
                let errorCount = index.torrents.filter {
                    DelugeWebClient.mapState($0) == .error
                }.count
                let stalledCount = index.torrents.filter {
                    DelugeWebClient.mapState($0) == .stalled
                }.count
                if errorCount > 0 {
                    return ServiceHealthResult(
                        serviceID: .deluge,
                        status: .warning,
                        summary: "Connected · \(errorCount) torrent error\(errorCount == 1 ? "" : "s")",
                        detail: "Deluge is reachable, but at least one torrent reported an error",
                        lastChecked: now,
                        lastSuccess: now,
                        sanitizedHost: host,
                        metadata: [
                            "torrents": "\(index.torrents.count)",
                            "errors": "\(errorCount)",
                        ],
                        suggestedAction: "Open Deluge and review torrents that need attention",
                    )
                }
                if stalledCount > 0 {
                    return ServiceHealthResult(
                        serviceID: .deluge,
                        status: .warning,
                        summary: "Connected · \(stalledCount) stalled",
                        detail: "Deluge is reachable, but some torrents look stalled or paused incomplete",
                        lastChecked: now,
                        lastSuccess: now,
                        sanitizedHost: host,
                        metadata: [
                            "torrents": "\(index.torrents.count)",
                            "stalled": "\(stalledCount)",
                        ],
                    )
                }
                return ServiceHealthResult(
                    serviceID: .deluge,
                    status: .healthy,
                    summary: index.torrents.isEmpty
                        ? "Connected"
                        : "Connected · \(index.torrents.count) torrent\(index.torrents.count == 1 ? "" : "s")",
                    detail: "Deluge WebUI authenticated",
                    lastChecked: now,
                    lastSuccess: now,
                    sanitizedHost: host,
                    metadata: ["torrents": "\(index.torrents.count)"],
                )
            case .failure(let error):
                return unavailable(error: error, host: host, now: now)
        }
    }

    private func unavailable(
        error: DelugeClientError,
        host: String?,
        now: Date,
    ) -> ServiceHealthResult {
        let action: String
        switch error {
            case .authenticationFailed:
                action = "Check the Deluge WebUI password in Settings"
            case .invalidURL:
                action = "Check the Deluge WebUI URL in Settings"
            case .notConnectedToDaemon:
                action = "Connect Deluge WebUI to a daemon"
            case .cannotReachServer, .timeout, .invalidResponse, .rejected:
                action = "Check the Deluge URL and that the WebUI is running"
        }
        return ServiceHealthResult(
            serviceID: .deluge,
            status: .unavailable,
            summary: error.connection.message,
            detail: error.detail,
            lastChecked: now,
            sanitizedHost: host,
            lastError: error.detail,
            technicalDetail: error.connection.message,
            suggestedAction: action,
        )
    }

    private func disabledDetail(enabled: Bool, hasBase: Bool, hasPassword: Bool) -> String {
        if !enabled { return "Deluge is turned off" }
        if !hasBase { return "Server URL is missing" }
        if !hasPassword { return "Password is missing" }
        return "Not configured"
    }
}
