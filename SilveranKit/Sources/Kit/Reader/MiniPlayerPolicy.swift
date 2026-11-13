import CoreGraphics
import Foundation

/// Pure policy and formatting helpers for the Global Mini-Player Bar and
/// Audiobook Now Playing surfaces (Batch D).
public enum MiniPlayerPolicy {

    /// Determines whether dismissing the full-screen player card (via `< Library`
    /// or swipe-down) should preserve the live audio session in `GlobalMiniPlayerBar`.
    ///
    /// - Audiobooks stay docked in the mini-player whether playing or paused,
    ///   until the user explicitly taps the Stop (`xmark`) button on the mini-player.
    /// - Readaloud sessions stay docked when narration is actively playing.
    /// - Podcasts stay docked when actively playing.
    public static func shouldKeepSessionOnCardDismiss(
        sessionKind: AudioSessionKind?,
        cardBookID: BookID,
        cardCategory: LocalMediaCategory,
        isPlaying: Bool,
    ) -> Bool {
        guard let sessionKind, sessionKind.bookID == cardBookID else {
            return false
        }
        switch sessionKind {
            case .audiobook:
                return cardCategory == .audio
            case .readaloud:
                return isPlaying
            case .podcast:
                return isPlaying
        }
    }

    /// Formats rate-adjusted remaining time into a compact label (e.g. `"18m left"`, `"1h 24m left"`).
    public static func formatRemainingCompact(
        seconds: TimeInterval,
        playbackRate: Double = 1.0,
    ) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let safeRate = max(playbackRate, 0.1)
        let adjustedSeconds = seconds / safeRate
        let totalMinutes = Int((adjustedSeconds / 60.0).rounded(.up))
        if totalMinutes <= 0 {
            return nil
        }
        if adjustedSeconds < 60 {
            return "< 1m left"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            if minutes > 0 {
                return "\(hours)h \(minutes)m left"
            }
            return "\(hours)h left"
        }
        return "\(minutes)m left"
    }

    /// Builds the secondary subtitle line for `GlobalMiniPlayerBar`.
    /// Combines chapter title (or author fallback) with rate-adjusted remaining time or percentage.
    public static func subtitle(
        author: String?,
        chapterLabel: String?,
        bookProgress: Double?,
        remainingSeconds: TimeInterval?,
        playbackRate: Double = 1.0,
    ) -> String? {
        let trimmedChapter = chapterLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAuthor = author?.trimmingCharacters(in: .whitespacesAndNewlines)

        let contextLabel: String? = {
            if let c = trimmedChapter, !c.isEmpty, !isLoadingPlaceholder(c) {
                return c
            }
            if let a = trimmedAuthor, !a.isEmpty {
                return a
            }
            return nil
        }()

        let progressLabel: String? = {
            if let remainingSeconds,
                let compact = formatRemainingCompact(
                    seconds: remainingSeconds,
                    playbackRate: playbackRate,
                )
            {
                return compact
            }
            if let bookProgress, bookProgress.isFinite, bookProgress > 0 {
                let pct = Int((min(max(bookProgress, 0), 1) * 100).rounded())
                return "\(pct)%"
            }
            return nil
        }()

        switch (contextLabel, progressLabel) {
            case (let ctx?, let prog?):
                return "\(ctx) · \(prog)"
            case (let ctx?, nil):
                return ctx
            case (nil, let prog?):
                return prog
            case (nil, nil):
                return nil
        }
    }

    /// Chapter label shown while chapter metadata is still loading (exact match only).
    private static func isLoadingPlaceholder(_ trimmedLabel: String) -> Bool {
        let lowered = trimmedLabel.lowercased()
        return lowered == "loading..." || lowered == "loading…"
    }

    /// Apple Music / Apple Books style cover scale for playing vs paused state.
    public static func artworkPlaybackScale(isPlaying: Bool) -> CGFloat {
        isPlaying ? 1.0 : 0.88
    }

    /// Quantizes a normalized slider fraction (`0.0 ... 1.0`) into discrete haptic tokens.
    public static func scrubHapticStepToken(fraction: Double, stepCount: Int = 20) -> Int {
        let clamped = min(max(fraction, 0.0), 1.0)
        let steps = max(stepCount, 1)
        return Int((clamped * Double(steps)).rounded())
    }
}
