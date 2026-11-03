import Foundation
import Testing

@testable import SilveranKit

@Suite("HighlightExportPolicy")
struct HighlightExportPolicyTests {
    private func makeHighlight(
        text: String,
        color: HighlightColor? = .yellow,
        note: String? = nil,
        chapterTitle: String? = "Chapter 1",
        totalProgression: Double? = 0.42
    ) -> Highlight {
        let locator = BookLocator(
            href: "chapter1.xhtml",
            type: "application/xhtml+xml",
            title: chapterTitle,
            locations: BookLocator.Locations(
                fragments: ["epubcfi(/6/4!/4/2/1:0)"],
                progression: 0.25,
                position: nil,
                totalProgression: totalProgression,
                cssSelector: nil,
                partialCfi: "epubcfi(/6/4!/4/2/1:0)",
                domRange: nil
            ),
            text: nil
        )
        return Highlight(
            bookID: "book-1",
            locator: locator,
            text: text,
            color: color,
            note: note
        )
    }

    @Test("Filters highlights by search text, color, and note presence")
    func filtersHighlights() {
        let h1 = makeHighlight(
            text: "Call me Ishmael.",
            color: .yellow,
            note: "Opening line",
            chapterTitle: "Loomings"
        )
        let h2 = makeHighlight(
            text: "Towards thee I roll, thou all-destroying but unconquering whale.",
            color: .pink,
            note: nil,
            chapterTitle: "The Chase"
        )
        let h3 = makeHighlight(
            text: "Ignorance is the parent of fear.",
            color: .yellow,
            note: "   ",
            chapterTitle: "The Pulpit"
        )
        let all = [h1, h2, h3]

        #expect(HighlightExportPolicy.filterHighlights(all).count == 3)
        #expect(HighlightExportPolicy.filterHighlights(all, selectedColor: .pink) == [h2])
        #expect(HighlightExportPolicy.filterHighlights(all, onlyWithNotes: true) == [h1])
        #expect(
            HighlightExportPolicy.filterHighlights(all, searchText: "unconquering") == [h2]
        )
        #expect(
            HighlightExportPolicy.filterHighlights(all, searchText: "opening") == [h1]
        )
        #expect(
            HighlightExportPolicy.filterHighlights(all, searchText: "pulpit") == [h3]
        )
    }

    @Test("Available colors are returned in canonical palette order")
    func availableColorsCanonicalOrder() {
        let h1 = makeHighlight(text: "A", color: .purple)
        let h2 = makeHighlight(text: "B", color: .pink)
        let h3 = makeHighlight(text: "C", color: .yellow)
        let colors = HighlightExportPolicy.availableColors(in: [h1, h2, h3])
        #expect(colors == [.pink, .yellow, .purple])
    }

    @Test("Formats progress percentage text from totalProgression or progression fallback")
    func formatsProgressPercentage() {
        let h1 = makeHighlight(text: "A", totalProgression: 0.424)
        #expect(HighlightExportPolicy.progressPercentText(for: h1) == "42%")

        let h2 = makeHighlight(text: "B", totalProgression: nil)
        #expect(HighlightExportPolicy.progressPercentText(for: h2) == "25%")
    }

    @Test("Formats single quote and full Markdown notebook")
    func formatsMarkdownQuoteAndNotebook() {
        let h1 = makeHighlight(
            text: "It is a truth universally acknowledged.",
            color: .green,
            note: "Classic ironic opener",
            chapterTitle: "Chapter I",
            totalProgression: 0.01
        )
        let b1 = makeHighlight(
            text: "Mr. Bennet was among the earliest of those who waited on Mr. Bingley.",
            color: nil,
            note: "Resume reading here",
            chapterTitle: "Chapter II",
            totalProgression: 0.05
        )

        let quote = HighlightExportPolicy.markdownQuote(
            for: h1,
            bookTitle: "Pride and Prejudice",
            author: "Jane Austen"
        )
        #expect(quote.contains("> It is a truth universally acknowledged."))
        #expect(quote.contains("**Note:** Classic ironic opener"))
        #expect(quote.contains("*Pride and Prejudice* by Jane Austen · Chapter I · 1%"))

        let notebook = HighlightExportPolicy.markdownNotebook(
            bookTitle: "Pride and Prejudice",
            author: "Jane Austen",
            highlights: [h1],
            bookmarks: [b1]
        )
        #expect(notebook.contains("# Pride and Prejudice"))
        #expect(notebook.contains("*by Jane Austen*"))
        #expect(notebook.contains("## Highlights (1)"))
        #expect(notebook.contains("### **Chapter I** · 1% · Green"))
        #expect(notebook.contains("## Bookmarks (1)"))
        #expect(notebook.contains("**Chapter II** (5%)"))
    }
}
