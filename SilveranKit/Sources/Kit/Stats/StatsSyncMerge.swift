//
//  StatsSyncMerge.swift
//  SilveranKit
//
//  Cross-device Stats sync: session-id last-write-wins merge (no double-count,
//  totals never drop when folding remote into local).
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// One recorded media session for Stats sync transport.
public struct InkampStatsSessionRecord: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case reading
        case listening
    }

    public var id: UUID
    public var kind: Kind
    public var mediaID: String
    public var mediaTitle: String
    public var startedAt: Date
    public var endedAt: Date
    public var durationSeconds: TimeInterval
    public var endProgress: Double?
    /// Actual medium played: "ebook" | "audiobook" | "readaloud" | "podcast".
    public var medium: String?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        mediaID: String,
        mediaTitle: String,
        startedAt: Date,
        endedAt: Date,
        durationSeconds: TimeInterval,
        endProgress: Double? = nil,
        medium: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.mediaID = mediaID
        self.mediaTitle = mediaTitle
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.endProgress = endProgress
        self.medium = medium
    }
}

public struct InkampStatsFinishedRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: String { mediaID }
    public var mediaID: String
    public var mediaTitle: String
    public var finishedAt: Date

    public init(mediaID: String, mediaTitle: String, finishedAt: Date) {
        self.mediaID = mediaID
        self.mediaTitle = mediaTitle
        self.finishedAt = finishedAt
    }
}

/// Blob stored on Storyteller (private collection description) for phone ↔ iPad Stats.
public struct InkampStatsSyncDocument: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let collectionName = ".inkamp.stats.v1"

    public var schemaVersion: Int
    public var updatedAt: Date
    public var sessions: [InkampStatsSessionRecord]
    public var finished: [InkampStatsFinishedRecord]

    public init(
        schemaVersion: Int = InkampStatsSyncDocument.schemaVersion,
        updatedAt: Date = Date(),
        sessions: [InkampStatsSessionRecord] = [],
        finished: [InkampStatsFinishedRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.sessions = sessions
        self.finished = finished
    }
}

/// Pure merge helpers — unit-tested without UI / network.
public enum StatsSyncMerge {
    /// Last-write-wins per session `id` (by `endedAt`). Union never drops a side's unique sessions.
    public static func mergeSessions(
        local: [InkampStatsSessionRecord],
        remote: [InkampStatsSessionRecord]
    ) -> [InkampStatsSessionRecord] {
        var byID: [UUID: InkampStatsSessionRecord] = [:]
        for session in local {
            byID[session.id] = session
        }
        for session in remote {
            if let existing = byID[session.id] {
                if session.endedAt > existing.endedAt
                    || (session.endedAt == existing.endedAt
                        && session.durationSeconds > existing.durationSeconds)
                {
                    byID[session.id] = session
                }
            } else {
                byID[session.id] = session
            }
        }
        return byID.values.sorted { $0.endedAt < $1.endedAt }
    }

    /// Last-write-wins per `mediaID` (by `finishedAt`).
    public static func mergeFinished(
        local: [InkampStatsFinishedRecord],
        remote: [InkampStatsFinishedRecord]
    ) -> [InkampStatsFinishedRecord] {
        var byID: [String: InkampStatsFinishedRecord] = [:]
        for item in local {
            byID[item.mediaID] = item
        }
        for item in remote {
            if let existing = byID[item.mediaID] {
                if item.finishedAt > existing.finishedAt {
                    byID[item.mediaID] = item
                }
            } else {
                byID[item.mediaID] = item
            }
        }
        return byID.values.sorted { $0.finishedAt < $1.finishedAt }
    }

    public static func mergeDocuments(
        local: InkampStatsSyncDocument,
        remote: InkampStatsSyncDocument
    ) -> InkampStatsSyncDocument {
        InkampStatsSyncDocument(
            updatedAt: max(max(local.updatedAt, remote.updatedAt), Date()),
            sessions: mergeSessions(local: local.sessions, remote: remote.sessions),
            finished: mergeFinished(local: local.finished, remote: remote.finished)
        )
    }

    /// Encode for Storyteller collection `description` (UTF-8 JSON).
    public static func encodeDescription(_ document: InkampStatsSyncDocument) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        guard let string = String(data: data, encoding: .utf8) else {
            throw StatsSyncEncodeError.utf8
        }
        return string
    }

    public static func decodeDescription(_ string: String) throws -> InkampStatsSyncDocument {
        guard let data = string.data(using: .utf8) else {
            throw StatsSyncEncodeError.utf8
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(InkampStatsSyncDocument.self, from: data)
    }
}

public enum StatsSyncEncodeError: Error, Sendable {
    case utf8
}

/// UserDefaults key for last successful Stats sync (Settings + coordinator).
public enum InkampStatsSyncDefaults {
    public static let lastSuccessfulSyncAtKey = "punkRally.stats.lastSuccessfulSyncAt.v1"
}
