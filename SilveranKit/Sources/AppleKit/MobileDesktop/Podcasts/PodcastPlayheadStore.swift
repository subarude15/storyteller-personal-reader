//
//  PodcastPlayheadStore.swift
//  SilveranAppleKit
//
//  Last playhead for RSS episodes (streaming + downloaded). Separate from the
//  download ledger so Vergecast-style stream plays still resume after close.
//  Cross-device sync via `.inkamp.podcastSync.v1` (PodcastSyncCoordinator).
//
//  SPDX-License-Identifier: AGPL-3.0-only

#if os(iOS)
import Foundation
import SilveranKit

/// Persists RSS episode playheads on-device (UserDefaults app group when available).
public struct PodcastPlayheadStore: Sendable {
    public static let shared = PodcastPlayheadStore()

    private static let defaultsKey = "punkRally.podcastPlayheads.v1"
    private static let maxEntries = 80

    private init() {}

    public struct Entry: Codable, Equatable, Sendable {
        public var episodeID: String
        public var positionSeconds: TimeInterval
        public var durationSeconds: TimeInterval?
        public var feedURL: String?
        public var showTitle: String?
        public var updatedAt: Date
        /// Finished / near-end tombstone for cross-device sync.
        public var cleared: Bool

        private enum CodingKeys: String, CodingKey {
            case episodeID
            case positionSeconds
            case durationSeconds
            case feedURL
            case showTitle
            case updatedAt
            case cleared
        }

        public init(
            episodeID: String,
            positionSeconds: TimeInterval,
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

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            episodeID = try container.decode(String.self, forKey: .episodeID)
            positionSeconds = try container.decode(TimeInterval.self, forKey: .positionSeconds)
            durationSeconds = try container.decodeIfPresent(
                TimeInterval.self,
                forKey: .durationSeconds
            )
            feedURL = try container.decodeIfPresent(String.self, forKey: .feedURL)
            showTitle = try container.decodeIfPresent(String.self, forKey: .showTitle)
            updatedAt = try container.decode(Date.self, forKey: .updatedAt)
            cleared = try container.decodeIfPresent(Bool.self, forKey: .cleared) ?? false
        }

        public var progress: Double {
            guard let durationSeconds, durationSeconds > 0 else { return 0 }
            return min(max(positionSeconds / durationSeconds, 0), 1)
        }
    }

    private var defaults: UserDefaults {
        if let group = UserDefaults(suiteName: "group.com.punkrally.reader") {
            return group
        }
        return .standard
    }

    public func position(for episodeID: String) -> TimeInterval? {
        guard let entry = entry(for: episodeID), !entry.cleared else { return nil }
        return entry.positionSeconds
    }

    public func entry(for episodeID: String) -> Entry? {
        load().first(where: { $0.episodeID == episodeID && !$0.cleared })
    }

    /// All entries including cleared tombstones (for sync export).
    public func allEntriesForSync() -> [Entry] {
        load()
    }

    public func replaceAllForSync(_ entries: [Entry]) {
        var items = entries.sorted { $0.updatedAt > $1.updatedAt }
        if items.count > Self.maxEntries {
            items = Array(items.prefix(Self.maxEntries))
        }
        persist(items)
    }

    /// Save playhead. Near-end (≥95%) writes a cleared tombstone so sync
    /// does not resurrect an older mid-episode position from another device.
    public func save(
        episodeID: String,
        positionSeconds: TimeInterval,
        durationSeconds: TimeInterval?,
        feedURL: String? = nil,
        showTitle: String? = nil,
        markFinished: Bool = false
    ) {
        let finished: Bool = {
            if markFinished { return true }
            guard let durationSeconds, durationSeconds > 0 else { return false }
            return positionSeconds / durationSeconds >= 0.95
        }()

        let prior = load().first(where: { $0.episodeID == episodeID })
        var items = load().filter { $0.episodeID != episodeID }
        if finished {
            items.insert(
                Entry(
                    episodeID: episodeID,
                    positionSeconds: 0,
                    durationSeconds: durationSeconds ?? prior?.durationSeconds,
                    feedURL: feedURL ?? prior?.feedURL,
                    showTitle: showTitle ?? prior?.showTitle,
                    updatedAt: Date(),
                    cleared: true
                ),
                at: 0
            )
        } else if positionSeconds >= 1 {
            items.insert(
                Entry(
                    episodeID: episodeID,
                    positionSeconds: positionSeconds,
                    durationSeconds: durationSeconds,
                    feedURL: feedURL ?? prior?.feedURL,
                    showTitle: showTitle ?? prior?.showTitle
                ),
                at: 0
            )
        }
        if items.count > Self.maxEntries {
            items = Array(items.prefix(Self.maxEntries))
        }
        persist(items)
    }

    public func clear(episodeID: String) {
        let prior = load().first(where: { $0.episodeID == episodeID })
        var items = load().filter { $0.episodeID != episodeID }
        items.insert(
            Entry(
                episodeID: episodeID,
                positionSeconds: 0,
                durationSeconds: prior?.durationSeconds,
                feedURL: prior?.feedURL,
                showTitle: prior?.showTitle,
                updatedAt: Date(),
                cleared: true
            ),
            at: 0
        )
        if items.count > Self.maxEntries {
            items = Array(items.prefix(Self.maxEntries))
        }
        persist(items)
    }

    public func exportPlayheadRecords() -> [InkampPodcastPlayheadRecord] {
        load().map { entry in
            InkampPodcastPlayheadRecord(
                episodeID: entry.episodeID,
                positionSeconds: entry.positionSeconds,
                durationSeconds: entry.durationSeconds,
                feedURL: entry.feedURL,
                showTitle: entry.showTitle,
                updatedAt: entry.updatedAt,
                cleared: entry.cleared
            )
        }
    }

    public func applyPlayheadRecords(_ records: [InkampPodcastPlayheadRecord]) {
        replaceAllForSync(
            records.map { record in
                Entry(
                    episodeID: record.episodeID,
                    positionSeconds: record.positionSeconds,
                    durationSeconds: record.durationSeconds,
                    feedURL: record.feedURL,
                    showTitle: record.showTitle,
                    updatedAt: record.updatedAt,
                    cleared: record.cleared
                )
            }
        )
    }

    private func load() -> [Entry] {
        guard
            let data = defaults.data(forKey: Self.defaultsKey),
            let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return decoded
    }

    private func persist(_ items: [Entry]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
#endif
