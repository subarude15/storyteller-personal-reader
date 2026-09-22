//
//  TorBoxClient.swift
//  SilveranKit
//
//  TorBox torrents API (`https://api.torbox.app/v1/api/...`).
//  Credentials are never logged. Token query params are redacted in debug output.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct TorBoxHTTP: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public protocol TorBoxTransport: Sendable {
    func send(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        contentType: String?,
        timeout: TimeInterval,
    ) async throws -> TorBoxHTTP
}

public struct LiveTorBoxTransport: TorBoxTransport {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        contentType: String?,
        timeout: TimeInterval,
    ) async throws -> TorBoxHTTP {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        return TorBoxHTTP(status: http?.statusCode ?? 0, body: data)
    }
}

public enum TorBoxConnection: Equatable, Sendable {
    case ok
    case missingAPIKey
    case invalidAPIKey
    case unauthorized
    case rateLimited
    case cannotReachServer
    case timeout
    case invalidResponse
    case serverUnavailable

    public var message: String {
        switch self {
            case .ok: "Connected"
            case .missingAPIKey: "Add a TorBox API key to continue."
            case .invalidAPIKey: "TorBox rejected this API key."
            case .unauthorized: "TorBox denied access with this API key."
            case .rateLimited: "TorBox rate-limited this request. Try again in a moment."
            case .cannotReachServer: "TorBox could not be reached. Check your network connection and try again."
            case .timeout: "The TorBox request timed out."
            case .invalidResponse: "TorBox returned an unexpected response."
            case .serverUnavailable: "TorBox is temporarily unavailable. Try again later."
        }
    }

    public var isOK: Bool { self == .ok }
}

public enum TorBoxClientError: Error, Equatable, Sendable {
    case missingAPIKey
    case invalidAPIKey
    case unauthorized
    case rateLimited
    case cannotReachServer
    case timeout
    case invalidResponse
    case serverUnavailable
    case rejected(String)
    case malformedMagnet

    public var connection: TorBoxConnection {
        switch self {
            case .missingAPIKey: .missingAPIKey
            case .invalidAPIKey: .invalidAPIKey
            case .unauthorized: .unauthorized
            case .rateLimited: .rateLimited
            case .cannotReachServer: .cannotReachServer
            case .timeout: .timeout
            case .invalidResponse: .invalidResponse
            case .serverUnavailable: .serverUnavailable
            case .rejected, .malformedMagnet: .invalidResponse
        }
    }

    public var message: String {
        switch self {
            case .missingAPIKey: TorBoxConnection.missingAPIKey.message
            case .invalidAPIKey: TorBoxConnection.invalidAPIKey.message
            case .unauthorized: TorBoxConnection.unauthorized.message
            case .rateLimited: TorBoxConnection.rateLimited.message
            case .cannotReachServer: TorBoxConnection.cannotReachServer.message
            case .timeout: TorBoxConnection.timeout.message
            case .invalidResponse: TorBoxConnection.invalidResponse.message
            case .serverUnavailable: TorBoxConnection.serverUnavailable.message
            case .rejected(let detail):
                detail.isEmpty
                    ? "TorBox rejected the request."
                    : detail
            case .malformedMagnet:
                "This magnet link is malformed."
        }
    }

    public var handoff: NASHandoffError {
        switch self {
            case .missingAPIKey, .invalidAPIKey, .unauthorized:
                .authenticationFailed(.torbox)
            case .cannotReachServer:
                .unreachable(.torbox)
            case .timeout:
                .timeout(.torbox)
            case .rateLimited, .invalidResponse, .serverUnavailable, .rejected, .malformedMagnet:
                .rejected(.torbox)
        }
    }
}

public struct TorBoxTorrentFile: Equatable, Sendable, Codable {
    public var id: Int
    public var name: String
    public var size: Int64
    public var mimeType: String

    public init(id: Int, name: String, size: Int64, mimeType: String = "") {
        self.id = id
        self.name = name
        self.size = size
        self.mimeType = mimeType
    }
}

public struct TorBoxTorrentInfo: Equatable, Sendable {
    public var id: Int
    public var name: String
    public var hash: String
    public var authID: String?
    public var downloadState: String
    public var downloadFinished: Bool
    public var downloadPresent: Bool
    public var progress: Double
    public var size: Int64?
    public var files: [TorBoxTorrentFile]

    public var isDownloadReady: Bool {
        downloadPresent || downloadFinished || downloadState.lowercased() == "cached"
            || downloadState.lowercased() == "uploading"
    }

    public init(
        id: Int,
        name: String,
        hash: String,
        authID: String? = nil,
        downloadState: String,
        downloadFinished: Bool,
        downloadPresent: Bool,
        progress: Double,
        size: Int64? = nil,
        files: [TorBoxTorrentFile] = [],
    ) {
        self.id = id
        self.name = name
        self.hash = hash
        self.authID = authID
        self.downloadState = downloadState
        self.downloadFinished = downloadFinished
        self.downloadPresent = downloadPresent
        self.progress = progress
        self.size = size
        self.files = files
    }
}

public struct TorBoxCreateResult: Equatable, Sendable {
    public var torrentID: Int
    public var hash: String?
    public var authID: String?

    public init(torrentID: Int, hash: String? = nil, authID: String? = nil) {
        self.torrentID = torrentID
        self.hash = hash
        self.authID = authID
    }

    public var jobID: String { String(torrentID) }
}

/// Dedicated TorBox API client. Owns auth header construction, decoding, and errors.
public struct TorBoxClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.torbox.app/v1/api")!

    public var transport: any TorBoxTransport
    public var baseURL: URL
    public var timeout: TimeInterval

    public init(
        transport: any TorBoxTransport = LiveTorBoxTransport(),
        baseURL: URL = TorBoxClient.defaultBaseURL,
        timeout: TimeInterval = 20,
    ) {
        self.transport = transport
        self.baseURL = baseURL
        self.timeout = timeout
    }

    public func testConnection(apiKey: String) async -> TorBoxConnection {
        do {
            try await validateAPIKey(apiKey)
            return .ok
        } catch let error as TorBoxClientError {
            return error.connection
        } catch let error as URLError {
            return Self.mapURLError(error).connection
        } catch {
            return .invalidResponse
        }
    }

    public func validateAPIKey(_ apiKey: String) async throws {
        let key = Self.trimmedKey(apiKey)
        guard !key.isEmpty else { throw TorBoxClientError.missingAPIKey }
        debugLog("[TorBox] request started path=user/me")
        let response = try await get(path: "user/me", apiKey: key)
        try throwIfHTTPError(response, fallback: "TorBox authentication failed.")
        let envelope = try TorBoxJSON.envelope(response.body)
        try throwIfEnvelopeAuthFailure(envelope)
        guard envelope.success || (200...299).contains(response.status) else {
            throw TorBoxClientError.rejected(
                envelope.detail.isEmpty ? "TorBox authentication failed." : envelope.detail
            )
        }
        debugLog("[TorBox] connection ok")
    }

    public func addMagnet(apiKey: String, magnet: String, name: String? = nil) async throws
        -> TorBoxCreateResult
    {
        let key = Self.trimmedKey(apiKey)
        guard !key.isEmpty else { throw TorBoxClientError.missingAPIKey }
        let trimmed = magnet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TorBoxClient.isValidMagnet(trimmed) else {
            throw TorBoxClientError.malformedMagnet
        }
        var fields: [String: String] = ["magnet": trimmed]
        if let name, !name.isEmpty { fields["name"] = name }
        debugLog("[TorBox] request started path=torrents/createtorrent kind=magnet")
        let response = try await postMultipart(
            path: "torrents/createtorrent",
            apiKey: key,
            fields: fields,
            file: nil,
        )
        let result = try parseCreateResult(response)
        debugLog("[TorBox] torrent submitted id=\(result.torrentID)")
        return result
    }

    public func addTorrentFile(
        apiKey: String,
        data: Data,
        filename: String,
        name: String? = nil,
    ) async throws -> TorBoxCreateResult {
        let key = Self.trimmedKey(apiKey)
        guard !key.isEmpty else { throw TorBoxClientError.missingAPIKey }
        guard !data.isEmpty else { throw TorBoxClientError.rejected("The .torrent file is empty.") }
        let safeName = ManualDownloadStaging.safeFilename(filename, fallback: "download.torrent")
        var fields: [String: String] = [:]
        if let name, !name.isEmpty { fields["name"] = name }
        debugLog("[TorBox] request started path=torrents/createtorrent kind=file")
        let response = try await postMultipart(
            path: "torrents/createtorrent",
            apiKey: key,
            fields: fields,
            file: (fieldName: "file", filename: safeName, data: data),
        )
        let result = try parseCreateResult(response)
        debugLog("[TorBox] torrent submitted id=\(result.torrentID)")
        return result
    }

    public func getTorrent(apiKey: String, id: String, bypassCache: Bool = true) async throws
        -> TorBoxTorrentInfo
    {
        let key = Self.trimmedKey(apiKey)
        guard !key.isEmpty else { throw TorBoxClientError.missingAPIKey }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("torrents/mylist"),
            resolvingAgainstBaseURL: false,
        )!
        components.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "bypass_cache", value: bypassCache ? "true" : "false"),
        ]
        guard let url = components.url else { throw TorBoxClientError.invalidResponse }
        debugLog("[TorBox] request started path=torrents/mylist id=\(id)")
        let response = try await send(
            url: url,
            method: "GET",
            apiKey: key,
            body: nil,
            contentType: nil,
        )
        try throwIfHTTPError(response, fallback: "Could not load TorBox torrent.")
        let envelope = try TorBoxJSON.envelope(response.body)
        try throwIfEnvelopeAuthFailure(envelope)
        guard envelope.success else {
            throw TorBoxClientError.rejected(
                envelope.detail.isEmpty ? "Could not load TorBox torrent." : envelope.detail
            )
        }
        let dict: [String: Any]
        if let one = envelope.dataDict {
            dict = one
        } else if let first = envelope.dataArray?.first {
            dict = first
        } else {
            throw TorBoxClientError.invalidResponse
        }
        return TorBoxJSON.parseTorrent(dict)
    }

    public func listTorrents(apiKey: String, bypassCache: Bool = false) async throws -> [TorBoxTorrentInfo] {
        let key = Self.trimmedKey(apiKey)
        guard !key.isEmpty else { throw TorBoxClientError.missingAPIKey }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("torrents/mylist"),
            resolvingAgainstBaseURL: false,
        )!
        components.queryItems = [
            URLQueryItem(name: "bypass_cache", value: bypassCache ? "true" : "false"),
        ]
        guard let url = components.url else { throw TorBoxClientError.invalidResponse }
        let response = try await send(
            url: url,
            method: "GET",
            apiKey: key,
            body: nil,
            contentType: nil,
        )
        try throwIfHTTPError(response, fallback: "Could not load TorBox torrents.")
        let envelope = try TorBoxJSON.envelope(response.body)
        try throwIfEnvelopeAuthFailure(envelope)
        guard envelope.success else {
            throw TorBoxClientError.rejected(
                envelope.detail.isEmpty ? "Could not load TorBox torrents." : envelope.detail
            )
        }
        if let array = envelope.dataArray {
            return array.map(TorBoxJSON.parseTorrent)
        }
        if let one = envelope.dataDict {
            return [TorBoxJSON.parseTorrent(one)]
        }
        return []
    }

    public func deleteTorrent(apiKey: String, id: String) async throws {
        let key = Self.trimmedKey(apiKey)
        guard !key.isEmpty else { throw TorBoxClientError.missingAPIKey }
        guard let torrentID = Int(id) else { throw TorBoxClientError.invalidResponse }
        let payload: [String: Any] = [
            "torrent_id": torrentID,
            "operation": "delete",
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        debugLog("[TorBox] request started path=torrents/controltorrent op=delete id=\(id)")
        let response = try await send(
            url: baseURL.appendingPathComponent("torrents/controltorrent"),
            method: "POST",
            apiKey: key,
            body: body,
            contentType: "application/json",
        )
        try throwIfHTTPError(response, fallback: "Could not delete TorBox torrent.")
        let envelope = try TorBoxJSON.envelope(response.body)
        try throwIfEnvelopeAuthFailure(envelope)
        guard envelope.success else {
            throw TorBoxClientError.rejected(
                envelope.detail.isEmpty ? "Could not delete TorBox torrent." : envelope.detail
            )
        }
        debugLog("[TorBox] torrent deleted id=\(id)")
    }

    /// Phase 2 seam: obtain a direct download URL for a TorBox file.
    /// Do not log the returned URL — it may include signed tokens.
    public func requestDownloadURL(apiKey: String, torrentID: Int, fileID: Int) async throws -> URL {
        let key = Self.trimmedKey(apiKey)
        guard !key.isEmpty else { throw TorBoxClientError.missingAPIKey }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("torrents/requestdl"),
            resolvingAgainstBaseURL: false,
        )!
        components.queryItems = [
            URLQueryItem(name: "token", value: key),
            URLQueryItem(name: "torrent_id", value: String(torrentID)),
            URLQueryItem(name: "file_id", value: String(fileID)),
            URLQueryItem(name: "redirect", value: "false"),
        ]
        guard let url = components.url else { throw TorBoxClientError.invalidResponse }
        debugLog(
            "[TorBox] request started path=torrents/requestdl torrent_id=\(torrentID) file_id=\(fileID)"
        )
        // Auth is in the query token — do not also send Bearer (and never log the URL).
        let response = try await transport.send(
            url: url,
            method: "GET",
            headers: [:],
            body: nil,
            contentType: nil,
            timeout: timeout,
        )
        try throwIfHTTPError(response, fallback: "Could not get TorBox download link.")
        let envelope = try TorBoxJSON.envelope(response.body)
        try throwIfEnvelopeAuthFailure(envelope)
        guard envelope.success else {
            throw TorBoxClientError.rejected(
                envelope.detail.isEmpty ? "Could not get TorBox download link." : envelope.detail
            )
        }
        if let link = envelope.dataString, let download = URL(string: link) {
            return download
        }
        if let link = TorBoxJSON.stringValue(envelope.dataDict?["download_url"])
            ?? TorBoxJSON.stringValue(envelope.dataDict?["url"]),
            let download = URL(string: link)
        {
            return download
        }
        throw TorBoxClientError.rejected("TorBox finished but no downloadable file was found.")
    }

    public static func isValidMagnet(_ value: String) -> Bool {
        let lower = value.lowercased()
        guard lower.hasPrefix("magnet:?") else { return false }
        return lower.contains("xt=urn:btih:") || lower.contains("xt=urn:btmh:")
    }

    public static func redactAuthorizationHeader(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.lowercased().hasPrefix("bearer ") {
            return "Bearer ••••••••"
        }
        return "••••••••"
    }

    public static func redactSensitiveURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        if let items = components.queryItems {
            components.queryItems = items.map { item in
                let name = item.name.lowercased()
                if name == "token" || name == "authorization" || name.contains("key") {
                    return URLQueryItem(name: item.name, value: "••••••••")
                }
                return item
            }
        }
        return components.string ?? url.absoluteString
    }

    // MARK: - Internals

    private static func trimmedKey(_ apiKey: String) -> String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func authHeaders(_ apiKey: String) -> [String: String] {
        ["Authorization": "Bearer \(apiKey)"]
    }

    private func get(path: String, apiKey: String) async throws -> TorBoxHTTP {
        try await send(
            url: baseURL.appendingPathComponent(path),
            method: "GET",
            apiKey: apiKey,
            body: nil,
            contentType: nil,
        )
    }

    private func send(
        url: URL,
        method: String,
        apiKey: String,
        body: Data?,
        contentType: String?,
    ) async throws -> TorBoxHTTP {
        do {
            return try await transport.send(
                url: url,
                method: method,
                headers: authHeaders(apiKey),
                body: body,
                contentType: contentType,
                timeout: timeout,
            )
        } catch let error as URLError {
            throw Self.mapURLError(error)
        }
    }

    private func postMultipart(
        path: String,
        apiKey: String,
        fields: [String: String],
        file: (fieldName: String, filename: String, data: Data)?,
    ) async throws -> TorBoxHTTP {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        for (name, value) in fields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append(value.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }
        if let file {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append(
                "Content-Disposition: form-data; name=\"\(file.fieldName)\"; filename=\"\(file.filename)\"\r\n"
                    .data(using: .utf8)!
            )
            body.append("Content-Type: application/x-bittorrent\r\n\r\n".data(using: .utf8)!)
            body.append(file.data)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return try await send(
            url: baseURL.appendingPathComponent(path),
            method: "POST",
            apiKey: apiKey,
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)",
        )
    }

    private func parseCreateResult(_ response: TorBoxHTTP) throws -> TorBoxCreateResult {
        try throwIfHTTPError(response, fallback: "Could not add torrent to TorBox.")
        let envelope = try TorBoxJSON.envelope(response.body)
        try throwIfEnvelopeAuthFailure(envelope)
        if envelope.errorCode == "BOZO_TORRENT" {
            throw TorBoxClientError.malformedMagnet
        }
        guard envelope.success else {
            throw TorBoxClientError.rejected(
                envelope.detail.isEmpty ? "Could not add torrent to TorBox." : envelope.detail
            )
        }
        guard
            let id = TorBoxJSON.intValue(envelope.dataDict?["torrent_id"])
                ?? TorBoxJSON.intValue(envelope.dataDict?["torrentId"])
                ?? TorBoxJSON.intValue(envelope.dataDict?["id"])
        else {
            throw TorBoxClientError.invalidResponse
        }
        return TorBoxCreateResult(
            torrentID: id,
            hash: TorBoxJSON.stringValue(envelope.dataDict?["hash"]),
            authID: TorBoxJSON.stringValue(envelope.dataDict?["auth_id"])
                ?? TorBoxJSON.stringValue(envelope.dataDict?["authId"]),
        )
    }

    private func throwIfHTTPError(_ response: TorBoxHTTP, fallback: String) throws {
        switch response.status {
            case 200...299:
                return
            case 401:
                throw TorBoxClientError.unauthorized
            case 403:
                throw TorBoxClientError.invalidAPIKey
            case 429:
                throw TorBoxClientError.rateLimited
            case 500...599:
                throw TorBoxClientError.serverUnavailable
            case 0:
                throw TorBoxClientError.cannotReachServer
            default:
                if let envelope = try? TorBoxJSON.envelope(response.body) {
                    try throwIfEnvelopeAuthFailure(envelope)
                    if !envelope.detail.isEmpty {
                        throw TorBoxClientError.rejected(envelope.detail)
                    }
                }
                throw TorBoxClientError.rejected(fallback)
        }
    }

    private func throwIfEnvelopeAuthFailure(_ envelope: TorBoxJSON.Envelope) throws {
        let code = (envelope.errorCode ?? "").uppercased()
        if code == "BAD_TOKEN" || code == "NO_AUTH" || code == "AUTH_ERROR" {
            throw TorBoxClientError.invalidAPIKey
        }
    }

    private static func mapURLError(_ error: URLError) -> TorBoxClientError {
        switch error.code {
            case .timedOut:
                return .timeout
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                .cannotConnectToHost, .dnsLookupFailed:
                return .cannotReachServer
            default:
                return .cannotReachServer
        }
    }
}

// MARK: - JSON

enum TorBoxJSON {
    struct Envelope {
        var success: Bool
        var detail: String
        var errorCode: String?
        var dataDict: [String: Any]?
        var dataArray: [[String: Any]]?
        var dataString: String?
    }

    static func envelope(_ data: Data) throws -> Envelope {
        guard !data.isEmpty else {
            throw TorBoxClientError.invalidResponse
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TorBoxClientError.invalidResponse
        }
        let success = (obj["success"] as? Bool) ?? false
        let detail = stringValue(obj["detail"]) ?? ""
        let errorCode: String?
        if obj["error"] is NSNull || obj["error"] == nil {
            errorCode = nil
        } else if let s = obj["error"] as? String {
            errorCode = s
        } else {
            errorCode = String(describing: obj["error"]!)
        }
        var dataDict: [String: Any]?
        var dataArray: [[String: Any]]?
        var dataString: String?
        switch obj["data"] {
            case let dict as [String: Any]:
                dataDict = dict
            case let arr as [[String: Any]]:
                dataArray = arr
            case let arr as [Any]:
                dataArray = arr.compactMap { $0 as? [String: Any] }
            case let s as String:
                dataString = s
            default:
                break
        }
        return Envelope(
            success: success,
            detail: detail,
            errorCode: errorCode,
            dataDict: dataDict,
            dataArray: dataArray,
            dataString: dataString,
        )
    }

    static func parseTorrent(_ dict: [String: Any]) -> TorBoxTorrentInfo {
        let filesRaw = (dict["files"] as? [[String: Any]]) ?? []
        let files = filesRaw.map { file -> TorBoxTorrentFile in
            TorBoxTorrentFile(
                id: intValue(file["id"]) ?? 0,
                name: stringValue(file["name"]) ?? stringValue(file["short_name"]) ?? "file",
                size: Int64(doubleValue(file["size"])),
                mimeType: stringValue(file["mimetype"]) ?? "",
            )
        }
        let size = int64Value(dict["size"]) ?? int64Value(dict["total_size"])
        return TorBoxTorrentInfo(
            id: intValue(dict["id"]) ?? 0,
            name: stringValue(dict["name"]) ?? "",
            hash: stringValue(dict["hash"]) ?? "",
            authID: stringValue(dict["auth_id"]) ?? stringValue(dict["authId"]),
            downloadState: stringValue(dict["download_state"])
                ?? stringValue(dict["downloadState"]) ?? "",
            downloadFinished: boolValue(dict["download_finished"])
                || boolValue(dict["downloadFinished"]),
            downloadPresent: boolValue(dict["download_present"])
                || boolValue(dict["downloadPresent"]),
            progress: doubleValue(dict["progress"]),
            size: size,
            files: files,
        )
    }

    static func stringValue(_ any: Any?) -> String? {
        switch any {
            case let s as String: s
            case let n as NSNumber: n.stringValue
            default: nil
        }
    }

    static func intValue(_ any: Any?) -> Int? {
        switch any {
            case let i as Int: i
            case let n as NSNumber: n.intValue
            case let s as String: Int(s)
            default: nil
        }
    }

    static func int64Value(_ any: Any?) -> Int64? {
        switch any {
            case let i as Int64: i
            case let i as Int: Int64(i)
            case let n as NSNumber: n.int64Value
            case let s as String: Int64(s)
            default: nil
        }
    }

    static func doubleValue(_ any: Any?) -> Double {
        switch any {
            case let d as Double: d
            case let i as Int: Double(i)
            case let n as NSNumber: n.doubleValue
            case let s as String: Double(s) ?? 0
            default: 0
        }
    }

    static func boolValue(_ any: Any?) -> Bool {
        switch any {
            case let b as Bool: b
            case let n as NSNumber: n.boolValue
            case let s as String: ["1", "true", "yes"].contains(s.lowercased())
            default: false
        }
    }
}
