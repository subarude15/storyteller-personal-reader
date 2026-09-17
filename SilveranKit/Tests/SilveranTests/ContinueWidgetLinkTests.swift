import Foundation
import SilveranAppleWidgets
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
        #expect(SilveranWidgetConstants.sideloadContinueWidgetKind == "inkamp.continue.v5")
        #expect(
            SilveranWidgetConstants.sideloadContinueWidgetKind
                != SilveranWidgetConstants.readingWidgetKind
        )
        // Old static tiles must never be resurrected by a reload call.
        #expect(
            !SilveranWidgetConstants.legacySideloadContinueWidgetKinds.contains(
                SilveranWidgetConstants.sideloadContinueWidgetKind
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
        // Widget view falls back to this URL when snapshot.deepLink is nil.
        #expect(InkAmpContinueLink.continueURL.absoluteString == "punkrally://continue")
    }
}
