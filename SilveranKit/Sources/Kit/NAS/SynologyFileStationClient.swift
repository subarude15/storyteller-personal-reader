//
//  SynologyFileStationClient.swift
//  SilveranKit
//
//  DSM File Station HTTP API. Login, upload from a local file, verify
//  size. Session IDs are never persisted or logged.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SynologyHTTP: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public protocol SynologyTransport: Sendable {
    func send(_ request: URLRequest) async throws -> SynologyHTTP
    func upload(request: URLRequest, fileURL: URL) async throws -> SynologyHTTP
}

public struct LiveSynologyTransport: SynologyTransport {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> SynologyHTTP {
        let (data, response) = try await session.data(for: request)
        return SynologyHTTP(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }

    public func upload(request: URLRequest, fileURL: URL) async throws -> SynologyHTTP {
        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        return SynologyHTTP(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}

public enum SynologyConnection: Equatable, Sendable {
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

public enum SynologyClientError: Error, Equatable, Sendable {
    case invalidURL
    case cannotReachServer
    case authenticationFailed
    case timeout
    case invalidResponse
    case rejected
    case verificationFailed

    public var connection: SynologyConnection {
        switch self {
            case .invalidURL: .invalidURL
            case .cannotReachServer: .cannotReachServer
            case .authenticationFailed: .authenticationFailed
            case .timeout: .timeout
            case .invalidResponse, .rejected, .verificationFailed: .invalidResponse
        }
    }

    public var handoff: NASHandoffError {
        switch self {
            case .invalidURL: .invalidURL(.synology)
            case .cannotReachServer: .unreachable(.synology)
            case .authenticationFailed: .authenticationFailed(.synology)
            case .timeout: .timeout(.synology)
            case .invalidResponse, .rejected, .verificationFailed: .uploadRejected
        }
    }
}

public struct SynologyFileStationClient: Sendable {
    public var transport: any SynologyTransport
    public var timeout: TimeInterval

    public init(
        transport: any SynologyTransport = LiveSynologyTransport(),
        timeout: TimeInterval = 30,
    ) {
        self.transport = transport
        self.timeout = timeout
    }

    public func testConnection(baseURL: String, username: String, password: String) async
        -> SynologyConnection
    {
        do {
            let sid = try await login(baseURL: baseURL, username: username, password: password)
            _ = sid
            try? await logout(baseURL: baseURL, sid: sid)
            return .ok
        } catch let error as SynologyClientError {
            return error.connection
        } catch let error as URLError {
            switch error.code {
                case .timedOut: return .timeout
                default: return .cannotReachServer
            }
        } catch {
            return .invalidResponse
        }
    }

    public func upload(
        baseURL: String,
        username: String,
        password: String,
        localFile: URL,
        destination: NASUploadDestination,
    ) async throws -> NASUploadResult {
        let mapped: SynologyFileStationPath
        switch SynologyPathMapping.resolve(destination.volumePath) {
            case .success(let value): mapped = value
            case .failure(.emptyDestination): throw NASHandoffError.emptyDestination
            case .failure: throw NASHandoffError.invalidDestination
        }
        let filename: String
        switch SynologyPathMapping.filePath(directory: destination.volumePath, filename: destination.filename)
        {
            case .success(let remote):
                filename = (remote as NSString).lastPathComponent
            case .failure:
                throw NASHandoffError.invalidDestination
        }
        let sid = try await login(baseURL: baseURL, username: username, password: password)
        defer { Task { try? await logout(baseURL: baseURL, sid: sid) } }

        let localSize = (try? FileManager.default.attributesOfItem(atPath: localFile.path)[.size] as? NSNumber)?
            .int64Value
        let multipart = try Self.multipartFile(
            localFile: localFile,
            filename: filename,
            directory: mapped.fileStationPath,
            sid: sid,
        )
        defer { try? FileManager.default.removeItem(at: multipart.fileURL) }

        guard let endpoint = Self.entryURL(from: baseURL) else { throw SynologyClientError.invalidURL }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "_sid", value: sid)]
        guard let uploadURL = components?.url else { throw SynologyClientError.invalidURL }
        var request = URLRequest(url: uploadURL, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        let http = try await sendUpload(request, fileURL: multipart.fileURL)
        try Self.throwIfFailed(http)
        guard Self.isSuccess(http.body) else { throw SynologyClientError.rejected }

        let remoteFile = mapped.fileStationPath + "/" + filename
        let verifiedSize = try await fileSize(
            baseURL: baseURL,
            sid: sid,
            path: remoteFile,
        )
        if let localSize, let verifiedSize, localSize != verifiedSize {
            throw SynologyClientError.verificationFailed
        }
        return NASUploadResult(
            remotePath: remoteFile,
            byteCount: verifiedSize ?? localSize,
            verified: verifiedSize != nil,
        )
    }

    private func login(baseURL: String, username: String, password: String) async throws -> String {
        guard let endpoint = Self.authURL(from: baseURL) else { throw SynologyClientError.invalidURL }
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = [
            "api": "SYNO.API.Auth",
            "version": "3",
            "method": "login",
            "account": username,
            "passwd": password,
            "session": "FileStation",
            "format": "sid",
        ]
        request.httpBody = QBittorrentClient.formBody(fields)
        let http = try await send(request)
        try Self.throwIfFailed(http)
        guard let json = Self.json(http.body), json["success"] as? Bool == true else {
            if Self.errorCode(http.body) == 400 || Self.errorCode(http.body) == 401
                || Self.errorCode(http.body) == 407
            {
                throw SynologyClientError.authenticationFailed
            }
            throw SynologyClientError.authenticationFailed
        }
        let data = json["data"] as? [String: Any]
        guard let sid = data?["sid"] as? String, !sid.isEmpty else {
            throw SynologyClientError.authenticationFailed
        }
        return sid
    }

    private func logout(baseURL: String, sid: String) async throws {
        guard let endpoint = Self.authURL(from: baseURL) else { return }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.API.Auth"),
            URLQueryItem(name: "version", value: "3"),
            URLQueryItem(name: "method", value: "logout"),
            URLQueryItem(name: "session", value: "FileStation"),
            URLQueryItem(name: "_sid", value: sid),
        ]
        guard let url = components?.url else { return }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        _ = try? await send(request)
    }

    private func fileSize(baseURL: String, sid: String, path: String) async throws -> Int64? {
        guard let endpoint = Self.entryURL(from: baseURL) else { throw SynologyClientError.invalidURL }
        let payload = try JSONSerialization.data(withJSONObject: [path])
        let encoded = String(data: payload, encoding: .utf8) ?? "[]"
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.FileStation.List"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "getinfo"),
            URLQueryItem(name: "path", value: encoded),
            URLQueryItem(name: "additional", value: #"["size"]"#),
            URLQueryItem(name: "_sid", value: sid),
        ]
        guard let url = components?.url else { throw SynologyClientError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let http = try await send(request)
        try Self.throwIfFailed(http)
        guard let json = Self.json(http.body), json["success"] as? Bool == true else {
            throw SynologyClientError.verificationFailed
        }
        let files = (json["data"] as? [String: Any])?["files"] as? [[String: Any]]
        let additional = files?.first?["additional"] as? [String: Any]
        if let size = additional?["size"] as? Int64 { return size }
        if let size = additional?["size"] as? Int { return Int64(size) }
        if let size = additional?["size"] as? NSNumber { return size.int64Value }
        return nil
    }

    private func send(_ request: URLRequest) async throws -> SynologyHTTP {
        do {
            return try await transport.send(request)
        } catch let error as URLError {
            throw Self.clientError(from: error)
        }
    }

    private func sendUpload(_ request: URLRequest, fileURL: URL) async throws -> SynologyHTTP {
        do {
            return try await transport.upload(request: request, fileURL: fileURL)
        } catch let error as URLError {
            if error.code == .timedOut { throw SynologyClientError.timeout }
            throw NASHandoffError.uploadInterrupted
        }
    }

    public static func entryURL(from raw: String) -> URL? {
        apiURL(from: raw, path: "/webapi/entry.cgi")
    }

    public static func authURL(from raw: String) -> URL? {
        apiURL(from: raw, path: "/webapi/auth.cgi")
    }

    /// Shared URL builder for Synology CGI paths (Download Station, etc.).
    public static func apiPathURL(from raw: String, path: String) -> URL? {
        apiURL(from: raw, path: path)
    }

    private static func apiURL(from raw: String, path: String) -> URL? {
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
        components.path = path
        return components.url
    }

    public static func multipartFile(
        localFile: URL,
        filename: String,
        directory: String,
        sid: String,
    ) throws -> (fileURL: URL, contentType: String) {
        let boundary = "InkampBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("inkamp-synology-\(UUID().uuidString).multipart")
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
        try field("api", "SYNO.FileStation.Upload")
        try field("version", "2")
        try field("method", "upload")
        try field("path", directory)
        try field("create_parents", "true")
        try field("overwrite", "true")
        try field("_sid", sid)
        try write("--\(boundary)\r\n")
        try write(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
        )
        try write("Content-Type: application/octet-stream\r\n\r\n")
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

    private static func throwIfFailed(_ http: SynologyHTTP) throws {
        guard http.status != 0 else { throw SynologyClientError.cannotReachServer }
        guard http.status != 401, http.status != 403 else {
            throw SynologyClientError.authenticationFailed
        }
        guard http.status >= 200, http.status < 500 else {
            throw SynologyClientError.cannotReachServer
        }
    }

    private static func isSuccess(_ body: Data) -> Bool {
        json(body)?["success"] as? Bool == true
    }

    private static func errorCode(_ body: Data) -> Int? {
        ((json(body)?["error"] as? [String: Any])?["code"] as? Int)
    }

    private static func json(_ body: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    private static func clientError(from error: URLError) -> SynologyClientError {
        switch error.code {
            case .timedOut: .timeout
            default: .cannotReachServer
        }
    }

    // MARK: - Folder / verify helpers (Phase 2)

    public func ensureFolder(
        baseURL: String,
        username: String,
        password: String,
        volumePath: String,
    ) async throws {
        let mapped: SynologyFileStationPath
        switch SynologyPathMapping.resolve(volumePath) {
            case .success(let value): mapped = value
            case .failure(.emptyDestination): throw NASHandoffError.emptyDestination
            case .failure: throw NASHandoffError.invalidDestination
        }
        let sid = try await login(baseURL: baseURL, username: username, password: password)
        defer { Task { try? await logout(baseURL: baseURL, sid: sid) } }
        try await createFolderTree(baseURL: baseURL, sid: sid, fileStationPath: mapped.fileStationPath)
    }

    public func remoteFileSize(
        baseURL: String,
        username: String,
        password: String,
        volumeDirectory: String,
        filename: String,
    ) async throws -> Int64? {
        let remote: String
        switch SynologyPathMapping.filePath(directory: volumeDirectory, filename: filename) {
            case .success(let path): remote = path
            case .failure(.emptyDestination): throw NASHandoffError.emptyDestination
            case .failure: throw NASHandoffError.invalidDestination
        }
        let sid = try await login(baseURL: baseURL, username: username, password: password)
        defer { Task { try? await logout(baseURL: baseURL, sid: sid) } }
        return try await fileSize(baseURL: baseURL, sid: sid, path: remote)
    }

    public func renameFile(
        baseURL: String,
        username: String,
        password: String,
        volumeDirectory: String,
        fromFilename: String,
        toFilename: String,
    ) async throws {
        let fromPath: String
        let toName = NASPathSafety.sanitizeComponent(toFilename)
        guard !toName.isEmpty else { throw NASHandoffError.invalidDestination }
        switch SynologyPathMapping.filePath(directory: volumeDirectory, filename: fromFilename) {
            case .success(let path): fromPath = path
            case .failure(.emptyDestination): throw NASHandoffError.emptyDestination
            case .failure: throw NASHandoffError.invalidDestination
        }
        let sid = try await login(baseURL: baseURL, username: username, password: password)
        defer { Task { try? await logout(baseURL: baseURL, sid: sid) } }
        guard let endpoint = Self.entryURL(from: baseURL) else { throw SynologyClientError.invalidURL }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.FileStation.Rename"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "rename"),
            URLQueryItem(name: "path", value: fromPath),
            URLQueryItem(name: "name", value: toName),
            URLQueryItem(name: "_sid", value: sid),
        ]
        guard let url = components?.url else { throw SynologyClientError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let http = try await send(request)
        try Self.throwIfFailed(http)
        guard Self.isSuccess(http.body) else { throw SynologyClientError.rejected }
    }

    public func listFilenames(
        baseURL: String,
        username: String,
        password: String,
        volumeDirectory: String,
    ) async throws -> [String] {
        let mapped: SynologyFileStationPath
        switch SynologyPathMapping.resolve(volumeDirectory) {
            case .success(let value): mapped = value
            case .failure(.emptyDestination): throw NASHandoffError.emptyDestination
            case .failure: throw NASHandoffError.invalidDestination
        }
        let sid = try await login(baseURL: baseURL, username: username, password: password)
        defer { Task { try? await logout(baseURL: baseURL, sid: sid) } }
        guard let endpoint = Self.entryURL(from: baseURL) else { throw SynologyClientError.invalidURL }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.FileStation.List"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "list"),
            URLQueryItem(name: "folder_path", value: mapped.fileStationPath),
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
        let files = (json["data"] as? [String: Any])?["files"] as? [[String: Any]] ?? []
        return files.compactMap { $0["name"] as? String }
    }

    /// Move one file or folder into `destinationVolumeDirectory` and wait until File Station finishes.
    /// Source and destination are DSM volume paths (`/volume1/...`). This does not delete siblings.
    public func moveItem(
        baseURL: String,
        username: String,
        password: String,
        sourceVolumePath: String,
        destinationVolumeDirectory: String,
    ) async throws {
        let source: SynologyFileStationPath
        let destination: SynologyFileStationPath
        switch SynologyPathMapping.resolve(sourceVolumePath) {
            case .success(let value): source = value
            case .failure(.emptyDestination): throw NASHandoffError.emptyDestination
            case .failure: throw NASHandoffError.invalidDestination
        }
        switch SynologyPathMapping.resolve(destinationVolumeDirectory) {
            case .success(let value): destination = value
            case .failure(.emptyDestination): throw NASHandoffError.emptyDestination
            case .failure: throw NASHandoffError.invalidDestination
        }
        // ponytail: refuse share roots and the completed folder itself; a payload is at least
        // share/torrents/completed/<name>. Upgrade path is an explicit caller-supplied root.
        let depth = source.fileStationPath.split(separator: "/", omittingEmptySubsequences: true).count
        guard depth >= 4, source.fileStationPath != destination.fileStationPath else {
            throw NASHandoffError.invalidDestination
        }
        let sid = try await login(baseURL: baseURL, username: username, password: password)
        defer { Task { try? await logout(baseURL: baseURL, sid: sid) } }
        let taskID = try await startMove(
            baseURL: baseURL,
            sid: sid,
            source: source.fileStationPath,
            destination: destination.fileStationPath,
        )
        guard !taskID.isEmpty else { return }
        // ponytail: eight status polls. A stuck task throws and the caller leaves the job Routing.
        for _ in 0..<8 {
            if try await moveFinished(baseURL: baseURL, sid: sid, taskID: taskID) { return }
        }
        throw SynologyClientError.timeout
    }

    private func startMove(
        baseURL: String,
        sid: String,
        source: String,
        destination: String,
    ) async throws -> String {
        let pathJSON = String(
            data: try JSONSerialization.data(withJSONObject: [source]),
            encoding: .utf8,
        ) ?? ""
        guard !pathJSON.isEmpty else { throw NASHandoffError.invalidDestination }
        let http = try await entry(
            baseURL: baseURL,
            sid: sid,
            items: [
                URLQueryItem(name: "api", value: "SYNO.FileStation.CopyMove"),
                URLQueryItem(name: "version", value: "3"),
                URLQueryItem(name: "method", value: "start"),
                URLQueryItem(name: "path", value: pathJSON),
                URLQueryItem(name: "dest_folder_path", value: destination),
                URLQueryItem(name: "remove_src", value: "true"),
                URLQueryItem(name: "overwrite", value: "false"),
                URLQueryItem(name: "accurate_progress", value: "true"),
            ],
        )
        guard Self.isSuccess(http.body) else { throw SynologyClientError.rejected }
        let data = Self.json(http.body)?["data"] as? [String: Any]
        return data?["taskid"] as? String ?? ""
    }

    private func moveFinished(baseURL: String, sid: String, taskID: String) async throws -> Bool {
        let http = try await entry(
            baseURL: baseURL,
            sid: sid,
            items: [
                URLQueryItem(name: "api", value: "SYNO.FileStation.CopyMove"),
                URLQueryItem(name: "version", value: "3"),
                URLQueryItem(name: "method", value: "status"),
                URLQueryItem(name: "taskid", value: taskID),
            ],
        )
        guard let json = Self.json(http.body), json["success"] as? Bool == true else {
            throw SynologyClientError.rejected
        }
        let data = json["data"] as? [String: Any] ?? [:]
        if data["error"] != nil { throw SynologyClientError.rejected }
        return data["finished"] as? Bool == true
    }

    private func entry(
        baseURL: String,
        sid: String,
        items: [URLQueryItem],
    ) async throws -> SynologyHTTP {
        guard let endpoint = Self.entryURL(from: baseURL) else { throw SynologyClientError.invalidURL }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = items + [URLQueryItem(name: "_sid", value: sid)]
        guard let url = components?.url else { throw SynologyClientError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let http = try await send(request)
        try Self.throwIfFailed(http)
        return http
    }

    private func createFolderTree(
        baseURL: String,
        sid: String,
        fileStationPath: String,
    ) async throws {
        let parts = fileStationPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 1 else { throw NASHandoffError.invalidDestination }
        // Share root already exists; create nested folders under it.
        var built = "/" + parts[0]
        for part in parts.dropFirst() {
            let parent = built
            built = built + "/" + part
            // Ignore "folder already exists" style failures by checking list after create.
            try? await createFolder(baseURL: baseURL, sid: sid, parent: parent, name: part)
        }
    }

    private func createFolder(
        baseURL: String,
        sid: String,
        parent: String,
        name: String,
    ) async throws {
        guard let endpoint = Self.entryURL(from: baseURL) else { throw SynologyClientError.invalidURL }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.FileStation.CreateFolder"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "create"),
            URLQueryItem(name: "folder_path", value: parent),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "force_parent", value: "true"),
            URLQueryItem(name: "_sid", value: sid),
        ]
        guard let url = components?.url else { throw SynologyClientError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        let http = try await send(request)
        try Self.throwIfFailed(http)
        // success=false with "already exists" is fine — caller continues.
    }
}

