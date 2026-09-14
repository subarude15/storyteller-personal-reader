//
//  PodcastSubscriptionStore.swift
//  punk+rally
//
//  Ported from Enve Book Player (AGPL-3.0-only):
//  https://github.com/opisaac9001/Enve-Book-Player
//  Original: ios/enve/Services/Integrations/PodcastSubscriptionStore.swift
//  Modifications: UserDefaults-backed; no Audiobookshelf coupling; RSS-only.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Local persistence for podcast subscriptions.
/// v1 keeps subscriptions in UserDefaults (app group) — lightweight, no SwiftData migration
/// needed against SilveranKit's own persistence. Can be swapped for SwiftData in a later milestone.
public struct PodcastSubscriptionStore: Sendable {
    private static let defaultsKey = "punkRally.podcastSubscriptions.v1"

    public static let shared = PodcastSubscriptionStore()
    private init() {}

    private var defaults: UserDefaults {
        // Use the app group when available (widgets share), else standard.
        if let group = UserDefaults(suiteName: "group.com.punkrally.reader") {
            return group
        }
        return .standard
    }

    public func loadSubscriptions() -> [PRPodcastSubscription] {
        guard
            let data = defaults.data(forKey: Self.defaultsKey),
            let subs = try? JSONDecoder().decode([PRPodcastSubscription].self, from: data)
        else { return [] }
        return subs
    }

    public func saveSubscriptions(_ subs: [PRPodcastSubscription]) {
        guard let data = try? JSONEncoder().encode(subs) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    public func isSubscribed(to feedURL: URL) -> Bool {
        loadSubscriptions().contains { $0.feedURL == feedURL }
    }

    public mutating func subscribe(to feedURL: URL) {
        var subs = loadSubscriptions()
        guard !subs.contains(where: { $0.feedURL == feedURL }) else { return }
        subs.append(PRPodcastSubscription(feedURL: feedURL))
        saveSubscriptions(subs)
    }

    public mutating func unsubscribe(from feedURL: URL) {
        var subs = loadSubscriptions()
        subs.removeAll { $0.feedURL == feedURL }
        saveSubscriptions(subs)
    }

    public mutating func markRefreshed(_ feedURL: URL, at date: Date = Date()) {
        var subs = loadSubscriptions()
        if let index = subs.firstIndex(where: { $0.feedURL == feedURL }) {
            subs[index].lastRefreshedAt = date
            saveSubscriptions(subs)
        }
    }
}