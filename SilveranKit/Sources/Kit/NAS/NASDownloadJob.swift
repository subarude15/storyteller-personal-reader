//
//  NASDownloadJob.swift
//  SilveranKit
//
//  Lightweight local record of a Manual Search NAS submission.
//  Never stores credentials.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum ManualDownloadJobStatus: String, Codable, Sendable, CaseIterable {
    case submitted
    case queued
    case downloading
    case downloaded
    case uploading
    case complete
    case failed
    case unknown

    public var label: String {
        switch self {
            case .submitted: "Submitted"
            case .queued: "Queued"
            case .downloading: "Downloading"
            case .downloaded: "Downloaded"
            case .uploading: "Uploading"
            case .complete: "Complete"
            case .failed: "Failed"
            case .unknown: "Unknown"
        }
    }

    public var canRetryUpload: Bool {
        switch self {
            case .downloaded, .failed: true
            case .submitted, .queued, .downloading, .uploading, .complete, .unknown: false
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
}
