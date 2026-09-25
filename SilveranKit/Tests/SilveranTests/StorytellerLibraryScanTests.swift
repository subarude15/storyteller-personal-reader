import Foundation
import Testing

@testable import SilveranKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("Storyteller library scan", .serialized)
struct StorytellerLibraryScanTests {

    // MARK: - Pure helpers

    @Test func parseStateReadsRunningSourceAndProgress() throws {
        let data = Data(
            """
            {"running":true,"source":"manual","startedAt":1700000000000,\
            "progress":{"processed":3,"total":10},"pendingSources":["watcher"]}
            """.utf8
        )
        let state = try StorytellerLibraryScan.parseState(from: data)
        #expect(state.running == true)
        #expect(state.source == "manual")
        #expect(state.startedAt == 1_700_000_000_000)
        #expect(state.progress?.processed == 3)
        #expect(state.progress?.total == 10)
        #expect(state.pendingSources == ["watcher"])
    }

    @Test func parseStateRejectsMalformedBody() {
        #expect(throws: StorytellerLibraryScan.DecodeError.emptyBody) {
            try StorytellerLibraryScan.parseState(from: Data())
        }
        #expect(throws: StorytellerLibraryScan.DecodeError.notObject) {
            try StorytellerLibraryScan.parseState(from: Data("[]".utf8))
        }
        #expect(throws: StorytellerLibraryScan.DecodeError.missingRunning) {
            try StorytellerLibraryScan.parseState(from: Data(#"{"source":"manual"}"#.utf8))
        }
    }

    @Test func completionDistinguishesStartedVersusCompleted() {
        let idle = StorytellerLibraryScan.State(running: false)
        let running = StorytellerLibraryScan.State(running: true, source: "manual")

        #expect(
            StorytellerLibraryScan.completion(afterStates: [running, idle], exhaustedBudget: false)
                == .confirmedComplete
        )
        #expect(
            StorytellerLibraryScan.completion(afterStates: [idle, idle], exhaustedBudget: true)
                == .startedUnconfirmed
        )
        #expect(
            StorytellerLibraryScan.completion(afterStates: [running, running], exhaustedBudget: true)
                == .stillRunning
        )
    }

    // MARK: - Networking

    @Test func successfulScanPostsForceAndReusesBearerAuth() async throws {
        ScanStubURLProtocol.reset()
        ScanStubURLProtocol.postStatus = 204
        ScanStubURLProtocol.stateSequence = [
            #"{"running":true,"source":"manual","startedAt":1}"#,
            #"{"running":false,"source":null,"startedAt":null}"#,
        ]
        let actor = makeScanActor()
        let configured = await actor.configureCredentials(
            baseURL: "https://storyteller.test",
            lanURL: "",
            username: "reader",
            password: "secret",
        )
        #expect(configured)

        let outcome = await actor.scanLibraryAndAwaitStatus(
            force: true,
            polling: StorytellerLibraryScan.Polling(intervalNanoseconds: 0, maxAttempts: 4),
        )
        #expect(outcome == .success(.confirmedComplete))

        let post = try #require(
            ScanStubURLProtocol.requests.last {
                $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/books/scan") == true
            }
        )
        #expect(post.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(post.url?.query?.contains("force=true") == true)

        let gets = ScanStubURLProtocol.requests.filter {
            $0.httpMethod == "GET" && $0.url?.path.hasSuffix("/books/scan") == true
        }
        #expect(gets.count >= 2)
        #expect(gets.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" })
        #expect(ScanStubURLProtocol.requests.contains { $0.url?.path.hasSuffix("/token") == true })
    }

    @Test func non2xxScanMapsToClearFailure() async {
        ScanStubURLProtocol.reset()
        ScanStubURLProtocol.postStatus = 403
        let actor = makeScanActor()
        _ = await actor.configureCredentials(
            baseURL: "https://storyteller.test",
            lanURL: "",
            username: "reader",
            password: "secret",
        )

        let result = await actor.scanLibrary(force: true)
        guard case .failure(.permissionDenied) = result else {
            Issue.record("expected permissionDenied, got \(result)")
            return
        }
    }

    @Test func unsupportedScanEndpointMapsToUnsupported() async {
        ScanStubURLProtocol.reset()
        ScanStubURLProtocol.postStatus = 404
        let actor = makeScanActor()
        _ = await actor.configureCredentials(
            baseURL: "https://storyteller.test",
            lanURL: "",
            username: "reader",
            password: "secret",
        )

        let result = await actor.scanLibrary(force: true)
        guard case .failure(.unsupported) = result else {
            Issue.record("expected unsupported, got \(result)")
            return
        }
    }

    @Test func malformedScanStateAfterAcceptYieldsStartedUnconfirmed() async {
        ScanStubURLProtocol.reset()
        ScanStubURLProtocol.postStatus = 204
        ScanStubURLProtocol.stateSequence = [#"{"not":"a scan state"}"#]
        let actor = makeScanActor()
        _ = await actor.configureCredentials(
            baseURL: "https://storyteller.test",
            lanURL: "",
            username: "reader",
            password: "secret",
        )

        let outcome = await actor.scanLibraryAndAwaitStatus(
            force: true,
            polling: StorytellerLibraryScan.Polling(intervalNanoseconds: 0, maxAttempts: 2),
        )
        #expect(outcome == .success(.startedUnconfirmed))
    }

    @Test func failureMessagesAreSpecificNotGeneric() {
        #expect(
            StorytellerLibraryScan.Failure.authenticationFailed.userMessage
                .contains("sign-in")
        )
        #expect(
            !StorytellerLibraryScan.Failure.rejected(statusCode: 500).userMessage
                .localizedCaseInsensitiveContains("request failed")
        )
        #expect(
            StorytellerLibraryScan.Failure.permissionDenied.userMessage
                .contains("permission")
        )
    }
}

private func makeScanActor() -> StorytellerActor {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ScanStubURLProtocol.self]
    return StorytellerActor(
        sourceRecord: BookSourceRecord(
            id: "server",
            name: "Test",
            kind: .storyteller,
            capabilities: .storyteller,
        ),
        session: URLSession(configuration: configuration),
    )
}

private final class ScanStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var postStatus = 204
    static var stateSequence: [String] = []
    private static var stateIndex = 0

    static func reset() {
        lock.lock()
        requests = []
        postStatus = 204
        stateSequence = []
        stateIndex = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        let postStatus = Self.postStatus
        let stateBody: String
        if Self.stateIndex < Self.stateSequence.count {
            stateBody = Self.stateSequence[Self.stateIndex]
            Self.stateIndex += 1
        } else if let last = Self.stateSequence.last {
            stateBody = last
        } else {
            stateBody = #"{"running":false,"source":null,"startedAt":null}"#
        }
        Self.lock.unlock()

        let status: Int
        let data: Data
        if path.hasSuffix("/token") {
            status = 200
            data = Data(
                #"{"access_token":"test-token","token_type":"Bearer","expires_in":3600}"#.utf8
            )
        } else if path.hasSuffix("/books/scan"), method == "POST" {
            status = postStatus
            data = Data()
        } else if path.hasSuffix("/books/scan"), method == "GET" {
            status = 200
            data = Data(stateBody.utf8)
        } else if path.hasSuffix("/books") {
            // refresh path may hit books list; keep tests focused on scan.
            status = 200
            data = Data("[]".utf8)
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"],
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
