import Foundation
import Testing

@testable import SilveranKit

/// Characterization of Storyteller auth reachability and progress wire shape.
/// Uses the same URLSession + URLProtocol inject pattern as StorytellerBookMergeTests.
///
/// Noted quirk (do not "fix" in R1): `sendProgressToServer` hardcodes
/// `"Bearer \(token)"` while `createAuthenticatedPositionUploadRequest` uses
/// `authorizationHeaderValue(for:)` (Bearer-normalized).
@Suite("Storyteller auth + progress characterization", .serialized)
struct StorytellerAuthProgressCharacterizationTests {
    private let bookUUID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    @Test func canReachAfterSuccessfulToken() async {
        AuthProgressStubURLProtocol.reset(tokenStatus: 200)
        let actor = makeActor()
        let configured = await actor.configureCredentials(
            baseURL: "https://storyteller.test",
            lanURL: "",
            username: "reader",
            password: "secret",
        )
        #expect(configured)
        #expect(await actor.canReachStorytellerForStatsSync())
        #expect(
            AuthProgressStubURLProtocol.requests.contains {
                $0.url?.path.hasSuffix("/token") == true
            }
        )
    }

    @Test func canReachFalseOnUnauthorizedToken() async {
        AuthProgressStubURLProtocol.reset(tokenStatus: 401)
        let actor = makeActor()
        let configured = await actor.configureCredentials(
            baseURL: "https://storyteller.test",
            lanURL: "",
            username: "reader",
            password: "wrong",
        )
        #expect(configured)
        #expect(!(await actor.canReachStorytellerForStatsSync()))
    }

    @Test func positionUploadRequestUsesAPIPathAuthAndLocatorBody() async throws {
        AuthProgressStubURLProtocol.reset(tokenStatus: 200)
        let actor = makeActor()
        #expect(
            await actor.configureCredentials(
                baseURL: "https://storyteller.test",
                lanURL: "",
                username: "reader",
                password: "secret",
            )
        )

        let locator = sampleLocator(progress: 0.42)
        let upload = try #require(
            await actor.createAuthenticatedPositionUploadRequest(
                bookId: bookUUID,
                locator: locator,
                timestamp: 1_700_000_000_123,
            )
        )

        #expect(upload.request.httpMethod == "POST")
        let url = try #require(upload.request.url)
        #expect(url.absoluteString.hasPrefix("https://storyteller.test/api/v2/"))
        #expect(url.path.contains(bookUUID))
        #expect(url.path.contains("positions") || url.absoluteString.contains("positions"))
        #expect(upload.request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        #expect(upload.request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let json = try #require(
            JSONSerialization.jsonObject(with: upload.body) as? [String: Any]
        )
        #expect(jsonInt64(json["timestamp"]) == 1_700_000_000_123)
        let locatorDict = try #require(json["locator"] as? [String: Any])
        #expect(locatorDict["href"] as? String == "/chapters/1")
        #expect(locatorDict["type"] as? String == "application/xhtml+xml")
        let locations = try #require(locatorDict["locations"] as? [String: Any])
        #expect(jsonDouble(locations["totalProgression"]) == 0.42)
    }

    @Test func sendProgressToServerPostsBearerAndMaps204() async throws {
        AuthProgressStubURLProtocol.reset(tokenStatus: 200, positionStatus: 204)
        let actor = makeActor()
        #expect(
            await actor.configureCredentials(
                baseURL: "https://storyteller.test",
                lanURL: "",
                username: "reader",
                password: "secret",
            )
        )
        // Prime token the same way progress sync does (ensureAuthentication).
        #expect(await actor.canReachStorytellerForStatsSync())

        let result = await actor.sendProgressToServer(
            bookId: bookUUID,
            locator: sampleLocator(progress: 0.55),
            timestamp: 99,
        )
        guard case .success = result else {
            Issue.record("expected .success, got \(result)")
            return
        }

        let position = try #require(
            AuthProgressStubURLProtocol.requests.last {
                $0.url?.path.hasSuffix("/books/\(bookUUID)/positions") == true
                    && $0.httpMethod == "POST"
            }
        )
        // Current behavior: hardcoded Bearer (not authorizationHeaderValue).
        #expect(position.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
        let body = try #require(position.httpBody ?? AuthProgressStubURLProtocol.lastBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(jsonInt64(json["timestamp"]) == 99)
        #expect(json["locator"] != nil)
    }

    @Test func sendProgressToServerMaps404ToFailure() async {
        AuthProgressStubURLProtocol.reset(tokenStatus: 200, positionStatus: 404)
        let actor = makeActor()
        #expect(
            await actor.configureCredentials(
                baseURL: "https://storyteller.test",
                lanURL: "",
                username: "reader",
                password: "secret",
            )
        )
        #expect(await actor.canReachStorytellerForStatsSync())

        let result = await actor.sendProgressToServer(
            bookId: bookUUID,
            locator: sampleLocator(progress: 0.1),
            timestamp: 1,
        )
        guard case .failure = result else {
            Issue.record("expected .failure, got \(result)")
            return
        }
    }

    private func makeActor() -> StorytellerActor {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthProgressStubURLProtocol.self]
        return StorytellerActor(
            sourceRecord: BookSourceRecord(
                id: "server",
                name: "Storyteller",
                kind: .storyteller,
                capabilities: .storyteller,
            ),
            session: URLSession(configuration: configuration),
        )
    }

    private func sampleLocator(progress: Double) -> BookLocator {
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

private final class AuthProgressStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var lastBody: Data?
    static var tokenStatus = 200
    static var positionStatus = 204

    static func reset(tokenStatus: Int = 200, positionStatus: Int = 204) {
        lock.lock()
        requests = []
        lastBody = nil
        Self.tokenStatus = tokenStatus
        Self.positionStatus = positionStatus
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        if let body = request.httpBody ?? bodyFromStream(request.httpBodyStream) {
            Self.lastBody = body
        }
        let path = request.url?.path ?? ""
        let tokenStatus = Self.tokenStatus
        let positionStatus = Self.positionStatus
        Self.lock.unlock()

        if path.hasSuffix("/token") {
            if tokenStatus == 200 {
                respond(
                    status: 200,
                    data: Data(
                        #"{"access_token":"test-token","token_type":"Bearer","expires_in":3600}"#
                            .utf8
                    ),
                )
            } else {
                respond(status: tokenStatus, data: Data(#"{"error":"unauthorized"}"#.utf8))
            }
            return
        }

        if path.contains("/positions") {
            respond(status: positionStatus, data: Data())
            return
        }

        client?.urlProtocol(self, didFailWithError: URLError(.badURL))
    }

    override func stopLoading() {}

    private func respond(status: Int, data: Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"],
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func jsonInt64(_ value: Any?) -> Int64? {
    switch value {
        case let number as Int64: number
        case let number as Int: Int64(number)
        case let number as NSNumber: number.int64Value
        default: nil
    }
}

private func jsonDouble(_ value: Any?) -> Double? {
    switch value {
        case let number as Double: number
        case let number as Int: Double(number)
        case let number as NSNumber: number.doubleValue
        default: nil
    }
}

private func bodyFromStream(_ stream: InputStream?) -> Data? {
    guard let stream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufferSize)
        if read > 0 {
            data.append(buffer, count: read)
        } else {
            break
        }
    }
    return data.isEmpty ? nil : data
}
