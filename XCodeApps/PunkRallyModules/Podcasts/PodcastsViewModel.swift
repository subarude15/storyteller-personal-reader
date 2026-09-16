//
//  PodcastsViewModel.swift
//  ink+amp
//
//  Ported from Enve Book Player (AGPL-3.0-only):
//  https://github.com/opisaac9001/Enve-Book-Player
//  Original: ios/enve/Screens/Podcasts/PodcastsModel.swift
//  Modifications: RSS-only (no server shows); subscription store integration;
//  ink+amp presentation state.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Observation
import SwiftUI
import SilveranAppleKit
import SilveranKit

@MainActor
@Observable
final class PodcastsViewModel {
    private var store = PodcastSubscriptionStore.shared

    private(set) var shows: [PRPodcastShow] = []
    private(set) var isLoading = false
    private(set) var loadFailed = false
    private var lastLoadDate: Date?

    var subscriptions: [PRPodcastSubscription] {
        store.loadSubscriptions()
    }

    var subscribedFeedURLs: [URL] {
        subscriptions.map(\.feedURL)
    }

    var hasAnySubscription: Bool {
        !subscriptions.isEmpty
    }

    var playableShows: [PRPodcastShow] {
        shows.filter { !$0.episodes.isEmpty }
    }

    func show(for feedURL: URL) -> PRPodcastShow? {
        shows.first { $0.feedURL == feedURL }
    }

    /// Load all subscribed feeds. Skips a refresh if we loaded < 5 minutes ago.
    func loadIfNeeded() async {
        guard !isLoading else { return }
        if let lastLoadDate, Date().timeIntervalSince(lastLoadDate) < 300, !shows.isEmpty {
            return
        }
        await load()
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        loadFailed = false

        var loaded: [PRPodcastShow] = []
        for feed in subscribedFeedURLs {
            if let show = await fetchFeed(feed) {
                loaded.append(show)
            }
        }
        shows = loaded
        loadFailed = loaded.isEmpty && hasAnySubscription
        lastLoadDate = Date()
        isLoading = false
    }

    func refreshFeed(_ feedURL: URL) async {
        guard let show = await fetchFeed(feedURL) else { return }
        if let index = shows.firstIndex(where: { $0.feedURL == feedURL }) {
            shows[index] = show
        } else {
            shows.append(show)
        }
        store.markRefreshed(feedURL)
    }

    /// Subscribe only after the RSS feed loads successfully.
    @discardableResult
    func subscribe(feedURL: URL) async -> Bool {
        guard let show = await fetchFeed(feedURL) else { return false }
        store.subscribe(to: feedURL)
        if let index = shows.firstIndex(where: { $0.feedURL == feedURL }) {
            shows[index] = show
        } else {
            shows.append(show)
        }
        store.markRefreshed(feedURL)
        return true
    }

    func isSubscribed(to feedURL: URL) -> Bool {
        store.isSubscribed(to: feedURL)
    }

    func unsubscribe(feedURL: URL) async {
        store.unsubscribe(from: feedURL)
        shows.removeAll { $0.feedURL == feedURL }
    }

    func removeAllFeeds() async {
        var subs = subscriptions
        for sub in subs {
            store.unsubscribe(from: sub.feedURL)
            shows.removeAll { $0.feedURL == sub.feedURL }
        }
        subs.removeAll()
    }

    // MARK: - Playback

    func playNext(
        episode: PRPodcastEpisode,
        mediaKind: PRPodcastMediaKind? = nil,
        feedURL: URL? = nil
    ) {
        Task {
            let kind = resolvedMediaKind(for: episode, feedURL: feedURL, override: mediaKind)
            guard let item = makeQueueItem(episode: episode, mediaKind: kind, feedURL: feedURL) else {
                return
            }
            let startNow = await PodcastPlaybackQueueStore.shared.enqueuePlayNext(item)
            if startNow {
                play(episode: episode, mediaKind: kind, feedURL: feedURL)
            }
        }
    }

    func playLast(
        episode: PRPodcastEpisode,
        mediaKind: PRPodcastMediaKind? = nil,
        feedURL: URL? = nil
    ) {
        Task {
            let kind = resolvedMediaKind(for: episode, feedURL: feedURL, override: mediaKind)
            guard let item = makeQueueItem(episode: episode, mediaKind: kind, feedURL: feedURL) else {
                return
            }
            let startNow = await PodcastPlaybackQueueStore.shared.enqueuePlayLast(item)
            if startNow {
                play(episode: episode, mediaKind: kind, feedURL: feedURL)
            }
        }
    }

    /// Sends an episode to Silveran's shared player (mini-player / Now
    /// Playing / PlaybackRateButton — same path as audiobooks) via a plain
    /// NotificationCenter bridge. Prefer local download for audio when present.
    /// For dual-enclosure episodes, pass the chosen `mediaKind` (Audio | Video).
    func play(
        episode: PRPodcastEpisode,
        mediaKind: PRPodcastMediaKind = .audio,
        feedURL: URL? = nil
    ) {
        let remote: URL?
        switch mediaKind {
            case .audio:
                remote = episode.audioURL
            case .video:
                remote = episode.videoURL ?? episode.audioURL
        }
        guard let remote else { return }

        if let feedURL {
            PodcastMediaPreferenceStore.shared.setPreference(mediaKind, for: feedURL)
        }

        let playURL: URL
        if mediaKind == .audio,
            let local = PodcastDownloadStore.shared.localAudioURL(for: episode.id)
        {
            playURL = local
        } else {
            playURL = remote
        }

        var userInfo: [String: Any] = [
            "episodeID": episode.id,
            "title": episode.title,
            "audioURL": playURL,
            "mediaKind": mediaKind.rawValue,
        ]
        userInfo["summary"] = episode.summary
        userInfo["showTitle"] = episode.showTitle
        if let duration = episode.durationSeconds {
            userInfo["durationSeconds"] = duration
        }
        if let cover = episode.coverURL {
            userInfo["coverURL"] = cover
        }
        if let feedURL {
            userInfo["feedURL"] = feedURL
        }
        if let youtube = episode.watchOnYouTubeURL {
            userInfo["youtubeURL"] = youtube
        }

        PodcastRecentStore.shared.record(
            PodcastRecentEntry(
                episodeID: episode.id,
                title: episode.title,
                showTitle: episode.showTitle,
                coverURL: episode.coverURL,
                audioURL: playURL,
                durationSeconds: episode.durationSeconds,
                feedURL: feedURL,
                mediaKind: mediaKind,
                lastTouched: Date(),
                progress: Self.recentProgress(for: episode),
                youtubeURL: episode.watchOnYouTubeURL
            )
        )

        NotificationCenter.default.post(
            name: Notification.Name("punkRallyPlayPodcastEpisode"),
            object: nil,
            userInfo: userInfo
        )
    }

    /// Resolve YouTube via Settings URL and play on the shared video path.
    /// Returns false on resolve failure (caller toasts / hands off).
    @discardableResult
    func playYouTubeInApp(
        episode: PRPodcastEpisode,
        watchURL: URL,
        feedURL: URL? = nil
    ) async -> Bool {
        do {
            let pick = try await PodcastYouTubeResolver.shared.resolve(watchURL: watchURL)
            var userInfo: [String: Any] = [
                "episodeID": episode.id,
                "title": episode.title,
                "audioURL": pick.url,
                "mediaKind": PRPodcastMediaKind.video.rawValue,
                "youtubeURL": watchURL,
            ]
            userInfo["summary"] = episode.summary
            userInfo["showTitle"] = episode.showTitle
            if let duration = episode.durationSeconds {
                userInfo["durationSeconds"] = duration
            }
            if let cover = episode.coverURL {
                userInfo["coverURL"] = cover
            }
            if let feedURL {
                userInfo["feedURL"] = feedURL
            }

            PodcastRecentStore.shared.record(
                PodcastRecentEntry(
                    episodeID: episode.id,
                    title: episode.title,
                    showTitle: episode.showTitle,
                    coverURL: episode.coverURL,
                    audioURL: pick.url,
                    durationSeconds: episode.durationSeconds,
                    feedURL: feedURL,
                    mediaKind: .video,
                    lastTouched: Date(),
                    progress: Self.recentProgress(for: episode, youtubeURL: watchURL),
                    youtubeURL: watchURL
                )
            )

            NotificationCenter.default.post(
                name: Notification.Name("punkRallyPlayPodcastEpisode"),
                object: nil,
                userInfo: userInfo
            )
            return true
        } catch {
            NotificationCenter.default.post(name: .punkRallyYouTubeResolveFailed, object: nil)
            return false
        }
    }

    private func resolvedMediaKind(
        for episode: PRPodcastEpisode,
        feedURL: URL?,
        override: PRPodcastMediaKind?
    ) -> PRPodcastMediaKind {
        if let override { return override }
        if episode.hasAudioAndVideo, let feedURL {
            // Prefer Video when the show has no saved A|V choice yet.
            return PodcastMediaPreferenceStore.shared.preference(for: feedURL) ?? .video
        }
        if episode.videoURL != nil, episode.audioURL == nil { return .video }
        return .audio
    }

    private func makeQueueItem(
        episode: PRPodcastEpisode,
        mediaKind: PRPodcastMediaKind,
        feedURL: URL?
    ) -> PodcastPlaybackQueueItem? {
        let remote: URL?
        switch mediaKind {
            case .audio:
                remote = episode.audioURL
            case .video:
                remote = episode.videoURL ?? episode.audioURL
        }
        guard let remote else { return nil }

        let playURL: URL
        if mediaKind == .audio,
            let local = PodcastDownloadStore.shared.localAudioURL(for: episode.id)
        {
            playURL = local
        } else {
            playURL = remote
        }

        return PodcastPlaybackQueueItem(
            episodeID: episode.id,
            title: episode.title,
            showTitle: episode.showTitle,
            summary: episode.summary,
            audioURL: playURL,
            durationSeconds: episode.durationSeconds,
            coverURL: episode.coverURL,
            feedURL: feedURL,
            mediaKindRaw: mediaKind.rawValue,
            youtubeURL: episode.watchOnYouTubeURL
        )
    }

    // MARK: - Fetch

    private func fetchFeed(_ feedURL: URL) async -> PRPodcastShow? {
        var request = URLRequest(url: feedURL)
        request.setValue("ink-amp/1.0 (RSS Podcast Client)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let parser = RSSPodcastParser()
            return parser.parse(data, feedURL: feedURL)
        } catch {
            return nil
        }
    }

    /// Prefer YouTube playhead progress when a watch URL is known; else download ledger.
    private static func recentProgress(
        for episode: PRPodcastEpisode,
        youtubeURL: URL? = nil
    ) -> Double {
        let watch = youtubeURL ?? episode.watchOnYouTubeURL
        if let watch,
            let videoID = PodcastYouTubeURL.videoID(from: watch),
            let entry = YouTubePlayheadStore.shared.entry(for: videoID)
        {
            return entry.progress
        }
        if let playhead = PodcastPlayheadStore.shared.entry(for: episode.id) {
            return playhead.progress
        }
        return PodcastDownloadStore.shared.record(for: episode.id)?.progress ?? 0
    }
}