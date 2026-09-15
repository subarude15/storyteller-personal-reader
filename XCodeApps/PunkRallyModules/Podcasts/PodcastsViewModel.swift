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

    func subscribe(feedURL: URL) async {
        store.subscribe(to: feedURL)
        await refreshFeed(feedURL)
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
}