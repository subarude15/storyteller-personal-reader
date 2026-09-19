import Foundation

/// Failures from the user's Shelfarr server. Messages are safe to show in the UI.
/// Tokens are never included.
public enum ShelfarrError: Error, Equatable, Sendable {
    public enum Permission: Equatable, Sendable {
        case readRequests
        case writeRequests
    }

    case invalidConfiguration
    case invalidURL
    case authenticationFailed
    case permissionDenied(Permission)
    case endpointNotFound
    case serverError(statusCode: Int, message: String?)
    case invalidWorkID
    case transportError(String)
    case insecureRedirect
    case invalidResponse

    public var userMessage: String {
        switch self {
            case .invalidConfiguration:
                return "Base URL and token are required."
            case .invalidURL:
                return "Invalid URL. Enter the Shelfarr address, such as http://192.168.1.2:5057 or https://shelfarr.example.com."
            case .authenticationFailed:
                return "Authentication failed. Check your Shelfarr API token."
            case .permissionDenied(let permission):
                switch permission {
                    case .readRequests:
                        return "Connected to Shelfarr, but this token does not have permission to read requests."
                    case .writeRequests:
                        return "Connected to Shelfarr, but this token does not have permission to create requests."
                }
            case .endpointNotFound:
                return "Shelfarr responded, but the API endpoint was not found. Check the server URL and Shelfarr version."
            case .serverError(let statusCode, let message):
                if let message, !message.isEmpty {
                    if statusCode == 422 {
                        return "Shelfarr rejected the request: \(message)"
                    }
                    return "Shelfarr returned HTTP \(statusCode): \(message)"
                }
                return "Shelfarr returned HTTP \(statusCode)."
            case .invalidWorkID:
                return "This title has no Open Library work ID, so Shelfarr cannot request it."
            case .transportError(let message):
                return message
            case .insecureRedirect:
                return "Shelfarr redirected this HTTPS request to an insecure HTTP URL. Check the Shelfarr/Cloudflare proxy configuration."
            case .invalidResponse:
                return "Shelfarr returned a response the app could not read."
        }
    }
}

/// Turns an Open Library identifier from a `ReadingIdea` into Shelfarr's `work_id`.
enum ShelfarrWorkID {
    private static let workKeyExpression: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"OL\d+W"#, options: [.caseInsensitive])
        } catch {
            preconditionFailure("Shelfarr Open Library work-id pattern is invalid")
        }
    }()

    /// `OL893415W`, `/works/OL893415W`, `ol:/works/OL893415W`, and `openlibrary:OL893415W`
    /// all become `openlibrary:OL893415W`. Already-prefixed values are not double-prefixed.
    /// Shelfarr's request API does not accept ISBN or title as a substitute for `work_id`.
    static func openLibrary(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = workKeyExpression.firstMatch(in: trimmed, range: range),
            let swiftRange = Range(match.range, in: trimmed)
        else { return nil }
        return "openlibrary:\(trimmed[swiftRange].uppercased())"
    }
}

/// Shared Shelfarr HTTP client. Builds the base URL, bearer header, and error mapping once
/// for Settings and book requests.
public struct ShelfarrClient: Sendable {
    public var baseURL: String
    public var token: String
    public var session: URLSession

    public init(baseURL: String, token: String, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.token = token
        self.session = session ?? Self.sharedSession
    }

    public static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    /// `GET /api/v1/requests?limit=1` — proves the server is up and the token is accepted.
    public func testConnection() async -> Result<Void, ShelfarrError> {
        let prepared: (URL, String)
        switch prepare() {
            case .success(let value):
                prepared = value
            case .failure(let error):
                return .failure(error)
        }
        guard let url = Self.endpointURL(
            base: prepared.0,
            path: "api/v1/requests",
            query: [URLQueryItem(name: "limit", value: "1")],
        ) else { return .failure(.invalidURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        authorize(&request, token: prepared.1)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        switch await perform(request, permission: .readRequests) {
            case .success:
                return .success(())
            case .failure(let error):
                return .failure(error)
        }
    }

    public func createRequest(
        for idea: ReadingIdea,
        mediums: [ShelfarrMedium],
    ) async -> Result<Void, ShelfarrError> {
        guard !mediums.isEmpty else { return .failure(.invalidConfiguration) }
        let prepared: (URL, String)
        switch prepare() {
            case .success(let value):
                prepared = value
            case .failure(let error):
                return .failure(error)
        }
        guard let body = Self.createRequestBody(idea: idea, mediums: mediums) else {
            return .failure(.invalidWorkID)
        }
        guard let url = Self.endpointURL(base: prepared.0, path: "api/v1/requests") else {
            return .failure(.invalidURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        authorize(&request, token: prepared.1)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        switch await perform(request, permission: .writeRequests) {
            case .success:
                return .success(())
            case .failure(let error):
                return .failure(error)
        }
    }

    static func normalizedBaseURL(from raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        let lower = text.lowercased()
        for suffix in ["/api/v1/requests", "/api/v1"] where lower.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
            while text.hasSuffix("/") { text.removeLast() }
            break
        }
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

    static func endpointURL(base: URL, path: String, query: [URLQueryItem] = []) -> URL? {
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
        guard let url = components.url, !url.absoluteString.contains("//api/") else { return nil }
        return url
    }

    static func isInsecureDowngrade(from original: URL?, to next: URL?) -> Bool {
        original?.scheme?.lowercased() == "https" && next?.scheme?.lowercased() == "http"
    }

    static func isInsecureDowngrade(original: URL?, response: HTTPURLResponse) -> Bool {
        guard (300..<400).contains(response.statusCode) else { return false }
        guard let location = response.value(forHTTPHeaderField: "Location"),
            let next = URL(string: location, relativeTo: original)?.absoluteURL
        else { return false }
        return isInsecureDowngrade(from: original, to: next)
    }

    static func createRequestBody(idea: ReadingIdea, mediums: [ShelfarrMedium]) -> Data? {
        guard let workID = ShelfarrWorkID.openLibrary(from: idea.id) else { return nil }
        let types = mediums.map(\.rawValue)
        let payload = CreatePayload(
            workID: workID,
            bookType: types.count == 1 ? types[0] : nil,
            bookTypes: types.count > 1 ? types : nil,
            title: idea.title,
            author: idea.author,
            externalSource: "inkamp",
            coverURL: idea.coverURL?.absoluteString,
            year: idea.year.flatMap { $0 > 0 ? $0 : nil },
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(payload)
    }

    private func prepare() -> Result<(URL, String), ShelfarrError> {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty, !trimmedToken.isEmpty else {
            return .failure(.invalidConfiguration)
        }
        guard let base = Self.normalizedBaseURL(from: trimmedBase) else {
            return .failure(.invalidURL)
        }
        return .success((base, trimmedToken))
    }

    private func authorize(_ request: inout URLRequest, token: String) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func perform(
        _ request: URLRequest,
        permission: ShelfarrError.Permission,
    ) async -> Result<Void, ShelfarrError> {
        let redirectGuard = ShelfarrRedirectGuard()
        let loaded: (Data, HTTPURLResponse)
        do {
            let (data, response) = try await session.data(for: request, delegate: redirectGuard)
            if redirectGuard.didRefuseInsecureRedirect {
                return .failure(.insecureRedirect)
            }
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            if Self.isInsecureDowngrade(from: request.url, to: http.url)
                || Self.isInsecureDowngrade(original: request.url, response: http)
            {
                return .failure(.insecureRedirect)
            }
            loaded = (data, http)
        } catch {
            if redirectGuard.didRefuseInsecureRedirect {
                return .failure(.insecureRedirect)
            }
            return .failure(Self.transportError(error, original: request.url))
        }

        let status = loaded.1.statusCode
        if (200...299).contains(status) { return .success(()) }
        return .failure(Self.httpError(status: status, data: loaded.0, response: loaded.1, permission: permission))
    }

    static func httpError(
        status: Int,
        data: Data,
        response: HTTPURLResponse,
        permission: ShelfarrError.Permission,
    ) -> ShelfarrError {
        switch status {
            case 401:
                return .authenticationFailed
            case 403:
                if isCloudflareChallenge(response: response, data: data) {
                    return .transportError(
                        "Cloudflare is challenging this request before it reaches Shelfarr. API clients cannot solve that challenge. Allow /api/v1 through the Cloudflare WAF, and keep the public URL on HTTPS."
                    )
                }
                return .permissionDenied(permissionScope(from: data, fallback: permission))
            case 404:
                return .endpointNotFound
            default:
                return .serverError(statusCode: status, message: serverMessage(from: data))
        }
    }

    private static func transportError(_ error: Error, original: URL?) -> ShelfarrError {
        let nsError = error as NSError
        let rawCode = (error as? URLError)?.code.rawValue ?? nsError.code
        let isURLError = error is URLError || nsError.domain == NSURLErrorDomain
        let unreachable = "Could not reach Shelfarr. Check the server address and network connection."
        guard isURLError else { return .transportError(unreachable) }
        if rawCode == URLError.Code.appTransportSecurityRequiresSecureConnection.rawValue {
            if original?.scheme?.lowercased() == "https" {
                return .insecureRedirect
            }
            return .transportError(
                "This Shelfarr URL is not allowed by App Transport Security. Use HTTPS for a public server. Local network HTTP is allowed."
            )
        }
        return .transportError(unreachable)
    }

    private static func isCloudflareChallenge(response: HTTPURLResponse, data: Data) -> Bool {
        if response.value(forHTTPHeaderField: "cf-mitigated")?.localizedCaseInsensitiveContains("challenge") == true {
            return true
        }
        let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard type.contains("text/html"),
            let text = String(data: data, encoding: .utf8)?.lowercased()
        else { return false }
        return text.contains("challenges.cloudflare.com") || text.contains("just a moment")
    }

    private static func permissionScope(
        from data: Data,
        fallback: ShelfarrError.Permission,
    ) -> ShelfarrError.Permission {
        let message = serverMessage(from: data)?.lowercased() ?? ""
        if message.contains("requests:write") { return .writeRequests }
        if message.contains("requests:read") { return .readRequests }
        return fallback
    }

    static func serverMessage(from data: Data) -> String? {
        guard !data.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let raw: String?
        if let errors = object["errors"] as? [String] {
            let joined = errors
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "; ")
            raw = joined.isEmpty ? nil : joined
        } else if let error = object["error"] as? String, !error.isEmpty {
            raw = error
        } else if let message = object["message"] as? String, !message.isEmpty {
            raw = message
        } else {
            raw = nil
        }
        guard let raw else { return nil }
        return redactSecrets(raw)
    }

    /// Shelfarr tokens look like `shf_...`. Never surface one in an error string.
    static func redactSecrets(_ message: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"shf_[A-Za-z0-9_-]+"#) else {
            return message
        }
        let range = NSRange(message.startIndex..., in: message)
        return expression.stringByReplacingMatches(
            in: message,
            range: range,
            withTemplate: "shf_[redacted]",
        )
    }
}

private struct CreatePayload: Encodable {
    let workID: String
    let bookType: String?
    let bookTypes: [String]?
    let title: String
    let author: String
    let externalSource: String
    let coverURL: String?
    let year: Int?

    enum CodingKeys: String, CodingKey {
        case workID = "work_id"
        case bookType = "book_type"
        case bookTypes = "book_types"
        case title
        case author
        case externalSource = "external_source"
        case coverURL = "cover_url"
        case year
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workID, forKey: .workID)
        try container.encodeIfPresent(bookType, forKey: .bookType)
        try container.encodeIfPresent(bookTypes, forKey: .bookTypes)
        try container.encode(title, forKey: .title)
        try container.encode(author, forKey: .author)
        try container.encode(externalSource, forKey: .externalSource)
        try container.encodeIfPresent(coverURL, forKey: .coverURL)
        try container.encodeIfPresent(year, forKey: .year)
    }
}

/// Refuses an HTTPS → HTTP redirect before URLSession follows it into an ATS failure.
/// Internal, not private: URLSession calls this through the Objective-C delegate, which
/// cannot see a private method.
final class ShelfarrRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var refused = false

    var didRefuseInsecureRedirect: Bool {
        lock.lock()
        defer { lock.unlock() }
        return refused
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void,
    ) {
        if ShelfarrClient.isInsecureDowngrade(from: task.originalRequest?.url, to: request.url) {
            lock.lock()
            refused = true
            lock.unlock()
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
