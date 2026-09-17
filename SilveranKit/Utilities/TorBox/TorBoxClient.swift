import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTP surface for TorBox (GET + multipart POST).
public protocol TorBoxHTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse)
    func postForm(
        _ url: URL,
        headers: [String: String],
        fields: [String: String]
    ) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTorBoxHTTPClient: TorBoxHTTPClient {
    public init() {}

    public func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    public func postForm(
        _ url: URL,
        headers: [String: String],
        fields: [String: String]
    ) async throws -> (Data, HTTPURLResponse) {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        var body = Data()
        for (name, value) in fields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append(value.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

public enum TorBoxError: Error, LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case invalidAPIKey
    case malformedMagnet
    case api(message: String)
    case notReady
    case timeout
    case noDownloadableFile

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add a TorBox API key in Settings → Debrid Settings."
        case .invalidAPIKey:
            return "TorBox API key is invalid."
        case .malformedMagnet:
            return "Magnet link looks malformed."
        case .api(let message):
            return message
        case .notReady:
            return "TorBox is still downloading this torrent."
        case .timeout:
            return "Timed out waiting for TorBox to finish downloading."
        case .noDownloadableFile:
            return "TorBox finished but no downloadable file was found."
        }
    }
}

public struct TorBoxTorrentFile: Equatable, Sendable {
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
    public var downloadState: String
    public var downloadFinished: Bool
    public var downloadPresent: Bool
    public var progress: Double
    public var files: [TorBoxTorrentFile]

    public var isDownloadReady: Bool {
        downloadPresent || downloadFinished || downloadState.lowercased() == "cached"
    }

    public init(
        id: Int,
        name: String,
        hash: String,
        downloadState: String,
        downloadFinished: Bool,
        downloadPresent: Bool,
        progress: Double,
        files: [TorBoxTorrentFile]
    ) {
        self.id = id
        self.name = name
        self.hash = hash
        self.downloadState = downloadState
        self.downloadFinished = downloadFinished
        self.downloadPresent = downloadPresent
        self.progress = progress
        self.files = files
    }
}

/// Client for TorBox torrents API (`https://api.torbox.app/v1/api/...`).
///
/// Flow maps to the product steps:
/// - add magnet → `POST /torrents/createtorrent` (docs sometimes call this "add")
/// - poll status → `GET /torrents/mylist?id=` (docs sometimes call this "get")
/// - direct link → `GET /torrents/requestdl` (`data` is the download URL)
public struct TorBoxClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.torbox.app/v1/api")!

    public var apiKey: String
    public var baseURL: URL
    public var http: any TorBoxHTTPClient

    public init(
        apiKey: String,
        baseURL: URL = TorBoxClient.defaultBaseURL,
        http: any TorBoxHTTPClient = URLSessionTorBoxHTTPClient()
    ) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = baseURL
        self.http = http
    }

    private var authHeaders: [String: String] {
        ["Authorization": "Bearer \(apiKey)"]
    }

    /// Validates the saved API key (`GET /user/me`).
    public func validateAPIKey() async throws {
        guard !apiKey.isEmpty else { throw TorBoxError.missingAPIKey }
        let url = baseURL.appendingPathComponent("user/me")
        let (data, response) = try await http.get(url, headers: authHeaders)
        if response.statusCode == 403 {
            throw TorBoxError.invalidAPIKey
        }
        let envelope = try TorBoxJSON.envelope(data)
        if response.statusCode == 401 || envelope.errorCode == "BAD_TOKEN" || envelope.errorCode == "NO_AUTH" {
            throw TorBoxError.invalidAPIKey
        }
        guard envelope.success || (200 ... 299).contains(response.statusCode) else {
            throw TorBoxError.api(message: envelope.detail.isEmpty ? "TorBox authentication failed." : envelope.detail)
        }
    }

    /// Adds a magnet. Returns TorBox torrent id.
    public func addMagnet(_ magnet: String) async throws -> Int {
        guard !apiKey.isEmpty else { throw TorBoxError.missingAPIKey }
        let trimmed = magnet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidMagnet(trimmed) else { throw TorBoxError.malformedMagnet }

        let url = baseURL.appendingPathComponent("torrents/createtorrent")
        let (data, response) = try await http.postForm(
            url,
            headers: authHeaders,
            fields: ["magnet": trimmed]
        )
        if response.statusCode == 403 {
            throw TorBoxError.invalidAPIKey
        }
        let envelope = try TorBoxJSON.envelope(data)
        if envelope.errorCode == "BAD_TOKEN" || envelope.errorCode == "NO_AUTH" {
            throw TorBoxError.invalidAPIKey
        }
        if envelope.errorCode == "BOZO_TORRENT" {
            throw TorBoxError.malformedMagnet
        }
        guard envelope.success else {
            throw TorBoxError.api(message: envelope.detail.isEmpty ? "Could not add magnet to TorBox." : envelope.detail)
        }
        guard let id = TorBoxJSON.intValue(envelope.dataDict?["torrent_id"])
            ?? TorBoxJSON.intValue(envelope.dataDict?["torrentId"])
            ?? TorBoxJSON.intValue(envelope.dataDict?["id"])
        else {
            throw TorBoxError.api(message: "TorBox did not return a torrent id.")
        }
        return id
    }

    /// Fetches one torrent (`GET /torrents/mylist?id=`).
    public func getTorrent(id: Int, bypassCache: Bool = true) async throws -> TorBoxTorrentInfo {
        guard !apiKey.isEmpty else { throw TorBoxError.missingAPIKey }
        var components = URLComponents(url: baseURL.appendingPathComponent("torrents/mylist"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "id", value: String(id)),
            URLQueryItem(name: "bypass_cache", value: bypassCache ? "true" : "false"),
        ]
        guard let url = components.url else { throw TorBoxError.api(message: "Bad TorBox URL.") }
        let (data, response) = try await http.get(url, headers: authHeaders)
        if response.statusCode == 403 {
            throw TorBoxError.invalidAPIKey
        }
        let envelope = try TorBoxJSON.envelope(data)
        if envelope.errorCode == "BAD_TOKEN" || envelope.errorCode == "NO_AUTH" {
            throw TorBoxError.invalidAPIKey
        }
        guard envelope.success else {
            throw TorBoxError.api(message: envelope.detail.isEmpty ? "Could not load TorBox torrent." : envelope.detail)
        }
        let dict: [String: Any]
        if let one = envelope.dataDict {
            dict = one
        } else if let first = envelope.dataArray?.first {
            dict = first
        } else {
            throw TorBoxError.api(message: "TorBox returned no torrent data.")
        }
        return TorBoxJSON.parseTorrent(dict)
    }

    /// Requests a direct download URL for a file (`GET /torrents/requestdl`).
    public func requestDownloadURL(torrentID: Int, fileID: Int) async throws -> URL {
        guard !apiKey.isEmpty else { throw TorBoxError.missingAPIKey }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("torrents/requestdl"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "token", value: apiKey),
            URLQueryItem(name: "torrent_id", value: String(torrentID)),
            URLQueryItem(name: "file_id", value: String(fileID)),
            URLQueryItem(name: "redirect", value: "false"),
        ]
        guard let url = components.url else { throw TorBoxError.api(message: "Bad TorBox URL.") }
        let (data, response) = try await http.get(url, headers: [:])
        if response.statusCode == 403 {
            throw TorBoxError.invalidAPIKey
        }
        let envelope = try TorBoxJSON.envelope(data)
        if envelope.errorCode == "BAD_TOKEN" || envelope.errorCode == "NO_AUTH" {
            throw TorBoxError.invalidAPIKey
        }
        guard envelope.success else {
            throw TorBoxError.api(message: envelope.detail.isEmpty ? "Could not get TorBox download link." : envelope.detail)
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
        throw TorBoxError.noDownloadableFile
    }

    /// Permalink Storyteller (or the app) can fetch without another requestdl round-trip.
    public func downloadPermalink(torrentID: Int, fileID: Int) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("torrents/requestdl"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "token", value: apiKey),
            URLQueryItem(name: "torrent_id", value: String(torrentID)),
            URLQueryItem(name: "file_id", value: String(fileID)),
            URLQueryItem(name: "redirect", value: "true"),
        ]
        return components.url ?? baseURL
    }

    /// Polls until the torrent is ready, then returns preferred file + direct URL.
    public func resolveMagnet(
        _ magnet: String,
        pollIntervalSeconds: Double = 2.0,
        timeoutSeconds: Double = 300,
        preferExtensions: [String] = ["epub", "mobi", "azw3", "pdf", "mp3", "m4b", "m4a"]
    ) async throws -> (info: TorBoxTorrentInfo, file: TorBoxTorrentFile, downloadURL: URL) {
        let torrentID = try await addMagnet(magnet)
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var last: TorBoxTorrentInfo?
        while Date() < deadline {
            let info = try await getTorrent(id: torrentID, bypassCache: true)
            last = info
            if info.isDownloadReady, let file = Self.preferredFile(in: info.files, prefer: preferExtensions) {
                let url = try await requestDownloadURL(torrentID: info.id, fileID: file.id)
                return (info, file, url)
            }
            try await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
        }
        if let last, last.isDownloadReady {
            throw TorBoxError.noDownloadableFile
        }
        throw TorBoxError.timeout
    }

    public static func isValidMagnet(_ value: String) -> Bool {
        let lower = value.lowercased()
        guard lower.hasPrefix("magnet:?") else { return false }
        return lower.contains("xt=urn:btih:") || lower.contains("xt=urn:btmh:")
    }

    public static func preferredFile(
        in files: [TorBoxTorrentFile],
        prefer: [String]
    ) -> TorBoxTorrentFile? {
        guard !files.isEmpty else { return nil }
        for ext in prefer {
            if let match = files.first(where: { $0.name.lowercased().hasSuffix(".\(ext)") }) {
                return match
            }
        }
        return files.max(by: { $0.size < $1.size })
    }
}

// MARK: - JSON helpers

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
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TorBoxError.api(message: "Unexpected TorBox response.")
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
            dataString: dataString
        )
    }

    static func parseTorrent(_ dict: [String: Any]) -> TorBoxTorrentInfo {
        let filesRaw = (dict["files"] as? [[String: Any]]) ?? []
        let files = filesRaw.map { file -> TorBoxTorrentFile in
            TorBoxTorrentFile(
                id: intValue(file["id"]) ?? 0,
                name: stringValue(file["name"]) ?? stringValue(file["short_name"]) ?? "file",
                size: Int64(doubleValue(file["size"])),
                mimeType: stringValue(file["mimetype"]) ?? ""
            )
        }
        return TorBoxTorrentInfo(
            id: intValue(dict["id"]) ?? 0,
            name: stringValue(dict["name"]) ?? "",
            hash: stringValue(dict["hash"]) ?? "",
            downloadState: stringValue(dict["download_state"]) ?? stringValue(dict["downloadState"]) ?? "",
            downloadFinished: boolValue(dict["download_finished"]) || boolValue(dict["downloadFinished"]),
            downloadPresent: boolValue(dict["download_present"]) || boolValue(dict["downloadPresent"]),
            progress: doubleValue(dict["progress"]),
            files: files
        )
    }

    static func stringValue(_ any: Any?) -> String? {
        switch any {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let i as Int: return i
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }

    static func doubleValue(_ any: Any?) -> Double {
        switch any {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s) ?? 0
        default: return 0
        }
    }

    static func boolValue(_ any: Any?) -> Bool {
        switch any {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return ["1", "true", "yes"].contains(s.lowercased())
        default: return false
        }
    }
}
