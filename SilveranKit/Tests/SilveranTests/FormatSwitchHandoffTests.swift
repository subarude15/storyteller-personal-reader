import Foundation
import Testing

@testable import SilveranKit

@Suite("Format switch handoff + integration mapping")
struct FormatSwitchHandoffTests {
    private let bookA = BookID(sourceID: "server", uuid: "handoff-a")
    private let bookB = BookID(sourceID: "server", uuid: "handoff-b")

    // MARK: - Handoff store

    @Test func handoffConsumeIsOneShotAndCategoryScoped() async {
        let store = FormatSwitchHandoffStore()
        let locator = audioLocator(0.44)
        await store.set(
            FormatSwitchHandoff(
                bookID: bookA,
                category: .audio,
                locator: locator,
                progression: 0.44,
                precision: .wholeBookPercentage,
            )
        )
        #expect(await store.consume(bookID: bookA, category: .ebook) == nil)
        let handoff = await store.consume(bookID: bookA, category: .audio)
        #expect(handoff?.progression == 0.44)
        #expect(await store.consume(bookID: bookA, category: .audio) == nil)
    }

    @Test func rapidReswitchReplacesPendingHandoff() async {
        let store = FormatSwitchHandoffStore()
        await store.set(
            FormatSwitchHandoff(
                bookID: bookA,
                category: .ebook,
                locator: textLocator(0.10, href: "a.xhtml"),
                progression: 0.10,
                precision: .wholeBookPercentage,
            )
        )
        await store.set(
            FormatSwitchHandoff(
                bookID: bookA,
                category: .audio,
                locator: audioLocator(0.55),
                progression: 0.55,
                precision: .chapterRelative,
            )
        )
        let handoff = await store.peek(bookID: bookA)
        #expect(handoff?.category == .audio)
        #expect(handoff?.progression == 0.55)
        #expect(handoff?.precision == .chapterRelative)
    }

    // MARK: - Directional mapping with chapters (integration-style)

    @Test func audiobookToEbookWithChapterMetadata() {
        let chapters = [
            StoryPositionChapter(
                title: "Arrival",
                href: "text/ch1.xhtml",
                startProgression: 0.0,
                durationFraction: 0.5,
            ),
            StoryPositionChapter(
                title: "Departure",
                href: "text/ch2.xhtml",
                startProgression: 0.5,
                durationFraction: 0.5,
            ),
        ]
        let source = BookLocator(
            href: "toc-1-audio",
            type: "audio/mp4",
            title: "Departure",
            locations: BookLocator.Locations(
                fragments: ["t=120"],
                progression: 0.25,
                position: nil,
                totalProgression: 0.625,
                cssSelector: nil,
                partialCfi: nil,
                domRange: nil,
            ),
            text: nil,
        )
        let result = StoryPositionTranslator.translate(
            StoryPositionTranslationInput(
                sourceBookID: bookA,
                destinationBookID: bookA,
                sourceCategory: .audio,
                destinationCategory: .ebook,
                sourceLocator: source,
                sourceProgression: 0.625,
                destinationChapters: chapters,
            )
        )
        #expect(result.precision == .chapterRelative)
        // 0.5 + 0.25 * 0.5 = 0.625
        #expect(abs(result.progression - 0.625) < 0.0001)
        #expect(result.locator?.href == "text/ch2.xhtml")
        #expect(result.shouldApplyHandoff)
    }

    @Test func ebookToAudiobookAfterAdvanceWithoutAudio() {
        // Ebook-only locator (no audio fragments) → audiobook via chapter title.
        let chapters = [
            StoryPositionChapter(
                title: "Chapter 4",
                href: "chapter-3",
                startProgression: 0.6,
                durationFraction: 0.1,
            )
        ]
        let source = BookLocator(
            href: "OEBPS/ch4.xhtml",
            type: "application/xhtml+xml",
            title: "Chapter 4",
            locations: BookLocator.Locations(
                fragments: nil,
                progression: 0.1,
                position: nil,
                totalProgression: 0.61,
                cssSelector: nil,
                partialCfi: nil,
                domRange: nil,
            ),
            text: nil,
        )
        let result = StoryPositionTranslator.translate(
            StoryPositionTranslationInput(
                sourceBookID: bookA,
                destinationBookID: bookA,
                sourceCategory: .ebook,
                destinationCategory: .audio,
                sourceLocator: source,
                sourceProgression: 0.61,
                sourceTimestamp: 5_000,
                destinationChapters: chapters,
                destinationSavedProgression: 0.05,
                destinationSavedTimestamp: 1_000,
            )
        )
        #expect(result.precision == .chapterRelative)
        #expect(abs(result.progression - 0.61) < 0.0001)
        #expect(result.locator.map { StoryPositionTranslator.isAudioLocator($0) } == true)
        #expect(result.conflictingDestinationSaved == nil)
    }

    @Test func readaloudFragmentToAudiobookFallsBackToPercentageOrChapter() {
        let chapters = [
            StoryPositionChapter(
                title: "Night",
                href: "ch-night",
                startProgression: 0.4,
                durationFraction: 0.2,
            )
        ]
        let source = textLocator(0.45, href: "text/night.xhtml", fragment: "sent-9", title: "Night")
        let result = StoryPositionTranslator.translate(
            StoryPositionTranslationInput(
                sourceBookID: bookA,
                destinationBookID: bookA,
                sourceCategory: .synced,
                destinationCategory: .audio,
                sourceLocator: source,
                sourceProgression: 0.45,
                destinationChapters: chapters,
                hasVerifiedMediaOverlay: true,
            )
        )
        // Fragment→audio is not mediaOverlayAlignment; chapter title match applies.
        #expect(result.precision == .contentReference || result.precision == .chapterRelative)
        #expect(result.precision != .mediaOverlayAlignment)
        #expect(result.locator?.href == "ch-night")
    }

    @Test func linkedSeparateBookIDsStillApplyHandoff() {
        let result = StoryPositionTranslator.translate(
            StoryPositionTranslationInput(
                sourceBookID: bookA,
                destinationBookID: bookB,
                sourceCategory: .ebook,
                destinationCategory: .audio,
                sourceLocator: textLocator(0.3, href: "c.xhtml"),
                sourceProgression: 0.3,
            )
        )
        #expect(bookA != bookB)
        #expect(result.shouldApplyHandoff)
        #expect(result.precision == .wholeBookPercentage)
    }

    @Test func offlineApproximateMappingOffersChoiceWhenDestinationNewer() {
        let result = StoryPositionTranslator.translate(
            StoryPositionTranslationInput(
                sourceBookID: bookA,
                destinationBookID: bookA,
                sourceCategory: .ebook,
                destinationCategory: .audio,
                sourceLocator: textLocator(0.25, href: "x.xhtml"),
                sourceProgression: 0.25,
                sourceTimestamp: 1_000,
                destinationSavedProgression: 0.80,
                destinationSavedTimestamp: 9_000,
                destinationSavedLocator: audioLocator(0.80),
            )
        )
        #expect(result.precision == .wholeBookPercentage)
        #expect(result.conflictingDestinationSaved != nil)
        // Choosing either side still requests a local handoff (no Storyteller write required).
        #expect(result.shouldApplyHandoff)
        #expect(result.conflictingDestinationSaved?.shouldApplyHandoff == true)
    }

    @Test func accurateFragmentMappingPreservesSyncIntentWithoutChoice() {
        let result = StoryPositionTranslator.translate(
            StoryPositionTranslationInput(
                sourceBookID: bookA,
                destinationBookID: bookA,
                sourceCategory: .synced,
                destinationCategory: .ebook,
                sourceLocator: textLocator(0.5, href: "p.html", fragment: "a1"),
                sourceProgression: 0.5,
                sourceTimestamp: 1_000,
                destinationSavedProgression: 0.9,
                destinationSavedTimestamp: 99_000,
                hasVerifiedMediaOverlay: true,
            )
        )
        #expect(result.precision == .mediaOverlayAlignment)
        #expect(result.conflictingDestinationSaved == nil)
        #expect(result.locator?.locations?.fragments?.first == "a1")
    }

    @Test func sessionChapterHelpersBuildProgressFractions() {
        let chapters = [
            AudiobookSessionChapter(id: "c0", title: "One", duration: 100),
            AudiobookSessionChapter(id: "c1", title: "Two", duration: 300),
        ]
        let mapped = StoryPositionChapter.fromSessionChapters(chapters, totalDuration: 400)
        #expect(mapped.count == 2)
        #expect(abs((mapped[0].startProgression ?? -1) - 0.0) < 0.0001)
        #expect(abs((mapped[1].startProgression ?? -1) - 0.25) < 0.0001)
        #expect(abs((mapped[1].durationFraction ?? -1) - 0.75) < 0.0001)
    }

    @Test func repeatedHandoffSetConsumeCycles() async {
        let store = FormatSwitchHandoffStore()
        for progress in [0.1, 0.2, 0.3, 0.4] {
            await store.set(
                FormatSwitchHandoff(
                    bookID: bookA,
                    category: .ebook,
                    locator: textLocator(progress, href: "r.xhtml"),
                    progression: progress,
                    precision: .wholeBookPercentage,
                )
            )
            let handoff = await store.consume(bookID: bookA, category: .ebook)
            #expect(handoff?.progression == progress)
        }
        #expect(await store.peek(bookID: bookA) == nil)
    }

    // MARK: - Helpers

    private func audioLocator(_ progress: Double) -> BookLocator {
        BookLocator(
            href: "audiobook",
            type: "audio/mp4",
            title: nil,
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
        _ progress: Double,
        href: String,
        fragment: String? = nil,
        title: String? = nil,
    ) -> BookLocator {
        BookLocator(
            href: href,
            type: "application/xhtml+xml",
            title: title,
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
