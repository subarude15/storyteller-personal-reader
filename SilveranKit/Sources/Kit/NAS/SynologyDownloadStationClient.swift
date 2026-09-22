//
//  SynologyDownloadStationClient.swift
//  SilveranKit
//
//  Synology Download Station Task API — NAS pulls remote HTTP URLs directly
//  (TorBox Phase 2). Session IDs and source URLs are never logged.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum SynologyDownloadTaskStatus: String, Equatable, Sendable {
    case waiting
    case downloading
    case paused
    case finishing
    case finished
    case hashChecking = "hash_checking"
    case seeding
    case filehostingWaiting = "filehosting_waiting"
    case extracting
    case error
    case unknown

    public var isTerminalSuccess: Bool {
        switch self {
            case .finished, .seeding: true
            case .waiting, .downloading, .paused, .finishing, .hashChecking,
                .filehostingWaiting, .extracting, .error, .unknown:
                false
        }
    }

    public var isTerminalFailure: Bool { self == .error }

    public var isActive: Bool {
        switch self {
            case .waiting, .downloading, .paused, .finishing, .hashChecking,
                .filehostingWaiting, .extracting:
                true
            case .finished, .seeding, .error, .unknown:
                false
        }
    }

    public static func parse(_ raw: String) -> SynologyDownloadTaskStatus {
        SynologyDownloadTaskStatus(rawValue: raw.lowercased()) ?? .unknown
    }
}

public struct SynologyDownloadTaskSnapshot: Equatable, Sendable {
    public var id: String
    public var title: String
    public var size: Int64
    public var status: SynologyDownloadTaskStatus
    public var downloadedBytes: Int64?
    public var destination: String?

    public init(
        id: String,
        title: String,
        size: Int64,
        status: SynologyDownloadTaskStatus,
        downloadedBytes: Int64? = nil,
        destination: String? = nil,
    ) {
        self.id = id
        self.title = title
        self.size = size
        self.status = status
        self.downloadedBytes = downloadedBytes
        self.destination = destination
    }
}

public struct SynologyDownloadStationClient: Sendable {
    public var transport: any SynologyTransport
    public var timeout: TimeInterval

    public init(
        transport: any SynologyTransport = LiveSynologyTransport(),
        timeout: TimeInterval = 30,
    ) {
        self.transport = transport
        self.timeout = timeout
    }

    /// Create an HTTP download task on the NAS. Destination is share-relative
    /// (`media/books/...`) without a leading slash.
    ///
    /// Some DSM builds omit `task_id` in the create response. This method lists
    /// tasks before/after create on the **same session** and recovers the new ID
    /// without consulting signed source URLs.
    @discardableResult
    public func createURLTask(
        baseURL: String,
        username: String,
        password: String,
        sourceURL: URL,
        destination: String,
        expectedFilename: String? = nil,
    ) async throws -> String? {
        let dest = Self.normalizeDestination(destination)
        guard !dest.isEmpty else { throw SynologyClientError.invalidURL }
        let sid = try await login(baseURL: baseURL, username: username, password: password)
        defer { Task { try? await logout(baseURL: baseURL, sid: sid) } }

        let before = try await listTasks(baseURL: baseURL, sid: sid)
        guard let endpoint = Self.taskURL(from: baseURL) else { throw SynologyClientError.invalidURL }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        // Do not put the signed TorBox URL into debug logs — only into the request.
        components?.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.DownloadStation.Task"),
            URLQueryItem(name: "version", value: "1"),
            URLQueryItem(name: "method", value: "create"),
            URLQueryItem(name: "uri", value: sourceURL.absoluteString),
            URLQueryItem(name: "destination", value: dest),
            URLQueryItem(name: "_sid", value: sid),
        ]
        guard let url = components?.url else { throw SynologyClientError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        debugLog("[DownloadStation] create task destination=\(dest)")
        let http = try await send(request)
        try Self.throwIfFailed(http)
        guard let json = Self.json(http.body), json["success"] as? Bool == true else {
            if Self.errorCode(http.body) == 403 || Self.errorCode(http.body) == 401 {
                throw SynologyClientError.authenticationFailed
            }
            throw SynologyClientError.rejected
        }
        if let data = json["data"] as? [String: Any] {
            if let ids = data["task_id"] as? [String], let first = ids.first, !first.isEmpty {
                return first
            }
            if let id = data["task_id"] as? String, !id.isEmpty { return id }
        }
        // DSM returned success without an ID — recover via before/after task list.
        let after = try await listTasks(baseURL: baseURL, sid: sid)
        return Self.identifyCreatedTask(
            before: before,
            after: after,
            destination: dest,
            expectedFilename: expectedFilename,
        )?.id
    }

    public func taskInfo(
        baseURL: String,
        username: String,
        password: String,
        taskIDs: [String],
    ) async throws -> [SynologyDownloadTaskSnapshot] {
        let ids = taskIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !ids.isEmpty else { return [] }
        let sid = try await login(baseURL: baseURL, username: username, password: password)
        defer { Task { try? await logout(baseURL: baseURL, sid: sid) } }
        return try await taskInfo(baseURL: baseURL, sid: sid, taskIDs: ids)
    }

    public func listTasks(
        baseURL: String,
        username: String,
        password: String,
    ) async throws -> [SynologyDownloadTaskSnapshot] {
        let sid = try await login(baseURL: baseURL, username: username, password: password)
        defer { Task { try? await logout(baseURL: baseURL, sid: sid) } }
        return try await listTasks(baseURL: baseURL, sid: sid)
    }

    /// Find an existing Download Station task for a transfer we already started.
    /// Matches destination + expected filename title — never uses signed URLs.
    public func findTask(
        baseURL: String,
        username: String,
        password: String,
        destination: String,
        expectedFilename: String,
        expectedSize: Int64? = nil,
    ) async throws -> SynologyDownloadTaskSnapshot? {
        let dest = Self.normalizeDestination(destination)
        let tasks = try await listTasks(baseURL: baseURL, username: username, password: password)
        return Self.matchTask(
            in: tasks,
            destination: dest,
            expectedFilename: expectedFilename,
            expectedSize: expectedSize,
        )
    }

    /// Pure helper: pick the newly created task from a before/after list diff.
    public static func identifyCreatedTask(
        before: [SynologyDownloadTaskSnapshot],
        after: [SynologyDownloadTaskSnapshot],
        destination: String,
        expectedFilename: String?,
    ) -> SynologyDownloadTaskSnapshot? {
        let beforeIDs = Set(before.map(\.id))
        let created = after.filter { !beforeIDs.contains($0.id) }
        return matchTask(
            in: created,
            destination: normalizeDestination(destination),
            expectedFilename: expectedFilename ?? "",
            expectedSize: nil,
            allowSingleWithoutName: true,
        )
    }

    /// Basename reported by Download Station for the downloaded file, if usable.
    public static func outputFilename(from task: SynologyDownloadTaskSnapshot) -> String? {
        let raw = (task.title as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw != ".", !raw.contains("/") else { return nil }
        let sanitized = NASPathSafety.sanitizeComponent(raw)
        return sanitized.isEmpty ? nil : sanitized
    }

    public static func destinationsMatch(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }
        let a = normalizeDestination(lhs)
        let b = normalizeDestination(rhs)
        if a.isEmpty || b.isEmpty { return false }
        return a == b || a.hasSuffix(b) || b.hasSuffix(a)
    }

    private static func matchTask(
        in tasks: [SynologyDownloadTaskSnapshot],
        destination: String,
        expectedFilename: String,
        expectedSize: Int64?,
        allowSingleWithoutName: Bool = false,
    ) -> SynologyDownloadTaskSnapshot? {
        var candidates = tasks
        if !destination.isEmpty {
            let destFiltered = candidates.filter { destinationsMatch($0.destination, destination) }
            if !destFiltered.isEmpty { candidates = destFiltered }
        }
        let expected = expectedFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        if !expected.isEmpty {
            let exact = candidates.filter {
                (($0.title as NSString).lastPathComponent)
                    .caseInsensitiveCompare(expected) == .orderedSame
            }
            if exact.count == 1 { return exact[0] }
            if exact.count > 1 {
                if let expectedSize, expectedSize > 0 {
                    let sized = exact.filter { $0.size == 0 || $0.size == expectedSize }
                    if sized.count == 1 { return sized[0] }
                }
                return nil
            }
        }
        if allowSingleWithoutName, candidates.count == 1 { return candidates[0] }
        if candidates.count == 1, expected.isEmpty { return candidates[0] }
        if let expectedSize, expectedSize > 0 {
            let sized = candidates.filter { $0.size == expectedSize }
            if sized.count == 1 { return sized[0] }
        }
        return nil
    }

    /// Share-relative destination for Download Station create.
    public static func downloadStationDestination(fromVolumePath raw: String) -> String? {
        switch SynologyPathMapping.resolve(raw) {
            case .failure:
                return nil
            case .success(let mapped):
                var path = mapped.fileStationPath
                if path.hasPrefix("/") { path.removeFirst() }
                return path.isEmpty ? nil : path
        }
    }

    public static func normalizeDestination(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.hasPrefix("/") { path.removeFirst() }
        while path.hasSuffix("/") { path.removeLast() }
        return path
    }

    // MARK: - Auth

    private func listTasks(baseURL: String, sid: String) async throws -> [SynologyDownloadTaskSnapshot] {
        guard let endpoint = Self.taskURL(from: baseURL) else { throw SynologyClientError.invalidURL }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.DownloadStation.Task"),
            URLQueryItem(name: "version", value: "1"),
            URLQueryItem(name: "method", value: "list"),
            URLQueryItem(name: "additional", value: "detail,transfer"),
            URLQueryItem(name: "limit", value: "-1"),
            URLQueryItem(name: "_sid", value: sid),
        ]
        guard let url = components?.url else { throw SynologyClientError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let http = try await send(request)
        try Self.throwIfFailed(http)
        guard let json = Self.json(http.body), json["success"] as? Bool == true else {
            throw SynologyClientError.invalidResponse
        }
        let tasks = (json["data"] as? [String: Any])?["tasks"] as? [[String: Any]] ?? []
        return tasks.compactMap(Self.parseTask)
    }

    private func taskInfo(
        baseURL: String,
        sid: String,
        taskIDs: [String],
    ) async throws -> [SynologyDownloadTaskSnapshot] {
        guard let endpoint = Self.taskURL(from: baseURL) else { throw SynologyClientError.invalidURL }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.DownloadStation.Task"),
            URLQueryItem(name: "version", value: "1"),
            URLQueryItem(name: "method", value: "getinfo"),
            URLQueryItem(name: "id", value: taskIDs.joined(separator: ",")),
            URLQueryItem(name: "additional", value: "detail,transfer"),
            URLQueryItem(name: "_sid", value: sid),
        ]
        guard let url = components?.url else { throw SynologyClientError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let http = try await send(request)
        try Self.throwIfFailed(http)
        guard let json = Self.json(http.body), json["success"] as? Bool == true else {
            throw SynologyClientError.invalidResponse
        }
        let tasks = (json["data"] as? [String: Any])?["tasks"] as? [[String: Any]] ?? []
        return tasks.compactMap(Self.parseTask)
    }

    private func login(baseURL: String, username: String, password: String) async throws -> String {
        guard let endpoint = SynologyFileStationClient.authURL(from: baseURL) else {
            throw SynologyClientError.invalidURL
        }
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = [
            "api": "SYNO.API.Auth",
            "version": "3",
            "method": "login",
            "account": username,
            "passwd": password,
            "session": "DownloadStation",
            "format": "sid",
        ]
        request.httpBody = QBittorrentClient.formBody(fields)
        let http = try await send(request)
        try Self.throwIfFailed(http)
        guard let json = Self.json(http.body), json["success"] as? Bool == true else {
            throw SynologyClientError.authenticationFailed
        }
        let data = json["data"] as? [String: Any]
        guard let sid = data?["sid"] as? String, !sid.isEmpty else {
            throw SynologyClientError.authenticationFailed
        }
        return sid
    }

    private func logout(baseURL: String, sid: String) async throws {
        guard let endpoint = SynologyFileStationClient.authURL(from: baseURL) else { return }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.API.Auth"),
            URLQueryItem(name: "version", value: "3"),
            URLQueryItem(name: "method", value: "logout"),
            URLQueryItem(name: "session", value: "DownloadStation"),
            URLQueryItem(name: "_sid", value: sid),
        ]
        guard let url = components?.url else { return }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        _ = try? await send(request)
    }

    private func send(_ request: URLRequest) async throws -> SynologyHTTP {
        do {
            return try await transport.send(request)
        } catch let error as URLError {
            switch error.code {
                case .timedOut: throw SynologyClientError.timeout
                default: throw SynologyClientError.cannotReachServer
            }
        }
    }

    private static func taskURL(from raw: String) -> URL? {
        SynologyFileStationClient.apiPathURL(from: raw, path: "/webapi/DownloadStation/task.cgi")
            ?? SynologyFileStationClient.entryURL(from: raw)
    }

    private static func parseTask(_ dict: [String: Any]) -> SynologyDownloadTaskSnapshot? {
        guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
        let title = (dict["title"] as? String) ?? ""
        let size = int64(dict["size"]) ?? 0
        let status = SynologyDownloadTaskStatus.parse((dict["status"] as? String) ?? "")
        let additional = dict["additional"] as? [String: Any]
        let transfer = additional?["transfer"] as? [String: Any]
        let detail = additional?["detail"] as? [String: Any]
        let downloaded = int64(transfer?["size_downloaded"])
        let destination = detail?["destination"] as? String
        return SynologyDownloadTaskSnapshot(
            id: id,
            title: title,
            size: size,
            status: status,
            downloadedBytes: downloaded,
            destination: destination,
        )
    }

    private static func int64(_ any: Any?) -> Int64? {
        switch any {
            case let i as Int64: i
            case let i as Int: Int64(i)
            case let n as NSNumber: n.int64Value
            case let s as String: Int64(s)
            default: nil
        }
    }

    private static func throwIfFailed(_ http: SynologyHTTP) throws {
        guard http.status != 0 else { throw SynologyClientError.cannotReachServer }
        guard http.status != 401, http.status != 403 else {
            throw SynologyClientError.authenticationFailed
        }
        guard http.status >= 200, http.status < 500 else {
            throw SynologyClientError.cannotReachServer
        }
    }

    private static func errorCode(_ body: Data) -> Int? {
        ((json(body)?["error"] as? [String: Any])?["code"] as? Int)
    }

    private static func json(_ body: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}
