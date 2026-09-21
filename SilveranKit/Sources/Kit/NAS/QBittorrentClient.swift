//
//  QBittorrentClient.swift
//  SilveranKit
//
//  Minimal qBittorrent WebAPI v2 client. The phone never downloads the
//  torrent body; magnets and torrent URLs are handed to the NAS.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct QBittorrentHTTP: Sendable {
    public var status: Int
    public var body: Data
    public var setCookie: String?

    public init(status: Int, body: Data, setCookie: String? = nil) {
        self.status = status
        self.body = body
        self.setCookie = setCookie
    }
}

public protocol QBittorrentTransport: Sendable {
    func send(
        url: URL,
        method: String,
        body: Data?,
        contentType: String?,
        cookie: String?,
        timeout: TimeInterval,
    ) async throws -> QBittorrentHTTP
}

public struct LiveQBittorrentTransport: QBittorrentTransport {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(
        url: URL,
        method: String,
        body: Data?,
        contentType: String?,
        cookie: String?,
        timeout: TimeInterval,
    ) async throws -> QBittorrentHTTP {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let cookie, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        return QBittorrentHTTP(
            status: http?.statusCode ?? 0,
            body: data,
            setCookie: http?.value(forHTTPHeaderField: "Set-Cookie"),
        )
    }
}

public enum QBittorrentConnection: Equatable, Sendable {
    case ok
    case cannotReachServer
    case authenticationFailed
    case timeout
    case invalidResponse
    case invalidURL

    public var message: String {
        switch self {
            case .ok: "Connected"
            case .cannotReachServer: "Cannot reach server"
            case .authenticationFailed: "Authentication failed"
            case .timeout: "Timed out"
            case .invalidResponse: "Invalid server response"
            case .invalidURL: "Invalid URL"
        }
    }
}

public enum QBittorrentClientError: Error, Equatable, Sendable {
    case invalidURL
    case cannotReachServer
    case authenticationFailed
    case timeout
    case invalidResponse
    case rejected

    public var connection: QBittorrentConnection {
        switch self {
            case .invalidURL: .invalidURL
            case .cannotReachServer: .cannotReachServer
            case .authenticationFailed: .authenticationFailed
            case .timeout: .timeout
            case .invalidResponse: .invalidResponse
            case .rejected: .invalidResponse
        }
    }

    public var handoff: NASHandoffError {
        switch self {
            case .invalidURL: .invalidURL(.qbittorrent)
            case .cannotReachServer: .unreachable(.qbittorrent)
            case .authenticationFailed: .authenticationFailed(.qbittorrent)
            case .timeout: .timeout(.qbittorrent)
            case .invalidResponse, .rejected: .rejected(.qbittorrent)
        }
    }
}

public struct QBittorrentAddResult: Equatable, Sendable {
    public var jobID: String?

    public init(jobID: String? = nil) {
        self.jobID = jobID
    }
}

public struct QBittorrentClient: Sendable {
    public var transport: any QBittorrentTransport
    public var timeout: TimeInterval

    public init(
        transport: any QBittorrentTransport = LiveQBittorrentTransport(),
        timeout: TimeInterval = 12,
    ) {
        self.transport = transport
        self.timeout = timeout
    }

    public func testConnection(baseURL: String, username: String, password: String) async
        -> QBittorrentConnection
    {
        do {
            _ = try await login(baseURL: baseURL, username: username, password: password)
            return .ok
        } catch let error as QBittorrentClientError {
            return error.connection
        } catch let error as URLError {
            return Self.mapURLError(error)
        } catch {
            return .invalidResponse
        }
    }

    public func addMagnet(
        baseURL: String,
        username: String,
        password: String,
        uri: String,
        savePath: String,
        start: Bool,
    ) async throws -> QBittorrentAddResult {
        try await addURLs(
            baseURL: baseURL,
            username: username,
            password: password,
            urls: uri,
            savePath: savePath,
            start: start,
        )
    }

    public func addTorrentURL(
        baseURL: String,
        username: String,
        password: String,
        url: String,
        savePath: String,
        start: Bool,
    ) async throws -> QBittorrentAddResult {
        try await addURLs(
            baseURL: baseURL,
            username: username,
            password: password,
            urls: url,
            savePath: savePath,
            start: start,
        )
    }

    private func addURLs(
        baseURL: String,
        username: String,
        password: String,
        urls: String,
        savePath: String,
        start: Bool,
    ) async throws -> QBittorrentAddResult {
        let cookie = try await login(baseURL: baseURL, username: username, password: password)
        guard let endpoint = Self.apiURL(from: baseURL, path: "torrents/add") else {
            throw QBittorrentClientError.invalidURL
        }
        let fields = [
            "urls": urls,
            "savepath": savePath,
            "paused": start ? "false" : "true",
        ]
        let http = try await postForm(url: endpoint, fields: fields, cookie: cookie)
        try Self.throwIfHTTPFailed(http)
        let body = String(data: http.body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if body.caseInsensitiveCompare("Fails.") == .orderedSame {
            throw QBittorrentClientError.rejected
        }
        if !body.isEmpty, !Self.isOK(body) {
            throw QBittorrentClientError.rejected
        }
        return QBittorrentAddResult()
    }

    private func login(baseURL: String, username: String, password: String) async throws -> String {
        guard let endpoint = Self.apiURL(from: baseURL, path: "auth/login") else {
            throw QBittorrentClientError.invalidURL
        }
        let http = try await postForm(
            url: endpoint,
            fields: [
                "username": username,
                "password": password,
            ],
            cookie: nil,
        )
        if http.status == 401 || http.status == 403 {
            throw QBittorrentClientError.authenticationFailed
        }
        try Self.throwIfHTTPFailed(http)
        let body = String(data: http.body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if body.caseInsensitiveCompare("Fails.") == .orderedSame {
            throw QBittorrentClientError.authenticationFailed
        }
        guard Self.isOK(body) else {
            throw QBittorrentClientError.invalidResponse
        }
        guard let cookie = Self.sessionCookie(from: http.setCookie), !cookie.isEmpty else {
            throw QBittorrentClientError.authenticationFailed
        }
        return cookie
    }

    private func postForm(url: URL, fields: [String: String], cookie: String?) async throws
        -> QBittorrentHTTP
    {
        let body = Self.formBody(fields)
        do {
            return try await transport.send(
                url: url,
                method: "POST",
                body: body,
                contentType: "application/x-www-form-urlencoded",
                cookie: cookie,
                timeout: timeout,
            )
        } catch let error as URLError {
            throw Self.clientError(from: error)
        }
    }

    public static func apiURL(from raw: String, path: String) -> URL? {
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
        var existing = components.path
        if existing.hasSuffix("/") { existing.removeLast() }
        if existing.hasSuffix("/api/v2") {
            components.path = existing + "/" + path
        } else if existing.hasSuffix("/api") {
            components.path = existing + "/v2/" + path
        } else {
            components.path = existing + "/api/v2/" + path
        }
        return components.url
    }

    public static func formBody(_ fields: [String: String]) -> Data {
        let pairs = fields.map { key, value in
            "\(encode(key))=\(encode(value))"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    private static func isOK(_ body: String) -> Bool {
        body.caseInsensitiveCompare("Ok.") == .orderedSame
            || body.caseInsensitiveCompare("Ok") == .orderedSame
    }

    private static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func sessionCookie(from setCookie: String?) -> String? {
        guard let setCookie, !setCookie.isEmpty else { return nil }
        let parts = setCookie.split(separator: ";").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if let sid = parts.first(where: { $0.lowercased().hasPrefix("sid=") }) {
            return String(sid)
        }
        return parts.first
    }

    private static func throwIfHTTPFailed(_ http: QBittorrentHTTP) throws {
        guard http.status != 0 else { throw QBittorrentClientError.cannotReachServer }
        guard http.status != 401, http.status != 403 else {
            throw QBittorrentClientError.authenticationFailed
        }
        guard http.status >= 200, http.status < 500 else {
            throw QBittorrentClientError.cannotReachServer
        }
        guard http.status < 400 else { throw QBittorrentClientError.rejected }
    }

    private static func mapURLError(_ error: URLError) -> QBittorrentConnection {
        switch error.code {
            case .timedOut: .timeout
            case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed,
                .notConnectedToInternet:
                .cannotReachServer
            default: .cannotReachServer
        }
    }

    private static func clientError(from error: URLError) -> QBittorrentClientError {
        switch error.code {
            case .timedOut: .timeout
            default: .cannotReachServer
        }
    }
}
