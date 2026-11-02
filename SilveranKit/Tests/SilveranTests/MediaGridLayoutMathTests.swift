import SwiftUI
import Testing

@testable import SilveranAppleKit

@Suite("Media grid cover column math")
struct MediaGridLayoutMathTests {

    private func fixedWidths(_ columns: [GridItem]) -> [CGFloat?] {
        columns.map { item in
            if case .fixed(let width) = item.size { return width }
            return nil
        }
    }

    @Test func columnsAreEqualFixedWidthsMatchingTileWidth() {
        let layout = MediaGridViewUtilities.coverColumnLayout(
            availableWidth: 700,
            minimumTileWidth: 125,
            minimumCount: 1,
            spacing: 16,
        )
        #expect(layout.columns.count == layout.columnCount)
        #expect(fixedWidths(layout.columns).allSatisfy { $0 == layout.tileWidth })
        #expect(layout.columns.allSatisfy { $0.spacing == 16 })
    }

    @Test func phoneWidthPinsTwoColumns() {
        // 390pt iPhone minus 16pt grid padding on each side.
        let layout = MediaGridViewUtilities.coverColumnLayout(
            availableWidth: 358,
            minimumTileWidth: 150,
            minimumCount: 2,
            spacing: 16,
        )
        #expect(layout.columnCount == 2)
        #expect(layout.tileWidth == 171)
    }

    @Test func minimumCountWinsOnNarrowPhones() {
        // 320pt iPhone SE: only one 150pt tile fits, but phones pin two columns.
        let layout = MediaGridViewUtilities.coverColumnLayout(
            availableWidth: 288,
            minimumTileWidth: 150,
            minimumCount: 2,
            spacing: 16,
        )
        #expect(layout.columnCount == 2)
        #expect(layout.tileWidth == 136)
    }

    @Test func smallCoverModeUsesThreeColumns() {
        let layout = MediaGridViewUtilities.coverColumnLayout(
            availableWidth: 358,
            minimumTileWidth: 100,
            minimumCount: 3,
            spacing: 16,
        )
        #expect(layout.columnCount == 3)
        #expect(layout.tileWidth == 108)
    }

    @Test func fitCountGrowsOnlyWhenWidthAllows() {
        let wide = MediaGridViewUtilities.coverColumnLayout(
            availableWidth: 700,
            minimumTileWidth: 125,
            minimumCount: 1,
            spacing: 16,
        )
        #expect(wide.columnCount == 5)
        #expect(wide.tileWidth == 127)
        #expect(wide.tileWidth >= 125)

        let justUnder = MediaGridViewUtilities.coverColumnLayout(
            availableWidth: 125 * 5 + 16 * 4 - 1,
            minimumTileWidth: 125,
            minimumCount: 1,
            spacing: 16,
        )
        #expect(justUnder.columnCount == 4)
    }

    @Test func zeroSpacingMacStyleLayout() {
        let layout = MediaGridViewUtilities.coverColumnLayout(
            availableWidth: 1000,
            minimumTileWidth: 125,
            minimumCount: 1,
            spacing: 0,
        )
        #expect(layout.columnCount == 8)
        #expect(layout.tileWidth == 125)
        #expect(layout.columns.allSatisfy { $0.spacing == 0 })
    }

    @Test func invalidInputsFallBackToSingleColumn() {
        let zeroWidth = MediaGridViewUtilities.coverColumnLayout(
            availableWidth: 0,
            minimumTileWidth: 125,
            minimumCount: 2,
            spacing: 16,
        )
        #expect(zeroWidth.columnCount == 1)
        #expect(zeroWidth.columns.count == 1)
        #expect(zeroWidth.tileWidth == 125)

        let zeroTile = MediaGridViewUtilities.coverColumnLayout(
            availableWidth: 300,
            minimumTileWidth: 0,
            minimumCount: 1,
            spacing: 16,
        )
        #expect(zeroTile.columnCount == 1)
        #expect(zeroTile.tileWidth == 0)

        let negativeWidth = MediaGridViewUtilities.coverColumnLayout(
            availableWidth: -50,
            minimumTileWidth: 125,
            minimumCount: 1,
            spacing: 16,
        )
        #expect(negativeWidth.columnCount == 1)
    }
}
