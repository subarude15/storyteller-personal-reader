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
    case queued
    case downloading
    case complete
    case failed
    case unknown

    public var label: String {
        switch self {
            case .queued: "Queued"
            case .downloading: "Downloading"
            case .complete: "Complete"
            case .failed: "Failed"
            case .unknown: "Unknown"
        }
    }
}

public struct ManualDownloadJob: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var author: String
    public var sourceHost: String
    public var backend: NASDownloadBackend
    public var mediaType: NASMediaKind
    public var destination: String
    public var submittedAt: Date
    public var backendJobID: String?
    public var status: ManualDownloadJobStatus
    public var lastError: String?

    public init(
        id: String = UUID().uuidString,
        title: String,
        author: String,
        sourceHost: String,
        backend: NASDownloadBackend,
        mediaType: NASMediaKind,
        destination: String,
        submittedAt: Date = Date(),
        backendJobID: String? = nil,
        status: ManualDownloadJobStatus,
        lastError: String? = nil,
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.sourceHost = sourceHost
        self.backend = backend
        self.mediaType = mediaType
        self.destination = destination
        self.submittedAt = submittedAt
        self.backendJobID = backendJobID
        self.status = status
        self.lastError = lastError
    }
}

public protocol ManualDownloadJobStoring: Sendable {
    func record(_ job: ManualDownloadJob) async
    func allJobs() async -> [ManualDownloadJob]
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
}
