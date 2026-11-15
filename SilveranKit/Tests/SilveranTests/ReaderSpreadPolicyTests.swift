import Foundation
import SilveranKit
import Testing

@Suite("iPad two-page spread policy")
struct ReaderSpreadPolicyTests {
    private func shows(
        enabled: Bool = true,
        regular: Bool = true,
        scrolling: Bool = false,
        _ width: Double,
        _ height: Double
    ) -> Bool {
        ReaderSpreadPolicy.showsSpread(
            enabled: enabled,
            regularWidth: regular,
            scrolling: scrolling,
            width: width,
            height: height
        )
    }

    @Test func thresholds() {
        #expect(shows(1000, 700))
        #expect(shows(1366, 1024))
        #expect(!shows(999, 700))
        #expect(!shows(1000, 1000), "square is not landscape")
        #expect(!shows(1024, 1366), "portrait")
        #expect(!shows(regular: false, 1200, 700))
        #expect(!shows(enabled: false, 1200, 700))
        #expect(!shows(scrolling: true, 1200, 700))
    }

    @Test func rotationAndSidebarUseMeasuredContainer() {
        // 13" iPad landscape: spread; rotating to portrait drops it; reopening landscape restores it.
        let sizes: [(Double, Double)] = [(1366, 1024), (1024, 1366), (1366, 1024)]
        #expect(sizes.map { shows($0.0, $0.1) } == [true, false, true])
        // The audio sidebar (1pt separator + 360pt + 28pt padding) shrinks the reader below 1000pt.
        let sidebar = 389.0
        #expect(shows(1194, 834))
        #expect(!shows(1194 - sidebar, 834))
        #expect(!shows(1366 - sidebar, 1024))
    }

    @Test func geometry() {
        #expect(ReaderSpreadPolicy.pageWidth(containerWidth: 1000) == 436)
        #expect(ReaderSpreadPolicy.pageWidth(containerWidth: 1366) == 619)
        let w = 1366.0
        let page = ReaderSpreadPolicy.pageWidth(containerWidth: w)
        #expect(2 * ReaderSpreadPolicy.outerMargin + ReaderSpreadPolicy.gutter + 2 * page == w)
    }

    @Test func pagePairsPutCoverOnRectoAndBlankAfterOddLastPage() {
        // Rendered index 0 is the blank verso, 1 the cover.
        #expect(ReaderSpreadPolicy.pair(containing: 0, pageCount: 9) == (0, 1))
        #expect(ReaderSpreadPolicy.pair(containing: 1, pageCount: 9) == (0, 1))
        #expect(ReaderSpreadPolicy.pair(containing: 4, pageCount: 9) == (4, 5))
        #expect(ReaderSpreadPolicy.pair(containing: 5, pageCount: 9) == (4, 5))
        #expect(ReaderSpreadPolicy.pair(containing: 8, pageCount: 9) == (8, nil))
        #expect(ReaderSpreadPolicy.pair(containing: -3, pageCount: 9) == (0, 1))
    }

    @Test func readaloudAdvancesOnlyWhenTheSentenceLeavesTheSpread() {
        // Highlight moving 2 -> 3 stays on the same spread; 3 -> 4 needs one spread turn.
        let pairs = [2, 3, 4].map { ReaderSpreadPolicy.pair(containing: $0, pageCount: 10).left }
        #expect(pairs == [2, 2, 4])
    }

    @Test func spineOpacityPerTheme() {
        #expect(ReaderSpreadPolicy.spineOpacity(isDark: false) == 0.10)
        #expect(ReaderSpreadPolicy.spineOpacity(isDark: true) == 0.30)
        #expect(ReaderSpreadPolicy.hairlineOpacity == 0.06)
        #expect(!ReaderSpreadPolicy.isDark(backgroundHex: kDefaultBackgroundColorLight))
        #expect(!ReaderSpreadPolicy.isDark(backgroundHex: "#F4ECD8"), "sepia")
        #expect(ReaderSpreadPolicy.isDark(backgroundHex: kDefaultBackgroundColorDark))
        #expect(!ReaderSpreadPolicy.isDark(backgroundHex: "nonsense"))
    }
}
