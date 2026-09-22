//
//  TorrentDownloadProvider.swift
//  SilveranKit
//
//  Provider-independent torrent job surface for TorBox / Deluge / qBittorrent.
//  UI and Downloads refresh against these types; networking stays in each client.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Identifies which torrent backend owns a job.
public enum TorrentProviderKind: String, Codable, Sendable, CaseIterable {
    case torbox
    case deluge
    case qbittorrent

    public var displayName: String {
        switch self {
            case .torbox: "TorBox"
            case .deluge: "Deluge"
            case .qbittorrent: "qBittorrent"
        }
    }

    public init?(backend: NASDownloadBackend) {
        switch backend {
            case .torbox: self = .torbox
            case .deluge: self = .deluge
            case .qbittorrent: self = .qbittorrent
            case .synology: return nil
        }
    }

    public var backend: NASDownloadBackend {
        switch self {
            case .torbox: .torbox
            case .deluge: .deluge
            case .qbittorrent: .qbittorrent
        }
    }
}

/// Normalized torrent lifecycle for Downloads UI.
public enum TorrentJobStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case downloading
    case processing
    case ready
    case failed
    case cancelled

    public var label: String {
        switch self {
            case .queued: "Queued"
            case .downloading: "Downloading"
            case .processing: "Processing"
            case .ready: "Ready"
            case .failed: "Failed"
            case .cancelled: "Cancelled"
        }
    }
}

/// File stub retained for Phase 2 TorBox → NAS transfer.
public struct TorrentJobFile: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var size: Int64?
    public var mimeType: String?

    public init(id: String, name: String, size: Int64? = nil, mimeType: String? = nil) {
        self.id = id
        self.name = name
        self.size = size
        self.mimeType = mimeType
    }

    public init(_ file: TorBoxTorrentFile) {
        self.id = String(file.id)
        self.name = file.name
        self.size = file.size
        self.mimeType = file.mimeType.isEmpty ? nil : file.mimeType
    }
}

/// Provider-independent torrent job used by Downloads after normalizing backends.
public struct TorrentJob: Equatable, Sendable, Identifiable {
    public var id: String
    public var provider: TorrentProviderKind
    public var name: String
    public var status: TorrentJobStatus
    public var progress: Double?
    public var size: Int64?
    public var createdAt: Date?
    public var errorMessage: String?
    public var infoHash: String?
    public var rawProviderStatus: String?
    public var files: [TorrentJobFile]
    /// TorBox auth_id (and similar) needed later for requestdl / Phase 2.
    public var providerAuthID: String?

    public init(
        id: String,
        provider: TorrentProviderKind,
        name: String,
        status: TorrentJobStatus,
        progress: Double? = nil,
        size: Int64? = nil,
        createdAt: Date? = nil,
        errorMessage: String? = nil,
        infoHash: String? = nil,
        rawProviderStatus: String? = nil,
        files: [TorrentJobFile] = [],
        providerAuthID: String? = nil,
    ) {
        self.id = id
        self.provider = provider
        self.name = name
        self.status = status
        self.progress = progress
        self.size = size
        self.createdAt = createdAt
        self.errorMessage = errorMessage
        self.infoHash = infoHash
        self.rawProviderStatus = rawProviderStatus
        self.files = files
        self.providerAuthID = providerAuthID
    }
}

/// Shared operations each torrent backend should expose.
public protocol TorrentDownloadProviding: Sendable {
    var kind: TorrentProviderKind { get }
    var displayName: String { get }
}

/// Maps TorBox download states into app-friendly statuses.
public enum TorBoxStatusMapping {
    public static func jobStatus(for info: TorBoxTorrentInfo) -> TorrentJobStatus {
        if info.isDownloadReady {
            return .ready
        }
        let state = info.downloadState.lowercased()
        if state.contains("error") || state.contains("failed") || state == "missingfiles" {
            return .failed
        }
        if state.contains("queued") || state == "metadl" || state == "allocating"
            || state == "checkingresumedata"
        {
            return .queued
        }
        if state.contains("download") || state.contains("stalled") || state.contains("forceddl")
            || state.contains("pauseddl") || state.contains("stoppeddl")
        {
            return .downloading
        }
        if state.contains("check") || state.contains("moving") || state.contains("processing")
            || state == "paused"
        {
            return .processing
        }
        if info.progress > 0, info.progress < 1 {
            return .downloading
        }
        return .queued
    }

    public static func manualStatus(for info: TorBoxTorrentInfo) -> ManualDownloadJobStatus {
        switch jobStatus(for: info) {
            case .queued: .queued
            case .downloading: .downloading
            case .processing: .processing
            case .ready: .ready
            case .failed: .failed
            case .cancelled: .failed
        }
    }

    public static func torrentJob(
        from info: TorBoxTorrentInfo,
        createdAt: Date? = nil,
        errorMessage: String? = nil,
    ) -> TorrentJob {
        let status = jobStatus(for: info)
        return TorrentJob(
            id: String(info.id),
            provider: .torbox,
            name: info.name.isEmpty ? "TorBox torrent" : info.name,
            status: status,
            progress: info.progress,
            size: info.size ?? info.files.reduce(Int64(0)) { $0 + $1.size },
            createdAt: createdAt,
            errorMessage: errorMessage,
            infoHash: info.hash.isEmpty ? nil : info.hash,
            rawProviderStatus: info.downloadState,
            files: info.files.map(TorrentJobFile.init),
            providerAuthID: info.authID,
        )
    }

    public static func apply(
        _ info: TorBoxTorrentInfo,
        to job: ManualDownloadJob,
        at date: Date = Date(),
    ) -> ManualDownloadJob {
        if job.status == .failed { return job }
        var updated = job
        let previous = job.status
        let next = manualStatus(for: info)
        updated.status = next
        updated.progress = info.progress
        updated.totalSize = info.size ?? info.files.reduce(Int64(0)) { $0 + $1.size }
        if let completed = info.files.isEmpty ? nil : info.files.reduce(Int64(0), { $0 + $1.size }),
            info.isDownloadReady
        {
            updated.byteCount = completed
        }
        if !info.name.isEmpty, job.title.isEmpty || job.title.hasPrefix("Magnet ") {
            updated.title = info.name
        }
        updated.providerRawStatus = info.downloadState
        updated.providerInfoHash = info.hash.isEmpty ? nil : info.hash
        updated.providerAuthID = info.authID
        updated.providerFiles = info.files.map(TorrentJobFile.init)
        updated.lastStatusAt = date
        if next != .failed {
            updated.lastError = nil
        } else if updated.lastError == nil {
            updated.lastError = "TorBox reported a torrent failure."
        }
        if previous != next {
            switch next {
                case .ready:
                    debugLog("[TorBox] torrent ready id=\(info.id)")
                case .failed:
                    debugLog("[TorBox] torrent failed id=\(info.id)")
                case .submitted, .queued, .downloading, .processing, .delugeFinishing,
                    .readyToRoute, .routing, .downloaded, .uploading, .complete, .unknown:
                    debugLog(
                        "[TorBox] status changed id=\(info.id) \(previous.rawValue)->\(next.rawValue)"
                    )
            }
        }
        return updated
    }
}
