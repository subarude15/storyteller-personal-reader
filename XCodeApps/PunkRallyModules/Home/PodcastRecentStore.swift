//
//  PodcastRecentStore.swift
//  ink+amp
//
//  Last-touched podcast episodes for Home mixed Continue / Up next.
//  Separate from the download ledger so streaming plays still appear.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// One recently played RSS episode (Home last-touched ordering).
public struct PodcastRecentEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: String { episodeID }
    public let episodeID: String
    public var title: String
    public var showTitle: String?
    public var coverURL: URL?
    public var audioURL: URL
    public var durationSeconds: TimeInterval?
    public var feedURL: URL?
    public var mediaKind: PRPodcastMediaKind
    public var lastTouched: Date
    public var progress: Double
    /// Watch URL when this recent is in-app YouTube (re-resolve on Continue).
    public var youtubeURL: URL?

    public init(
        episodeID: String,
        title: String,
        showTitle: String? = nil,
        coverURL: URL? = nil,
        audioURL: URL,
        durationSeconds: TimeInterval? = nil,
        feedURL: URL? = nil,
        mediaKind: PRPodcastMediaKind = .audio,
        lastTouched: Date = Date(),
        progress: Double = 0,
        youtubeURL: URL? = nil
    ) {
        self.episodeID = episodeID
        self.title = title
        self.showTitle = showTitle
        self.coverURL = coverURL
        self.audioURL = audioURL
        self.durationSeconds = durationSeconds
        self.feedURL = feedURL
        self.mediaKind = mediaKind
        self.lastTouched = lastTouched
        self.progress = min(max(progress, 0), 1)
        self.youtubeURL = youtubeURL
    }
}

/// Persists recent podcast plays for the Home mixed rail.
public struct PodcastRecentStore: Sendable {
    private static let defaultsKey = "punkRally.podcastRecents.v1"
    private static let maxEntries = 30

    public static let shared = PodcastRecentStore()
    private init() {}

    private var defaults: UserDefaults {
        if let group = UserDefaults(suiteName: "group.com.punkrally.reader") {
            return group
        }
        return .standard
    }

    public func all() -> [PodcastRecentEntry] {
        load().sorted { $0.lastTouched > $1.lastTouched }
    }

    public func record(_ entry: PodcastRecentEntry) {
        var items = load().filter { $0.episodeID != entry.episodeID }
        items.insert(entry, at: 0)
        if items.count > Self.maxEntries {
            items = Array(items.prefix(Self.maxEntries))
        }
        save(items)
    }

    public func updateProgress(episodeID: String, progress: Double, at date: Date = Date()) {
        var items = load()
        guard let index = items.firstIndex(where: { $0.episodeID == episodeID }) else { return }
        items[index].progress = min(max(progress, 0), 1)
        items[index].lastTouched = date
        save(items)
    }

    private func load() -> [PodcastRecentEntry] {
        guard
            let data = defaults.data(forKey: Self.defaultsKey),
            let decoded = try? JSONDecoder().decode([PodcastRecentEntry].self, from: data)
        else { return [] }
        return decoded
    }

    private func save(_ items: [PodcastRecentEntry]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
