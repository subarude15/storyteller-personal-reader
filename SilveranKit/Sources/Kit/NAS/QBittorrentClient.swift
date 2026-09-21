//
//  QBittorrentClient.swift
//  SilveranKit
//
//  Minimal qBittorrent WebAPI v2 client. Magnets and torrent URLs are handed
//  to the NAS. When WebKit already captured a `.torrent` file, that tiny
//  metadata file is submitted as multipart instead of re-fetching the URL.
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

public struct QBittorrentTorrentSnapshot: Equatable, Sendable {
    public var hash: String
    public var state: String
    public var progress: Double
    public var downloadRate: Int
    public var size: Int64
    public var completed: Int64

    public init(
        hash: String,
        state: String,
        progress: Double,
        downloadRate: Int = 0,
        size: Int64 = 0,
        completed: Int64 = 0,
    ) {
        self.hash = hash
        self.state = state
        self.progress = progress
        self.downloadRate = downloadRate
        self.size = size
        self.completed = completed
    }

    public var liveStatus: ManualTorrentLiveStatus {
        ManualTorrentLiveStatus(
            status: ManualDownloadStatusMapping.qbittorrent(state: state, progress: progress),
            progress: progress,
            downloadRate: downloadRate,
            totalSize: size > 0 ? size : nil,
            completedSize: completed > 0 ? completed : nil,
        )
    }

    public static func parse(_ fields: [String: Any]) -> QBittorrentTorrentSnapshot? {
        let hash = string(fields["hash"]) ?? ""
        guard !hash.isEmpty else { return nil }
        let progressRaw = double(fields["progress"]) ?? 0
        return QBittorrentTorrentSnapshot(
            hash: hash,
            state: string(fields["state"]) ?? "unknown",
            progress: min(max(progressRaw, 0), 1),
            downloadRate: int(fields["dlspeed"]) ?? 0,
            size: int64(fields["size"]) ?? 0,
            completed: int64(fields["completed"]) ?? 0,
        )
    }

    private static func string(_ any: Any?) -> String? {
        if let text = any as? String { return text }
        return nil
    }

    private static func double(_ any: Any?) -> Double? {
        if let value = any as? Double { return value }
        if let value = any as? Int { return Double(value) }
        if let value = any as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func int(_ any: Any?) -> Int? {
        if let value = any as? Int { return value }
        if let value = any as? NSNumber { return value.intValue }
        return nil
    }

    private static func int64(_ any: Any?) -> Int64? {
        if let value = any as? Int64 { return value }
        if let value = any as? Int { return Int64(value) }
        if let value = any as? NSNumber { return value.int64Value }
        return nil
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

    public func torrentStatuses(
        baseURL: String,
        username: String,
        password: String,
        hashes: [String],
    ) async throws -> [String: QBittorrentTorrentSnapshot] {
        let unique = Array(Set(hashes.filter { !$0.isEmpty }))
        guard !unique.isEmpty else { return [:] }
        let cookie = try await login(baseURL: baseURL, username: username, password: password)
        guard var endpoint = Self.apiURL(from: baseURL, path: "torrents/info") else {
            throw QBittorrentClientError.invalidURL
        }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "hashes", value: unique.joined(separator: "|"))]
        guard let url = components?.url else { throw QBittorrentClientError.invalidURL }
        endpoint = url
        let http: QBittorrentHTTP
        do {
            http = try await transport.send(
                url: endpoint,
                method: "GET",
                body: nil,
                contentType: nil,
                cookie: cookie,
                timeout: timeout,
            )
        } catch let error as URLError {
            throw Self.clientError(from: error)
        }
        try Self.throwIfHTTPFailed(http)
        guard let list = try? JSONSerialization.jsonObject(with: http.body) as? [[String: Any]] else {
            throw QBittorrentClientError.invalidResponse
        }
        var result: [String: QBittorrentTorrentSnapshot] = [:]
        for item in list {
            guard let snapshot = QBittorrentTorrentSnapshot.parse(item) else { continue }
            result[snapshot.hash.lowercased()] = snapshot
        }
        return result
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

    public func addTorrentFile(
        baseURL: String,
        username: String,
        password: String,
        fileURL: URL,
        filename: String? = nil,
        savePath: String,
        start: Bool,
    ) async throws -> QBittorrentAddResult {
        let cookie = try await login(baseURL: baseURL, username: username, password: password)
        guard let endpoint = Self.apiURL(from: baseURL, path: "torrents/add") else {
            throw QBittorrentClientError.invalidURL
        }
        let name = ManualDownloadStaging.safeFilename(
            filename ?? fileURL.lastPathComponent,
            fallback: "download.torrent",
        )
        let multipart: (fileURL: URL, contentType: String)
        do {
            multipart = try Self.multipartTorrent(
                localFile: fileURL,
                filename: name,
                savePath: savePath,
                paused: !start,
            )
        } catch {
            throw QBittorrentClientError.invalidResponse
        }
        defer { try? FileManager.default.removeItem(at: multipart.fileURL) }
        let body: Data
        do {
            body = try Data(contentsOf: multipart.fileURL)
        } catch {
            throw QBittorrentClientError.invalidResponse
        }
        let http: QBittorrentHTTP
        do {
            http = try await transport.send(
                url: endpoint,
                method: "POST",
                body: body,
                contentType: multipart.contentType,
                cookie: cookie,
                timeout: timeout,
            )
        } catch let error as URLError {
            throw Self.clientError(from: error)
        }
        try Self.throwIfHTTPFailed(http)
        let text = String(data: http.body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.caseInsensitiveCompare("Fails.") == .orderedSame {
            throw QBittorrentClientError.rejected
        }
        if !text.isEmpty, !Self.isOK(text) {
            throw QBittorrentClientError.rejected
        }
        return QBittorrentAddResult()
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

    /// Builds a file-backed multipart body for `torrents/add` (field name `torrents`).
    public static func multipartTorrent(
        localFile: URL,
        filename: String,
        savePath: String,
        paused: Bool,
    ) throws -> (fileURL: URL, contentType: String) {
        let boundary = "InkampBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("inkamp-qbittorrent-\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temp)
        func write(_ text: String) throws {
            try handle.write(contentsOf: Data(text.utf8))
        }
        func field(_ name: String, _ value: String) throws {
            try write("--\(boundary)\r\n")
            try write("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            try write("\(value)\r\n")
        }
        try field("savepath", savePath)
        try field("paused", paused ? "true" : "false")
        try write("--\(boundary)\r\n")
        try write(
            "Content-Disposition: form-data; name=\"torrents\"; filename=\"\(filename)\"\r\n"
        )
        try write("Content-Type: application/x-bittorrent\r\n\r\n")
        let input = try FileHandle(forReadingFrom: localFile)
        while true {
            let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            try handle.write(contentsOf: chunk)
        }
        try input.close()
        try write("\r\n--\(boundary)--\r\n")
        try handle.close()
        return (temp, "multipart/form-data; boundary=\(boundary)")
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
