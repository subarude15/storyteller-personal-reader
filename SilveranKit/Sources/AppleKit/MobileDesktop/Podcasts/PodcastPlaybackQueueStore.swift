//
//  PodcastPlaybackQueueStore.swift
//  SilveranAppleKit
//
//  Persisted upcoming podcast episodes for the shared player queue.
//
//  SPDX-License-Identifier: AGPL-3.0-only

#if os(iOS)
import Foundation
import Observation
import SilveranKit

extension Notification.Name {
    /// Queue order or contents changed (UI refresh).
    public static let punkRallyPodcastPlaybackQueueDidChange = Notification.Name(
        "punkRallyPodcastPlaybackQueueDidChange"
    )
}

/// Upcoming episodes only — the live episode is owned by `AudioSessionActor`.
@MainActor
@Observable
public final class PodcastPlaybackQueueStore {
    public static let shared = PodcastPlaybackQueueStore()

    private static let defaultsKey = "punkRally.podcastPlaybackQueue.v1"

    public private(set) var upcoming: [PodcastPlaybackQueueItem] = []

    private init() {
        upcoming = Self.load()
    }

    public var count: Int { upcoming.count }

    /// Play Next: after current if playing; otherwise caller should start playback.
    public func enqueuePlayNext(_ item: PodcastPlaybackQueueItem) async -> Bool {
        let playingID = await Self.currentPodcastEpisodeID()
        if playingID == item.episodeID { return false }
        if playingID != nil {
            upcoming = PodcastPlaybackQueueEdits.playNext(upcoming: upcoming, item: item)
            persist()
            notifyChange()
            return false
        }
        upcoming.removeAll { $0.episodeID == item.episodeID }
        persist()
        notifyChange()
        return true
    }

    /// Play Last: append; if nothing playing, caller should start playback.
    public func enqueuePlayLast(_ item: PodcastPlaybackQueueItem) async -> Bool {
        let playingID = await Self.currentPodcastEpisodeID()
        if playingID == item.episodeID { return false }
        if playingID != nil {
            upcoming = PodcastPlaybackQueueEdits.playLast(upcoming: upcoming, item: item)
            persist()
            notifyChange()
            return false
        }
        upcoming.removeAll { $0.episodeID == item.episodeID }
        persist()
        notifyChange()
        return true
    }

    /// User tapped an episode to play now — drop it from upcoming without touching audio.
    public func noteManualPlay(episodeID: String) {
        let before = upcoming.count
        upcoming.removeAll { $0.episodeID == episodeID }
        guard upcoming.count != before else { return }
        persist()
        notifyChange()
    }

    public func remove(at offsets: IndexSet) {
        upcoming.remove(atOffsets: offsets)
        persist()
        notifyChange()
    }

    public func remove(episodeID: String) {
        let before = upcoming.count
        upcoming.removeAll { $0.episodeID == episodeID }
        guard upcoming.count != before else { return }
        persist()
        notifyChange()
    }

    public func move(fromOffsets: IndexSet, toOffset: Int) {
        upcoming.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persist()
        notifyChange()
    }

    /// Next episode after natural finish — removes it from persisted upcoming.
    public func consumeNext() -> PodcastPlaybackQueueItem? {
        guard !upcoming.isEmpty else { return nil }
        let item = upcoming.removeFirst()
        persist()
        notifyChange()
        return item
    }

    public func clearFinished() {
        let before = upcoming.count
        upcoming.removeAll { Self.isEpisodeFinished($0.episodeID) }
        guard upcoming.count != before else { return }
        persist()
        notifyChange()
    }

    public func clearAll() {
        guard !upcoming.isEmpty else { return }
        upcoming = []
        persist()
        notifyChange()
    }

    // MARK: - Private

    private func persist() {
        guard let data = try? JSONEncoder().encode(upcoming) else { return }
        Self.userDefaults.set(data, forKey: Self.defaultsKey)
    }

    private static func load() -> [PodcastPlaybackQueueItem] {
        guard
            let data = userDefaults.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode([PodcastPlaybackQueueItem].self, from: data)
        else { return [] }
        return decoded
    }

    private static var userDefaults: UserDefaults {
        if let group = UserDefaults(suiteName: "group.com.punkrally.reader") {
            return group
        }
        return .standard
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: .punkRallyPodcastPlaybackQueueDidChange, object: nil)
    }

    private static func currentPodcastEpisodeID() async -> String? {
        let snapshot = await AudioSessionActor.shared.currentSnapshot()
        guard case .podcast(let id) = snapshot?.kind else { return nil }
        return id
    }

    private static func isEpisodeFinished(_ episodeID: String) -> Bool {
        if let record = PodcastDownloadStore.shared.record(for: episodeID) {
            if record.isFinished || record.progress >= 0.95 { return true }
        }
        if let entry = PodcastPlayheadStore.shared.entry(for: episodeID), entry.progress >= 0.95 {
            return true
        }
        return false
    }
}
#endif
