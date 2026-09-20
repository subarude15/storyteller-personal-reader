import Foundation
import Testing

@testable import SilveranKit

@Suite("Service health diagnostics")
struct ServiceHealthTests {
    // MARK: - LazyLibrarian

    @Test func lazyLibrarianConfiguredSuccessIncludesVersion() async {
        let transport = LLScript()
        transport.handler = { _, _ in
            LLScript.http(
                #"{"Success":true,"current_version":"1.2.3","latest_version":"1.2.3"}"#
            )
        }
        let checker = LazyLibrarianHealthChecker(transport: transport)
        let result = await checker.check(
            settings: .init(
                lazyLibrarianEnabled: true,
                lazyLibrarianBaseURL: "http://192.168.1.20:5299",
                lazyLibrarianAPIKey: "secret-key",
            )
        )
        #expect(result.status == .healthy)
        #expect(result.summary.contains("1.2.3"))
        #expect(result.sanitizedHost?.contains("secret-key") != true)
        #expect(result.isActionableIssue == false)
        #expect(transport.commands == ["getVersion"])
    }

    @Test func lazyLibrarianBadAuth() async {
        let transport = LLScript()
        transport.handler = { _, _ in
            LLScript.http(
                #"{"Success":false,"Error":{"Code":401,"Message":"Incorrect API key"}}"#
            )
        }
        let result = await LazyLibrarianHealthChecker(transport: transport).check(
            settings: .init(
                lazyLibrarianEnabled: true,
                lazyLibrarianBaseURL: "http://host:5299",
                lazyLibrarianAPIKey: "bad",
            )
        )
        #expect(result.status == .unavailable)
        #expect(result.technicalDetail == "unauthorized")
        #expect(result.isActionableIssue)
    }

    @Test func lazyLibrarianUnreachable() async {
        let transport = LLScript()
        transport.error = URLError(.cannotConnectToHost)
        let result = await LazyLibrarianHealthChecker(transport: transport).check(
            settings: .init(
                lazyLibrarianEnabled: true,
                lazyLibrarianBaseURL: "http://host:5299",
                lazyLibrarianAPIKey: "key",
            )
        )
        #expect(result.status == .unavailable)
        #expect(result.summary == "Could not reach LazyLibrarian")
    }

    @Test func lazyLibrarianDisabled() async {
        let result = await LazyLibrarianHealthChecker(transport: LLScript()).check(
            settings: .init(lazyLibrarianEnabled: false)
        )
        #expect(result.status == .disabled)
        #expect(result.isActionableIssue == false)
    }

    // MARK: - Shelfarr

    @Test func shelfarrSuccess() async throws {
        let session = try shelfarrSession(status: 200, body: #"{"requests":[]}"#)
        let result = await ShelfarrHealthChecker(session: session).check(
            settings: .init(
                shelfarrBaseURL: "https://shelfarr.example.com",
                shelfarrAPIToken: "shf_testtoken",
            )
        )
        #expect(result.status == .healthy)
        #expect(result.summary == "Connected")
        #expect(result.sanitizedHost?.contains("shf_") != true)
    }

    @Test func shelfarrAuthenticationFailure() async throws {
        let session = try shelfarrSession(status: 401, body: "")
        let result = await ShelfarrHealthChecker(session: session).check(
            settings: .init(
                shelfarrBaseURL: "https://shelfarr.example.com",
                shelfarrAPIToken: "shf_bad",
            )
        )
        #expect(result.status == .unavailable)
        #expect(result.technicalDetail == "authenticationFailed")
        #expect(result.suggestedAction?.localizedCaseInsensitiveContains("token") == true)
    }

    @Test func shelfarrPermissionFailure() async throws {
        let session = try shelfarrSession(
            status: 403,
            body: #"{"errors":["Missing API scope: requests:read"]}"#,
        )
        let result = await ShelfarrHealthChecker(session: session).check(
            settings: .init(
                shelfarrBaseURL: "https://shelfarr.example.com",
                shelfarrAPIToken: "shf_readonly_missing",
            )
        )
        #expect(result.status == .warning)
        #expect(result.detail == "Token cannot read requests")
        #expect(result.suggestedAction == "Check API token permissions")
        #expect(result.isActionableIssue)
    }

    @Test func shelfarrTimeoutUnreachable() async throws {
        HealthShelfarrStubURLProtocol.reset(
            status: 200,
            headers: [:],
            body: Data(),
            error: URLError(.timedOut),
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HealthShelfarrStubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let result = await ShelfarrHealthChecker(session: session).check(
            settings: .init(
                shelfarrBaseURL: "https://shelfarr.example.com",
                shelfarrAPIToken: "shf_token",
            )
        )
        #expect(result.status == .unavailable)
        #expect(result.technicalDetail == "URLError timedOut")
    }

    // MARK: - LibriVox

    @Test func librivoxSuccess() async {
        let payload = Data(#"{"books":[{"id":"1","title":"Test"}]}"#.utf8)
        let checker = LibriVoxHealthChecker { url in
            #expect(url.absoluteString.contains("limit=1"))
            #expect(!url.absoluteString.contains("Pride"))
            return payload
        }
        let result = await checker.check(settings: .init())
        #expect(result.status == .healthy)
        #expect(result.summary == "Public catalog reachable")
    }

    @Test func librivoxRateLimited() async {
        let checker = LibriVoxHealthChecker { _ in
            throw AudiobookProviderError.rateLimited
        }
        let result = await checker.check(settings: .init())
        #expect(result.status == .warning)
        #expect(result.summary == "Rate limited")
        #expect(result.isActionableIssue)
    }

    @Test func librivoxTimeout() async {
        let checker = LibriVoxHealthChecker { _ in
            throw AudiobookProviderError.timeout
        }
        let result = await checker.check(settings: .init())
        #expect(result.status == .unavailable)
        #expect(result.technicalDetail == "URLError timedOut")
    }

    @Test func librivoxMalformedResponse() async {
        let checker = LibriVoxHealthChecker { _ in
            Data("<html>nope</html>".utf8)
        }
        let result = await checker.check(settings: .init())
        #expect(result.status == .warning)
        #expect(result.technicalDetail == "undecodable")
    }

    // MARK: - Book Search LAN

    @Test func bookSearchDisabled() async {
        let result = await BookSearchLANHealthChecker(transport: BookSearchScript()).check(
            settings: .init(bookSearchLANEnabled: false)
        )
        #expect(result.status == .disabled)
        #expect(result.isActionableIssue == false)
    }

    @Test func bookSearchReachable() async {
        let transport = BookSearchScript()
        transport.status = 200
        let result = await BookSearchLANHealthChecker(transport: transport).check(
            settings: .init(
                bookSearchLANEnabled: true,
                bookSearchLANBaseURL: "http://192.168.1.2:3010",
            )
        )
        #expect(result.status == .healthy)
        #expect(result.summary == "Reachable on local network")
        #expect(result.isActionableIssue == false)
    }

    @Test func bookSearchUnreachableIsLocalOnlyNotWarning() async {
        let transport = BookSearchScript()
        transport.error = URLError(.cannotConnectToHost)
        let result = await BookSearchLANHealthChecker(transport: transport).check(
            settings: .init(
                bookSearchLANEnabled: true,
                bookSearchLANBaseURL: "http://192.168.1.2:3010",
            )
        )
        #expect(result.status == .localOnly)
        #expect(result.isActionableIssue == false)
        #expect(result.summary == "Not reachable from this network")
    }

    // MARK: - Storyteller

    @Test func storytellerSuccessfulConnection() async {
        let probe = StubStorytellerProbe(
            result: .init(
                isConfigured: true,
                isReachable: true,
                sanitizedHost: "https://storyteller.example.com",
                lastSync: Date().addingTimeInterval(-120),
            )
        )
        let result = await StorytellerHealthChecker(probe: probe).check(settings: .init())
        #expect(result.status == .healthy)
        #expect(result.summary.hasPrefix("Connected"))
    }

    @Test func storytellerUnreachable() async {
        let probe = StubStorytellerProbe(
            result: .init(isConfigured: true, isReachable: false, errorDetail: "auth failed")
        )
        let result = await StorytellerHealthChecker(probe: probe).check(settings: .init())
        #expect(result.status == .unavailable)
        #expect(result.summary == "Could not reach Storyteller")
        #expect(result.isActionableIssue)
    }

    @Test func storytellerStaleSyncIsWarning() async {
        let probe = StubStorytellerProbe(
            result: .init(
                isConfigured: true,
                isReachable: true,
                lastSync: Date().addingTimeInterval(-12 * 3600),
            )
        )
        let result = await StorytellerHealthChecker(probe: probe).check(settings: .init())
        #expect(result.status == .warning)
        #expect(result.detail?.contains("12") == true)
        #expect(result.isActionableIssue)
    }

    // MARK: - Needs Attention

    @Test func needsAttentionIncludesWarningAndUnavailable() {
        let results = [
            ServiceHealthResult(
                serviceID: .shelfarr,
                status: .warning,
                summary: "perm",
                detail: "Token cannot read requests",
                suggestedAction: "Check API token permissions",
            ),
            ServiceHealthResult(
                serviceID: .lazyLibrarian,
                status: .unavailable,
                summary: "down",
                detail: "Could not reach LazyLibrarian",
                suggestedAction: "Check URL",
            ),
        ]
        let items = ServiceHealthAttention.items(from: results)
        #expect(items.count == 2)
        #expect(items.map(\.serviceID) == [.shelfarr, .lazyLibrarian])
    }

    @Test func needsAttentionSkipsDisabledOptionalService() {
        let results = [
            ServiceHealthResult(
                serviceID: .lazyLibrarian,
                status: .disabled,
                summary: "Not configured",
            ),
            ServiceHealthResult(
                serviceID: .shelfarr,
                status: .disabled,
                summary: "Not configured",
            ),
        ]
        #expect(ServiceHealthAttention.items(from: results).isEmpty)
        let summary = ServiceHealthSummary(results: results)
        #expect(summary.healthy == 0)
        #expect(summary.warnings == 0)
        #expect(summary.unavailable == 0)
    }

    @Test func needsAttentionSkipsLANOnlyOffNetwork() {
        let results = [
            ServiceHealthResult(
                serviceID: .bookSearchLAN,
                status: .localOnly,
                summary: "Not reachable from this network",
                isActionableIssue: false,
            ),
            ServiceHealthResult(
                serviceID: .librivox,
                status: .healthy,
                summary: "Public catalog reachable",
            ),
        ]
        #expect(ServiceHealthAttention.items(from: results).isEmpty)
        let summary = ServiceHealthSummary(results: results)
        #expect(summary.healthy == 1)
        #expect(summary.warnings == 0)
        #expect(summary.unavailable == 0)
    }

    @Test func summaryDerivesFromActualStatuses() {
        let results = [
            ServiceHealthResult(serviceID: .lazyLibrarian, status: .healthy, summary: "ok"),
            ServiceHealthResult(serviceID: .shelfarr, status: .healthy, summary: "ok"),
            ServiceHealthResult(serviceID: .librivox, status: .warning, summary: "429"),
            ServiceHealthResult(serviceID: .storyteller, status: .unavailable, summary: "down"),
            ServiceHealthResult(serviceID: .bookSearchLAN, status: .localOnly, summary: "lan"),
            ServiceHealthResult(serviceID: .lazyLibrarian, status: .checking, summary: "…"),
        ]
        // Two LazyLibrarian entries intentionally — summary counts rows as given.
        let summary = ServiceHealthSummary(results: results)
        #expect(summary.healthy == 2)
        #expect(summary.warnings == 1)
        #expect(summary.unavailable == 1)
    }

    @Test func urlSanitizerStripsCredentialsAndQuery() {
        let sanitized = ServiceHealthURLSanitizer.sanitize(
            "https://user:pass@host.example:8443/api?apikey=secret"
        )
        #expect(sanitized?.contains("pass") != true)
        #expect(sanitized?.contains("apikey") != true)
        #expect(sanitized?.contains("host.example") == true)
    }

    @Test func cacheRoundTripOmitsSecrets() throws {
        let defaults = UserDefaults(suiteName: "service-health-tests-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }
        let cache = ServiceHealthCache(defaults: defaults)
        let result = ServiceHealthResult(
            serviceID: .shelfarr,
            status: .healthy,
            summary: "Connected",
            lastChecked: Date(timeIntervalSince1970: 1_700_000_000),
            sanitizedHost: "https://shelfarr.example.com",
            metadata: ["version": "1"],
        )
        cache.save([result])
        let loaded = cache.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].status == .healthy)
        let data = try #require(defaults.data(forKey: "punkRally.serviceHealth.results.v1"))
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(!text.contains("Bearer"))
        #expect(!text.contains("apikey"))
        #expect(!text.contains("shf_"))
    }

    // MARK: - Helpers

    private func shelfarrSession(status: Int, body: String) throws -> URLSession {
        HealthShelfarrStubURLProtocol.reset(
            status: status,
            headers: ["Content-Type": "application/json"],
            body: Data(body.utf8),
            error: nil,
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HealthShelfarrStubURLProtocol.self]
        configuration.timeoutIntervalForRequest = 3
        return URLSession(configuration: configuration)
    }
}

private struct StubStorytellerProbe: StorytellerHealthProbing {
    var result: StorytellerHealthProbeResult

    func probe(lastSyncHint: Date?) async -> StorytellerHealthProbeResult {
        var copy = result
        if copy.lastSync == nil {
            copy.lastSync = lastSyncHint
        }
        return copy
    }
}

private final class LLScript: LazyLibrarianTransport, @unchecked Sendable {
    var commands: [String] = []
    var error: URLError?
    var handler: ((String, [String: String]) -> LazyLibrarianHTTP)?
    private let lock = NSLock()

    func send(_ url: URL, timeout _: TimeInterval) async throws -> LazyLibrarianHTTP {
        if let error { throw error }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let cmd = items.first { $0.name == "cmd" }?.value ?? ""
        var query: [String: String] = [:]
        for item in items where item.name != "apikey" && item.name != "cmd" {
            query[item.name] = item.value ?? ""
        }
        lock.lock()
        commands.append(cmd)
        lock.unlock()
        return handler?(cmd, query) ?? Self.http("OK")
    }

    static func http(_ body: String, status: Int = 200) -> LazyLibrarianHTTP {
        LazyLibrarianHTTP(status: status, body: Data(body.utf8))
    }
}

private final class BookSearchScript: BookSearchLANTransport, @unchecked Sendable {
    var status = 200
    var error: URLError?

    func ping(_ url: URL, timeout _: TimeInterval) async throws -> BookSearchLANHTTP {
        _ = url
        if let error { throw error }
        return BookSearchLANHTTP(status: status)
    }
}

final class HealthShelfarrStubURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var status = 200
    static var headers: [String: String] = [:]
    static var body = Data()
    static var error: Error?

    static func reset(status: Int, headers: [String: String], body: Data, error: Error?) {
        lock.lock()
        self.status = status
        self.headers = headers
        self.body = body
        self.error = error
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let status = Self.status
        let headers = Self.headers
        let body = Self.body
        let error = Self.error
        Self.lock.unlock()

        if let error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        let url = request.url ?? URL(string: "https://shelfarr.example.com")!
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers,
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
