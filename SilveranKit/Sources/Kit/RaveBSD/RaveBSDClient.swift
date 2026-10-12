//
//  RaveBSDClient.swift
//  SilveranKit
//
//  Native client for self-hosted RaveBSD JSON endpoints. Does not scrape HTML.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RaveBSDHTTPResponse: Sendable {
    public var status: Int
    public var data: Data
    public var contentType: String?

    public init(status: Int, data: Data, contentType: String? = nil) {
        self.status = status
        self.data = data
        self.contentType = contentType
    }
}

public protocol RaveBSDTransport: Sendable {
    func send(_ request: URLRequest) async throws -> RaveBSDHTTPResponse
}

public struct LiveRaveBSDTransport: RaveBSDTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> RaveBSDHTTPResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        return RaveBSDHTTPResponse(
            status: http?.statusCode ?? 0,
            data: data,
            contentType: http?.value(forHTTPHeaderField: "Content-Type"),
        )
    }
}

public enum RaveBSDClientError: Error, Equatable, Sendable {
    case invalidEndpoint(String)
    case unavailable(String)
    case timeout(String)
    case authOrCloudflare(String)
    case unauthorized(String)
    case unsupportedAPIResponse(String)
    case expiredOrUnknownResult(String)
    case emptyQuery
    case cancelled

    public var message: String {
        switch self {
            case .invalidEndpoint(let detail),
                .unavailable(let detail),
                .timeout(let detail),
                .authOrCloudflare(let detail),
                .unauthorized(let detail),
                .unsupportedAPIResponse(let detail),
                .expiredOrUnknownResult(let detail):
                detail
            case .emptyQuery:
                "Enter a title or author to search"
            case .cancelled:
                "Search cancelled"
        }
    }
}

public struct RaveBSDSearchQuery: Equatable, Sendable {
    public var title: String
    public var author: String
    public var freeText: String
    public var mode: RaveBSDMediaMode

    public init(
        title: String = "",
        author: String = "",
        freeText: String = "",
        mode: RaveBSDMediaMode = .ebooks,
    ) {
        self.title = title
        self.author = author
        self.freeText = freeText
        self.mode = mode
    }

    public var hasTerms: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func from(book: ManualSearchBookContext, customQuery: String? = nil) -> RaveBSDSearchQuery {
        let custom = (customQuery ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let mode: RaveBSDMediaMode
        if let requested = book.requestedMediaType {
            mode = RaveBSDMediaMode(mediaType: requested)
        } else {
            mode = .ebooks
        }
        if !custom.isEmpty {
            return RaveBSDSearchQuery(freeText: custom, mode: mode)
        }
        return RaveBSDSearchQuery(
            title: book.title,
            author: book.authorDisplay,
            mode: mode,
        )
    }
}

public struct RaveBSDClient: Sendable {
    public var transport: any RaveBSDTransport
    public var searchTimeout: TimeInterval
    public var probeTimeout: TimeInterval

    public init(
        transport: any RaveBSDTransport = LiveRaveBSDTransport(),
        searchTimeout: TimeInterval = 45,
        probeTimeout: TimeInterval = 6,
    ) {
        self.transport = transport
        self.searchTimeout = searchTimeout
        self.probeTimeout = probeTimeout
    }

    public func testConnection(
        baseURL: String,
        apiKey: String? = nil,
    ) async -> RaveBSDConnectionStatus {
        guard let root = RaveBSDURL.normalizeBase(baseURL) else {
            return .invalidEndpoint(detail: "Enter an http or https RaveBSD URL")
        }
        let host = ServiceHealthURLSanitizer.sanitize(root.absoluteString) ?? root.host ?? "host"
        do {
            var request = URLRequest(url: root.appendingPathComponent("health"), timeoutInterval: probeTimeout)
            request.httpMethod = "GET"
            request.setValue("inkamp/ravebsd-health", forHTTPHeaderField: "User-Agent")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            if let apiKey, !apiKey.isEmpty {
                request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
            }
            let http = try await transport.send(request)
            if RaveBSDCloudflare.isChallenge(status: http.status, contentType: http.contentType, data: http.data) {
                return .authOrCloudflare(
                    host: host,
                    detail:
                        "Cloudflare Access or a browser challenge blocked this client. Allow /health and /api/v1 (or /search) through Access, or use the LAN URL on home Wi‑Fi.",
                )
            }
            if http.status == 401 || http.status == 403 {
                return .authOrCloudflare(
                    host: host,
                    detail: "HTTP \(http.status) — authentication or Access policy denied the probe",
                )
            }
            if RaveBSDResponseParsing.isHealthOK(http.data, status: http.status) {
                return .success(host: host, detail: "HTTP \(http.status) · /health ok")
            }
            // Some proxies wrap health; accept any JSON settings payload as proof of RaveBSD.
            if (200..<300).contains(http.status),
                let text = String(data: http.data, encoding: .utf8)?.lowercased(),
                text.contains("ok")
            {
                return .success(host: host, detail: "HTTP \(http.status)")
            }
            if (200..<300).contains(http.status) {
                return .unsupportedAPIResponse(
                    host: host,
                    detail: "Host answered HTTP \(http.status) but /health was not RaveBSD’s plain “ok”",
                )
            }
            if http.status == 0 {
                return .unavailable(host: host, detail: "No HTTP response")
            }
            return .unavailable(host: host, detail: "HTTP \(http.status)")
        } catch let error as URLError {
            if error.code == .timedOut {
                return .timeout(host: host, detail: "Timed out waiting for \(host)")
            }
            if error.code == .cancelled {
                return .unavailable(host: host, detail: "Cancelled")
            }
            return .unavailable(host: host, detail: "Could not reach \(host)")
        } catch {
            return .unavailable(host: host, detail: "Could not reach \(host)")
        }
    }

    public func search(
        baseURL: String,
        query: RaveBSDSearchQuery,
        apiKey: String? = nil,
    ) async throws -> RaveBSDSearchResponse {
        guard query.hasTerms else { throw RaveBSDClientError.emptyQuery }
        guard let root = RaveBSDURL.normalizeBase(baseURL) else {
            throw RaveBSDClientError.invalidEndpoint("Invalid RaveBSD URL")
        }

        let useAPIKey = !(apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let path = useAPIKey ? "api/v1/search" : "search/all"
        guard var components = URLComponents(
            url: root.appendingPathComponent(path),
            resolvingAgainstBaseURL: false,
        ) else {
            throw RaveBSDClientError.invalidEndpoint("Could not build search URL")
        }

        var items: [URLQueryItem] = [
            URLQueryItem(name: "mode", value: query.mode.rawValue),
        ]
        let free = query.freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = query.author.trimmingCharacters(in: .whitespacesAndNewlines)
        if !free.isEmpty {
            items.append(URLQueryItem(name: "q", value: free))
        } else {
            if !title.isEmpty { items.append(URLQueryItem(name: "title", value: title)) }
            if !author.isEmpty { items.append(URLQueryItem(name: "author", value: author)) }
        }
        components.queryItems = items
        guard let url = components.url else {
            throw RaveBSDClientError.invalidEndpoint("Could not build search URL")
        }

        var request = URLRequest(url: url, timeoutInterval: searchTimeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("inkamp/ravebsd-search", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if useAPIKey, let apiKey {
            request.setValue(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "X-API-Key")
        }

        let http = try await perform(request)
        if http.status == 401 {
            throw RaveBSDClientError.unauthorized("Missing or invalid X-API-Key")
        }
        if http.status == 403 {
            throw RaveBSDClientError.authOrCloudflare(
                "Authentication or Access policy denied the search (HTTP 403)"
            )
        }
        if !(200..<300).contains(http.status) {
            if let message = Self.errorMessage(from: http.data), !message.isEmpty {
                throw RaveBSDClientError.unsupportedAPIResponse(message)
            }
            throw RaveBSDClientError.unavailable("Search failed (HTTP \(http.status))")
        }
        let parsed = try RaveBSDResponseParsing.search(data: http.data)
        let stamped = parsed.results.map { row -> RaveBSDSearchResult in
            var copy = row
            copy.searchMode = query.mode
            return copy
        }
        let filtered = RaveBSDResultFiltering.matching(stamped, mode: query.mode)
        return RaveBSDSearchResponse(
            source: parsed.source,
            results: RaveBSDResultFiltering.deduplicated(filtered),
            meta: parsed.meta,
        )
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let text = (object["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }

    public func resolve(
        baseURL: String,
        id: String,
    ) async throws -> RaveBSDResolveResponse {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("local-") else {
            throw RaveBSDClientError.expiredOrUnknownResult("This result has no server id to resolve")
        }
        guard let root = RaveBSDURL.normalizeBase(baseURL) else {
            throw RaveBSDClientError.invalidEndpoint("Invalid RaveBSD URL")
        }
        guard var components = URLComponents(
            url: root.appendingPathComponent("resolve"),
            resolvingAgainstBaseURL: false,
        ) else {
            throw RaveBSDClientError.invalidEndpoint("Could not build resolve URL")
        }
        components.queryItems = [URLQueryItem(name: "id", value: trimmed)]
        guard let url = components.url else {
            throw RaveBSDClientError.invalidEndpoint("Could not build resolve URL")
        }
        var request = URLRequest(url: url, timeoutInterval: probeTimeout + 10)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("inkamp/ravebsd-resolve", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let http = try await perform(request)
        if http.status == 404 {
            throw RaveBSDClientError.expiredOrUnknownResult("Unknown or expired result")
        }
        return try RaveBSDResponseParsing.resolve(data: http.data)
    }

    public func downloadTorrent(
        baseURL: String,
        id: String,
    ) async throws -> Data {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("local-") else {
            throw RaveBSDClientError.expiredOrUnknownResult("This result has no torrent id")
        }
        guard let root = RaveBSDURL.normalizeBase(baseURL) else {
            throw RaveBSDClientError.invalidEndpoint("Invalid RaveBSD URL")
        }
        guard var components = URLComponents(
            url: root.appendingPathComponent("torrent"),
            resolvingAgainstBaseURL: false,
        ) else {
            throw RaveBSDClientError.invalidEndpoint("Could not build torrent URL")
        }
        components.queryItems = [URLQueryItem(name: "id", value: trimmed)]
        guard let url = components.url else {
            throw RaveBSDClientError.invalidEndpoint("Could not build torrent URL")
        }
        var request = URLRequest(url: url, timeoutInterval: probeTimeout + 15)
        request.httpMethod = "GET"
        request.setValue("inkamp/ravebsd-torrent", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let http = try await perform(request)
        if http.status == 404 {
            throw RaveBSDClientError.expiredOrUnknownResult("No cached torrent file for this result")
        }
        guard (200..<300).contains(http.status), !http.data.isEmpty else {
            throw RaveBSDClientError.unavailable("Torrent download failed (HTTP \(http.status))")
        }
        return http.data
    }

    private func perform(_ request: URLRequest) async throws -> RaveBSDHTTPResponse {
        do {
            let http = try await transport.send(request)
            if RaveBSDCloudflare.isChallenge(
                status: http.status,
                contentType: http.contentType,
                data: http.data,
            ) {
                throw RaveBSDClientError.authOrCloudflare(
                    "Cloudflare Access or a browser challenge blocked this request"
                )
            }
            if http.status == 0 {
                throw RaveBSDClientError.unavailable("No HTTP response")
            }
            return http
        } catch let error as RaveBSDClientError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled { throw RaveBSDClientError.cancelled }
            if error.code == .timedOut {
                throw RaveBSDClientError.timeout("RaveBSD timed out")
            }
            throw RaveBSDClientError.unavailable("Could not reach RaveBSD")
        } catch {
            throw RaveBSDClientError.unavailable("Could not reach RaveBSD")
        }
    }
}

public enum RaveBSDURL {
    public static let defaultLocal = "http://192.168.1.2:8686"
    public static let defaultRemote = "https://rave.punkandrally.com"

    public static func normalizeBase(_ raw: String) -> URL? {
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
}

enum RaveBSDCloudflare {
    static func isChallenge(status: Int, contentType: String?, data: Data) -> Bool {
        if status == 403 || status == 503 || (200..<600).contains(status) {
            let type = (contentType ?? "").lowercased()
            guard type.contains("text/html") || type.isEmpty,
                let text = String(data: data, encoding: .utf8)?.lowercased()
            else { return false }
            return text.contains("challenges.cloudflare.com")
                || text.contains("just a moment")
                || text.contains("cf-browser-verification")
                || text.contains("cloudflare access")
        }
        return false
    }
}
