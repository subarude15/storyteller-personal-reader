//
//  YouTubePlayheadStore.swift
//  SilveranKit
//
//  Local playhead for in-app YouTube (matched or feed watch URL). Keyed by
//  video id — sibling of PodcastPlayheadStore. No Storyteller sync this cut.
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

        public init(
            videoID: String,
            positionSeconds: TimeInterval,
            durationSeconds: TimeInterval? = nil,
            episodeID: String? = nil,
            showTitle: String? = nil,
            updatedAt: Date = Date()
        ) {
            self.videoID = videoID
            self.positionSeconds = max(0, positionSeconds)
            self.durationSeconds = durationSeconds
            self.episodeID = episodeID
            self.showTitle = showTitle
            self.updatedAt = updatedAt
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
        entry(for: videoID)?.positionSeconds
    }

    public func entry(for videoID: String) -> Entry? {
        load().first(where: { $0.videoID == videoID })
    }

    /// Save playhead. Near-end (≥95%) clears so next open starts fresh.
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
        if !finished, positionSeconds >= 1 {
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
        let items = load().filter { $0.videoID != videoID }
        persist(items)
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
