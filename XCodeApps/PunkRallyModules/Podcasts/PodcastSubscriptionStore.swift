//
//  PodcastSubscriptionStore.swift
//  ink+amp
//
//  Ported from Enve Book Player (AGPL-3.0-only):
//  https://github.com/opisaac9001/Enve-Book-Player
//  Original: ios/enve/Services/Integrations/PodcastSubscriptionStore.swift
//  Modifications: UserDefaults-backed; no Audiobookshelf coupling; RSS-only;
//  cross-device sync tombstones via `.inkamp.podcastSync.v1`.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit

/// Local persistence for podcast subscriptions.
/// v1 keeps subscriptions in UserDefaults (app group) — lightweight, no SwiftData migration
/// needed against SilveranKit's own persistence. Can be swapped for SwiftData in a later milestone.
public struct PodcastSubscriptionStore: Sendable {
    private static let defaultsKey = "punkRally.podcastSubscriptions.v1"
    private static let maxTombstones = 120

    public static let shared = PodcastSubscriptionStore()
    private init() {}

    private var defaults: UserDefaults {
        // Use the app group when available (widgets share), else standard.
        if let group = UserDefaults(suiteName: "group.com.punkrally.reader") {
            return group
        }
        return .standard
    }

    /// Active subscriptions only (no unsubscribe tombstones).
    public func loadSubscriptions() -> [PRPodcastSubscription] {
        loadAll().filter { !$0.unsubscribed }
    }

    /// Active + tombstones for sync export.
    public func loadAllForSync() -> [PRPodcastSubscription] {
        loadAll()
    }

    public func saveSubscriptions(_ subs: [PRPodcastSubscription]) {
        persist(subs)
    }

    public func isSubscribed(to feedURL: URL) -> Bool {
        loadSubscriptions().contains { $0.feedURL == feedURL }
    }

    public mutating func subscribe(to feedURL: URL, title: String? = nil) {
        var all = loadAll()
        let now = Date()
        if let index = all.firstIndex(where: { $0.feedURL == feedURL }) {
            all[index].unsubscribed = false
            all[index].updatedAt = now
            if let title, !title.isEmpty {
                all[index].title = title
            }
        } else {
            all.append(
                PRPodcastSubscription(
                    feedURL: feedURL,
                    addedAt: now,
                    title: title,
                    updatedAt: now,
                    unsubscribed: false
                )
            )
        }
        persist(prune(all))
    }

    public mutating func unsubscribe(from feedURL: URL) {
        var all = loadAll()
        let now = Date()
        if let index = all.firstIndex(where: { $0.feedURL == feedURL }) {
            all[index].unsubscribed = true
            all[index].updatedAt = now
            all[index].lastRefreshedAt = nil
        } else {
            all.append(
                PRPodcastSubscription(
                    feedURL: feedURL,
                    addedAt: now,
                    updatedAt: now,
                    unsubscribed: true
                )
            )
        }
        persist(prune(all))
    }

    public mutating func markRefreshed(_ feedURL: URL, at date: Date = Date()) {
        var all = loadAll()
        if let index = all.firstIndex(where: { $0.feedURL == feedURL && !$0.unsubscribed }) {
            all[index].lastRefreshedAt = date
            all[index].updatedAt = date
            persist(all)
        }
    }

    public func exportSubscriptionRecords() -> [InkampPodcastSubscriptionRecord] {
        loadAll().map { sub in
            InkampPodcastSubscriptionRecord(
                feedURL: sub.feedURL.absoluteString,
                title: sub.title,
                addedAt: sub.addedAt,
                updatedAt: sub.updatedAt,
                unsubscribed: sub.unsubscribed
            )
        }
    }

    /// Replace local ledger with merged sync result (includes unsubscribe tombstones).
    public func applySubscriptionRecords(_ records: [InkampPodcastSubscriptionRecord]) {
        let mapped: [PRPodcastSubscription] = records.compactMap { record in
            guard let url = URL(string: record.feedURL), !record.feedURL.isEmpty else { return nil }
            return PRPodcastSubscription(
                feedURL: url,
                addedAt: record.addedAt,
                lastRefreshedAt: nil,
                title: record.title,
                updatedAt: record.updatedAt,
                unsubscribed: record.unsubscribed
            )
        }
        persist(prune(mapped))
    }

    private func loadAll() -> [PRPodcastSubscription] {
        guard
            let data = defaults.data(forKey: Self.defaultsKey),
            let subs = try? JSONDecoder().decode([PRPodcastSubscription].self, from: data)
        else { return [] }
        return subs
    }

    private func persist(_ subs: [PRPodcastSubscription]) {
        guard let data = try? JSONEncoder().encode(subs) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Keep all active subs; cap unsubscribe tombstones by recency.
    private func prune(_ subs: [PRPodcastSubscription]) -> [PRPodcastSubscription] {
        let active = subs.filter { !$0.unsubscribed }
        var tombs = subs.filter(\.unsubscribed).sorted { $0.updatedAt > $1.updatedAt }
        if tombs.count > Self.maxTombstones {
            tombs = Array(tombs.prefix(Self.maxTombstones))
        }
        return active + tombs
    }
}
