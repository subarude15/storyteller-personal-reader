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

        public init(
            id: String,
            title: String,
            showTitle: String? = nil,
            summary: String? = nil,
            audioURL: URL,
            duration: TimeInterval? = nil
        ) {
            self.id = id
            self.title = title
            self.showTitle = showTitle
            self.summary = summary
            self.audioURL = audioURL
            self.duration = duration
        }
    }

    public private(set) var episode: Episode?

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
    /// card. Returns false when the audio pipeline is unavailable.
    @discardableResult
    public func play(_ episode: Episode) async -> Bool {
        if self.episode == episode { return true }
        // One card app-wide: a book card must not sit behind a podcast card.
        if PlayerPresenter.shared.card != nil {
            PlayerPresenter.shared.dismissCard()
        }
        do {
            try await AudioSessionActor.shared.openPodcast(
                episodeID: episode.id,
                title: episode.title,
                author: episode.showTitle,
                audioURL: episode.audioURL,
                duration: episode.duration
            )
        } catch {
            debugLog("[PodcastPlayerPresenter] Failed to open episode: \(error)")
            return false
        }
        activeEpisode = episode
        self.episode = episode
        return true
    }

    /// Closes the card. When playback is live the session keeps running so the
    /// episode continues in the mini player / Now Playing (mirrors the book
    /// card's dismiss-keeps-playing behavior); otherwise the session ends.
    public func dismiss() {
        Task { @MainActor in
            let snapshot = await AudioSessionActor.shared.currentSnapshot()
            episode = nil
            if snapshot?.isPlaying != true {
                activeEpisode = nil
                await AudioSessionActor.shared.closePodcast()
            }
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
}
#endif
