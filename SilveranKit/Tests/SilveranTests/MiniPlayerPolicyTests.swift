import Foundation
import SilveranKit
import Testing

@Suite("Persistent mini-player policy, compact remaining time & audiobook polish")
struct MiniPlayerPolicyTests {
    @Test func audiobookCardDismissalAlwaysKeepsSessionAliveEvenWhenPaused() {
        let bookID = BookID(sourceID: "storyteller", uuid: "book-uuid-123")
        let playingKeep = MiniPlayerPolicy.shouldKeepSessionOnCardDismiss(
            sessionKind: .audiobook(bookID),
            cardBookID: bookID,
            cardCategory: .audio,
            isPlaying: true
        )
        let pausedKeep = MiniPlayerPolicy.shouldKeepSessionOnCardDismiss(
            sessionKind: .audiobook(bookID),
            cardBookID: bookID,
            cardCategory: .audio,
            isPlaying: false
        )
        #expect(playingKeep == true)
        #expect(pausedKeep == true, "Audiobook session must persist in the mini-player when paused until explicitly closed")
    }

    @Test func readaloudCardDismissalKeepsSessionOnlyWhenPlaying() {
        let bookID = BookID(sourceID: "storyteller", uuid: "book-uuid-456")
        #expect(
            MiniPlayerPolicy.shouldKeepSessionOnCardDismiss(
                sessionKind: .readaloud(bookID),
                cardBookID: bookID,
                cardCategory: .synced,
                isPlaying: true
            ) == true
        )
        #expect(
            MiniPlayerPolicy.shouldKeepSessionOnCardDismiss(
                sessionKind: .readaloud(bookID),
                cardBookID: bookID,
                cardCategory: .synced,
                isPlaying: false
            ) == false
        )
    }

    @Test func mismatchedBookIDOrEmptySessionDoesNotKeepCardSession() {
        #expect(
            MiniPlayerPolicy.shouldKeepSessionOnCardDismiss(
                sessionKind: .audiobook(BookID(sourceID: "storyteller", uuid: "other-book")),
                cardBookID: BookID(sourceID: "storyteller", uuid: "current-book"),
                cardCategory: .audio,
                isPlaying: true
            ) == false
        )
        #expect(
            MiniPlayerPolicy.shouldKeepSessionOnCardDismiss(
                sessionKind: nil,
                cardBookID: BookID(sourceID: "storyteller", uuid: "current-book"),
                cardCategory: .audio,
                isPlaying: true
            ) == false
        )
    }

    /// The docked bar (and any inset clearance rendered inside it) exists only for a
    /// live session with no full-screen presenter, so a hidden bar reserves nothing.
    @Test func dockedBarVisibleOnlyForLiveSessionWithoutFullScreenPresenter() {
        #expect(
            MiniPlayerPolicy.isDockedBarVisible(
                hasSession: true, isCardPresented: false, isPodcastEpisodePresented: false) == true,
            "Playing or paused session docks the bar")
        #expect(
            MiniPlayerPolicy.isDockedBarVisible(
                hasSession: false, isCardPresented: false, isPodcastEpisodePresented: false) == false,
            "Stopped session hides the bar")
        #expect(
            MiniPlayerPolicy.isDockedBarVisible(
                hasSession: true, isCardPresented: true, isPodcastEpisodePresented: false) == false,
            "Full-screen book card hides the bar")
        #expect(
            MiniPlayerPolicy.isDockedBarVisible(
                hasSession: true, isCardPresented: false, isPodcastEpisodePresented: true) == false,
            "Full-screen podcast player hides the bar")
    }

    @Test func formatRemainingCompactAdjustsForPlaybackRate() {
        #expect(MiniPlayerPolicy.formatRemainingCompact(seconds: 0) == nil)
        #expect(MiniPlayerPolicy.formatRemainingCompact(seconds: 35, playbackRate: 1.0) == "< 1m left")
        #expect(MiniPlayerPolicy.formatRemainingCompact(seconds: 18 * 60, playbackRate: 1.0) == "18m left")
        #expect(MiniPlayerPolicy.formatRemainingCompact(seconds: 30 * 60, playbackRate: 1.5) == "20m left")
        #expect(MiniPlayerPolicy.formatRemainingCompact(seconds: 90 * 60, playbackRate: 1.0) == "1h 30m left")
        #expect(MiniPlayerPolicy.formatRemainingCompact(seconds: 120 * 60, playbackRate: 1.0) == "2h left")
    }

    @Test func subtitlePrioritizesChapterLabelAndRemainingTime() {
        let withChapterAndRemaining = MiniPlayerPolicy.subtitle(
            author: "Susanna Clarke",
            chapterLabel: "Chapter 4",
            bookProgress: 0.42,
            remainingSeconds: 18 * 60,
            playbackRate: 1.0
        )
        #expect(withChapterAndRemaining == "Chapter 4 · 18m left")

        let withAuthorAndPercentage = MiniPlayerPolicy.subtitle(
            author: "Susanna Clarke",
            chapterLabel: nil,
            bookProgress: 0.42,
            remainingSeconds: nil,
            playbackRate: 1.0
        )
        #expect(withAuthorAndPercentage == "Susanna Clarke · 42%")

        let loadingChapterFallsBackToAuthor = MiniPlayerPolicy.subtitle(
            author: "Frank Herbert",
            chapterLabel: "Loading...",
            bookProgress: 0.0,
            remainingSeconds: nil,
            playbackRate: 1.0
        )
        #expect(loadingChapterFallsBackToAuthor == "Frank Herbert")
    }

    @Test func loadingPlaceholderVariantsFallBackToAuthor() {
        for placeholder in ["Loading...", "Loading…", "  loading...\n", "LOADING…", "\tLoading..."] {
            let subtitle = MiniPlayerPolicy.subtitle(
                author: "Frank Herbert",
                chapterLabel: placeholder,
                bookProgress: nil,
                remainingSeconds: 18 * 60
            )
            #expect(subtitle == "Frank Herbert · 18m left", "placeholder \(placeholder.debugDescription)")
        }
    }

    @Test func realChapterTitlesContainingLoadingAreKept() {
        for title in ["Loading the Spice", "Chapter 3: Loading...", "Loading", "Loading....", "Reloading..."] {
            let subtitle = MiniPlayerPolicy.subtitle(
                author: "Frank Herbert",
                chapterLabel: title,
                bookProgress: nil,
                remainingSeconds: nil
            )
            #expect(subtitle == title)
        }
    }

    @Test func loadingPlaceholderWithoutAuthorShowsProgressOnly() {
        #expect(
            MiniPlayerPolicy.subtitle(
                author: nil, chapterLabel: "Loading...", bookProgress: 0.42, remainingSeconds: nil
            ) == "42%")
        #expect(
            MiniPlayerPolicy.subtitle(
                author: "  ", chapterLabel: "Loading…", bookProgress: nil, remainingSeconds: 30 * 60,
                playbackRate: 1.5
            ) == "20m left")
        #expect(
            MiniPlayerPolicy.subtitle(
                author: nil, chapterLabel: "Loading...", bookProgress: 0.0, remainingSeconds: nil
            ) == nil)
    }

    @Test func artworkScaleAndScrubHapticTokensBehaveDeterministically() {
        #expect(MiniPlayerPolicy.artworkPlaybackScale(isPlaying: true) == 1.0)
        #expect(MiniPlayerPolicy.artworkPlaybackScale(isPlaying: false) == 0.88)

        #expect(MiniPlayerPolicy.scrubHapticStepToken(fraction: 0.0, stepCount: 20) == 0)
        #expect(MiniPlayerPolicy.scrubHapticStepToken(fraction: 0.5, stepCount: 20) == 10)
        #expect(MiniPlayerPolicy.scrubHapticStepToken(fraction: 1.0, stepCount: 20) == 20)
    }
}
