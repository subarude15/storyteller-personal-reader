//
//  YouTubePlayheadSyncMerge.swift
//  SilveranKit
//
//  Cross-device YouTube playhead sync: LWW per video id (by updatedAt).
//  Union never drops the other device's unrelated ids. Cleared/finished
//  tombstones win over older mid-episode positions.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// One YouTube playhead for sync transport (keyed by video id).
public struct InkampYouTubePlayheadRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String { videoID }
    public var videoID: String
    public var positionSeconds: TimeInterval
    public var durationSeconds: TimeInterval?
    public var episodeID: String?
    public var showTitle: String?
    public var updatedAt: Date
    /// Near-end / finished — other devices should drop the resume point.
    public var cleared: Bool

    public init(
        videoID: String,
        positionSeconds: TimeInterval = 0,
        durationSeconds: TimeInterval? = nil,
        episodeID: String? = nil,
        showTitle: String? = nil,
        updatedAt: Date = Date(),
        cleared: Bool = false
    ) {
        self.videoID = videoID
        self.positionSeconds = max(0, positionSeconds)
        self.durationSeconds = durationSeconds
        self.episodeID = episodeID
        self.showTitle = showTitle
        self.updatedAt = updatedAt
        self.cleared = cleared
    }

    public init(from entry: YouTubePlayheadStore.Entry) {
        self.init(
            videoID: entry.videoID,
            positionSeconds: entry.positionSeconds,
            durationSeconds: entry.durationSeconds,
            episodeID: entry.episodeID,
            showTitle: entry.showTitle,
            updatedAt: entry.updatedAt,
            cleared: entry.cleared
        )
    }

    public func asStoreEntry() -> YouTubePlayheadStore.Entry {
        YouTubePlayheadStore.Entry(
            videoID: videoID,
            positionSeconds: positionSeconds,
            durationSeconds: durationSeconds,
            episodeID: episodeID,
            showTitle: showTitle,
            updatedAt: updatedAt,
            cleared: cleared
        )
    }
}

/// Blob stored on Storyteller (private collection description) for phone ↔ iPad
/// YouTube playheads. Same auth as Stats / place sync.
public struct InkampYouTubePlayheadSyncDocument: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let collectionName = ".inkamp.youtubePlayheads.v1"

    public var schemaVersion: Int
    public var updatedAt: Date
    public var playheads: [InkampYouTubePlayheadRecord]

    public init(
        schemaVersion: Int = InkampYouTubePlayheadSyncDocument.schemaVersion,
        updatedAt: Date = Date(),
        playheads: [InkampYouTubePlayheadRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.playheads = playheads
    }
}

/// Pure merge helpers — unit-tested without UI / network.
public enum YouTubePlayheadSyncMerge {
    /// Last-write-wins per `videoID` (by `updatedAt`). Union never drops a side's unique ids.
    public static func mergePlayheads(
        local: [InkampYouTubePlayheadRecord],
        remote: [InkampYouTubePlayheadRecord]
    ) -> [InkampYouTubePlayheadRecord] {
        var byID: [String: InkampYouTubePlayheadRecord] = [:]
        for item in local {
            byID[item.videoID] = item
        }
        for item in remote {
            if let existing = byID[item.videoID] {
                if item.updatedAt > existing.updatedAt
                    || (item.updatedAt == existing.updatedAt
                        && item.positionSeconds > existing.positionSeconds)
                {
                    byID[item.videoID] = item
                }
            } else {
                byID[item.videoID] = item
            }
        }
        return byID.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public static func mergeDocuments(
        local: InkampYouTubePlayheadSyncDocument,
        remote: InkampYouTubePlayheadSyncDocument
    ) -> InkampYouTubePlayheadSyncDocument {
        InkampYouTubePlayheadSyncDocument(
            updatedAt: max(max(local.updatedAt, remote.updatedAt), Date()),
            playheads: mergePlayheads(local: local.playheads, remote: remote.playheads)
        )
    }

    public static func encodeDescription(_ document: InkampYouTubePlayheadSyncDocument) throws
        -> String
    {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        guard let string = String(data: data, encoding: .utf8) else {
            throw YouTubePlayheadSyncEncodeError.utf8
        }
        return string
    }

    public static func decodeDescription(_ string: String) throws -> InkampYouTubePlayheadSyncDocument
    {
        guard let data = string.data(using: .utf8) else {
            throw YouTubePlayheadSyncEncodeError.utf8
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(InkampYouTubePlayheadSyncDocument.self, from: data)
    }
}

public enum YouTubePlayheadSyncEncodeError: Error, Sendable {
    case utf8
}

/// UserDefaults key for last successful YouTube playhead sync (Settings + coordinator).
public enum InkampYouTubePlayheadSyncDefaults {
    public static let lastSuccessfulSyncAtKey = "punkRally.youtubePlayheads.lastSuccessfulSyncAt.v1"
}
