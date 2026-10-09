import Foundation
import Testing

@testable import SilveranKit

@Suite("Story position translation")
struct StoryPositionTranslationTests {
    private let bookA = BookID(sourceID: "server", uuid: "book-a")
    private let bookB = BookID(sourceID: "server", uuid: "book-b")

    // MARK: - Directions

    @Test func audiobookToEbookUsesWholeBookPercentage() {
        let result = StoryPositionTranslator.translate(
            input(
                from: .audio,
                to: .ebook,
                progression: 0.42,
                locator: audioLocator(progress: 0.42, title: "Chapter 3"),
            )
        )
        #expect(result.precision == .wholeBookPercentage)
        #expect(abs(result.progression - 0.42) < 0.0001)
        #expect(result.locator?.locations?.totalProgression == 0.42)
        #expect(result.locator.map { !StoryPositionTranslator.isAudioLocator($0) } == true)
        #expect(result.shouldApplyHandoff)
        #expect(result.conflictingDestinationSaved == nil)
    }

    @Test func ebookToAudiobookUsesWholeBookPercentage() {
        let result = StoryPositionTranslator.translate(
            input(
                from: .ebook,
                to: .audio,
                progression: 0.55,
                locator: textLocator(progress: 0.55, href: "text/ch3.xhtml"),
            )
        )
        #expect(result.precision == .wholeBookPercentage)
        #expect(abs(result.progression - 0.55) < 0.0001)
        #expect(result.locator.map { StoryPositionTranslator.isAudioLocator($0) } == true)
    }

    @Test func percentageIntoReadaloudIsNotLabeledMediaOverlay() {
        // Verified SMIL without a fragment handoff must not claim mediaOverlayAlignment.
        let result = StoryPositionTranslator.translate(
            input(
                from: .audio,
                to: .synced,
                progression: 0.33,
                locator: audioLocator(progress: 0.33),
                hasVerifiedOverlay: true,
            )
        )
        #expect(result.precision == .wholeBookPercentage)
        #expect(result.precision != .mediaOverlayAlignment)
    }

    @Test func ebookToReadaloudWithFragmentIsMediaOverlayAlignment() {
        let source = textLocator(
            progress: 0.2,
            href: "text/part0007.html",
            fragment: "para-123",
        )
        let result = StoryPositionTranslator.translate(
            input(
                from: .ebook,
                to: .synced,
                progression: 0.2,
                locator: source,
                hasVerifiedOverlay: true,
            )
        )
        #expect(result.precision == .mediaOverlayAlignment)
        #expect(result.locator?.locations?.fragments?.first == "para-123")
        #expect(result.locator?.href == "text/part0007.html")
    }

    @Test func fragmentWithoutVerifiedOverlayIsNotMediaOverlayAlignment() {
        let result = StoryPositionTranslator.translate(
            input(
                from: .ebook,
                to: .synced,
                progression: 0.2,
                locator: textLocator(progress: 0.2, href: "t.html", fragment: "p1"),
                hasVerifiedOverlay: false,
            )
        )
        #expect(result.precision != .mediaOverlayAlignment)
    }

    @Test func readaloudFragmentToEbookIsMediaOverlayAlignment() {
        let result = StoryPositionTranslator.translate(
            input(
                from: .synced,
                to: .ebook,
                progression: 0.18,
                locator: textLocator(progress: 0.18, href: "text/ch1.xhtml", fragment: "p-1"),
                hasVerifiedOverlay: true,
            )
        )
        #expect(result.precision == .mediaOverlayAlignment)
        #expect(result.locator?.locations?.fragments?.first == "p-1")
    }

    @Test func readaloudToAudiobookDoesNotClaimMediaOverlay() {
        let result = StoryPositionTranslator.translate(
            input(
                from: .synced,
                to: .audio,
                progression: 0.61,
                locator: textLocator(progress: 0.61, href: "text/ch2.xhtml", fragment: "s-9"),
                hasVerifiedOverlay: true,
            )
        )
        // Fragment cannot map into audiobook timestamps without chapter metadata.
        #expect(result.precision == .wholeBookPercentage)
    }

    // MARK: - Chapter mapping

    @Test func chapterTitleMatchUsesContentReference() {
        let chapters = [
            StoryPositionChapter(
                title: "Chapter 1: Beginnings",
                href: "chapter-0",
                startProgression: 0.0,
                durationFraction: 0.25,
            ),
            StoryPositionChapter(
                title: "Chapter 2: The Road",
                href: "chapter-1",
                startProgression: 0.25,
                durationFraction: 0.30,
            ),
        ]
        let source = BookLocator(
            href: "text/ch2.xhtml",
            type: "application/xhtml+xml",
            title: "Chapter 2: The Road",
            locations: BookLocator.Locations(
                fragments: nil,
                progression: 0.5,
                position: nil,
                totalProgression: 0.40,
                cssSelector: nil,
                partialCfi: nil,
                domRange: nil,
            ),
            text: nil,
        )
        let result = StoryPositionTranslator.translate(
            input(
                from: .ebook,
                to: .audio,
                progression: 0.40,
                locator: source,
                chapters: chapters,
            )
        )
        #expect(result.precision == .chapterRelative)
        #expect(abs(result.progression - 0.40) < 0.0001)
        #expect(result.locator?.href == "chapter-1")
    }

    @Test func normalizedChapterTitlesMatchAcrossFormats() {
        #expect(
            StoryPositionTranslator.normalizedChapterTitle("Chapter 3: Fire")
                == StoryPositionTranslator.normalizedChapterTitle("CH. 3 Fire")
        )
    }

    // MARK: - Discrepancy choice (no silent replace)

    @Test func significantDiscrepancyOffersChoiceNotSilentReplace() {
        let result = StoryPositionTranslator.translate(
            input(
                from: .ebook,
                to: .audio,
                progression: 0.20,
                locator: textLocator(progress: 0.20, href: "a.xhtml"),
                destSaved: 0.70,
                destTimestamp: 2_000,
                sourceTimestamp: 1_000,
            )
        )
        #expect(result.precision == .wholeBookPercentage)
        #expect(abs(result.progression - 0.20) < 0.0001)
        #expect(result.conflictingDestinationSaved != nil)
        #expect(result.conflictingDestinationSaved?.precision == .destinationSaved)
        #expect(abs((result.conflictingDestinationSaved?.progression ?? 0) - 0.70) < 0.0001)
    }

    @Test func intentionalSwitchKeepsSourceWhenDestinationIsOlder() {
        let result = StoryPositionTranslator.translate(
            input(
                from: .audio,
                to: .ebook,
                progression: 0.65,
                locator: audioLocator(progress: 0.65),
                destSaved: 0.10,
                destTimestamp: 500,
                sourceTimestamp: 2_000,
            )
        )
        #expect(result.precision == .wholeBookPercentage)
        #expect(abs(result.progression - 0.65) < 0.0001)
        #expect(result.conflictingDestinationSaved == nil)
    }

    @Test func mediaOverlayDoesNotOfferDiscrepancyChoice() {
        let result = StoryPositionTranslator.translate(
            input(
                from: .synced,
                to: .ebook,
                progression: 0.22,
                locator: textLocator(progress: 0.22, href: "t.xhtml", fragment: "x"),
                hasVerifiedOverlay: true,
                destSaved: 0.80,
                destTimestamp: 9_000,
                sourceTimestamp: 1_000,
            )
        )
        #expect(result.precision == .mediaOverlayAlignment)
        #expect(abs(result.progression - 0.22) < 0.0001)
        #expect(result.conflictingDestinationSaved == nil)
    }

    // MARK: - Handoff apply

    @Test func mappedPositionsRequestHandoffApply() {
        let same = StoryPositionTranslator.translate(
            input(from: .ebook, to: .audio, progression: 0.3, locator: textLocator(progress: 0.3, href: "c.xhtml"))
        )
        #expect(same.shouldApplyHandoff)

        let cross = StoryPositionTranslator.translate(
            StoryPositionTranslationInput(
                sourceBookID: bookA,
                destinationBookID: bookB,
                sourceCategory: .ebook,
                destinationCategory: .audio,
                sourceLocator: textLocator(progress: 0.3, href: "c.xhtml"),
                sourceProgression: 0.3,
            )
        )
        #expect(cross.shouldApplyHandoff)
    }

    @Test func clampsOutOfRangeProgression() {
        let high = StoryPositionTranslator.translate(
            input(from: .audio, to: .ebook, progression: 1.5, locator: audioLocator(progress: 1.5))
        )
        #expect(high.progression == 1)
        let low = StoryPositionTranslator.translate(
            input(from: .audio, to: .ebook, progression: -0.2, locator: audioLocator(progress: -0.2))
        )
        #expect(low.progression == 0)
    }

    @Test func formatSwitchLabelsCoverAllCategories() {
        for category in LocalMediaCategory.allCases {
            #expect(!FormatSwitchLabels.title(for: category).isEmpty)
            #expect(!FormatSwitchLabels.systemImage(for: category).isEmpty)
        }
    }

    @Test func syncReasonIncludesFormatSwitch() {
        #expect(SyncReason.userSwitchedFormat.rawValue == "userSwitchedFormat")
        #expect(!AudiobookProgressConflict.isRoutineListeningMilestoneReason(.userSwitchedFormat))
    }

    @Test func impreciseFlagsMatchDoctrine() {
        #expect(StoryPositionTranslator.isImprecise(.wholeBookPercentage))
        #expect(StoryPositionTranslator.isImprecise(.chapterRelative))
        #expect(!StoryPositionTranslator.isImprecise(.mediaOverlayAlignment))
        #expect(!StoryPositionTranslator.isImprecise(.contentReference))
    }

    // MARK: - Helpers

    private func input(
        from: LocalMediaCategory,
        to: LocalMediaCategory,
        progression: Double,
        locator: BookLocator?,
        chapters: [StoryPositionChapter] = [],
        hasVerifiedOverlay: Bool = false,
        destSaved: Double? = nil,
        destTimestamp: Double? = nil,
        sourceTimestamp: Double? = nil,
    ) -> StoryPositionTranslationInput {
        StoryPositionTranslationInput(
            sourceBookID: bookA,
            destinationBookID: bookA,
            sourceCategory: from,
            destinationCategory: to,
            sourceLocator: locator,
            sourceProgression: progression,
            sourceTimestamp: sourceTimestamp,
            destinationChapters: chapters,
            destinationSavedProgression: destSaved,
            destinationSavedTimestamp: destTimestamp,
            destinationSavedLocator: destSaved.map { audioLocator(progress: $0) },
            hasVerifiedMediaOverlay: hasVerifiedOverlay,
        )
    }

    private func audioLocator(progress: Double, title: String? = nil) -> BookLocator {
        BookLocator(
            href: "audiobook",
            type: "audio/mp4",
            title: title,
            locations: BookLocator.Locations(
                fragments: nil,
                progression: nil,
                position: nil,
                totalProgression: progress,
                cssSelector: nil,
                partialCfi: nil,
                domRange: nil,
            ),
            text: nil,
        )
    }

    private func textLocator(
        progress: Double,
        href: String,
        fragment: String? = nil,
    ) -> BookLocator {
        BookLocator(
            href: href,
            type: "application/xhtml+xml",
            title: nil,
            locations: BookLocator.Locations(
                fragments: fragment.map { [$0] },
                progression: nil,
                position: nil,
                totalProgression: progress,
                cssSelector: nil,
                partialCfi: nil,
                domRange: nil,
            ),
            text: nil,
        )
    }
}
