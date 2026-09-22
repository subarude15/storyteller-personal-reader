//
//  NASDownloadJob.swift
//  SilveranKit
//
//  Lightweight local record of a Manual Search NAS submission.
//  Never stores credentials.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum ManualDownloadRetryAction: String, Sendable, Equatable {
    case none
    case retryUpload
    case retryDownload
    case retryTorrent
    case retryRouting
    case retryTransfer
}

public enum ManualDownloadJobStatus: String, Codable, Sendable, CaseIterable {
    case submitted
    case queued
    case downloading
    /// Provider is checking / assembling / processing (TorBox and similar).
    case processing
    /// Deluge finished downloading but is still relocating incoming → completed.
    case delugeFinishing
    /// At Deluge completed staging; ink+amp may call move_storage.
    case readyToRoute
    /// ink+amp asked Deluge to move storage into the final library folder.
    case routing
    case downloaded
    case uploading
    /// TorBox (and similar) content is fully available in the cloud.
    case ready
    /// NAS is pulling TorBox files into the library destination.
    case transferring
    case complete
    case failed
    case unknown

    public var label: String {
        switch self {
            case .submitted: "Submitted"
            case .queued: "Queued"
            case .downloading: "Downloading"
            case .processing: "Processing"
            case .delugeFinishing: "Deluge finishing"
            case .readyToRoute: "Ready to route"
            case .routing: "Moving to library"
            case .downloaded: "Downloaded"
            case .uploading: "Uploading"
            case .ready: "Ready"
            case .transferring: "Transferring to NAS"
            case .complete: "Complete"
            case .failed: "Failed"
            case .unknown: "Unknown"
        }
    }

    public var canRetryUpload: Bool {
        switch self {
            case .downloaded, .failed: true
            case .submitted, .queued, .downloading, .processing, .delugeFinishing, .readyToRoute,
                .routing, .uploading, .ready, .transferring, .complete, .unknown:
                false
        }
    }

    public var isActive: Bool {
        switch self {
            case .queued, .submitted, .downloading, .processing, .delugeFinishing, .readyToRoute,
                .routing, .downloaded, .uploading, .transferring, .unknown:
                true
            case .ready, .complete, .failed:
                false
        }
    }
}

public struct ManualDownloadJob: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var author: String
    public var sourceURL: String?
    public var sourceHost: String
    public var filename: String?
    public var backend: NASDownloadBackend
    public var mediaType: NASMediaKind
    public var destination: String
    public var stagedFilePath: String?
    public var byteCount: Int64?
    public var submittedAt: Date
    public var backendJobID: String?
    public var status: ManualDownloadJobStatus
    public var lastError: String?
    public var progress: Double?
    public var downloadRate: Int?
    public var totalSize: Int64?
    public var lastStatusAt: Date?
    /// Set once this Deluge job reaches `readyToRoute` / `routing`. Distinguishes
    /// final-move failures from initial addMagnet failures that still carry a BTIH.
    public var delugeReachedFinalRouting: Bool?
    /// Raw provider status string (TorBox download_state, etc.) for debugging.
    public var providerRawStatus: String?
    /// Info-hash when the provider exposes one (kept separately from numeric TorBox ids).
    public var providerInfoHash: String?
    /// TorBox auth_id (and similar) retained for Phase 2 requestdl.
    public var providerAuthID: String?
    /// Provider file stubs for Phase 2 NAS transfer / file selection.
    public var providerFiles: [TorrentJobFile]?
    /// Per-file NAS transfer state (TorBox Phase 2). Never stores signed URLs.
    public var transferFiles: [RemoteTransferFileState]?

    public init(
        id: String = UUID().uuidString,
        title: String,
        author: String,
        sourceURL: String? = nil,
        sourceHost: String,
        filename: String? = nil,
        backend: NASDownloadBackend,
        mediaType: NASMediaKind,
        destination: String,
        stagedFilePath: String? = nil,
        byteCount: Int64? = nil,
        submittedAt: Date = Date(),
        backendJobID: String? = nil,
        status: ManualDownloadJobStatus,
        lastError: String? = nil,
        progress: Double? = nil,
        downloadRate: Int? = nil,
        totalSize: Int64? = nil,
        lastStatusAt: Date? = nil,
        delugeReachedFinalRouting: Bool? = nil,
        providerRawStatus: String? = nil,
        providerInfoHash: String? = nil,
        providerAuthID: String? = nil,
        providerFiles: [TorrentJobFile]? = nil,
        transferFiles: [RemoteTransferFileState]? = nil,
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.sourceURL = sourceURL
        self.sourceHost = sourceHost
        self.filename = filename
        self.backend = backend
        self.mediaType = mediaType
        self.destination = destination
        self.stagedFilePath = stagedFilePath
        self.byteCount = byteCount
        self.submittedAt = submittedAt
        self.backendJobID = backendJobID
        self.status = status
        self.lastError = lastError
        self.progress = progress
        self.downloadRate = downloadRate
        self.totalSize = totalSize
        self.lastStatusAt = lastStatusAt
        self.delugeReachedFinalRouting = delugeReachedFinalRouting
        self.providerRawStatus = providerRawStatus
        self.providerInfoHash = providerInfoHash
        self.providerAuthID = providerAuthID
        self.providerFiles = providerFiles
        self.transferFiles = transferFiles
    }

    public var hasReachedDelugeFinalRouting: Bool {
        delugeReachedFinalRouting == true
    }

    public var canRetryUploadNow: Bool {
        backend == .synology && hasStagedFile && status.canRetryUpload
    }

    public var canRetryDownloadNow: Bool {
        backend == .synology && status == .failed && sourceURL != nil && !hasStagedFile
    }

    public var canRetryTorrentNow: Bool {
        (backend == .qbittorrent || backend == .deluge || backend == .torbox)
            && status == .failed
            && !canRetryRoutingNow
            && !canRetryTransferNow
            && (sourceURL != nil || hasStagedFile)
    }

    /// Failed after reaching final routing — retry `move_storage`, do not re-add.
    public var canRetryRoutingNow: Bool {
        backend == .deluge
            && status == .failed
            && hasReachedDelugeFinalRouting
            && !(backendJobID ?? "").isEmpty
            && !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var canTransferToNASNow: Bool {
        backend == .torbox
            && status == .ready
            && !(backendJobID ?? "").isEmpty
    }

    /// Failed NAS transfer for a still-Ready TorBox cloud job — retry transfer only.
    public var canRetryTransferNow: Bool {
        backend == .torbox
            && status == .failed
            && !(backendJobID ?? "").isEmpty
            && ((transferFiles?.isEmpty == false) || (providerFiles?.isEmpty == false))
            && !canRetryRoutingNow
    }

    public var retryAction: ManualDownloadRetryAction {
        if canRetryUploadNow { return .retryUpload }
        if canRetryRoutingNow { return .retryRouting }
        if canRetryTransferNow { return .retryTransfer }
        if canRetryTorrentNow { return .retryTorrent }
        if canRetryDownloadNow { return .retryDownload }
        return .none
    }

    public var stagedFileURL: URL? {
        guard let stagedFilePath, !stagedFilePath.isEmpty else { return nil }
        return URL(fileURLWithPath: stagedFilePath)
    }

    public var hasStagedFile: Bool {
        guard let url = stagedFileURL else { return false }
        return ManualDownloadStaging.exists(url)
    }
}

public protocol ManualDownloadJobStoring: Sendable {
    func record(_ job: ManualDownloadJob) async
    func allJobs() async -> [ManualDownloadJob]
    func job(id: String) async -> ManualDownloadJob?
    func delete(id: String) async
    func clearCompleted() async
}

public actor ManualDownloadJobStore: ManualDownloadJobStoring {
    public static let shared = ManualDownloadJobStore()

    private let fileURL: URL
    private var jobs: [ManualDownloadJob]
    private let limit = 50

    public init(fileURL: URL? = nil) {
        let resolved =
            fileURL
            ?? SilveranPlatform.applicationSupportDirectory(fileManager: .default)
            .appendingPathComponent("Config", isDirectory: true)
            .appendingPathComponent("inkamp.manualDownloads.v1.json", isDirectory: false)
        self.fileURL = resolved
        jobs = Self.load(from: resolved)
    }

    public func record(_ job: ManualDownloadJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.insert(job, at: 0)
        }
        if jobs.count > limit {
            jobs = Array(jobs.prefix(limit))
        }
        save()
        Task { @MainActor in
            NotificationCenter.default.post(name: .inkampManualDownloadJobsDidChange, object: nil)
        }
    }

    public func allJobs() -> [ManualDownloadJob] {
        jobs
    }

    public func job(id: String) -> ManualDownloadJob? {
        jobs.first { $0.id == id }
    }

    public func delete(id: String) {
        if let job = jobs.first(where: { $0.id == id }),
            let staged = job.stagedFileURL
        {
            ManualDownloadStaging.remove(staged)
        }
        jobs.removeAll { $0.id == id }
        save()
        Task { @MainActor in
            NotificationCenter.default.post(name: .inkampManualDownloadJobsDidChange, object: nil)
        }
    }

    public func clearCompleted() {
        jobs.removeAll { $0.status == .complete }
        save()
        Task { @MainActor in
            NotificationCenter.default.post(name: .inkampManualDownloadJobsDidChange, object: nil)
        }
    }

    private func save() {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(jobs) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    private static func load(from url: URL) -> [ManualDownloadJob] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ManualDownloadJob].self, from: data)) ?? []
    }
}

extension Notification.Name {
    public static let inkampManualDownloadJobsDidChange = Notification.Name(
        "inkampManualDownloadJobsDidChange"
    )
    public static let inkampShowManualDownloads = Notification.Name(
        "inkampShowManualDownloads"
    )
    public static let inkampProcessManualDownloadIntake = Notification.Name(
        "inkampProcessManualDownloadIntake"
    )
    public static let inkampOpenManualMagnet = Notification.Name(
        "inkampOpenManualMagnet"
    )
}

public enum ManualDownloadIntakeDeepLink {
    public static func isAddDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "punkrally" else { return false }
        let host = (url.host ?? "").lowercased()
        if host == "add-download" { return true }
        // punkrally:///add-download style
        return url.path.lowercased().contains("add-download")
    }
}

public final class RecordingManualDownloadJobStore: ManualDownloadJobStoring, @unchecked Sendable {
    public private(set) var jobs: [ManualDownloadJob] = []

    public init() {}

    public func record(_ job: ManualDownloadJob) async {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.insert(job, at: 0)
        }
    }

    public func allJobs() async -> [ManualDownloadJob] {
        jobs
    }

    public func job(id: String) async -> ManualDownloadJob? {
        jobs.first { $0.id == id }
    }

    public func delete(id: String) async {
        jobs.removeAll { $0.id == id }
    }

    public func clearCompleted() async {
        jobs.removeAll { $0.status == .complete }
    }
}
