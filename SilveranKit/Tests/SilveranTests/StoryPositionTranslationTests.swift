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

    @Test func chapterTitleMatchUsesRelativeOnlyWhenTimingVerified() {
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
        let verified = StoryPositionTranslator.translate(
            input(
                from: .ebook,
                to: .audio,
                progression: 0.40,
                locator: source,
                chapters: chapters,
                chaptersTimingVerified: true,
            )
        )
        #expect(verified.precision == .chapterRelative)
        #expect(abs(verified.progression - 0.40) < 0.0001)
        #expect(verified.locator?.href == "chapter-1")

        let unverified = StoryPositionTranslator.translate(
            input(
                from: .ebook,
                to: .audio,
                progression: 0.40,
                locator: source,
                chapters: chapters,
                chaptersTimingVerified: false,
            )
        )
        #expect(unverified.precision == .contentReference)
        #expect(abs(unverified.progression - 0.25) < 0.0001)
    }

    @Test func normalizedChapterTitlesMatchAcrossFormats() {
        #expect(
            StoryPositionTranslator.normalizedChapterTitle("Chapter 3: Fire")
                == StoryPositionTranslator.normalizedChapterTitle("CH. 3 Fire")
        )
        // Number-only titles must still match (strip would otherwise leave empty).
        #expect(
            StoryPositionTranslator.normalizedChapterTitle("Chapter 4")
                == StoryPositionTranslator.normalizedChapterTitle("CHAPTER 4")
        )
        #expect(!StoryPositionTranslator.normalizedChapterTitle("Chapter 4").isEmpty)
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

    @Test func approximateMappingOffersChoiceEvenWhenDestinationIsOlder() {
        // Phase A: never silently overwrite a saved destination place with %.
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
        #expect(result.conflictingDestinationSaved != nil)
        #expect(abs((result.conflictingDestinationSaved?.progression ?? 0) - 0.10) < 0.0001)
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

    @Test func placeholderReaderHrefDetection() {
        #expect(StoryPositionTranslator.isPlaceholderReaderHref("ebook"))
        #expect(StoryPositionTranslator.isPlaceholderReaderHref("audiobook"))
        #expect(StoryPositionTranslator.isPlaceholderReaderHref(""))
        #expect(!StoryPositionTranslator.isPlaceholderReaderHref("OEBPS/ch3.xhtml"))
    }

    @Test func audiobookToEbookWholeBookDoesNotInventChapterHref() {
        // Equal-weight / unverified TOC must not pretend to pick a chapter for %.
        let chapters = [
            StoryPositionChapter(
                title: "Early",
                href: "text/early.xhtml",
                startProgression: 0.0,
                durationFraction: 0.4,
            ),
            StoryPositionChapter(
                title: "Late",
                href: "text/late.xhtml",
                startProgression: 0.4,
                durationFraction: 0.6,
            ),
        ]
        let result = StoryPositionTranslator.translate(
            input(
                from: .audio,
                to: .ebook,
                progression: 0.7,
                locator: audioLocator(progress: 0.7, title: "Unrelated Audio Title"),
                chapters: chapters,
            )
        )
        #expect(result.precision == .wholeBookPercentage)
        #expect(result.mappingMethod == "wholeBookPercentEstimate")
        #expect(result.locator?.href == "ebook")
        #expect(result.locator?.locations?.totalProgression == 0.7)
        #expect(!StoryPositionTranslator.isAudioLocator(result.locator!))
    }

    @Test func resolveReaderNavigationMapsPlaceholderOntoSpine() {
        let structure = [
            SectionInfo(index: 0, id: "OEBPS/ch1.xhtml", label: "One", level: 0, mediaOverlay: []),
            SectionInfo(index: 1, id: "OEBPS/ch2.xhtml", label: "Two", level: 0, mediaOverlay: []),
            SectionInfo(index: 2, id: "OEBPS/ch3.xhtml", label: "Three", level: 0, mediaOverlay: []),
            SectionInfo(index: 3, id: "OEBPS/ch4.xhtml", label: "Four", level: 0, mediaOverlay: []),
        ]
        let placeholder = BookLocator(
            href: "ebook",
            type: "application/xhtml+xml",
            title: nil,
            locations: BookLocator.Locations(
                fragments: nil,
                progression: nil,
                position: nil,
                totalProgression: 0.75,
                cssSelector: nil,
                partialCfi: nil,
                domRange: nil,
            ),
            text: nil,
        )
        let resolved = StoryPositionTranslator.resolveReaderNavigationTarget(
            locator: placeholder,
            progression: 0.75,
            bookStructure: structure,
        )
        #expect(resolved.navigation == .bookFraction)
        #expect(resolved.locator.href == "OEBPS/ch4.xhtml")
        #expect(resolved.locator.locations?.totalProgression == 0.75)
    }

    @Test func resolveReaderNavigationKeepsValidFragment() {
        let structure = [
            SectionInfo(index: 0, id: "p.html", label: "P", level: 0, mediaOverlay: []),
        ]
        let source = textLocator(progress: 0.5, href: "p.html", fragment: "sent-1")
        let resolved = StoryPositionTranslator.resolveReaderNavigationTarget(
            locator: source,
            progression: 0.5,
            bookStructure: structure,
        )
        #expect(resolved.navigation == .fragment)
        #expect(resolved.locator.locations?.fragments?.first == "sent-1")
    }

    @Test func staleEbookSavedOffersChoiceForApproximateAudiobookHandoff() {
        // Approximate % mapping still prefers live source progression, but offers saved place.
        let result = StoryPositionTranslator.translate(
            input(
                from: .audio,
                to: .ebook,
                progression: 0.62,
                locator: audioLocator(progress: 0.62),
                destSaved: 0.15,
                destTimestamp: 1_000,
                sourceTimestamp: 9_000,
            )
        )
        #expect(result.progression == 0.62)
        #expect(result.conflictingDestinationSaved != nil)
        #expect(result.shouldApplyHandoff)
    }

    // MARK: - Phase B: audiobook ↔ SMIL

    @Test func audiobookToSmilMapsFragmentWhenDurationsCompatible() {
        let sections = sampleSmilSections(total: 1000)
        let result = StoryPositionTranslator.translate(
            StoryPositionTranslationInput(
                sourceBookID: bookA,
                destinationBookID: bookA,
                sourceCategory: .audio,
                destinationCategory: .synced,
                sourceLocator: audioLocator(progress: 0.36),
                sourceProgression: 0.36,
                sourceElapsedSeconds: 360,
                sourceAudiobookDuration: 1000,
                destinationBookStructure: sections,
                destinationSmilTotalDuration: 1000,
                hasVerifiedMediaOverlay: true,
            )
        )
        #expect(result.precision == .mediaOverlayAlignment)
        #expect(result.mappingMethod == "audiobookTimeToSmilFragment")
        #expect(result.locator?.locations?.fragments?.first == "p-mid")
        #expect(result.locator?.href == "text/ch2.xhtml")
    }

    @Test func mismatchedAudioSmilDurationsFallBackToApproximate() {
        let sections = sampleSmilSections(total: 1000)
        let result = StoryPositionTranslator.translate(
            StoryPositionTranslationInput(
                sourceBookID: bookA,
                destinationBookID: bookA,
                sourceCategory: .audio,
                destinationCategory: .synced,
                sourceLocator: audioLocator(progress: 0.36),
                sourceProgression: 0.36,
                sourceElapsedSeconds: 360,
                sourceAudiobookDuration: 1000,
                destinationBookStructure: sections,
                destinationSmilTotalDuration: 5000,  // incompatible
                hasVerifiedMediaOverlay: true,
            )
        )
        #expect(result.precision == .wholeBookPercentage)
        #expect(result.mappingMethod == "wholeBookPercentEstimate")
        #expect(
            !StoryPositionTranslator.areAudioTimelinesCompatible(
                audiobookDuration: 1000,
                smilDuration: 5000,
            )
        )
    }

    @Test func smilToAudiobookMapsWhenDurationsCompatible() {
        let result = StoryPositionTranslator.translate(
            StoryPositionTranslationInput(
                sourceBookID: bookA,
                destinationBookID: bookA,
                sourceCategory: .synced,
                destinationCategory: .audio,
                sourceLocator: textLocator(progress: 0.5, href: "text/ch2.xhtml", fragment: "p-mid"),
                sourceProgression: 0.5,
                destinationAudiobookDuration: 2000,
                destinationChapters: [
                    StoryPositionChapter(
                        title: "Two",
                        href: "audio-2",
                        startProgression: 0.4,
                        durationFraction: 0.3,
                    )
                ],
                destinationChaptersTimingVerified: true,
                sourceSmilTotalDuration: 2000,
                hasVerifiedMediaOverlay: true,
            )
        )
        #expect(result.precision == .mediaOverlayAlignment)
        #expect(result.mappingMethod == "smilTimeToAudiobookProgress")
        #expect(abs(result.progression - 0.5) < 0.0001)
        #expect(StoryPositionTranslator.isAudioLocator(result.locator!))
    }

    // MARK: - Phase C: fragment validation

    @Test func missingFragmentFallsBackToClosestSpine() {
        let sections = sampleSmilSections(total: 1000)
        let result = StoryPositionTranslator.translate(
            StoryPositionTranslationInput(
                sourceBookID: bookA,
                destinationBookID: bookA,
                sourceCategory: .synced,
                destinationCategory: .ebook,
                sourceLocator: textLocator(
                    progress: 0.5,
                    href: "text/ch2.xhtml",
                    fragment: "missing-id",
                ),
                sourceProgression: 0.5,
                destinationBookStructure: sections,
                hasVerifiedMediaOverlay: true,
            )
        )
        #expect(result.precision == .contentReference)
        #expect(result.mappingMethod == "fragmentMissingClosestSpine")
        #expect(result.locator?.href == "text/ch2.xhtml")
        #expect(result.locator?.locations?.fragments == nil)
    }

    @Test func differentEpubStructureFallsBackGracefully() {
        let sourceSections = sampleSmilSections(total: 1000)
        let destStructure = [
            SectionInfo(index: 0, id: "other/book.html", label: "Other", level: 0, mediaOverlay: [])
        ]
        let result = StoryPositionTranslator.translate(
            StoryPositionTranslationInput(
                sourceBookID: bookA,
                destinationBookID: bookB,
                sourceCategory: .synced,
                destinationCategory: .ebook,
                sourceLocator: textLocator(
                    progress: 0.5,
                    href: "text/ch2.xhtml",
                    fragment: "p-mid",
                ),
                sourceProgression: 0.5,
                destinationBookStructure: destStructure,
                sourceBookStructure: sourceSections,
                hasVerifiedMediaOverlay: true,
            )
        )
        // Fragment/href absent from destination → not exact media-overlay claim.
        #expect(result.precision != .mediaOverlayAlignment)
        #expect(result.shouldApplyHandoff)
    }

    // MARK: - Phase D: SMIL chapter timing

    @Test func smilChapterTimingPreferedOverEqualWeight() {
        let sections = sampleSmilSections(total: 1000)
        let (chapters, verified) = StoryPositionChapter.fromSectionsPreferringSmilTiming(sections)
        #expect(verified)
        #expect(chapters.count == 2)
        // Ch1 ends at 200s → 0.2; Ch2 spans 200…1000 → start 0.2, duration 0.8
        #expect(abs((chapters[0].durationFraction ?? -1) - 0.2) < 0.001)
        #expect(abs((chapters[1].startProgression ?? -1) - 0.2) < 0.001)
        #expect(abs((chapters[1].durationFraction ?? -1) - 0.8) < 0.001)

        let equal = StoryPositionChapter.fromLabeledSections(sections)
        #expect(abs((equal[0].durationFraction ?? -1) - 0.5) < 0.001)
    }

    @Test func precisionLabelsDistinguishExactChapterAndApproximate() {
        #expect(FormatSwitchLabels.precisionLabel(for: .mediaOverlayAlignment) == "exact alignment")
        #expect(FormatSwitchLabels.precisionLabel(for: .contentReference) == "chapter match")
        #expect(FormatSwitchLabels.precisionLabel(for: .chapterRelative) == "chapter estimate")
        #expect(
            FormatSwitchLabels.precisionLabel(for: .wholeBookPercentage) == "approximate percentage"
        )
    }

    @Test func sixDirectionsCoveredWithoutClaimingFalseAlignment() {
        let pairs: [(LocalMediaCategory, LocalMediaCategory)] = [
            (.audio, .ebook), (.audio, .synced),
            (.ebook, .audio), (.ebook, .synced),
            (.synced, .audio), (.synced, .ebook),
        ]
        for (from, to) in pairs {
            let result = StoryPositionTranslator.translate(
                input(
                    from: from,
                    to: to,
                    progression: 0.33,
                    locator: from == .audio
                        ? audioLocator(progress: 0.33)
                        : textLocator(progress: 0.33, href: "t.xhtml"),
                )
            )
            #expect(result.shouldApplyHandoff)
            // Without SMIL/timeline inputs, never claim exact media-overlay.
            #expect(result.precision != .mediaOverlayAlignment)
        }
    }

    // MARK: - Helpers

    private func input(
        from: LocalMediaCategory,
        to: LocalMediaCategory,
        progression: Double,
        locator: BookLocator?,
        chapters: [StoryPositionChapter] = [],
        chaptersTimingVerified: Bool = false,
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
            destinationChaptersTimingVerified: chaptersTimingVerified,
            destinationSavedProgression: destSaved,
            destinationSavedTimestamp: destTimestamp,
            destinationSavedLocator: destSaved.map { audioLocator(progress: $0) },
            hasVerifiedMediaOverlay: hasVerifiedOverlay,
        )
    }

    private func sampleSmilSections(total: Double) -> [SectionInfo] {
        [
            SectionInfo(
                index: 0,
                id: "text/ch1.xhtml",
                label: "One",
                level: 0,
                mediaOverlay: [
                    SMILEntry(
                        textId: "p-early",
                        textHref: "text/ch1.xhtml",
                        audioFile: "a.mp3",
                        begin: 0,
                        end: 200,
                        cumSumAtEnd: 200,
                    )
                ],
            ),
            SectionInfo(
                index: 1,
                id: "text/ch2.xhtml",
                label: "Two",
                level: 0,
                mediaOverlay: [
                    SMILEntry(
                        textId: "p-mid",
                        textHref: "text/ch2.xhtml",
                        audioFile: "a.mp3",
                        begin: 200,
                        end: 400,
                        cumSumAtEnd: 400,
                    ),
                    SMILEntry(
                        textId: "p-late",
                        textHref: "text/ch2.xhtml",
                        audioFile: "a.mp3",
                        begin: 400,
                        end: total,
                        cumSumAtEnd: total,
                    ),
                ],
            ),
        ]
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
