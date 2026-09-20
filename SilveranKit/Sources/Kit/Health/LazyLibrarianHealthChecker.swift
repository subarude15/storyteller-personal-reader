import Foundation

/// LazyLibrarian health via the existing client transport. Read-only: getVersion only.
public struct LazyLibrarianHealthChecker: ServiceHealthChecking {
    public var serviceID: ServiceHealthID { .lazyLibrarian }
    private let client: LazyLibrarianClient

    public init(transport: any LazyLibrarianTransport = LiveLazyLibrarianTransport()) {
        self.client = LazyLibrarianClient(transport: transport)
    }

    public init(client: LazyLibrarianClient) {
        self.client = client
    }

    public func check(settings: ServiceHealthSettingsSnapshot) async -> ServiceHealthResult {
        let now = Date()
        let host = ServiceHealthURLSanitizer.sanitize(settings.lazyLibrarianBaseURL)
        let enabled = settings.lazyLibrarianEnabled
        let base = settings.lazyLibrarianBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = settings.lazyLibrarianAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard enabled, !base.isEmpty, !key.isEmpty else {
            return ServiceHealthResult(
                serviceID: .lazyLibrarian,
                status: .disabled,
                summary: "Not configured",
                detail: disabledDetail(enabled: enabled, hasBase: !base.isEmpty, hasKey: !key.isEmpty),
                lastChecked: now,
                sanitizedHost: host,
                isActionableIssue: false,
            )
        }

        let probe = await client.probeHealth(baseURL: base, apiKey: key)
        switch probe.connection {
            case .ok:
                let versionLabel = probe.version.map { "v\($0)" }
                let summary = versionLabel.map { "Connected · \($0)" } ?? "Connected"
                var metadata: [String: String] = [:]
                if let version = probe.version { metadata["version"] = version }
                return ServiceHealthResult(
                    serviceID: .lazyLibrarian,
                    status: .healthy,
                    summary: summary,
                    detail: versionLabel.map { "LazyLibrarian \($0)" },
                    lastChecked: now,
                    lastSuccess: now,
                    sanitizedHost: host,
                    metadata: metadata,
                )
            case .unauthorized:
                return ServiceHealthResult(
                    serviceID: .lazyLibrarian,
                    status: .unavailable,
                    summary: "Authentication failed",
                    detail: "Invalid API key",
                    lastChecked: now,
                    sanitizedHost: host,
                    lastError: "Unauthorized / invalid API key",
                    technicalDetail: "unauthorized",
                    suggestedAction: "Check the LazyLibrarian API key in Settings",
                )
            case .timeout:
                return ServiceHealthResult(
                    serviceID: .lazyLibrarian,
                    status: .unavailable,
                    summary: "Could not reach LazyLibrarian",
                    detail: "Timed out waiting for the server",
                    lastChecked: now,
                    sanitizedHost: host,
                    lastError: LazyLibrarianConnection.timeout.message,
                    technicalDetail: "URLError timedOut",
                    suggestedAction: "Check the server address and network connection",
                )
            case .cannotReachServer:
                return ServiceHealthResult(
                    serviceID: .lazyLibrarian,
                    status: .unavailable,
                    summary: "Could not reach LazyLibrarian",
                    detail: "Server did not respond",
                    lastChecked: now,
                    sanitizedHost: host,
                    lastError: LazyLibrarianConnection.cannotReachServer.message,
                    technicalDetail: "unreachable",
                    suggestedAction: "Check the LazyLibrarian URL and that the server is running",
                )
            case .invalidResponse:
                return ServiceHealthResult(
                    serviceID: .lazyLibrarian,
                    status: .warning,
                    summary: "Unexpected response",
                    detail: "Server responded, but the version payload could not be read",
                    lastChecked: now,
                    sanitizedHost: host,
                    lastError: LazyLibrarianConnection.invalidResponse.message,
                    technicalDetail: "invalidResponse",
                    suggestedAction: "Verify the LazyLibrarian URL points at the API",
                )
        }
    }

    private func disabledDetail(enabled: Bool, hasBase: Bool, hasKey: Bool) -> String {
        if !enabled { return "LazyLibrarian is turned off" }
        if !hasBase { return "Server URL is missing" }
        if !hasKey { return "API key is missing" }
        return "Not configured"
    }
}

public struct LazyLibrarianHealthProbe: Equatable, Sendable {
    public var connection: LazyLibrarianConnection
    public var version: String?

    public init(connection: LazyLibrarianConnection, version: String?) {
        self.connection = connection
        self.version = version
    }
}
