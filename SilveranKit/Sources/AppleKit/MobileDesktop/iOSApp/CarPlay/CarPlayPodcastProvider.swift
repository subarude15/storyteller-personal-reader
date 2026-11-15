#if os(iOS)
import Foundation
import SilveranKit

/// Podcast sources that live in the host app target (subscriptions, RSS parsing and
/// recents). Set from the app entry point so a CarPlay-only launch has them too.
public struct CarPlayPodcastProvider: Sendable {
    /// Recently played audio episodes, newest first.
    public var recentEpisodes: @MainActor @Sendable () -> [CarPlayBrowseItem]
    /// Subscribed shows from local storage (no network).
    public var subscribedShows: @MainActor @Sendable () -> [CarPlayPodcastShow]
    /// One show's audio episodes, newest first; fetches the feed when opened.
    public var showEpisodes: @MainActor @Sendable (CarPlayPodcastShow) async -> [CarPlayBrowseItem]

    public init(
        recentEpisodes: @escaping @MainActor @Sendable () -> [CarPlayBrowseItem],
        subscribedShows: @escaping @MainActor @Sendable () -> [CarPlayPodcastShow],
        showEpisodes: @escaping @MainActor @Sendable (CarPlayPodcastShow) async -> [CarPlayBrowseItem],
    ) {
        self.recentEpisodes = recentEpisodes
        self.subscribedShows = subscribedShows
        self.showEpisodes = showEpisodes
    }

    @MainActor public static var current: CarPlayPodcastProvider?

    /// Up Next from the shared podcast queue (AppleKit-owned).
    @MainActor
    static func upNextItems() -> [CarPlayBrowseItem] {
        PodcastPlaybackQueueStore.shared.upcoming.filter { !$0.isVideo }.map { item in
            CarPlayBrowseItem(
                source: .podcast(item),
                title: item.title,
                detail: item.showTitle,
                progress: nil,
                lastTouched: nil,
                isLocal: PodcastDownloadStore.shared.isDownloaded(item.episodeID),
            )
        }
    }

    /// Downloaded episodes whose audio file is on disk.
    @MainActor
    static func downloadedItems() -> [CarPlayBrowseItem] {
        let store = PodcastDownloadStore.shared
        return store.allDownloads().compactMap { record in
            guard let local = store.localAudioURL(for: record.episodeID) else { return nil }
            let item = PodcastPlaybackQueueItem(
                episodeID: record.episodeID,
                title: record.title,
                showTitle: record.showTitle,
                audioURL: local,
                durationSeconds: record.durationSeconds,
                feedURL: record.feedURL,
            )
            return CarPlayBrowseItem(
                source: .podcast(item),
                title: record.title,
                detail: record.showTitle,
                progress: record.isFinished
                    ? 1 : record.durationSeconds.flatMap { $0 > 0 ? record.positionSeconds / $0 : nil },
                lastTouched: record.lastPlayedAt ?? record.downloadedAt,
                isLocal: true,
            )
        }
    }
}
#endif
