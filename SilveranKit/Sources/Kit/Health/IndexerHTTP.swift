import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct DiagnosticHTTPResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public protocol DiagnosticHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> DiagnosticHTTPResponse
}

public struct LiveDiagnosticHTTPTransport: DiagnosticHTTPTransport {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 8) {
        self.timeout = timeout
    }

    public func send(_ request: URLRequest) async throws -> DiagnosticHTTPResponse {
        var copy = request
        copy.timeoutInterval = timeout
        copy.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: copy)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return DiagnosticHTTPResponse(status: status, body: data)
    }
}

public enum IndexerProbeFailure: Equatable, Error, Sendable {
    case invalidURL
    case unauthorized
    case unreachable
    case timeout
    case malformed
    case httpStatus(Int)

    public var technicalDetail: String {
        switch self {
            case .invalidURL: "invalidURL"
            case .unauthorized: "unauthorized"
            case .unreachable: "unreachable"
            case .timeout: "URLError timedOut"
            case .malformed: "malformed"
            case .httpStatus(let code): "HTTP \(code)"
        }
    }
}

enum IndexerSecretRedactor {
    static func redact(_ text: String, secrets: [String]) -> String {
        var result = text
        for secret in secrets {
            let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 4 else { continue }
            result = result.replacingOccurrences(of: trimmed, with: "••••")
            if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                encoded != trimmed
            {
                result = result.replacingOccurrences(of: encoded, with: "••••")
            }
        }
        if let query = try? NSRegularExpression(
            pattern: "(?i)(apikey|api_key|token)=[^&\\s]+"
        ) {
            let range = NSRange(result.startIndex..., in: result)
            result = query.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "$1=••••",
            )
        }
        if let header = try? NSRegularExpression(
            pattern: "(?i)(X-Api-Key|Authorization)\\s*[:=]\\s*\\S+"
        ) {
            let range = NSRange(result.startIndex..., in: result)
            result = header.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "$1 ••••",
            )
        }
        if result.count > 160 {
            result = String(result.prefix(157)) + "…"
        }
        return result
    }
}

enum IndexerEndpoint {
    static func baseURL(from raw: String) -> URL? {
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
        if components.path == "/" { components.path = "" }
        return components.url
    }

    static func url(base: URL, path: String, query: [URLQueryItem] = []) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let extra = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let basePath = components.path
        if basePath.isEmpty || basePath == "/" {
            components.path = "/" + extra
        } else {
            let trimmed = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
            components.path = trimmed + "/" + extra
        }
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }
}
