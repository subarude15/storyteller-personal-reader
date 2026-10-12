import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct BookSearchLANHTTP: Sendable {
    public var status: Int
    public var data: Data
    public var contentType: String?

    public init(status: Int, data: Data = Data(), contentType: String? = nil) {
        self.status = status
        self.data = data
        self.contentType = contentType
    }
}

public protocol BookSearchLANTransport: Sendable {
    func ping(_ url: URL, timeout: TimeInterval) async throws -> BookSearchLANHTTP
}

public struct LiveBookSearchLANTransport: BookSearchLANTransport {
    public init() {}

    public func ping(_ url: URL, timeout: TimeInterval) async throws -> BookSearchLANHTTP {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("inkamp/book-search-health", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        return BookSearchLANHTTP(
            status: http?.statusCode ?? 0,
            data: data,
            contentType: http?.value(forHTTPHeaderField: "Content-Type"),
        )
    }
}

/// RaveBSD health via `/health`. Tries local first, then remote.
public struct BookSearchLANHealthChecker: ServiceHealthChecking {
    public var serviceID: ServiceHealthID { .bookSearchLAN }
    private let transport: any BookSearchLANTransport

    public init(transport: any BookSearchLANTransport = LiveBookSearchLANTransport()) {
        self.transport = transport
    }

    public func check(settings: ServiceHealthSettingsSnapshot) async -> ServiceHealthResult {
        let now = Date()
        let enabled = settings.bookSearchLANEnabled
        let local = settings.bookSearchLANBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = settings.raveBSDRemoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = ServiceHealthURLSanitizer.sanitize(
            local.isEmpty ? remote : local
        )

        guard enabled else {
            return ServiceHealthResult(
                serviceID: .bookSearchLAN,
                status: .disabled,
                summary: "Not configured",
                detail: "RaveBSD is turned off",
                lastChecked: now,
                sanitizedHost: host,
                isActionableIssue: false,
            )
        }

        let bases = RaveBSDEndpointRouting.orderedBases(localURL: local, remoteURL: remote)
        guard !bases.isEmpty else {
            return ServiceHealthResult(
                serviceID: .bookSearchLAN,
                status: .disabled,
                summary: "Not configured",
                detail: "Local and remote URLs are missing",
                lastChecked: now,
                sanitizedHost: host,
                isActionableIssue: false,
            )
        }

        var lastFailure: (selection: RaveBSDEndpointSelection, technical: String, cloudflare: Bool)?
        for selection in bases {
            guard let root = RaveBSDURL.normalizeBase(selection.baseURL),
                let healthURL = URL(string: root.appendingPathComponent("health").absoluteString)
            else { continue }
            do {
                let http = try await transport.ping(healthURL, timeout: 4)
                let sanitized = ServiceHealthURLSanitizer.sanitize(selection.baseURL)
                if RaveBSDCloudflare.isChallenge(
                    status: http.status,
                    contentType: http.contentType,
                    data: http.data,
                ) {
                    lastFailure = (selection, "cloudflareChallenge", true)
                    // Prefer trying the other endpoint before failing.
                    continue
                }
                if http.status == 401 || http.status == 403 {
                    lastFailure = (selection, "HTTP \(http.status)", false)
                    continue
                }
                if RaveBSDResponseParsing.isHealthOK(http.data, status: http.status) {
                    return ServiceHealthResult(
                        serviceID: .bookSearchLAN,
                        status: .healthy,
                        summary: "Connected · \(selection.route.settingsStatusLabel)",
                        detail: "HTTP \(http.status) · \(selection.route.rawValue)",
                        lastChecked: now,
                        lastSuccess: now,
                        sanitizedHost: sanitized,
                        metadata: [
                            "httpStatus": String(http.status),
                            "route": selection.route.rawValue,
                        ],
                        isActionableIssue: false,
                    )
                }
                if (200..<300).contains(http.status) {
                    lastFailure = (selection, "unsupportedHealthPayload", false)
                } else if http.status > 0 {
                    lastFailure = (selection, "HTTP \(http.status)", false)
                } else {
                    lastFailure = (selection, "emptyStatus", false)
                }
            } catch let error as URLError {
                let code: String
                switch error.code {
                    case .timedOut: code = "URLError timedOut"
                    case .cannotConnectToHost: code = "URLError cannotConnectToHost"
                    case .notConnectedToInternet: code = "URLError notConnectedToInternet"
                    case .networkConnectionLost: code = "URLError networkConnectionLost"
                    default: code = "URLError \(error.code.rawValue)"
                }
                lastFailure = (selection, code, false)
            } catch {
                lastFailure = (selection, "unreachable", false)
            }
        }

        if let lastFailure, lastFailure.cloudflare {
            let sanitized = ServiceHealthURLSanitizer.sanitize(lastFailure.selection.baseURL)
            return ServiceHealthResult(
                serviceID: .bookSearchLAN,
                status: .unavailable,
                summary: "Cloudflare Access blocked",
                detail: "API clients cannot solve the Access challenge",
                lastChecked: now,
                sanitizedHost: sanitized,
                lastError: "Cloudflare Access / browser challenge",
                technicalDetail: lastFailure.technical,
                suggestedAction: "Allow /health and search API paths through Access, or use the local URL on home Wi‑Fi",
                isActionableIssue: true,
            )
        }

        if let lastFailure,
            lastFailure.technical == "HTTP 401" || lastFailure.technical == "HTTP 403"
        {
            let sanitized = ServiceHealthURLSanitizer.sanitize(lastFailure.selection.baseURL)
            return ServiceHealthResult(
                serviceID: .bookSearchLAN,
                status: .unavailable,
                summary: "Auth / Access denied",
                detail: lastFailure.technical,
                lastChecked: now,
                sanitizedHost: sanitized,
                lastError: "Authentication or Access policy denied /health",
                technicalDetail: lastFailure.technical,
                suggestedAction: "Check Cloudflare Access policy or use the local URL on home Wi‑Fi",
                isActionableIssue: true,
            )
        }

        if let lastFailure, lastFailure.technical == "unsupportedHealthPayload" {
            let sanitized = ServiceHealthURLSanitizer.sanitize(lastFailure.selection.baseURL)
            return ServiceHealthResult(
                serviceID: .bookSearchLAN,
                status: .warning,
                summary: "Unsupported API response",
                detail: "Host answered, but /health was not RaveBSD’s plain “ok”",
                lastChecked: now,
                sanitizedHost: sanitized,
                lastError: "Unexpected /health payload",
                technicalDetail: lastFailure.technical,
                suggestedAction: "Confirm the URL points at RaveBSD",
                isActionableIssue: true,
            )
        }

        // Offline from every configured endpoint: informational when only local mattered historically.
        let onlyLocal = bases.count == 1 && bases[0].route == .local
        if onlyLocal {
            return localOnly(host: host, now: now, technical: lastFailure?.technical ?? "unreachable")
        }
        return ServiceHealthResult(
            serviceID: .bookSearchLAN,
            status: .unavailable,
            summary: "Could not reach RaveBSD",
            detail: "Local and remote endpoints failed",
            lastChecked: now,
            sanitizedHost: host,
            lastError: "Could not reach RaveBSD",
            technicalDetail: lastFailure?.technical ?? "unreachable",
            suggestedAction: "Check the local/remote URLs and that RaveBSD is running",
            isActionableIssue: true,
        )
    }

    private func localOnly(host: String?, now: Date, technical: String) -> ServiceHealthResult {
        ServiceHealthResult(
            serviceID: .bookSearchLAN,
            status: .localOnly,
            summary: "Not reachable from this network",
            detail: "Available only on the home LAN",
            lastChecked: now,
            sanitizedHost: host,
            lastError: "Not reachable from this network",
            technicalDetail: technical,
            suggestedAction: nil,
            isActionableIssue: false,
        )
    }
}
