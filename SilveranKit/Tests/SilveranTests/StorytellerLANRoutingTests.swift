import Foundation
import Testing

@testable import SilveranKit

@Test func lanRoutingMissingKeyUsesDefault() {
    #expect(StorytellerLANRouting.effectiveLANURL(stored: nil) == kDefaultStorytellerLANURL)
}

@Test func lanRoutingEmptyDisables() {
    #expect(StorytellerLANRouting.effectiveLANURL(stored: "") == nil)
    #expect(StorytellerLANRouting.effectiveLANURL(stored: "   ") == nil)
}

@Test func lanRoutingCustomURL() {
    #expect(
        StorytellerLANRouting.effectiveLANURL(stored: "http://10.0.0.5:1800")
            == "http://10.0.0.5:1800"
    )
}

@Test func lanRoutingPreferOnlyWhenProbeSucceeds() {
    #expect(
        StorytellerLANRouting.preferLAN(
            probeSucceeded: true,
            effectiveLANURL: kDefaultStorytellerLANURL,
        )
    )
    #expect(
        !StorytellerLANRouting.preferLAN(
            probeSucceeded: false,
            effectiveLANURL: kDefaultStorytellerLANURL,
        )
    )
    #expect(
        !StorytellerLANRouting.preferLAN(probeSucceeded: true, effectiveLANURL: nil)
    )
}

@Test func lanRoutingResolveAPIBaseAppendsV2() {
    let base = URL(string: "http://192.168.1.2:1800")!
    let api = StorytellerLANRouting.resolveAPIBaseURL(from: base)
    #expect(api.absoluteString == "http://192.168.1.2:1800/api/v2")
}

@Test func networkRouteStatusLabels() {
    #expect(StorytellerNetworkRoute.lan.settingsStatusLabel == "Using LAN")
    #expect(StorytellerNetworkRoute.public.settingsStatusLabel == "Using public")
}
