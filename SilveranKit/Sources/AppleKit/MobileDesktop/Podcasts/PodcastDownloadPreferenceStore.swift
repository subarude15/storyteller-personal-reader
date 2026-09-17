//
//  PodcastDownloadPreferenceStore.swift
//  SilveranAppleKit
//
//  Remembers last download choice (Original vs Clean) per show feed URL.
//
//  SPDX-License-Identifier: AGPL-3.0-only

#if os(iOS)
import Foundation
import SilveranKit

/// Per-show last Download-sheet choice for ad-strip UX.
public struct PodcastDownloadPreferenceStore: Sendable {
    public static let shared = PodcastDownloadPreferenceStore()

    private static let defaultsKey = "punkRally.podcastDownloadIntent.v1"

    private init() {}

    private var defaults: UserDefaults {
        if let group = UserDefaults(suiteName: "group.com.punkrally.reader") {
            return group
        }
        return .standard
    }

    public func lastIntent(for feedURL: URL?) -> PodcastDownloadIntent {
        guard let key = feedKey(feedURL) else { return .original }
        let raw = defaults.string(forKey: Self.defaultsKey + "." + key)
        return PodcastDownloadIntent(rawValue: raw ?? "") ?? .original
    }

    public func setLastIntent(_ intent: PodcastDownloadIntent, for feedURL: URL?) {
        guard let key = feedKey(feedURL) else { return }
        defaults.set(intent.rawValue, forKey: Self.defaultsKey + "." + key)
    }

    private func feedKey(_ feedURL: URL?) -> String? {
        feedURL?.absoluteString
    }
}
#endif
