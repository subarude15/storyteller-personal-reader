import Foundation
import Testing

@testable import SilveranKit

@Test func bookProgressPrefersTotalProgression() {
    let locator = makeLocator(progression: 0.2, totalProgression: 0.65)
    let progress = BookProgress(locator: locator, timestamp: 1, source: .server)

    #expect(progress.progressFraction == 0.65)
}

@Test func bookProgressClampsOutOfRangeValues() {
    let belowZero = BookProgress(
        locator: makeLocator(progression: nil, totalProgression: -0.25),
        timestamp: 1,
        source: .server,
    )
    let aboveOne = BookProgress(
        locator: makeLocator(progression: nil, totalProgression: 1.4),
        timestamp: 2,
        source: .pendingSync,
    )

    #expect(belowZero.progressFraction == 0)
    #expect(aboveOne.progressFraction == 1)
}

@Test func pendingProgressSyncRoundTripPreservesScopedIdentityAndLocator() throws {
    let pending = PendingProgressSync(
        bookID: BookID(sourceID: "storyteller-home", uuid: "book-123"),
        locator: makeLocator(progression: 0.5, totalProgression: 0.42),
        timestamp: 1_789_000_000_000,
        syncedToStoryteller: false,
    )

    let data = try JSONEncoder().encode(pending)
    let decoded = try JSONDecoder().decode(PendingProgressSync.self, from: data)

    #expect(decoded == pending)
    #expect(decoded.bookID.sourceID == "storyteller-home")
    #expect(decoded.bookID.uuid == "book-123")
    #expect(decoded.locator.locations?.totalProgression == 0.42)
    #expect(decoded.syncedToStoryteller == false)
}

private func makeLocator(
    progression: Double?,
    totalProgression: Double?,
) -> BookLocator {
    BookLocator(
        href: "chapter-03.xhtml",
        type: "application/xhtml+xml",
        title: "Chapter 3",
        locations: BookLocator.Locations(
            fragments: ["chapter-03"],
            progression: progression,
            position: 3,
            totalProgression: totalProgression,
            cssSelector: nil,
            partialCfi: nil,
            domRange: nil,
        ),
        text: nil,
    )
}
