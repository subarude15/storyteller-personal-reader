import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shelfarr health via `ShelfarrClient.testConnection()` — read-only GET /api/v1/requests?limit=1.
public struct ShelfarrHealthChecker: ServiceHealthChecking {
    public var serviceID: ServiceHealthID { .shelfarr }
    private let session: URLSession

    public init(session: URLSession = ShelfarrClient.sharedSession) {
        self.session = session
    }

    public func check(settings: ServiceHealthSettingsSnapshot) async -> ServiceHealthResult {
        let now = Date()
        let base = settings.shelfarrBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = settings.shelfarrAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = ServiceHealthURLSanitizer.sanitize(base)

        guard !base.isEmpty, !token.isEmpty else {
            return ServiceHealthResult(
                serviceID: .shelfarr,
                status: .disabled,
                summary: "Not configured",
                detail: base.isEmpty ? "Base URL is missing" : "API token is missing",
                lastChecked: now,
                sanitizedHost: host,
                isActionableIssue: false,
            )
        }

        let client = ShelfarrClient(baseURL: base, token: token, session: session)
        switch await client.testConnection() {
            case .success:
                return ServiceHealthResult(
                    serviceID: .shelfarr,
                    status: .healthy,
                    summary: "Connected",
                    detail: "Requests API reachable",
                    lastChecked: now,
                    lastSuccess: now,
                    sanitizedHost: host,
                )
            case .failure(let error):
                return mapError(error, host: host, now: now)
        }
    }

    private func mapError(
        _ error: ShelfarrError,
        host: String?,
        now: Date,
    ) -> ServiceHealthResult {
        switch error {
            case .invalidConfiguration:
                return ServiceHealthResult(
                    serviceID: .shelfarr,
                    status: .disabled,
                    summary: "Not configured",
                    detail: error.userMessage,
                    lastChecked: now,
                    sanitizedHost: host,
                    lastError: error.userMessage,
                    technicalDetail: "invalidConfiguration",
                    isActionableIssue: false,
                )
            case .invalidURL:
                return ServiceHealthResult(
                    serviceID: .shelfarr,
                    status: .unavailable,
                    summary: "Invalid URL",
                    detail: error.userMessage,
                    lastChecked: now,
                    sanitizedHost: host,
                    lastError: error.userMessage,
                    technicalDetail: "invalidURL",
                    suggestedAction: "Enter a valid Shelfarr base URL",
                )
            case .authenticationFailed:
                return ServiceHealthResult(
                    serviceID: .shelfarr,
                    status: .unavailable,
                    summary: "Authentication failed",
                    detail: "Token invalid",
                    lastChecked: now,
                    sanitizedHost: host,
                    lastError: error.userMessage,
                    technicalDetail: "authenticationFailed",
                    suggestedAction: "Check API token",
                )
            case .permissionDenied(.readRequests):
                return ServiceHealthResult(
                    serviceID: .shelfarr,
                    status: .warning,
                    summary: "Connected, but token cannot read requests",
                    detail: "Token cannot read requests",
                    lastChecked: now,
                    sanitizedHost: host,
                    lastError: error.userMessage,
                    technicalDetail: "permissionDenied:readRequests",
                    suggestedAction: "Check API token permissions",
                )
            case .permissionDenied(.writeRequests):
                return ServiceHealthResult(
                    serviceID: .shelfarr,
                    status: .warning,
                    summary: "Connected, but token cannot write requests",
                    detail: "Token cannot create requests",
                    lastChecked: now,
                    sanitizedHost: host,
                    lastError: error.userMessage,
                    technicalDetail: "permissionDenied:writeRequests",
                    suggestedAction: "Check API token permissions",
                )
            case .endpointNotFound:
                return ServiceHealthResult(
                    serviceID: .shelfarr,
                    status: .unavailable,
                    summary: "Endpoint not found",
                    detail: error.userMessage,
                    lastChecked: now,
                    sanitizedHost: host,
                    lastError: error.userMessage,
                    technicalDetail: "endpointNotFound",
                    suggestedAction: "Check the server URL and Shelfarr version",
                )
            case .serverError(let statusCode, _):
                return ServiceHealthResult(
                    serviceID: .shelfarr,
                    status: .unavailable,
                    summary: "Server error",
                    detail: error.userMessage,
                    lastChecked: now,
                    sanitizedHost: host,
                    lastError: error.userMessage,
                    technicalDetail: "HTTP \(statusCode)",
                    suggestedAction: "Check Shelfarr server logs",
                )
            case .transportError(let message):
                let isCloudflare = message.localizedCaseInsensitiveContains("Cloudflare")
                let isTimeout = message.localizedCaseInsensitiveContains("timed out")
                return ServiceHealthResult(
                    serviceID: .shelfarr,
                    status: .unavailable,
                    summary: isCloudflare
                        ? "Cloudflare challenge"
                        : "Could not reach Shelfarr",
                    detail: isTimeout ? "Timed out" : (isCloudflare ? message : "Server did not respond"),
                    lastChecked: now,
                    sanitizedHost: host,
                    lastError: message,
                    technicalDetail: isCloudflare
                        ? "cloudflareChallenge"
                        : (isTimeout ? "URLError timedOut" : "unreachable"),
                    suggestedAction: isCloudflare
                        ? "Allow /api/v1 through the Cloudflare WAF"
                        : "Check the server address and network connection",
                )
            case .insecureRedirect:
                return ServiceHealthResult(
                    serviceID: .shelfarr,
                    status: .unavailable,
                    summary: "Insecure redirect",
                    detail: error.userMessage,
                    lastChecked: now,
                    sanitizedHost: host,
                    lastError: error.userMessage,
                    technicalDetail: "insecureRedirect",
                    suggestedAction: "Check the Shelfarr/Cloudflare proxy configuration",
                )
            case .invalidResponse:
                return ServiceHealthResult(
                    serviceID: .shelfarr,
                    status: .warning,
                    summary: "Unexpected response",
                    detail: error.userMessage,
                    lastChecked: now,
                    sanitizedHost: host,
                    lastError: error.userMessage,
                    technicalDetail: "invalidResponse",
                    suggestedAction: "Verify the Shelfarr URL and version",
                )
            case .invalidWorkID:
                // Not expected from a connection test.
                return ServiceHealthResult(
                    serviceID: .shelfarr,
                    status: .warning,
                    summary: "Unexpected response",
                    detail: error.userMessage,
                    lastChecked: now,
                    sanitizedHost: host,
                    lastError: error.userMessage,
                    technicalDetail: "invalidWorkID",
                    suggestedAction: "Retry diagnostics",
                )
        }
    }
}
