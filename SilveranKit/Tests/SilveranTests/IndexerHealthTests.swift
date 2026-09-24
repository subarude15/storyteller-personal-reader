import Foundation
import Testing

@testable import SilveranKit

@Suite("Prowlarr and Jackett health")
struct IndexerHealthTests {
    private let prowlarrSecret = "prowlarr-secret-9f3a"
    private let jackettSecret = "jackett-secret-9f3a"

    // MARK: - Prowlarr

    @Test func prowlarrDisabled() async {
        let transport = ScriptHTTP()
        let result = await ProwlarrHealthChecker(transport: transport).check(
            settings: .init(
                prowlarrEnabled: false,
                prowlarrBaseURL: "http://192.168.1.2:9696",
                prowlarrAPIKey: prowlarrSecret,
            )
        )
        #expect(result.status == .disabled)
        #expect(result.summary == "Not configured")
        #expect(result.isActionableIssue == false)
        #expect(transport.seen.isEmpty)
        #expect(result.sanitizedHost?.contains(prowlarrSecret) != true)
    }

    @Test func prowlarrMissingURLOrKey() async {
        let missingURL = await ProwlarrHealthChecker(transport: ScriptHTTP()).check(
            settings: .init(prowlarrEnabled: true, prowlarrAPIKey: prowlarrSecret)
        )
        #expect(missingURL.status == .disabled)
        #expect(missingURL.detail == "Server URL is missing")
        #expect(missingURL.isActionableIssue == false)

        let missingKey = await ProwlarrHealthChecker(transport: ScriptHTTP()).check(
            settings: .init(prowlarrEnabled: true, prowlarrBaseURL: "http://192.168.1.2:9696")
        )
        #expect(missingKey.status == .disabled)
        #expect(missingKey.detail == "API key is missing")
        #expect(missingKey.isActionableIssue == false)
    }

    @Test func prowlarrSuccessCountsEnabledIndexers() async {
        let transport = prowlarrTransport(
            statusBody: #"{"version":"1.25.0"}"#,
            indexers: """
                [
                  {"id":1,"name":"NZBGeek","enable":true},
                  {"id":2,"name":"AudiobookBay","enable":true},
                  {"id":3,"name":"Turned Off","enable":false}
                ]
                """,
            statuses: "[]",
        )
        let result = await ProwlarrHealthChecker(transport: transport).check(
            settings: prowlarrSettings()
        )
        #expect(result.status == .healthy)
        #expect(result.summary == "Connected · 2 indexers")
        #expect(result.metadata["Version"] == "1.25.0")
        #expect(result.metadata["Enabled"] == "2")
        #expect(result.metadata["Failing"] == "0")
        #expect(result.indexers.count == 3)
        #expect(result.indexers.contains { $0.name == "Turned Off" && $0.health == .disabled })
        #expect(result.isActionableIssue == false)
        let header = transport.seen.first?.value(forHTTPHeaderField: "X-Api-Key")
        #expect(header == prowlarrSecret)
        #expect(transport.seen.allSatisfy { $0.url?.query?.contains("apikey") != true })
    }

    @Test func prowlarrDisabledIndexerDoesNotWarn() async {
        let transport = prowlarrTransport(
            statusBody: #"{"version":"1"}"#,
            indexers: #"[{"id":1,"name":"Off","enable":false}]"#,
            statuses: #"[{"indexerId":1,"mostRecentFailure":"2026-03-18T12:00:00Z"}]"#,
        )
        let result = await ProwlarrHealthChecker(transport: transport).check(
            settings: prowlarrSettings()
        )
        #expect(result.status == .healthy)
        #expect(result.summary == "Connected · 0 indexers")
        #expect(result.indexers.first?.health == .disabled)
        #expect(ServiceHealthAttention.items(from: [result]).isEmpty)
    }

    @Test func prowlarrFailingEnabledIndexerWarns() async {
        let transport = prowlarrTransport(
            statusBody: #"{"version":"1.25.0"}"#,
            indexers: """
                [
                  {"id":1,"name":"NZBGeek","enable":true},
                  {"id":2,"name":"AudiobookBay","enable":true},
                  {"id":3,"name":"Off","enable":false}
                ]
                """,
            statuses: """
                [{
                  "indexerId":2,
                  "initialFailure":"2026-03-18T10:00:00Z",
                  "mostRecentFailure":"2026-03-19T14:30:00Z",
                  "disabledTill":"2026-03-20T08:00:00Z"
                }]
                """,
        )
        let result = await ProwlarrHealthChecker(transport: transport).check(
            settings: prowlarrSettings()
        )
        #expect(result.status == .warning)
        #expect(result.summary == "Connected · 1 indexer failing")
        #expect(result.detail == "1 enabled indexer is failing")
        #expect(result.suggestedAction == "Open details to review affected indexers")
        let failing = result.indexers.first { $0.name == "AudiobookBay" }
        #expect(failing?.health == .failing)
        #expect(failing?.detail?.hasPrefix("Recent failures") == true)
        #expect(failing?.detail?.contains("disabled until") == true)
        #expect(failing?.detail?.contains("2026-03-19T14:30:00Z") != true)
        #expect(failing?.detail?.contains("2026-03-20T08:00:00Z") != true)
        #expect(result.indexers.first { $0.name == "NZBGeek" }?.health == .healthy)
        #expect(result.isActionableIssue)
    }

    @Test func prowlarrAllEnabledFailing() async {
        let transport = prowlarrTransport(
            statusBody: #"{"version":"1"}"#,
            indexers: #"[{"id":1,"name":"A","enable":true},{"id":2,"name":"B","enable":true}]"#,
            statuses: """
                [
                  {"indexerId":1,"mostRecentFailure":"2026-03-18T12:00:00Z"},
                  {"indexerId":2,"initialFailure":"2026-03-17T09:15:00Z"}
                ]
                """,
        )
        let result = await ProwlarrHealthChecker(transport: transport).check(
            settings: prowlarrSettings()
        )
        #expect(result.detail == "All enabled indexers are unavailable")
        #expect(result.status == .warning)
        #expect(result.indexers.allSatisfy { $0.detail?.hasPrefix("Recent failures") == true })
        #expect(result.indexers.contains { $0.detail?.contains("2026-03-18T12:00:00Z") == true } == false)
    }

    @Test func prowlarrFailureDetailUsesFriendlyCopyNotRawTimestamps() async {
        let transport = prowlarrTransport(
            statusBody: #"{"version":"1"}"#,
            indexers: #"[{"id":9,"name":"Only Dates","enable":true}]"#,
            statuses: """
                [{
                  "indexerId":9,
                  "initialFailure":"2026-03-10T01:02:03Z",
                  "mostRecentFailure":"2026-03-11T04:05:06.789Z",
                  "disabledTill":"2026-03-12T07:08:09Z"
                }]
                """,
        )
        let result = await ProwlarrHealthChecker(transport: transport).check(
            settings: prowlarrSettings()
        )
        let detail = result.indexers.first?.detail ?? ""
        #expect(result.indexers.first?.health == .failing)
        #expect(detail == "Recent failures · disabled until \(prowlarrDisplayDate("2026-03-12T07:08:09Z")!)")
        #expect(!detail.contains("2026-03-10T01:02:03Z"))
        #expect(!detail.contains("2026-03-11T04:05:06.789Z"))
        #expect(!detail.contains("2026-03-12T07:08:09Z"))
        #expect(!detail.localizedCaseInsensitiveContains("last test failed"))
    }

    @Test func prowlarrUnreadableStatusDoesNotInventHealthyOrWarn() async {
        let transport = prowlarrTransport(
            statusBody: #"{"version":"1"}"#,
            indexers: #"[{"id":4,"name":"NZBGeek","enable":true}]"#,
            statuses: "not-json",
        )
        let result = await ProwlarrHealthChecker(transport: transport).check(
            settings: prowlarrSettings()
        )
        #expect(result.status == .healthy)
        #expect(result.isActionableIssue == false)
        #expect(result.indexers.first?.health == .unknown)
        #expect(result.indexers.first?.detail == "Configured · live health not available")
        #expect(result.metadata["Failing"] == "Unknown")
    }

    @Test func prowlarrInvalidAuth() async {
        let transport = ScriptHTTP()
        transport.stubs["/api/v1/system/status"] = .init(status: 401, body: Data())
        let result = await ProwlarrHealthChecker(transport: transport).check(
            settings: prowlarrSettings()
        )
        #expect(result.status == .unavailable)
        #expect(result.summary == "Authentication failed")
        #expect(result.technicalDetail == "unauthorized")
        #expect(result.isActionableIssue)
        #expect(!resultText(result).contains(prowlarrSecret))
    }

    @Test func prowlarrTimeoutAndUnreachable() async {
        let timeout = ScriptHTTP()
        timeout.stubs["/api/v1/system/status"] = .init(error: URLError(.timedOut))
        let timed = await ProwlarrHealthChecker(transport: timeout).check(settings: prowlarrSettings())
        #expect(timed.status == .unavailable)
        #expect(timed.summary == "Could not reach Prowlarr")
        #expect(timed.technicalDetail == "URLError timedOut")

        let down = ScriptHTTP()
        down.stubs["/api/v1/system/status"] = .init(error: URLError(.cannotConnectToHost))
        let unreachable = await ProwlarrHealthChecker(transport: down).check(settings: prowlarrSettings())
        #expect(unreachable.summary == "Could not reach Prowlarr")
        #expect(unreachable.technicalDetail == "unreachable")
    }

    @Test func prowlarrMalformedResponse() async {
        let transport = prowlarrTransport(statusBody: #"{"version":"1"}"#, indexers: "nope", statuses: "[]")
        let result = await ProwlarrHealthChecker(transport: transport).check(settings: prowlarrSettings())
        #expect(result.status == .warning)
        #expect(result.technicalDetail == "malformed")
        #expect(result.isActionableIssue)
    }

    @Test func prowlarrSecretsAreNotPersisted() async throws {
        let secret = prowlarrSecret
        let transport = prowlarrTransport(
            statusBody: #"{"version":"1"}"#,
            indexers: #"[{"id":1,"name":"Name \#(secret)","enable":true}]"#,
            statuses: #"[{"indexerId":1,"mostRecentFailure":"2026-03-19T14:30:00Z","disabledTill":"2026-03-20T08:00:00Z"}]"#,
        )
        let result = await ProwlarrHealthChecker(transport: transport).check(
            settings: .init(
                prowlarrEnabled: true,
                prowlarrBaseURL: "http://user:\(secret)@192.168.1.2:9696/prowlarr?apikey=\(secret)",
                prowlarrAPIKey: secret,
            )
        )
        #expect(result.indexers.first?.name.contains(secret) != true)
        #expect(result.indexers.first?.detail?.contains(secret) != true)
        #expect(result.indexers.first?.detail?.contains("apikey=") != true)
        #expect(result.indexers.first?.detail?.hasPrefix("Recent failures") == true)
        #expect(result.indexers.first?.detail?.contains("2026-03-19T14:30:00Z") != true)
        #expect(result.sanitizedHost?.contains(secret) != true)
        #expect(result.sanitizedHost?.contains("apikey") != true)
        try assertCacheOmits(result, secret: secret)
    }

    // MARK: - Jackett

    @Test func jackettDisabled() async {
        let transport = ScriptHTTP()
        let result = await JackettHealthChecker(transport: transport).check(
            settings: .init(
                jackettEnabled: false,
                jackettBaseURL: "http://192.168.1.2:9117",
                jackettAPIKey: jackettSecret,
            )
        )
        #expect(result.status == .disabled)
        #expect(result.isActionableIssue == false)
        #expect(transport.seen.isEmpty)
    }

    @Test func jackettMissingURLOrKey() async {
        let missingURL = await JackettHealthChecker(transport: ScriptHTTP()).check(
            settings: .init(jackettEnabled: true, jackettAPIKey: jackettSecret)
        )
        #expect(missingURL.status == .disabled)
        #expect(missingURL.detail == "Server URL is missing")

        let missingKey = await JackettHealthChecker(transport: ScriptHTTP()).check(
            settings: .init(jackettEnabled: true, jackettBaseURL: "http://192.168.1.2:9117")
        )
        #expect(missingKey.status == .disabled)
        #expect(missingKey.detail == "API key is missing")
        #expect(missingKey.isActionableIssue == false)
    }

    @Test func jackettSuccessCountsConfiguredIndexers() async throws {
        let transport = jackettTransport(body: jackettIndexersXML())
        let result = await JackettHealthChecker(transport: transport).check(settings: jackettSettings())
        #expect(result.status == .healthy)
        #expect(result.summary == "Connected · 2 indexers")
        #expect(result.metadata["Configured"] == "2")
        #expect(result.indexers.map(\.name) == ["NZBGeek", "AudiobookBay"])
        #expect(result.indexers.allSatisfy { $0.health == .unknown })
        #expect(
            result.indexers.allSatisfy {
                $0.detail == "Configured · live health not available"
            }
        )
        #expect(result.isActionableIssue == false)

        let request = try #require(transport.seen.first)
        #expect(request.url?.path.hasSuffix("/api/v2.0/indexers/all/results/torznab/api") == true)
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(query["t"] == "indexers")
        #expect(query["configured"] == "true")
        #expect(query["apikey"] == jackettSecret)
        #expect(result.sanitizedHost?.contains(jackettSecret) != true)
        #expect(result.sanitizedHost?.contains("apikey") != true)
    }

    @Test func jackettUnknownHealthDoesNotWarn() async {
        let transport = jackettTransport(
            body: jackettIndexersXML(
                rows: [
                    ("a", true, "A"),
                    ("b", true, "B"),
                ]
            )
        )
        let result = await JackettHealthChecker(transport: transport).check(settings: jackettSettings())
        #expect(result.status == .healthy)
        #expect(result.summary == "Connected · 2 indexers")
        #expect(result.indexers.allSatisfy { $0.health == .unknown })
        #expect(ServiceHealthAttention.items(from: [result]).isEmpty)
    }

    @Test func jackettTorznabListDoesNotInventFailures() async {
        // Torznab t=indexers exposes identity and caps only — no live health / last_error.
        let transport = jackettTransport(body: jackettIndexersXML())
        let result = await JackettHealthChecker(transport: transport).check(settings: jackettSettings())
        #expect(result.status == .healthy)
        #expect(result.indexers.contains { $0.health == .failing } == false)
        #expect(result.isActionableIssue == false)
        #expect(ServiceHealthAttention.items(from: [result]).isEmpty)
    }

    @Test func jackettConfiguredFalseIsDisabledNotWarning() async {
        let transport = jackettTransport(
            body: jackettIndexersXML(
                rows: [
                    ("nzbgeek", true, "NZBGeek"),
                    ("off", false, "Off"),
                ]
            )
        )
        let result = await JackettHealthChecker(transport: transport).check(settings: jackettSettings())
        #expect(result.status == .healthy)
        #expect(result.summary == "Connected · 1 indexer")
        #expect(result.indexers.first { $0.name == "Off" }?.health == .disabled)
        #expect(ServiceHealthAttention.items(from: [result]).isEmpty)
    }

    @Test func jackettInvalidAuth() async {
        let transport = ScriptHTTP()
        transport.stubs[JackettHealthClient.indexerListPath] = .init(
            status: 403,
            body: Data(jackettSecret.utf8),
        )
        let result = await JackettHealthChecker(transport: transport).check(settings: jackettSettings())
        #expect(result.status == .unavailable)
        #expect(result.summary == "Authentication failed")
        #expect(!resultText(result).contains(jackettSecret))
    }

    @Test func jackettTimeoutAndUnreachable() async {
        let timeout = ScriptHTTP()
        timeout.stubs[JackettHealthClient.indexerListPath] = .init(error: URLError(.timedOut))
        let timed = await JackettHealthChecker(transport: timeout).check(settings: jackettSettings())
        #expect(timed.summary == "Could not reach Jackett")
        #expect(timed.technicalDetail == "URLError timedOut")

        let down = ScriptHTTP()
        down.stubs[JackettHealthClient.indexerListPath] = .init(
            error: URLError(.cannotConnectToHost)
        )
        let unreachable = await JackettHealthChecker(transport: down).check(settings: jackettSettings())
        #expect(unreachable.technicalDetail == "unreachable")
    }

    @Test func jackettMalformedResponse() async {
        let transport = jackettTransport(body: #"{"not":"torznab xml"}"#)
        let result = await JackettHealthChecker(transport: transport).check(settings: jackettSettings())
        #expect(result.status == .warning)
        #expect(result.technicalDetail == "malformed")
        #expect(result.isActionableIssue)

        let wrongRoot = jackettTransport(body: #"<caps><server title="Jackett"/></caps>"#)
        let wrong = await JackettHealthChecker(transport: wrongRoot).check(settings: jackettSettings())
        #expect(wrong.technicalDetail == "malformed")
    }

    @Test func jackettSecretsAreNotPersisted() async throws {
        let secret = jackettSecret
        let transport = jackettTransport(
            body: jackettIndexersXML(
                rows: [
                    ("id-\(secret)", true, "Name \(secret)"),
                ]
            )
        )
        let result = await JackettHealthChecker(transport: transport).check(
            settings: .init(
                jackettEnabled: true,
                jackettBaseURL: "http://192.168.1.2:9117/?apikey=\(secret)#frag",
                jackettAPIKey: secret,
            )
        )
        #expect(result.status == .healthy)
        #expect(result.sanitizedHost == "http://192.168.1.2:9117")
        #expect(result.indexers.first?.name.contains(secret) != true)
        #expect(result.indexers.first?.id.contains(secret) != true)
        try assertCacheOmits(result, secret: secret)
        let redacted = IndexerSecretRedactor.redact(
            "X-Api-Key: \(secret) Authorization: Bearer \(secret) apikey=\(secret)",
            secrets: [secret],
        )
        #expect(!redacted.contains(secret))
        #expect(redacted.contains("apikey=••••"))
    }

    // MARK: - Dashboard

    @Test func defaultCheckersKeepExistingServicesAndInsertIndexers() {
        let ids = ServiceHealthDiagnostics.defaultCheckers().map(\.serviceID)
        #expect(
            ids == [
                .lazyLibrarian, .shelfarr, .librivox, .storyteller, .prowlarr, .jackett,
                .deluge, .bookSearchLAN,
            ]
        )
        #expect(ids == ServiceHealthID.allCases)
    }

    @Test func diagnosticsAttentionIncludesIndexerFailuresNotDisabledServices() async {
        let prowlarr = prowlarrTransport(
            statusBody: #"{"version":"1"}"#,
            indexers: #"[{"id":1,"name":"A","enable":true},{"id":2,"name":"B","enable":true}]"#,
            statuses: #"[{"indexerId":2,"mostRecentFailure":"2026-03-19T14:30:00Z","disabledTill":"2026-03-20T08:00:00Z"}]"#,
        )
        let jackett = ScriptHTTP()
        let diagnostics = ServiceHealthDiagnostics(
            checkers: dashboardCheckers(prowlarr: prowlarr, jackett: jackett),
            loadSettings: {
                ServiceHealthSettingsSnapshot(
                    lazyLibrarianEnabled: true,
                    prowlarrEnabled: true,
                    prowlarrBaseURL: "http://192.168.1.2:9696",
                    prowlarrAPIKey: "prowlarr-secret-9f3a",
                    jackettEnabled: false,
                    jackettBaseURL: "http://192.168.1.2:9117",
                    jackettAPIKey: "jackett-secret-9f3a",
                )
            },
            cache: isolatedCache(),
        )
        let results = await diagnostics.runAll()
        #expect(results.map(\.serviceID) == ServiceHealthID.allCases)
        #expect(results.map(\.displayName).contains("LazyLibrarian"))
        #expect(results.map(\.displayName).contains("Book Search (LAN-only)"))
        let attention = ServiceHealthAttention.items(from: results)
        #expect(attention.map(\.serviceID) == [.prowlarr])
        #expect(attention.first?.problem == "1 enabled indexer is failing")
        #expect(jackett.seen.isEmpty)

        let quiet = ServiceHealthDiagnostics(
            checkers: dashboardCheckers(prowlarr: ScriptHTTP(), jackett: ScriptHTTP()),
            loadSettings: {
                ServiceHealthSettingsSnapshot(
                    prowlarrEnabled: false,
                    jackettEnabled: false,
                )
            },
            cache: isolatedCache(),
        )
        let quietResults = await quiet.runAll()
        let quietAttention = ServiceHealthAttention.items(from: quietResults).map(\.serviceID)
        #expect(!quietAttention.contains(.prowlarr))
        #expect(!quietAttention.contains(.jackett))
    }

    // MARK: - Helpers

    private func prowlarrSettings() -> ServiceHealthSettingsSnapshot {
        .init(
            prowlarrEnabled: true,
            prowlarrBaseURL: "http://192.168.1.2:9696",
            prowlarrAPIKey: prowlarrSecret,
        )
    }

    private func jackettSettings() -> ServiceHealthSettingsSnapshot {
        .init(
            jackettEnabled: true,
            jackettBaseURL: "http://192.168.1.2:9117",
            jackettAPIKey: jackettSecret,
        )
    }

    private func prowlarrDisplayDate(_ iso: String) -> String? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: iso) ?? plain.date(from: iso) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func prowlarrTransport(statusBody: String, indexers: String, statuses: String) -> ScriptHTTP {
        let transport = ScriptHTTP()
        transport.stubs["/api/v1/system/status"] = .init(body: Data(statusBody.utf8))
        transport.stubs["/api/v1/indexer"] = .init(body: Data(indexers.utf8))
        transport.stubs["/api/v1/indexerstatus"] = .init(body: Data(statuses.utf8))
        return transport
    }

    private func jackettTransport(body: String) -> ScriptHTTP {
        let transport = ScriptHTTP()
        transport.stubs[JackettHealthClient.indexerListPath] = .init(body: Data(body.utf8))
        return transport
    }

    private func jackettIndexersXML(
        rows: [(id: String, configured: Bool, title: String)] = [
            ("nzbgeek", true, "NZBGeek"),
            ("audiobookbay", true, "AudiobookBay"),
        ]
    ) -> String {
        let body = rows.map { row in
            """
              <indexer id="\(row.id)" configured="\(row.configured ? "true" : "false")">
                <title>\(row.title)</title>
                <description>\(row.title) indexer</description>
                <link>https://example.test/</link>
                <language>en-US</language>
                <type>public</type>
                <caps>
                  <server title="Jackett"/>
                  <searching>
                    <search available="yes" supportedParams="q"/>
                  </searching>
                  <categories>
                    <category id="7000" name="Books"/>
                  </categories>
                </caps>
              </indexer>
            """
        }.joined(separator: "\n")
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <indexers>
            \(body)
            </indexers>
            """
    }

    private func dashboardCheckers(
        prowlarr: ScriptHTTP,
        jackett: ScriptHTTP,
    ) -> [any ServiceHealthChecking] {
        [
            FixedHealthChecker(.lazyLibrarian, status: .healthy, summary: "Connected"),
            FixedHealthChecker(.shelfarr, status: .healthy, summary: "Connected"),
            FixedHealthChecker(.librivox, status: .healthy, summary: "Public catalog reachable"),
            FixedHealthChecker(.storyteller, status: .healthy, summary: "Connected"),
            ProwlarrHealthChecker(transport: prowlarr),
            JackettHealthChecker(transport: jackett),
            FixedHealthChecker(.deluge, status: .disabled, summary: "Not configured"),
            FixedHealthChecker(.bookSearchLAN, status: .localOnly, summary: "Not configured"),
        ]
    }

    private func isolatedCache() -> ServiceHealthCache {
        let defaults = UserDefaults(suiteName: "indexer-health-\(UUID().uuidString)")!
        return ServiceHealthCache(defaults: defaults)
    }

    private func resultText(_ result: ServiceHealthResult) -> String {
        let meta = result.metadata.values.joined()
        let indexers = result.indexers.map { "\($0.name) \($0.detail ?? "")" }.joined()
        let parts = [
            result.summary,
            result.detail ?? "",
            result.lastError ?? "",
            result.technicalDetail ?? "",
            result.sanitizedHost ?? "",
            result.suggestedAction ?? "",
        ]
        return parts.joined(separator: "\n") + meta + indexers
    }

    private func assertCacheOmits(_ result: ServiceHealthResult, secret: String) throws {
        let name = "indexer-cache-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let cache = ServiceHealthCache(defaults: defaults)
        cache.save([result])
        let loaded = cache.load()
        #expect(loaded.count == 1)
        let data = try #require(defaults.data(forKey: "punkRally.serviceHealth.results.v1"))
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(!text.contains(secret))
        #expect(!text.localizedCaseInsensitiveContains("X-Api-Key"))
    }
}

private struct FixedHealthChecker: ServiceHealthChecking {
    var serviceID: ServiceHealthID
    var status: ServiceHealthStatus
    var summary: String

    init(_ serviceID: ServiceHealthID, status: ServiceHealthStatus, summary: String) {
        self.serviceID = serviceID
        self.status = status
        self.summary = summary
    }

    func check(settings _: ServiceHealthSettingsSnapshot) async -> ServiceHealthResult {
        ServiceHealthResult(serviceID: serviceID, status: status, summary: summary)
    }
}

final class ScriptHTTP: DiagnosticHTTPTransport, @unchecked Sendable {
    struct Stub {
        var status: Int = 200
        var body: Data = Data()
        var error: Error?
    }

    var stubs: [String: Stub] = [:]
    private(set) var seen: [URLRequest] = []
    private let lock = NSLock()

    func send(_ request: URLRequest) async throws -> DiagnosticHTTPResponse {
        lock.lock()
        seen.append(request)
        lock.unlock()
        let path = request.url?.path ?? ""
        guard let stub = stubs.first(where: { path.hasSuffix($0.key) })?.value else {
            throw URLError(.cannotConnectToHost)
        }
        if let error = stub.error { throw error }
        return DiagnosticHTTPResponse(status: stub.status, body: stub.body)
    }
}
