//
//  YouTubePlayheadStore.swift
//  SilveranKit
//
//  Local playhead for in-app YouTube (matched or feed watch URL). Keyed by
//  video id — sibling of PodcastPlayheadStore. Cross-device sync via
//  `.inkamp.youtubePlayheads.v1` (YouTubePlayheadSyncCoordinator).
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Persists YouTube video playheads on-device (UserDefaults app group when available).
public struct YouTubePlayheadStore: Sendable {
    public static let shared = YouTubePlayheadStore()

    private static let defaultsKey = "punkRally.youtubePlayheads.v1"
    private static let maxEntries = 80

    private init() {}

    public struct Entry: Codable, Equatable, Sendable {
        public var videoID: String
        public var positionSeconds: TimeInterval
        public var durationSeconds: TimeInterval?
        /// RSS episode id when known (Continue / Up next).
        public var episodeID: String?
        public var showTitle: String?
        public var updatedAt: Date
        /// Finished / near-end tombstone for cross-device sync.
        public var cleared: Bool

        public init(
            videoID: String,
            positionSeconds: TimeInterval,
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

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            videoID = try container.decode(String.self, forKey: .videoID)
            positionSeconds = try container.decode(TimeInterval.self, forKey: .positionSeconds)
            durationSeconds = try container.decodeIfPresent(
                TimeInterval.self,
                forKey: .durationSeconds
            )
            episodeID = try container.decodeIfPresent(String.self, forKey: .episodeID)
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

    public func position(for videoID: String) -> TimeInterval? {
        guard let entry = entry(for: videoID), !entry.cleared else { return nil }
        return entry.positionSeconds
    }

    public func entry(for videoID: String) -> Entry? {
        load().first(where: { $0.videoID == videoID && !$0.cleared })
    }

    /// All entries including cleared tombstones (for sync export).
    public func allEntriesForSync() -> [Entry] {
        load()
    }

    /// Replace local ledger with merged sync result (includes tombstones).
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
        videoID: String,
        positionSeconds: TimeInterval,
        durationSeconds: TimeInterval?,
        episodeID: String? = nil,
        showTitle: String? = nil,
        markFinished: Bool = false
    ) {
        let finished: Bool = {
            if markFinished { return true }
            guard let durationSeconds, durationSeconds > 0 else { return false }
            return positionSeconds / durationSeconds >= 0.95
        }()

        let prior = load().first(where: { $0.videoID == videoID })
        var items = load().filter { $0.videoID != videoID }
        if finished {
            items.insert(
                Entry(
                    videoID: videoID,
                    positionSeconds: 0,
                    durationSeconds: durationSeconds ?? prior?.durationSeconds,
                    episodeID: episodeID ?? prior?.episodeID,
                    showTitle: showTitle ?? prior?.showTitle,
                    updatedAt: Date(),
                    cleared: true
                ),
                at: 0
            )
        } else if positionSeconds >= 1 {
            items.insert(
                Entry(
                    videoID: videoID,
                    positionSeconds: positionSeconds,
                    durationSeconds: durationSeconds,
                    episodeID: episodeID ?? prior?.episodeID,
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

    public func clear(videoID: String) {
        let prior = load().first(where: { $0.videoID == videoID })
        var items = load().filter { $0.videoID != videoID }
        items.insert(
            Entry(
                videoID: videoID,
                positionSeconds: 0,
                durationSeconds: prior?.durationSeconds,
                episodeID: prior?.episodeID,
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

    public func exportSyncDocument() -> InkampYouTubePlayheadSyncDocument {
        InkampYouTubePlayheadSyncDocument(
            playheads: load().map(InkampYouTubePlayheadRecord.init(from:))
        )
    }

    /// Apply merged remote∪local document. Caller already ran YouTubePlayheadSyncMerge.
    public func applyMergedSyncDocument(_ document: InkampYouTubePlayheadSyncDocument) {
        replaceAllForSync(document.playheads.map { $0.asStoreEntry() })
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
