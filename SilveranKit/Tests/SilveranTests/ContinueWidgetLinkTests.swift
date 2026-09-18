import Foundation
import SilveranAppleWidgets
import SilveranKit
import Testing

@Suite("Continue widget deep links")
struct ContinueWidgetLinkTests {
    @Test func continueURLMatchesScheme() {
        let url = InkAmpContinueLink.continueURL
        #expect(InkAmpContinueLink.isContinueURL(url))
        #expect(!InkAmpContinueLink.wantsToggle(url))
    }

    @Test func toggleQueryIsDetected() {
        let url = InkAmpContinueLink.toggleURL
        #expect(InkAmpContinueLink.isContinueURL(url))
        #expect(InkAmpContinueLink.wantsToggle(url))
    }

    @Test func appGroupFallbackIsPunkRally() {
        #expect(
            SilveranWidgetConstants.fallbackAppGroupIdentifier == "group.com.punkrally.reader"
        )
        #expect(SilveranWidgetConstants.continueWidgetKind == "InkAmpContinueWidget")
        #expect(
            SilveranWidgetConstants.continueWidgetKind
                != SilveranWidgetConstants.readingWidgetKind
        )
        // Old static tiles must never be resurrected by a register/reload call.
        #expect(
            !SilveranWidgetConstants.legacySideloadContinueWidgetKinds.contains(
                SilveranWidgetConstants.continueWidgetKind
            )
        )
    }

    @Test func appGroupIdentifierNeverUnexpanded() {
        let id = SilveranWidgetSnapshotStore.appGroupIdentifier(bundle: .main)
        #expect(!id.contains("$("))
        #expect(!id.isEmpty)
    }

    @Test func emptySnapshotStillDeepLinksToContinue() {
        let empty = ContinueWidgetSnapshot.empty
        #expect(empty.title == nil)
        #expect(!empty.hasItem)
        #expect(empty.upNextItems.isEmpty)
        // Widget view falls back to this URL when snapshot.deepLink is nil.
        #expect(InkAmpContinueLink.continueURL.absoluteString == "punkrally://continue")
        #expect(InkAmpContinueLink.queueItemID(from: InkAmpContinueLink.continueURL) == nil)
    }

    @Test func queueItemURLRoundTripsBookAndPodcast() {
        let bookQueueID = "book:storyteller/abc-def"
        let bookURL = InkAmpContinueLink.queueItemURL(id: bookQueueID)
        #expect(InkAmpContinueLink.isContinueURL(bookURL))
        #expect(!InkAmpContinueLink.wantsToggle(bookURL))
        #expect(InkAmpContinueLink.queueItemID(from: bookURL) == bookQueueID)
        let book = InkAmpContinueLink.bookID(fromQueueItemID: bookQueueID)
        #expect(book?.sourceID == "storyteller")
        #expect(book?.uuid == "abc-def")
        #expect(InkAmpContinueLink.podcastEpisodeID(fromQueueItemID: bookQueueID) == nil)

        let episodeID = "guid/with space"
        let podcastQueueID = "pod:\(episodeID)"
        let podcastURL = InkAmpContinueLink.queueItemURL(id: podcastQueueID)
        #expect(InkAmpContinueLink.queueItemID(from: podcastURL) == podcastQueueID)
        #expect(InkAmpContinueLink.podcastEpisodeID(fromQueueItemID: podcastQueueID) == episodeID)
        #expect(InkAmpContinueLink.bookID(fromQueueItemID: podcastQueueID) == nil)
    }

    @Test func bookQueueIDSplitsOnLastSlash() {
        let id = "book:folder/source/uuid-1"
        let book = InkAmpContinueLink.bookID(fromQueueItemID: id)
        #expect(book?.sourceID == "folder/source")
        #expect(book?.uuid == "uuid-1")
    }
}
