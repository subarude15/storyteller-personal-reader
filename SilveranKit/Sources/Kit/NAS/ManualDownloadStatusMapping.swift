//
//  ManualDownloadStatusMapping.swift
//  SilveranKit
//
//  Normalize qBittorrent / Deluge torrent states. Poll failures stay Unknown.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct ManualTorrentLiveStatus: Equatable, Sendable {
    public var status: ManualDownloadJobStatus
    public var progress: Double?
    public var downloadRate: Int?
    public var totalSize: Int64?
    public var completedSize: Int64?

    public init(
        status: ManualDownloadJobStatus,
        progress: Double? = nil,
        downloadRate: Int? = nil,
        totalSize: Int64? = nil,
        completedSize: Int64? = nil,
    ) {
        self.status = status
        self.progress = progress
        self.downloadRate = downloadRate
        self.totalSize = totalSize
        self.completedSize = completedSize
    }
}

public enum ManualDownloadStatusMapping {
    public static func qbittorrent(state: String, progress: Double) -> ManualDownloadJobStatus {
        let value = state.lowercased()
        if value.contains("error") || value == "missingfiles" {
            return .unknown
        }
        if isQBittorrentComplete(value, progress: progress) {
            return .complete
        }
        if value.contains("queued") || value == "metadl" || value == "allocating" {
            return .queued
        }
        if value.contains("download") || value.contains("stalleddl") || value.contains("checking")
            || value.contains("forceddl") || value.contains("pauseddl") || value.contains("stoppeddl")
            || value.contains("moving")
        {
            return .downloading
        }
        return .unknown
    }

    public static func deluge(state: String, progress: Double, isFinished: Bool) -> ManualDownloadJobStatus {
        let value = state.lowercased()
        if value.contains("error") {
            return .unknown
        }
        if isFinished || value.contains("seeding") {
            return progress >= 0.999 || isFinished ? .complete : .downloading
        }
        if value.contains("queued") {
            return .queued
        }
        if value.contains("downloading") || value.contains("checking") || value.contains("moving") {
            return .downloading
        }
        if value.contains("paused") {
            return progress >= 0.999 ? .complete : .downloading
        }
        if progress > 0, progress < 0.999 {
            return .downloading
        }
        return .unknown
    }

    public static func apply(
        _ live: ManualTorrentLiveStatus,
        to job: ManualDownloadJob,
        at date: Date = Date(),
    ) -> ManualDownloadJob {
        var updated = job
        if job.status == .failed { return job }
        updated.status = live.status
        updated.progress = live.progress
        updated.downloadRate = live.downloadRate
        updated.totalSize = live.totalSize
        if let completed = live.completedSize {
            updated.byteCount = completed
        }
        updated.lastStatusAt = date
        updated.lastError = nil
        return updated
    }

    public static func markUnknown(_ job: ManualDownloadJob, at date: Date = Date()) -> ManualDownloadJob {
        if job.status == .failed || job.status == .complete { return job }
        var updated = job
        updated.status = .unknown
        updated.lastStatusAt = date
        return updated
    }

    private static func isQBittorrentComplete(_ state: String, progress: Double) -> Bool {
        if state.contains("uploading") || state.contains("stalledup") || state.contains("pausedup")
            || state.contains("queuedup") || state.contains("forcedup") || state.contains("checkingup")
        {
            return true
        }
        if state.contains("paused") || state.contains("stopped") {
            return progress >= 0.999
        }
        return progress >= 0.999 && (state.contains("seed") || state.contains("up"))
    }
}
