//
//  PodcastSyncMerge.swift
//  SilveranKit
//
//  Cross-device podcast sync: subscriptions + episode playheads (not downloads).
//  LWW per feed URL / episode id. Union never drops the other device's unrelated
//  shows or episodes. Unsubscribe / finished use tombstones.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// One subscribed (or unsubscribed) feed for sync transport.
public struct InkampPodcastSubscriptionRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String { feedURL }
    public var feedURL: String
    public var title: String?
    public var addedAt: Date
    public var updatedAt: Date
    /// Tombstone — other devices should drop the show from the subscribed list.
    public var unsubscribed: Bool

    public init(
        feedURL: String,
        title: String? = nil,
        addedAt: Date = Date(),
        updatedAt: Date = Date(),
        unsubscribed: Bool = false
    ) {
        self.feedURL = feedURL
        self.title = title
        self.addedAt = addedAt
        self.updatedAt = updatedAt
        self.unsubscribed = unsubscribed
    }
}

/// One RSS episode playhead for sync transport (keyed by episode id).
public struct InkampPodcastPlayheadRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String { episodeID }
    public var episodeID: String
    public var positionSeconds: TimeInterval
    public var durationSeconds: TimeInterval?
    public var feedURL: String?
    public var showTitle: String?
    public var updatedAt: Date
    /// Finished / near-end — other devices should not resume mid-episode.
    public var cleared: Bool

    public init(
        episodeID: String,
        positionSeconds: TimeInterval = 0,
        durationSeconds: TimeInterval? = nil,
        feedURL: String? = nil,
        showTitle: String? = nil,
        updatedAt: Date = Date(),
        cleared: Bool = false
    ) {
        self.episodeID = episodeID
        self.positionSeconds = max(0, positionSeconds)
        self.durationSeconds = durationSeconds
        self.feedURL = feedURL
        self.showTitle = showTitle
        self.updatedAt = updatedAt
        self.cleared = cleared
    }
}

/// Blob on Storyteller (private collection description) for phone ↔ iPad
/// podcast subscriptions + playheads. Same auth as Stats / YouTube playheads.
public struct InkampPodcastSyncDocument: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let collectionName = ".inkamp.podcastSync.v1"

    public var schemaVersion: Int
    public var updatedAt: Date
    public var subscriptions: [InkampPodcastSubscriptionRecord]
    public var playheads: [InkampPodcastPlayheadRecord]

    public init(
        schemaVersion: Int = InkampPodcastSyncDocument.schemaVersion,
        updatedAt: Date = Date(),
        subscriptions: [InkampPodcastSubscriptionRecord] = [],
        playheads: [InkampPodcastPlayheadRecord] = []
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.subscriptions = subscriptions
        self.playheads = playheads
    }
}

/// Pure merge helpers — unit-tested without UI / network.
public enum PodcastSyncMerge {
    /// Last-write-wins per feed URL (by `updatedAt`). Union keeps unique feeds.
    public static func mergeSubscriptions(
        local: [InkampPodcastSubscriptionRecord],
        remote: [InkampPodcastSubscriptionRecord]
    ) -> [InkampPodcastSubscriptionRecord] {
        var byURL: [String: InkampPodcastSubscriptionRecord] = [:]
        for item in local {
            byURL[item.feedURL] = item
        }
        for item in remote {
            if let existing = byURL[item.feedURL] {
                if item.updatedAt > existing.updatedAt
                    || (item.updatedAt == existing.updatedAt && item.unsubscribed && !existing.unsubscribed)
                {
                    byURL[item.feedURL] = item
                }
            } else {
                byURL[item.feedURL] = item
            }
        }
        return byURL.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Last-write-wins per episode id (by `updatedAt`). Union keeps unique episodes.
    public static func mergePlayheads(
        local: [InkampPodcastPlayheadRecord],
        remote: [InkampPodcastPlayheadRecord]
    ) -> [InkampPodcastPlayheadRecord] {
        var byID: [String: InkampPodcastPlayheadRecord] = [:]
        for item in local {
            byID[item.episodeID] = item
        }
        for item in remote {
            if let existing = byID[item.episodeID] {
                if item.updatedAt > existing.updatedAt
                    || (item.updatedAt == existing.updatedAt
                        && item.positionSeconds > existing.positionSeconds)
                {
                    byID[item.episodeID] = item
                }
            } else {
                byID[item.episodeID] = item
            }
        }
        return byID.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public static func mergeDocuments(
        local: InkampPodcastSyncDocument,
        remote: InkampPodcastSyncDocument
    ) -> InkampPodcastSyncDocument {
        InkampPodcastSyncDocument(
            updatedAt: max(max(local.updatedAt, remote.updatedAt), Date()),
            subscriptions: mergeSubscriptions(
                local: local.subscriptions,
                remote: remote.subscriptions
            ),
            playheads: mergePlayheads(local: local.playheads, remote: remote.playheads)
        )
    }

    public static func encodeDescription(_ document: InkampPodcastSyncDocument) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        guard let string = String(data: data, encoding: .utf8) else {
            throw PodcastSyncEncodeError.utf8
        }
        return string
    }

    public static func decodeDescription(_ string: String) throws -> InkampPodcastSyncDocument {
        guard let data = string.data(using: .utf8) else {
            throw PodcastSyncEncodeError.utf8
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(InkampPodcastSyncDocument.self, from: data)
    }
}

public enum PodcastSyncEncodeError: Error, Sendable {
    case utf8
}

/// UserDefaults key for last successful podcast sync (Settings + coordinator).
public enum InkampPodcastSyncDefaults {
    public static let lastSuccessfulSyncAtKey = "punkRally.podcastSync.lastSuccessfulSyncAt.v1"
}
