import Foundation
import Testing

@testable import SilveranKit

@Suite("Storyteller pure helpers")
struct StorytellerPureHelpersTests {

    // MARK: - coverVersionQueryValue

    @Test func coverVersionNilAndEmptyYieldNil() {
        #expect(StorytellerActor.coverVersionQueryValue(from: nil) == nil)
        #expect(StorytellerActor.coverVersionQueryValue(from: "") == nil)
    }

    @Test func coverVersionNumericPassthrough() {
        #expect(StorytellerActor.coverVersionQueryValue(from: "1710000000000") == "1710000000000")
        #expect(StorytellerActor.coverVersionQueryValue(from: "0") == "0")
    }

    @Test func coverVersionISOBecomesEpochMillis() {
        let input = "2024-06-15T12:00:00Z"
        let expected = SilveranDate.epochMillisString(
            from: SilveranDate.parse(input, field: .coverVersion)!
        )
        #expect(StorytellerActor.coverVersionQueryValue(from: input) == expected)
    }

    @Test func coverVersionGarbageYieldsNil() {
        #expect(StorytellerActor.coverVersionQueryValue(from: "not-a-date") == nil)
        #expect(StorytellerActor.coverVersionQueryValue(from: "June 15th") == nil)
    }

    // MARK: - parseFilename (Content-Disposition)

    @Test func parseFilenameNilYieldsNil() {
        #expect(parseFilename(fromContentDisposition: nil) == nil)
        #expect(parseFilename(fromContentDisposition: "inline") == nil)
    }

    @Test func parseFilenameQuotedFilename() {
        #expect(
            parseFilename(fromContentDisposition: "attachment; filename=\"book.epub\"")
                == "book.epub"
        )
    }

    @Test func parseFilenameRFC5987PreferredOverFilename() {
        let header =
            "attachment; filename=\"fallback.epub\"; filename*=UTF-8''My%20Book.epub"
        #expect(parseFilename(fromContentDisposition: header) == "My Book.epub")
    }

    @Test func parseFilenameRFC5987Alone() {
        #expect(
            parseFilename(fromContentDisposition: "attachment; filename*=UTF-8''solo%2Fpath.m4b")
                == "solo/path.m4b"
        )
    }

    // MARK: - merge progress preferred tie-break

    @Test func preferredProgressEqualTimestampPicksLargerFraction() {
        let leftID = BookID(sourceID: "server", uuid: "11111111-1111-1111-1111-111111111111")
        let rightID = BookID(sourceID: "server", uuid: "22222222-2222-2222-2222-222222222222")
        let smaller = BookProgress(
            locator: locator(progress: 0.3),
            timestamp: 50,
            source: .server,
        )
        let larger = BookProgress(
            locator: locator(progress: 0.8),
            timestamp: 50,
            source: .pendingSync,
        )
        let winner = StorytellerBookMergeProgress.preferred(from: [
            leftID: smaller,
            rightID: larger,
        ])
        #expect(winner?.progressFraction == 0.8)
        #expect(winner?.timestamp == 50)
    }

    @Test func preferredProgressEmptyMapYieldsNil() {
        #expect(StorytellerBookMergeProgress.preferred(from: [:]) == nil)
    }

    // MARK: - Storyteller UUID identity

    @Test func isStorytellerUUIDRequiresParseableUUID() {
        #expect(
            StorytellerBookMergeEligibility.isStorytellerUUID(
                "11111111-1111-1111-1111-111111111111"
            )
        )
        #expect(!StorytellerBookMergeEligibility.isStorytellerUUID("ebook"))
        #expect(!StorytellerBookMergeEligibility.isStorytellerUUID(""))
        #expect(!StorytellerBookMergeEligibility.isStorytellerUUID("not-a-uuid"))
    }

    private func locator(progress: Double) -> BookLocator {
        BookLocator(
            href: "/chapters/1",
            type: "application/xhtml+xml",
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
}
