#if os(iOS)
import SwiftUI

/// Owns the full-screen card for a streaming RSS podcast episode.
///
/// Podcasts are not Storyteller books and have no local media, so they cannot
/// be carried by `PlayerBookData` / `PlayerPresenter` (which resolve a book
/// out of the library snapshot). This presenter mirrors the one-card rule
/// instead: showing a podcast card ends any book card and vice versa.
@MainActor
@Observable
public final class PodcastPlayerPresenter {
    public static let shared = PodcastPlayerPresenter()

    public struct Episode: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let showTitle: String?
        public let summary: String?
        public let audioURL: URL
        public let duration: TimeInterval?
        /// True when the chosen enclosure is video (full Now Playing card; shared player).
        public let isVideo: Bool
        public let coverURL: URL?
        /// YouTube watch URL for in-app resolve and/or Watch on YouTube handoff (full NP).
        public let youtubeURL: URL?

        public init(
            id: String,
            title: String,
            showTitle: String? = nil,
            summary: String? = nil,
            audioURL: URL,
            duration: TimeInterval? = nil,
            isVideo: Bool = false,
            coverURL: URL? = nil,
            youtubeURL: URL? = nil
        ) {
            self.id = id
            self.title = title
            self.showTitle = showTitle
            self.summary = summary
            self.audioURL = audioURL
            self.duration = duration
            self.isVideo = isVideo
            self.coverURL = coverURL
            self.youtubeURL = youtubeURL
        }
    }

    public private(set) var episode: Episode?

    /// True while openPodcast is in flight — Now Playing shows Loading…, not Pause.
    public private(set) var isOpening = false

    /// Brief start failure for the card (Play stays available).
    public private(set) var startError: String?

    /// Artwork URL for the live podcast session (card or mini-player).
    public var artworkURL: URL? {
        (episode ?? activeEpisode)?.coverURL
    }

    /// The episode still holding the shared audio session after its card has
    /// been dismissed (playback continues in the mini player). Cleared when the
    /// session actually ends, so `expandFromMiniPlayer` can re-show the card
    /// from a headless live session.
    @ObservationIgnored private var activeEpisode: Episode?

    private init() {}

    /// Drives the `.fullScreenCover(item:)` in the host shell. A swipe-down or
    /// programmatic dismissal routes through `dismiss()` so the session can
    /// keep playing in the mini player when appropriate.
    public var episodeItemBinding: Binding<Episode?> {
        Binding(
            get: { self.episode },
            set: { newValue in
                if newValue == nil, self.episode != nil {
                    self.dismiss()
                }
            },
        )
    }

    /// Starts streaming the episode on the shared audio session and shows the
    /// full Now Playing card (required for video — never mini-bar alone).
    /// Returns false when the audio pipeline is unavailable.
    ///
    /// Never early-returns success just because `self.episode == episode` —
    /// Home Continue / reopen must reopen or transport(.play) until the
    /// playhead actually advances.
    @discardableResult
    public func play(_ episode: Episode) async -> Bool {
        startError = nil

        // Same card already up AND session truly progressing → keep card, done.
        if self.episode == episode,
            await AudioSessionActor.shared.podcastIsActivelyProgressing(episodeID: episode.id)
        {
            return true
        }

        // One card app-wide: a book card must not sit behind a podcast card.
        if PlayerPresenter.shared.card != nil {
            PlayerPresenter.shared.dismissCard()
        }
        let resumeAt = Self.resumePositionSeconds(for: episode.id)
        // Show card immediately with Loading… while the session opens.
        activeEpisode = episode
        self.episode = nil
        self.episode = episode
        isOpening = true
        defer { isOpening = false }

        do {
            try await AudioSessionActor.shared.openPodcast(
                episodeID: episode.id,
                title: episode.title,
                author: episode.showTitle,
                audioURL: episode.audioURL,
                duration: episode.duration,
                startAtSeconds: resumeAt
            )
        } catch {
            debugLog("[PodcastPlayerPresenter] Failed to open episode: \(error)")
            startError = "Couldn't start playback"
            // Keep card visible with Play + error; drop live-session retain.
            activeEpisode = episode
            return false
        }

        PunkRallyStatsEvents.sessionStart(
            kind: "listening",
            mediaID: "podcast/\(episode.id)",
            mediaTitle: episode.title
        )
        return true
    }

    /// Clears a transient start error after the user dismisses it.
    public func clearStartError() {
        startError = nil
    }

    /// Closes the card. Audio may continue in the mini player; video sessions
    /// end with the card so video never runs mini-bar alone.
    public func dismiss() {
        Task { @MainActor in
            await Self.persistPodcastProgress(markFinished: false)
            let closing = episode ?? activeEpisode
            let snapshot = await AudioSessionActor.shared.currentSnapshot()
            episode = nil
            startError = nil
            isOpening = false
            if closing?.isVideo == true {
                activeEpisode = nil
                await AudioSessionActor.shared.closePodcast()
                PunkRallyStatsEvents.sessionEnd(mediaID: "podcast/\(closing!.id)")
            } else if snapshot?.isPlaying != true {
                activeEpisode = nil
                await AudioSessionActor.shared.closePodcast()
                if let closing {
                    PunkRallyStatsEvents.sessionEnd(mediaID: "podcast/\(closing.id)")
                } else {
                    PunkRallyStatsEvents.sessionEnd()
                }
            }
            NotificationCenter.default.post(name: .punkRallyHomeQueueDidChange, object: nil)
        }
    }

    /// Mini-player tap while a podcast session is live: re-show the card
    /// without restarting the stream. Falls back to the retained active
    /// episode when the card was dismissed while still playing.
    public func expandFromMiniPlayer() {
        guard let current = episode ?? activeEpisode else { return }
        // The card is nil (that's why the mini player is visible); the shell
        // observes `episode`, so reasserting it is enough to re-show.
        episode = nil
        episode = current
    }

    /// After mini-player Stop — session is gone; drop retained episode so the
    /// next play goes through openPodcast + resume seek.
    public func clearActiveEpisodeAfterStop() {
        episode = nil
        activeEpisode = nil
        startError = nil
        isOpening = false
    }

    /// Writes listen progress into the playhead store (always) and download
    /// ledger when the episode is on Shelf.
    public static func persistPodcastProgress(markFinished: Bool) async {
        guard let progress = await AudioSessionActor.shared.podcastPlaybackProgress() else {
            return
        }
        let duration = progress.duration > 0 ? progress.duration : nil
        PodcastPlayheadStore.shared.save(
            episodeID: progress.episodeID,
            positionSeconds: progress.position,
            durationSeconds: duration,
            markFinished: markFinished || progress.isFinished
        )
        PodcastDownloadStore.shared.updatePlayback(
            episodeID: progress.episodeID,
            positionSeconds: progress.position,
            durationSeconds: duration,
            markFinished: markFinished || progress.isFinished
        )
    }

    /// Prefer streaming playhead; fall back to download ledger position.
    private static func resumePositionSeconds(for episodeID: String) -> TimeInterval? {
        if let stored = PodcastPlayheadStore.shared.position(for: episodeID), stored > 1 {
            return stored
        }
        if let downloaded = PodcastDownloadStore.shared.record(for: episodeID)?.positionSeconds,
            downloaded > 1
        {
            return downloaded
        }
        return nil
    }
}
#endif
