import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Live POST to Deluge WebUI `/json`. Cookie jar is per-call via the cookie header.
public struct LiveDelugeTransport: DelugeTransport {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(
        url: URL,
        method: String,
        body: Data,
        cookie: String?,
        timeout: TimeInterval,
    ) async throws -> DelugeHTTP {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let cookie, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let setCookie = http?.value(forHTTPHeaderField: "Set-Cookie")
        return DelugeHTTP(status: status, body: data, setCookie: setCookie)
    }
}

/// Read-only Deluge WebUI JSON-RPC client (`/json`). Never mutates torrents.
public struct DelugeWebClient: Sendable {
    public var transport: any DelugeTransport
    public var timeout: TimeInterval

    public init(
        transport: any DelugeTransport = LiveDelugeTransport(),
        timeout: TimeInterval = 12,
    ) {
        self.transport = transport
        self.timeout = timeout
    }

    public func testConnection(baseURL: String, password: String) async -> DelugeConnection {
        do {
            _ = try await authenticateAndList(baseURL: baseURL, password: password)
            return .ok
        } catch let error as DelugeClientError {
            return error.connection
        } catch let error as URLError {
            switch error.code {
                case .timedOut: return .timeout
                case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed,
                    .notConnectedToInternet:
                    return .cannotReachServer
                default: return .cannotReachServer
            }
        } catch {
            return .invalidResponse
        }
    }

    public func fetchTorrentIndex(baseURL: String, password: String, now: Date = Date()) async
        -> Result<DelugeTorrentIndex, DelugeClientError>
    {
        do {
            let torrents = try await authenticateAndList(baseURL: baseURL, password: password)
            return .success(DelugeTorrentIndex(torrents: torrents, fetchedAt: now))
        } catch let error as DelugeClientError {
            return .failure(error)
        } catch let error as URLError {
            switch error.code {
                case .timedOut: return .failure(.timeout)
                default: return .failure(.cannotReachServer)
            }
        } catch {
            return .failure(.invalidResponse)
        }
    }

    public func addMagnet(
        baseURL: String,
        password: String,
        uri: String,
        downloadLocation: String,
        start: Bool,
    ) async throws -> String? {
        let session = try await authenticate(baseURL: baseURL, password: password)
        return try await add(
            session: session,
            method: "core.add_torrent_magnet",
            source: uri,
            downloadLocation: downloadLocation,
            start: start,
        )
    }

    public func addTorrentURL(
        baseURL: String,
        password: String,
        url: String,
        downloadLocation: String,
        start: Bool,
    ) async throws -> String? {
        let session = try await authenticate(baseURL: baseURL, password: password)
        return try await add(
            session: session,
            method: "core.add_torrent_url",
            source: url,
            downloadLocation: downloadLocation,
            start: start,
        )
    }

    // MARK: - Session

    private struct Session {
        var endpoint: URL
        var cookie: String
    }

    private func authenticate(baseURL: String, password: String) async throws -> Session {
        guard let endpoint = Self.jsonEndpoint(from: baseURL) else {
            throw DelugeClientError.invalidURL
        }
        var cookie = try await login(endpoint: endpoint, password: password)
        try await ensureDaemonConnected(endpoint: endpoint, cookie: &cookie)
        return Session(endpoint: endpoint, cookie: cookie)
    }

    private func authenticateAndList(baseURL: String, password: String) async throws
        -> [DelugeTorrentSnapshot]
    {
        let session = try await authenticate(baseURL: baseURL, password: password)
        return try await listTorrents(endpoint: session.endpoint, cookie: session.cookie)
    }

    private func add(
        session: Session,
        method: String,
        source: String,
        downloadLocation: String,
        start: Bool,
    ) async throws -> String? {
        let options: [String: Any] = [
            "download_location": downloadLocation,
            "add_paused": !start,
        ]
        let response = try await rpc(
            endpoint: session.endpoint,
            method: method,
            params: [source, options] as [Any],
            cookie: session.cookie,
            id: 10,
        )
        if response.error != nil {
            throw DelugeClientError.rejected
        }
        if let hash = response.result as? String, !hash.isEmpty {
            return hash
        }
        if response.result == nil {
            throw DelugeClientError.rejected
        }
        return nil
    }

    private func login(endpoint: URL, password: String) async throws -> String {
        let response = try await rpc(
            endpoint: endpoint,
            method: "auth.login",
            params: [password],
            cookie: nil,
            id: 1,
        )
        guard response.status != 401 else { throw DelugeClientError.authenticationFailed }
        guard response.status >= 200, response.status < 300 else {
            throw DelugeClientError.cannotReachServer
        }
        guard let ok = response.result as? Bool else {
            if response.error != nil { throw DelugeClientError.authenticationFailed }
            throw DelugeClientError.invalidResponse
        }
        guard ok else { throw DelugeClientError.authenticationFailed }
        guard let cookie = Self.sessionCookie(from: response.setCookie), !cookie.isEmpty else {
            // Some proxies fold the cookie into subsequent requests; still require a session id.
            throw DelugeClientError.authenticationFailed
        }
        return cookie
    }

    private func ensureDaemonConnected(endpoint: URL, cookie: inout String) async throws {
        let connected = try await rpc(
            endpoint: endpoint,
            method: "web.connected",
            params: [],
            cookie: cookie,
            id: 2,
        )
        if let yes = connected.result as? Bool, yes { return }

        let hosts = try await rpc(
            endpoint: endpoint,
            method: "web.get_hosts",
            params: [],
            cookie: cookie,
            id: 3,
        )
        guard let list = hosts.result as? [[Any]], let first = list.first,
            let hostID = first.first as? String, !hostID.isEmpty
        else {
            throw DelugeClientError.notConnectedToDaemon
        }
        let connect = try await rpc(
            endpoint: endpoint,
            method: "web.connect",
            params: [hostID],
            cookie: cookie,
            id: 4,
        )
        if let updated = Self.sessionCookie(from: connect.setCookie) {
            cookie = updated
        }
        let again = try await rpc(
            endpoint: endpoint,
            method: "web.connected",
            params: [],
            cookie: cookie,
            id: 5,
        )
        guard let yes = again.result as? Bool, yes else {
            throw DelugeClientError.notConnectedToDaemon
        }
    }

    private func listTorrents(endpoint: URL, cookie: String) async throws -> [DelugeTorrentSnapshot] {
        let keys = [
            "name",
            "state",
            "progress",
            "download_payload_rate",
            "upload_payload_rate",
            "eta",
            "save_path",
            "total_size",
            "total_done",
            "time_added",
            "completed_time",
            "tracker_status",
            "message",
            "hash",
            "is_finished",
        ]
        let response = try await rpc(
            endpoint: endpoint,
            method: "core.get_torrents_status",
            params: [[String: Any](), keys] as [Any],
            cookie: cookie,
            id: 6,
        )
        guard let dict = response.result as? [String: Any] else {
            throw DelugeClientError.invalidResponse
        }
        return dict.compactMap { id, value in
            guard let fields = value as? [String: Any] else { return nil }
            return Self.decodeTorrent(id: id, fields: fields)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - RPC

    private struct RPCResponse {
        var result: Any?
        var error: Any?
        var status: Int
        var setCookie: String?
    }

    private func rpc(
        endpoint: URL,
        method: String,
        params: [Any],
        cookie: String?,
        id: Int,
    ) async throws -> RPCResponse {
        let payload: [String: Any] = [
            "method": method,
            "params": params,
            "id": id,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let http: DelugeHTTP
        do {
            http = try await transport.send(
                url: endpoint,
                method: "POST",
                body: body,
                cookie: cookie,
                timeout: timeout,
            )
        } catch let error as URLError {
            switch error.code {
                case .timedOut: throw DelugeClientError.timeout
                default: throw DelugeClientError.cannotReachServer
            }
        }
        guard http.status != 0 else { throw DelugeClientError.cannotReachServer }
        guard http.status != 401, http.status != 403 else {
            throw DelugeClientError.authenticationFailed
        }
        guard http.status >= 200, http.status < 500 else {
            throw DelugeClientError.cannotReachServer
        }
        guard let json = try? JSONSerialization.jsonObject(with: http.body) as? [String: Any]
        else {
            throw DelugeClientError.invalidResponse
        }
        return RPCResponse(
            result: json["result"],
            error: json["error"],
            status: http.status,
            setCookie: http.setCookie,
        )
    }

    // MARK: - Decode

    public static func decodeTorrent(id: String, fields: [String: Any]) -> DelugeTorrentSnapshot? {
        let name = stringValue(fields["name"]) ?? ""
        guard !name.isEmpty else { return nil }
        let hash = stringValue(fields["hash"]) ?? id
        let state = stringValue(fields["state"]) ?? "Unknown"
        let progressRaw = doubleValue(fields["progress"]) ?? 0
        // Deluge reports progress as 0…100.
        let progress = progressRaw > 1.0 ? progressRaw / 100.0 : progressRaw
        let totalSize = int64Value(fields["total_size"])
        let totalDone = int64Value(fields["total_done"])
        let finishedFlag = boolValue(fields["is_finished"])
        let isFinished =
            finishedFlag
            ?? (progress >= 0.999 || (totalSize ?? 0) > 0 && totalDone == totalSize)
        let message = stringValue(fields["message"])
        let tracker = stringValue(fields["tracker_status"])
        let error: String?
        if state.localizedCaseInsensitiveContains("error") {
            error = sanitizedError(message) ?? sanitizedError(tracker) ?? "Deluge reported an error"
        } else if let message, message.localizedCaseInsensitiveContains("error") {
            error = sanitizedError(message)
        } else {
            error = nil
        }
        return DelugeTorrentSnapshot(
            id: hash,
            name: name,
            state: state,
            progress: min(max(progress, 0), 1),
            downloadRate: intValue(fields["download_payload_rate"]),
            uploadRate: intValue(fields["upload_payload_rate"]),
            etaSeconds: intValue(fields["eta"]).flatMap { $0 < 0 ? nil : $0 },
            savePath: stringValue(fields["save_path"]),
            totalSize: totalSize,
            completedSize: totalDone,
            isFinished: isFinished,
            error: error,
            addedAt: dateValue(fields["time_added"]),
            completedAt: dateValue(fields["completed_time"]),
        )
    }

    public static func mapState(_ snapshot: DelugeTorrentSnapshot) -> RequestDownloadStatus {
        if let error = snapshot.error, !error.isEmpty { return .error }
        let state = snapshot.state.lowercased()
        if state.contains("error") { return .error }
        if snapshot.isFinished || state.contains("seeding") {
            return snapshot.progress >= 0.999 || snapshot.isFinished ? .completed : .stalled
        }
        if state.contains("check") { return .checking }
        if state.contains("queued") { return .queued }
        if state.contains("downloading") { return .downloading }
        if state.contains("paused") {
            return snapshot.progress >= 0.999 ? .completed : .stalled
        }
        if state.contains("moving") { return .checking }
        if snapshot.progress > 0, snapshot.progress < 0.999 { return .downloading }
        return .unknown
    }

    public static func jsonEndpoint(from raw: String) -> URL? {
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
        var path = components.path
        if path.hasSuffix("/json") {
            // already correct
        } else if path.isEmpty || path == "/" {
            path = "/json"
        } else {
            path = path.hasSuffix("/") ? path + "json" : path + "/json"
        }
        components.path = path
        return components.url
    }

    private static func sessionCookie(from setCookie: String?) -> String? {
        guard let setCookie, !setCookie.isEmpty else { return nil }
        // Prefer _session_id; fall back to first cookie pair.
        let parts = setCookie.split(separator: ";").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if let session = parts.first(where: { $0.hasPrefix("_session_id=") }) {
            return String(session)
        }
        return parts.first
    }

    private static func sanitizedError(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count > 160 {
            return String(trimmed.prefix(157)) + "…"
        }
        return trimmed
    }

    private static func stringValue(_ any: Any?) -> String? {
        if let text = any as? String { return text }
        if let number = any as? NSNumber { return number.stringValue }
        return nil
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let value = any as? Double { return value }
        if let value = any as? Int { return Double(value) }
        if let value = any as? NSNumber { return value.doubleValue }
        if let text = any as? String { return Double(text) }
        return nil
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let value = any as? Int { return value }
        if let value = any as? Double { return Int(value) }
        if let value = any as? NSNumber { return value.intValue }
        if let text = any as? String { return Int(text) }
        return nil
    }

    private static func int64Value(_ any: Any?) -> Int64? {
        if let value = any as? Int64 { return value }
        if let value = any as? Int { return Int64(value) }
        if let value = any as? Double { return Int64(value) }
        if let value = any as? NSNumber { return value.int64Value }
        if let text = any as? String { return Int64(text) }
        return nil
    }

    private static func boolValue(_ any: Any?) -> Bool? {
        if let value = any as? Bool { return value }
        if let value = any as? NSNumber { return value.boolValue }
        return nil
    }

    private static func dateValue(_ any: Any?) -> Date? {
        guard let seconds = doubleValue(any), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
