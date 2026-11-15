//
//  CarPlayPodcastCatalog.swift
//  ink+amp
//
//  Feeds CarPlay's Podcasts / Continue tabs from app-owned podcast stores.
//
//  SPDX-License-Identifier: AGPL-3.0-only

#if os(iOS)
import Foundation
import SilveranAppleKit
import SilveranKit

enum CarPlayPodcastCatalog {
    @MainActor
    static func install() {
        CarPlayPodcastProvider.current = CarPlayPodcastProvider(
            recentEpisodes: { recentItems() },
            subscribedShows: { subscribedShows() },
            showEpisodes: { await episodeItems(for: $0) }
        )
    }

    /// CarPlay is audio-only: video and YouTube recents are skipped.
    @MainActor
    private static func recentItems() -> [CarPlayBrowseItem] {
        PodcastRecentStore.shared.all().compactMap { entry -> CarPlayBrowseItem? in
            guard entry.mediaKind == .audio, entry.youtubeURL == nil else { return nil }
            let local = PodcastDownloadStore.shared.localAudioURL(for: entry.episodeID)
            // A recent recorded from a since-deleted download has nothing to play.
            guard local != nil || !entry.audioURL.isFileURL else { return nil }
            let item = PodcastPlaybackQueueItem(
                episodeID: entry.episodeID,
                title: entry.title,
                showTitle: entry.showTitle,
                audioURL: local ?? entry.audioURL,
                durationSeconds: entry.durationSeconds,
                coverURL: entry.coverURL,
                feedURL: entry.feedURL
            )
            return CarPlayBrowseItem(
                source: .podcast(item),
                title: entry.title,
                detail: entry.showTitle,
                progress: entry.progress,
                lastTouched: entry.lastTouched,
                isLocal: local != nil
            )
        }
    }

    /// Local subscription list only; feeds are fetched when a show row is opened.
    @MainActor
    private static func subscribedShows() -> [CarPlayPodcastShow] {
        PodcastSubscriptionStore.shared.loadSubscriptions()
            .map { subscription -> CarPlayPodcastShow in
                let title = subscription.title.flatMap { $0.isEmpty ? nil : $0 }
                return CarPlayPodcastShow(
                    feedURL: subscription.feedURL,
                    title: title ?? subscription.feedURL.host ?? "Podcast"
                )
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Audio enclosures only: episodes without one (video-only or YouTube-only) are
    /// skipped, and playback never uses the video or YouTube URL.
    @MainActor
    private static func episodeItems(for subscription: CarPlayPodcastShow) async -> [CarPlayBrowseItem] {
        guard let show = await fetchShow(subscription.feedURL) else { return [] }
        let episodes = show.episodes
            .filter { $0.audioURL != nil }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }

        return episodes.compactMap { episode -> CarPlayBrowseItem? in
            guard let remote = episode.audioURL else { return nil }
            let local = PodcastDownloadStore.shared.localAudioURL(for: episode.id)
            let item = PodcastPlaybackQueueItem(
                episodeID: episode.id,
                title: episode.title,
                showTitle: episode.showTitle ?? show.title,
                audioURL: local ?? remote,
                durationSeconds: episode.durationSeconds,
                coverURL: episode.coverURL ?? show.coverURL,
                feedURL: show.feedURL ?? subscription.feedURL
            )
            return CarPlayBrowseItem(
                source: .podcast(item),
                title: episode.title,
                detail: show.title,
                progress: PodcastPlayheadStore.shared.entry(for: episode.id)?.progress,
                lastTouched: episode.publishedAt,
                isLocal: local != nil
            )
        }
    }

    private static func fetchShow(_ feedURL: URL) async -> PRPodcastShow? {
        var request = URLRequest(url: feedURL)
        request.setValue("ink-amp/1.0 (RSS Podcast Client)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        guard let result = try? await URLSession.shared.data(for: request),
            (result.1 as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return RSSPodcastParser().parse(result.0, feedURL: feedURL)
    }
}
#endif
