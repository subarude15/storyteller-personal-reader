import Foundation

/// Read-only downloader lifecycle for one requested format.
/// Separate from `RequestActivityStatus` (provider/request state).
public enum RequestDownloadStatus: String, Codable, Equatable, Sendable {
    case unknown
    case notFound
    case queued
    case downloading
    case stalled
    case checking
    case completed
    case waitingForImport
    case error

    public var label: String {
        switch self {
            case .unknown: "Unknown"
            case .notFound: "Not in Deluge"
            case .queued: "Queued"
            case .downloading: "Downloading"
            case .stalled: "Stalled"
            case .checking: "Checking download"
            case .completed: "Downloaded"
            case .waitingForImport: "Waiting for Storyteller import"
            case .error: "Download needs attention"
        }
    }

    /// Actively being handled by the downloader (suppresses provider fallback).
    public var isActivelyDownloading: Bool {
        switch self {
            case .queued, .downloading, .stalled, .checking, .waitingForImport:
                true
            case .unknown, .notFound, .completed, .error:
                false
        }
    }

    public var needsAttentionBucket: Bool {
        self == .error
    }

    public var showsProgress: Bool {
        switch self {
            case .downloading, .queued, .stalled, .checking:
                true
            case .unknown, .notFound, .completed, .waitingForImport, .error:
                false
        }
    }
}

/// Persisted per-format Deluge observability. Optional on legacy rows.
public struct RequestFormatDownloadState: Codable, Equatable, Sendable {
    public var format: BookRequestFormat
    public var status: RequestDownloadStatus
    public var progress: Double?
    public var etaSeconds: Int?
    public var detail: String?
    public var torrentID: String?
    public var torrentName: String?
    public var completedAt: Date?
    public var updatedAt: Date
    public var delugeUnavailable: Bool

    public init(
        format: BookRequestFormat,
        status: RequestDownloadStatus,
        progress: Double? = nil,
        etaSeconds: Int? = nil,
        detail: String? = nil,
        torrentID: String? = nil,
        torrentName: String? = nil,
        completedAt: Date? = nil,
        updatedAt: Date = Date(),
        delugeUnavailable: Bool = false,
    ) {
        self.format = format
        self.status = status
        self.progress = progress
        self.etaSeconds = etaSeconds
        self.detail = detail
        self.torrentID = torrentID
        self.torrentName = torrentName
        self.completedAt = completedAt
        self.updatedAt = updatedAt
        self.delugeUnavailable = delugeUnavailable
    }

    public var percentLabel: String? {
        guard let progress else { return nil }
        let pct = Int((progress * 100).rounded(.down).clamped(to: 0...100))
        return "\(pct)%"
    }

    public var etaLabel: String? {
        guard let etaSeconds, etaSeconds > 0, etaSeconds < 7 * 24 * 3600 else { return nil }
        if etaSeconds < 60 { return "ETA < 1 min" }
        if etaSeconds < 3600 {
            return "ETA \(etaSeconds / 60) min"
        }
        let hours = etaSeconds / 3600
        let minutes = (etaSeconds % 3600) / 60
        if minutes == 0 { return "ETA \(hours) hr" }
        return "ETA \(hours) hr \(minutes) min"
    }
}

/// One torrent as reported by Deluge WebUI. Read-only.
public struct DelugeTorrentSnapshot: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var state: String
    public var progress: Double
    public var downloadRate: Int?
    public var uploadRate: Int?
    public var etaSeconds: Int?
    public var savePath: String?
    public var totalSize: Int64?
    public var completedSize: Int64?
    public var isFinished: Bool
    public var error: String?
    public var addedAt: Date?
    public var completedAt: Date?

    public init(
        id: String,
        name: String,
        state: String,
        progress: Double,
        downloadRate: Int? = nil,
        uploadRate: Int? = nil,
        etaSeconds: Int? = nil,
        savePath: String? = nil,
        totalSize: Int64? = nil,
        completedSize: Int64? = nil,
        isFinished: Bool,
        error: String? = nil,
        addedAt: Date? = nil,
        completedAt: Date? = nil,
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.progress = progress
        self.downloadRate = downloadRate
        self.uploadRate = uploadRate
        self.etaSeconds = etaSeconds
        self.savePath = savePath
        self.totalSize = totalSize
        self.completedSize = completedSize
        self.isFinished = isFinished
        self.error = error
        self.addedAt = addedAt
        self.completedAt = completedAt
    }
}

public enum DelugeConnection: Equatable, Sendable {
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

public enum DelugeClientError: Error, Equatable, Sendable {
    case invalidURL
    case cannotReachServer
    case authenticationFailed
    case timeout
    case invalidResponse
    case notConnectedToDaemon

    public var connection: DelugeConnection {
        switch self {
            case .invalidURL: .invalidURL
            case .cannotReachServer: .cannotReachServer
            case .authenticationFailed: .authenticationFailed
            case .timeout: .timeout
            case .invalidResponse, .notConnectedToDaemon: .invalidResponse
        }
    }

    public var detail: String {
        switch self {
            case .invalidURL: "Invalid Deluge URL"
            case .cannotReachServer: "Cannot reach Deluge"
            case .authenticationFailed: "Authentication failed"
            case .timeout: "Deluge timed out"
            case .invalidResponse: "Unexpected Deluge response"
            case .notConnectedToDaemon: "Deluge WebUI is not connected to a daemon"
        }
    }
}

public struct DelugeHTTP: Sendable {
    public var status: Int
    public var body: Data
    public var setCookie: String?

    public init(status: Int, body: Data, setCookie: String? = nil) {
        self.status = status
        self.body = body
        self.setCookie = setCookie
    }
}

public protocol DelugeTransport: Sendable {
    func send(
        url: URL,
        method: String,
        body: Data,
        cookie: String?,
        timeout: TimeInterval,
    ) async throws -> DelugeHTTP
}

/// In-memory torrent list built once per refresh.
public struct DelugeTorrentIndex: Equatable, Sendable {
    public var torrents: [DelugeTorrentSnapshot]
    public var byID: [String: DelugeTorrentSnapshot]
    public var fetchedAt: Date
    public var unavailable: Bool

    public init(
        torrents: [DelugeTorrentSnapshot] = [],
        fetchedAt: Date = Date(),
        unavailable: Bool = false,
    ) {
        self.torrents = torrents
        self.byID = Dictionary(uniqueKeysWithValues: torrents.map { ($0.id, $0) })
        self.fetchedAt = fetchedAt
        self.unavailable = unavailable
    }

    public static func unavailable(at date: Date = Date()) -> DelugeTorrentIndex {
        DelugeTorrentIndex(torrents: [], fetchedAt: date, unavailable: true)
    }

    public func torrent(id: String) -> DelugeTorrentSnapshot? {
        byID[id]
    }
}

public enum DelugeMatchResult: Equatable, Sendable {
    case matched(DelugeTorrentSnapshot)
    case noMatch
    case ambiguous
}
