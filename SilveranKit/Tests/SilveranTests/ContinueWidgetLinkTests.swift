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
    }
}
