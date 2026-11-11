import Foundation
import SilveranKit
import Testing

@Suite("Apple Books reader scrubber, jump-back snapshot & bookmark matching")
struct ReaderScrubberPolicyTests {
    private let sampleSections: [SectionInfo] = [
        SectionInfo(index: 0, id: "OEBPS/ch1.xhtml", label: "Chapter 1", level: 0, mediaOverlay: []),
        SectionInfo(index: 1, id: "OEBPS/ch2.xhtml", label: "Chapter 2", level: 0, mediaOverlay: []),
        SectionInfo(index: 2, id: "OEBPS/ch3.xhtml", label: "Chapter 3", level: 0, mediaOverlay: []),
        SectionInfo(index: 3, id: "OEBPS/ch4.xhtml", label: "Chapter 4", level: 0, mediaOverlay: []),
    ]

    @Test func chapterTicksUseSectionFractionsAndDeduplicateCloseSubchapters() {
        let toc: [TocEntry] = [
            TocEntry(label: "One", href: "ch1.xhtml", level: 0, sectionIndex: 0),
            TocEntry(label: "One-Sub", href: "ch1.xhtml#sub", level: 1, sectionIndex: 0),
            TocEntry(label: "Two", href: "ch2.xhtml", level: 0, sectionIndex: 1),
            TocEntry(label: "Three", href: "ch3.xhtml", level: 0, sectionIndex: 2),
            TocEntry(label: "Four", href: "ch4.xhtml", level: 0, sectionIndex: 3),
        ]
        let fractions = [0.0, 0.22, 0.58, 0.84]
        let ticks = ReaderScrubberPolicy.buildChapterTicks(
            tocEntries: toc,
            sections: sampleSections,
            sectionFractions: fractions
        )

        #expect(ticks.count == 4, "Subchapter at identical section fraction is deduplicated")
        #expect(ticks.map(\.label) == ["One", "Two", "Three", "Four"])
        #expect(ticks.map(\.fraction) == [0.0, 0.22, 0.58, 0.84])
    }

    @Test func activeChapterResolvesAcrossBookFractions() {
        let ticks = ReaderScrubberPolicy.buildChapterTicks(
            tocEntries: [],
            sections: sampleSections,
            sectionFractions: [0.0, 0.25, 0.50, 0.75]
        )

        #expect(ReaderScrubberPolicy.activeChapter(atBookFraction: 0.0, ticks: ticks)?.label == "Chapter 1")
        #expect(ReaderScrubberPolicy.activeChapter(atBookFraction: 0.24, ticks: ticks)?.label == "Chapter 1")
        #expect(ReaderScrubberPolicy.activeChapter(atBookFraction: 0.25, ticks: ticks)?.label == "Chapter 2")
        #expect(ReaderScrubberPolicy.activeChapter(atBookFraction: 0.62, ticks: ticks)?.label == "Chapter 3")
        #expect(ReaderScrubberPolicy.activeChapter(atBookFraction: 0.99, ticks: ticks)?.label == "Chapter 4")
    }

    @Test func pageNumberAndPageTicksForChapterScrubbing() {
        #expect(ReaderScrubberPolicy.pageNumber(forChapterFraction: 0.0, totalPages: 10) == 1)
        #expect(ReaderScrubberPolicy.pageNumber(forChapterFraction: 0.5, totalPages: 10) == 6)
        #expect(ReaderScrubberPolicy.pageNumber(forChapterFraction: 1.0, totalPages: 10) == 10)

        let pageTicks = ReaderScrubberPolicy.pageTickFractions(totalPages: 5)
        #expect(pageTicks == [0.25, 0.50, 0.75])
        #expect(ReaderScrubberPolicy.pageTickFractions(totalPages: 50, maxTicks: 36).isEmpty)
    }

    @Test func hapticStepTokensChangeAcrossPagesAndChapterBoundaries() {
        let ticks = ReaderScrubberPolicy.buildChapterTicks(
            tocEntries: [],
            sections: sampleSections,
            sectionFractions: [0.0, 0.25, 0.50, 0.75]
        )

        let chPage1 = ReaderScrubberPolicy.hapticStepToken(
            for: 0.0,
            scope: .chapter,
            totalPages: 10,
            ticks: ticks
        )
        let chPage2 = ReaderScrubberPolicy.hapticStepToken(
            for: 0.12,
            scope: .chapter,
            totalPages: 10,
            ticks: ticks
        )
        #expect(chPage1 != chPage2)

        let beforeCh2 = ReaderScrubberPolicy.hapticStepToken(
            for: 0.249,
            scope: .book,
            totalPages: 10,
            ticks: ticks
        )
        let atCh2 = ReaderScrubberPolicy.hapticStepToken(
            for: 0.251,
            scope: .book,
            totalPages: 10,
            ticks: ticks
        )
        #expect(beforeCh2 != atCh2)
    }

    @Test func jumpSnapshotLabelsAndSignificance() {
        let backSnap = ReaderScrubberPolicy.JumpSnapshot(
            sectionIndex: 1,
            cfi: "epubcfi(/6/4!/4/2:0)",
            href: "OEBPS/ch2.xhtml",
            chapterFraction: 0.3,
            bookFraction: 0.42,
            pageNumber: 14,
            totalPages: 30,
            chapterTitle: "Chapter 2",
            isForwardTarget: false
        )
        #expect(backSnap.pillLabel == "Back to Page 14 (42%)")
        #expect(!backSnap.isSignificantJump(toSection: 1, toPage: 15, toBookFraction: 0.425))
        #expect(backSnap.isSignificantJump(toSection: 1, toPage: 18, toBookFraction: 0.43))
        #expect(backSnap.isSignificantJump(toSection: 2, toPage: 1, toBookFraction: 0.50))

        let forwardSnap = ReaderScrubberPolicy.JumpSnapshot(
            sectionIndex: 3,
            cfi: nil,
            href: "OEBPS/ch4.xhtml",
            chapterFraction: 0.0,
            bookFraction: 0.78,
            pageNumber: 1,
            totalPages: 20,
            chapterTitle: "Chapter 4",
            isForwardTarget: true
        )
        #expect(forwardSnap.pillLabel == "Forward to Page 1 (78%)")
    }

    @Test func matchingBookmarkFindsCurrentPageByCfiOrSectionFraction() {
        let locator = BookLocator(
            href: "OEBPS/ch2.xhtml",
            type: "application/xhtml+xml",
            title: "Chapter 2",
            locations: BookLocator.Locations(
                fragments: nil,
                progression: 0.3,
                position: nil,
                totalProgression: 0.35,
                cssSelector: nil,
                partialCfi: "epubcfi(/6/4!/4/10:0)",
                domRange: nil
            ),
            text: nil
        )
        let bookmark = Highlight(
            bookID: BookID(sourceID: "storyteller", uuid: "book-1"),
            locator: locator,
            text: "Sample bookmarked passage",
            color: nil
        )

        let byCfi = ReaderScrubberPolicy.matchingBookmark(
            in: [bookmark],
            sectionIndex: 1,
            cfi: "epubcfi(/6/4!/4/10:0)",
            href: "OEBPS/ch2.xhtml",
            bookFraction: 0.50,
            totalPagesInSection: 20,
            sections: sampleSections
        )
        #expect(byCfi?.id == bookmark.id)

        let byProximity = ReaderScrubberPolicy.matchingBookmark(
            in: [bookmark],
            sectionIndex: 1,
            cfi: "epubcfi(/6/4!/4/12:0)",
            href: "OEBPS/ch2.xhtml",
            bookFraction: 0.354,
            totalPagesInSection: 20,
            sections: sampleSections
        )
        #expect(byProximity?.id == bookmark.id)

        let differentPage = ReaderScrubberPolicy.matchingBookmark(
            in: [bookmark],
            sectionIndex: 1,
            cfi: "epubcfi(/6/4!/4/90:0)",
            href: "OEBPS/ch2.xhtml",
            bookFraction: 0.45,
            totalPagesInSection: 20,
            sections: sampleSections
        )
        #expect(differentPage == nil)
    }
}
