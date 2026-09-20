import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct BookSearchLANHTTP: Sendable {
    public var status: Int

    public init(status: Int) {
        self.status = status
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
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return BookSearchLANHTTP(status: status)
    }
}

/// Optional LAN-only book search. Off-network unavailability is Local only, never a warning.
public struct BookSearchLANHealthChecker: ServiceHealthChecking {
    public var serviceID: ServiceHealthID { .bookSearchLAN }
    private let transport: any BookSearchLANTransport

    public init(transport: any BookSearchLANTransport = LiveBookSearchLANTransport()) {
        self.transport = transport
    }

    public func check(settings: ServiceHealthSettingsSnapshot) async -> ServiceHealthResult {
        let now = Date()
        let enabled = settings.bookSearchLANEnabled
        let base = settings.bookSearchLANBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = ServiceHealthURLSanitizer.sanitize(base)

        guard enabled else {
            return ServiceHealthResult(
                serviceID: .bookSearchLAN,
                status: .disabled,
                summary: "Not configured",
                detail: "Book Search (LAN-only) is turned off",
                lastChecked: now,
                sanitizedHost: host,
                isActionableIssue: false,
            )
        }

        guard !base.isEmpty, let url = normalizedURL(from: base) else {
            return ServiceHealthResult(
                serviceID: .bookSearchLAN,
                status: .disabled,
                summary: "Not configured",
                detail: "Base URL is missing",
                lastChecked: now,
                sanitizedHost: host,
                isActionableIssue: false,
            )
        }

        do {
            let http = try await transport.ping(url, timeout: 4)
            // Any HTTP response means the host answered on this network.
            if http.status > 0 {
                return ServiceHealthResult(
                    serviceID: .bookSearchLAN,
                    status: .healthy,
                    summary: "Reachable on local network",
                    detail: "HTTP \(http.status)",
                    lastChecked: now,
                    lastSuccess: now,
                    sanitizedHost: host ?? ServiceHealthURLSanitizer.sanitize(url.absoluteString),
                    metadata: ["httpStatus": String(http.status)],
                    isActionableIssue: false,
                )
            }
            return localOnly(host: host, now: now, technical: "emptyStatus")
        } catch let error as URLError {
            let code: String
            switch error.code {
                case .timedOut: code = "URLError timedOut"
                case .cannotConnectToHost: code = "URLError cannotConnectToHost"
                case .notConnectedToInternet: code = "URLError notConnectedToInternet"
                case .networkConnectionLost: code = "URLError networkConnectionLost"
                default: code = "URLError \(error.code.rawValue)"
            }
            return localOnly(host: host, now: now, technical: code)
        } catch {
            return localOnly(host: host, now: now, technical: "unreachable")
        }
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

    private func normalizedURL(from raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        guard var components = URLComponents(string: text),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty
        else { return nil }
        components.scheme = scheme
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        if components.path.isEmpty { components.path = "/" }
        return components.url
    }
}
