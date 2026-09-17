//
//  PodcastMediaPreferenceStore.swift
//  ink+amp
//
//  Remembers Audio | Video preference per podcast show (feed URL).
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Per-show enclosure preference for dual Audio | Video episodes.
public struct PodcastMediaPreferenceStore: Sendable {
    private static let defaultsKey = "punkRally.podcastMediaPreference.v1"

    public static let shared = PodcastMediaPreferenceStore()
    private init() {}

    private var defaults: UserDefaults {
        if let group = UserDefaults(suiteName: "group.com.punkrally.reader") {
            return group
        }
        return .standard
    }

    public func preference(for feedURL: URL?) -> PRPodcastMediaKind? {
        guard let key = feedKey(feedURL) else { return nil }
        guard let raw = loadMap()[key] else { return nil }
        return PRPodcastMediaKind(rawValue: raw)
    }

    public func setPreference(_ kind: PRPodcastMediaKind, for feedURL: URL?) {
        guard let key = feedKey(feedURL) else { return }
        var map = loadMap()
        map[key] = kind.rawValue
        saveMap(map)
    }

    private func feedKey(_ feedURL: URL?) -> String? {
        feedURL?.absoluteString
    }

    private func loadMap() -> [String: String] {
        guard
            let data = defaults.data(forKey: Self.defaultsKey),
            let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
    }

    private func saveMap(_ map: [String: String]) {
        guard let data = try? JSONEncoder().encode(map) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
