//
//  PodcastMatchedYouTubeStore.swift
//  ink+amp
//
//  Persists a user-confirmed YouTube watch URL per RSS episode so Match on
//  YouTube does not re-search next open. Local only (UserDefaults).
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit

/// Episode id → confirmed watch URL chosen via Match on YouTube.
public struct PodcastMatchedYouTubeStore: Sendable {
    private static let defaultsKey = "punkRally.matchedYouTubeWatchURL.v1"

    public static let shared = PodcastMatchedYouTubeStore()
    private init() {}

    private var defaults: UserDefaults {
        if let group = UserDefaults(suiteName: "group.com.punkrally.reader") {
            return group
        }
        return .standard
    }

    public func watchURL(for episodeID: String) -> URL? {
        guard let raw = loadMap()[episodeID],
            let url = URL(string: raw),
            PodcastYouTubeURL.videoID(from: url) != nil
        else { return nil }
        return PodcastYouTubeURL.normalizedWatchURL(url) ?? url
    }

    public func save(watchURL: URL, for episodeID: String) {
        guard let normalized = PodcastYouTubeURL.normalizedWatchURL(watchURL)
            ?? (PodcastYouTubeURL.videoID(from: watchURL) != nil ? watchURL : nil)
        else { return }
        var map = loadMap()
        map[episodeID] = normalized.absoluteString
        saveMap(map)
    }

    public func remove(for episodeID: String) {
        var map = loadMap()
        map.removeValue(forKey: episodeID)
        saveMap(map)
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
