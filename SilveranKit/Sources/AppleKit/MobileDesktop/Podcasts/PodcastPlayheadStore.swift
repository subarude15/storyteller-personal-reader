//
//  PodcastPlayheadStore.swift
//  SilveranAppleKit
//
//  Last playhead for RSS episodes (streaming + downloaded). Separate from the
//  download ledger so Vergecast-style stream plays still resume after close.
//
//  SPDX-License-Identifier: AGPL-3.0-only

#if os(iOS)
import Foundation

/// Persists RSS episode playheads on-device (UserDefaults app group when available).
public struct PodcastPlayheadStore: Sendable {
    public static let shared = PodcastPlayheadStore()

    private static let defaultsKey = "punkRally.podcastPlayheads.v1"
    private static let maxEntries = 80

    private init() {}

    public struct Entry: Codable, Equatable, Sendable {
        public var episodeID: String
        public var positionSeconds: TimeInterval
        public var durationSeconds: TimeInterval?
        public var updatedAt: Date

        public init(
            episodeID: String,
            positionSeconds: TimeInterval,
            durationSeconds: TimeInterval? = nil,
            updatedAt: Date = Date()
        ) {
            self.episodeID = episodeID
            self.positionSeconds = max(0, positionSeconds)
            self.durationSeconds = durationSeconds
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

    public func position(for episodeID: String) -> TimeInterval? {
        load().first(where: { $0.episodeID == episodeID })?.positionSeconds
    }

    public func entry(for episodeID: String) -> Entry? {
        load().first(where: { $0.episodeID == episodeID })
    }

    /// Save playhead. Near-end (≥95%) clears so next open starts fresh.
    public func save(
        episodeID: String,
        positionSeconds: TimeInterval,
        durationSeconds: TimeInterval?,
        markFinished: Bool = false
    ) {
        let finished: Bool = {
            if markFinished { return true }
            guard let durationSeconds, durationSeconds > 0 else { return false }
            return positionSeconds / durationSeconds >= 0.95
        }()

        var items = load().filter { $0.episodeID != episodeID }
        if !finished, positionSeconds >= 1 {
            items.insert(
                Entry(
                    episodeID: episodeID,
                    positionSeconds: positionSeconds,
                    durationSeconds: durationSeconds
                ),
                at: 0
            )
        }
        if items.count > Self.maxEntries {
            items = Array(items.prefix(Self.maxEntries))
        }
        persist(items)
    }

    public func clear(episodeID: String) {
        let items = load().filter { $0.episodeID != episodeID }
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
#endif
