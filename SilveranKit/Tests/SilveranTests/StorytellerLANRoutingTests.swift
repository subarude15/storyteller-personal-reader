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

@Test func lanRoutingResolveAPIBaseWhenAlreadyApiAppendsV2() {
    let apiOnly = URL(string: "http://192.168.1.2:1800/api")!
    #expect(
        StorytellerLANRouting.resolveAPIBaseURL(from: apiOnly).absoluteString
            == "http://192.168.1.2:1800/api/v2"
    )
}

@Test func lanRoutingResolveAPIBaseWhenAlreadyV2Unchanged() {
    let full = URL(string: "http://192.168.1.2:1800/api/v2")!
    #expect(StorytellerLANRouting.resolveAPIBaseURL(from: full) == full)

    let trailing = URL(string: "http://192.168.1.2:1800/api/v2/")!
    #expect(StorytellerLANRouting.resolveAPIBaseURL(from: trailing) == trailing)
}

@Test func probeReachabilityTrueOnAnyHTTPResponseIncluding401() async {
    ProbeStubURLProtocol.reset(mode: .http(401))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProbeStubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let reachable = await StorytellerLANRouting.probeReachability(
        serverURL: URL(string: "http://10.0.0.5:1800")!,
        session: session,
    )
    #expect(reachable)
    #expect(
        ProbeStubURLProtocol.requests.contains {
            $0.url?.absoluteString == "http://10.0.0.5:1800/api/v2/books"
        }
    )
}

@Test func probeReachabilityFalseOnConnectionError() async {
    ProbeStubURLProtocol.reset(mode: .fail(URLError(.timedOut)))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProbeStubURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    let reachable = await StorytellerLANRouting.probeReachability(
        serverURL: URL(string: "http://10.0.0.5:1800")!,
        session: session,
    )
    #expect(!reachable)
}

@Test func credentialValidationTriesLANFirstWhenReachable() {
    let publicURL = URL(string: "https://storyteller.banditoburrito.xyz")!
    let lanURL = URL(string: "http://192.168.1.2:1800")!

    let bases = StorytellerLANRouting.credentialValidationBaseURLs(
        publicURL: publicURL,
        lanURL: lanURL,
        lanReachable: true,
    )

    #expect(bases.map(\.absoluteString) == [
        "http://192.168.1.2:1800",
        "https://storyteller.banditoburrito.xyz",
    ])
}

@Test func credentialValidationFallsBackToPublicWhenLANUnavailable() {
    let publicURL = URL(string: "https://storyteller.banditoburrito.xyz")!
    let lanURL = URL(string: "http://192.168.1.2:1800")!

    let bases = StorytellerLANRouting.credentialValidationBaseURLs(
        publicURL: publicURL,
        lanURL: lanURL,
        lanReachable: false,
    )

    #expect(bases == [publicURL])
}

@Test func networkRouteStatusLabels() {
    #expect(StorytellerNetworkRoute.lan.settingsStatusLabel == "Using LAN")
    #expect(StorytellerNetworkRoute.public.settingsStatusLabel == "Using public")
}

private final class ProbeStubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode: Sendable {
        case http(Int)
        case fail(URLError)
    }

    private static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var mode: Mode = .http(200)

    static func reset(mode: Mode) {
        lock.lock()
        requests = []
        Self.mode = mode
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let mode = Self.mode
        Self.lock.unlock()

        switch mode {
            case .http(let status):
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"],
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data())
                client?.urlProtocolDidFinishLoading(self)
            case .fail(let error):
                client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
