import Foundation
import Testing

@testable import SilveranKit

@Suite(.serialized)
struct ShelfarrClientTests {
    private let token = "shf_test_token"

    @Test func baseURLWithoutTrailingSlash() {
        let url = ShelfarrClient.endpointURL(
            base: ShelfarrClient.normalizedBaseURL(from: "https://shelfarr.example.com")!,
            path: "api/v1/requests",
            query: [URLQueryItem(name: "limit", value: "1")],
        )
        #expect(url?.absoluteString == "https://shelfarr.example.com/api/v1/requests?limit=1")
    }

    @Test func baseURLWithTrailingSlash() {
        let url = ShelfarrClient.endpointURL(
            base: ShelfarrClient.normalizedBaseURL(from: "https://shelfarr.example.com/")!,
            path: "api/v1/requests",
            query: [URLQueryItem(name: "limit", value: "1")],
        )
        #expect(url?.absoluteString == "https://shelfarr.example.com/api/v1/requests?limit=1")
        #expect(url?.absoluteString.contains("//api/") == false)
    }

    @Test func lanBaseURLKeepsPort() {
        let bare = ShelfarrClient.endpointURL(
            base: ShelfarrClient.normalizedBaseURL(from: "http://192.168.1.2:5057")!,
            path: "api/v1/requests",
        )
        let slashed = ShelfarrClient.endpointURL(
            base: ShelfarrClient.normalizedBaseURL(from: "http://192.168.1.2:5057/")!,
            path: "api/v1/requests",
        )
        #expect(bare?.absoluteString == "http://192.168.1.2:5057/api/v1/requests")
        #expect(slashed?.absoluteString == "http://192.168.1.2:5057/api/v1/requests")
    }

    @Test func doesNotRequireManualAPIV1Suffix() {
        let url = ShelfarrClient.normalizedBaseURL(from: "https://shelfarr.example.com/api/v1/")
        #expect(url?.absoluteString == "https://shelfarr.example.com")
    }

    @Test func openLibraryWorkIDNormalization() {
        #expect(ShelfarrWorkID.openLibrary(from: "OL893415W") == "openlibrary:OL893415W")
        #expect(ShelfarrWorkID.openLibrary(from: "/works/OL893415W") == "openlibrary:OL893415W")
        #expect(ShelfarrWorkID.openLibrary(from: "ol:/works/OL893415W") == "openlibrary:OL893415W")
        #expect(ShelfarrWorkID.openLibrary(from: "openlibrary:OL893415W") == "openlibrary:OL893415W")
        #expect(ShelfarrWorkID.openLibrary(from: "openlibrary:/works/OL893415W") == "openlibrary:OL893415W")
        #expect(ShelfarrWorkID.openLibrary(from: "openlibrary:openlibrary:OL893415W") == "openlibrary:OL893415W")
    }

    @Test func malformedWorkIDIsRejected() {
        #expect(ShelfarrWorkID.openLibrary(from: "") == nil)
        #expect(ShelfarrWorkID.openLibrary(from: "title:dune") == nil)
        #expect(ShelfarrWorkID.openLibrary(from: "hardcover:123") == nil)
        #expect(ShelfarrWorkID.openLibrary(from: "OL123M") == nil)
        let body = ShelfarrClient.createRequestBody(idea: idea(id: "title:dune"), mediums: [.ebook])
        #expect(body == nil)
    }

    @Test func ebookRequestBody() throws {
        let data = try #require(
            ShelfarrClient.createRequestBody(idea: idea(id: "ol:/works/OL893415W"), mediums: [.ebook])
        )
        let json = try json(data)
        #expect(json["work_id"] as? String == "openlibrary:OL893415W")
        #expect(json["book_type"] as? String == "ebook")
        #expect(json["book_types"] as? [String] == nil)
        #expect(json["title"] as? String == "Dune")
        #expect(json["author"] as? String == "Frank Herbert")
        #expect(json["ol_work_key"] as? String == nil)
        #expect(json["isbn"] as? String == nil)
    }

    @Test func audiobookRequestBody() throws {
        let data = try #require(
            ShelfarrClient.createRequestBody(idea: idea(id: "OL893415W"), mediums: [.audiobook])
        )
        let json = try json(data)
        #expect(json["work_id"] as? String == "openlibrary:OL893415W")
        #expect(json["book_type"] as? String == "audiobook")
        #expect(json["book_types"] as? [String] == nil)
    }

    @Test func bothBookTypesUseArray() throws {
        let data = try #require(
            ShelfarrClient.createRequestBody(
                idea: idea(id: "/works/OL893415W"),
                mediums: [.ebook, .audiobook],
            )
        )
        let json = try json(data)
        #expect(json["work_id"] as? String == "openlibrary:OL893415W")
        #expect(json["book_type"] as? String == nil)
        #expect((json["book_types"] as? [Any])?.compactMap { $0 as? String } == ["ebook", "audiobook"])
    }

    @Test func requestBodyKeepsTitleAuthorYearCoverWithoutISBN() throws {
        let data = try #require(
            ShelfarrClient.createRequestBody(
                idea: idea(
                    id: "OL893415W",
                    cover: URL(string: "https://covers.openlibrary.org/b/id/1-L.jpg"),
                    year: 1965,
                ),
                mediums: [.ebook],
            )
        )
        let json = try json(data)
        #expect(json["title"] as? String == "Dune")
        #expect(json["author"] as? String == "Frank Herbert")
        #expect(json["year"] as? Int == 1965)
        #expect(json["cover_url"] as? String == "https://covers.openlibrary.org/b/id/1-L.jpg")
        #expect(json["external_source"] as? String == "inkamp")
        #expect(json["isbn"] as? String == nil)
        #expect(json["ol_work_key"] as? String == nil)
    }

    @Test func bookRequestRoutingStillPrefersConfiguredProvider() {
        #expect(
            BookRequestRouting.choose(
                preference: .shelfarr,
                lazyLibrarianReady: true,
                shelfarrReady: true,
            ) == .shelfarr
        )
        #expect(
            BookRequestRouting.choose(
                preference: .lazyLibrarian,
                lazyLibrarianReady: false,
                shelfarrReady: true,
            ) == nil
        )
        #expect(
            BookRequestRouting.choose(
                preference: .automatic,
                lazyLibrarianReady: false,
                shelfarrReady: true,
            ) == .shelfarr
        )
    }

    @Test func httpsToHTTPRedirectIsDetected() {
        let original = URL(string: "https://shelfarr.example.com/api/v1/requests?limit=1")!
        let downgraded = URL(string: "http://shelfarr.example.com/api/v1/requests?limit=1")!
        let stayedSecure = URL(string: "https://shelfarr.example.com/api/v1/requests?limit=1")!
        #expect(ShelfarrClient.isInsecureDowngrade(from: original, to: downgraded))
        #expect(!ShelfarrClient.isInsecureDowngrade(from: original, to: stayedSecure))
        let response = HTTPURLResponse(
            url: original,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": downgraded.absoluteString],
        )!
        #expect(ShelfarrClient.isInsecureDowngrade(original: original, response: response))
    }

    @Test func redactsTokensInServerMessages() {
        let message = ShelfarrClient.serverMessage(
            from: Data(#"{"errors":["bad token shf_supersecretvalue"]}"#.utf8)
        )
        #expect(message == "bad token shf_[redacted]")
        #expect(message?.contains("supersecretvalue") == false)
        let bearer = ShelfarrClient.redactSecrets("Authorization Bearer abc.def-ghi failed")
        #expect(bearer.contains("Bearer [redacted]"))
        #expect(!bearer.contains("abc.def-ghi"))
    }

    @Test func connectionTestUsesRequestsLimitAndBearerToken() async throws {
        let client = try stubbedClient(status: 200, body: #"{"requests":[]}"#)
        let result = await client.testConnection()
        #expect(result == .success(()))
        let request = try #require(ShelfarrStubURLProtocol.requests.first)
        #expect(request.url?.absoluteString == "https://shelfarr.example.com/api/v1/requests?limit=1")
        #expect(request.url?.absoluteString.contains("/api/v1/status") == false)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        #expect(request.url?.absoluteString.contains(token) == false)
    }

    @Test func connectionTestTrailingSlashStillHitsRequests() async throws {
        let client = try stubbedClient(
            baseURL: "http://192.168.1.2:5057/",
            status: 200,
            body: #"{"requests":[]}"#,
        )
        let result = await client.testConnection()
        #expect(result == .success(()))
        let request = try #require(ShelfarrStubURLProtocol.requests.first)
        #expect(request.url?.absoluteString == "http://192.168.1.2:5057/api/v1/requests?limit=1")
    }

    @Test func connection401() async throws {
        let client = try stubbedClient(status: 401, body: "")
        let result = await client.testConnection()
        #expect(result == .failure(.authenticationFailed))
        #expect(
            failureMessage(result)
                == "Authentication failed. Check your Shelfarr API token."
        )
    }

    @Test func connection403() async throws {
        let client = try stubbedClient(
            status: 403,
            body: #"{"errors":["Missing API scope: requests:read"]}"#,
        )
        let result = await client.testConnection()
        #expect(result == .failure(.permissionDenied(.readRequests)))
        #expect(
            failureMessage(result)
                == "Connected to Shelfarr, but this token does not have permission to read requests."
        )
    }

    @Test func connection404() async throws {
        let client = try stubbedClient(status: 404, body: #"{"errors":["not found"]}"#)
        let result = await client.testConnection()
        #expect(result == .failure(.endpointNotFound))
        #expect(
            failureMessage(result)
                == "Shelfarr responded, but the API endpoint was not found. Check the server URL and Shelfarr version."
        )
    }

    @Test func cloudflareChallengeIsNotATokenPermissionError() async throws {
        let client = try stubbedClient(
            status: 403,
            headers: [
                "Content-Type": "text/html",
                "cf-mitigated": "challenge",
            ],
            body: "<html>challenges.cloudflare.com</html>",
        )
        let result = await client.testConnection()
        guard case .failure(.transportError(let message)) = result else {
            Issue.record("expected a Cloudflare diagnostic, got \(result)")
            return
        }
        #expect(message.localizedCaseInsensitiveContains("Cloudflare"))
        #expect(!message.localizedCaseInsensitiveContains("permission"))
    }

    @Test func httpsToHTTPRedirectResponse() async throws {
        let client = try stubbedClient(
            status: 302,
            headers: ["Location": "http://shelfarr.example.com/api/v1/requests?limit=1"],
            body: "",
        )
        let result = await client.testConnection()
        #expect(result == .failure(.insecureRedirect))
        #expect(
            failureMessage(result)
                == "Shelfarr redirected this HTTPS request to an insecure HTTP URL. Check the Shelfarr/Cloudflare proxy configuration."
        )
    }

    @Test func postedRequestContainsWorkIDAndBearerToken() async throws {
        let client = try stubbedClient(status: 201, body: #"{"requests":[{"id":1}]}"#)
        let result = await client.createRequest(for: idea(id: "ol:/works/OL893415W"), mediums: [.ebook])
        #expect(result == .success(()))
        let request = try #require(ShelfarrStubURLProtocol.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/v1/requests")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        let posted = try json(try #require(httpBody(request)))
        #expect(posted["work_id"] as? String == "openlibrary:OL893415W")
        #expect(posted["book_type"] as? String == "ebook")
    }

    @Test func validationFailureSurfacesServerMessage() async throws {
        let client = try stubbedClient(
            status: 422,
            body: #"{"errors":["Missing required information"]}"#,
        )
        let result = await client.createRequest(for: idea(id: "OL1W"), mediums: [.audiobook])
        #expect(result == .failure(.serverError(statusCode: 422, message: "Missing required information")))
        #expect(failureMessage(result) == "Shelfarr rejected the request: Missing required information")
    }

    @Test func missingWorkIDDoesNotSendARequest() async throws {
        let client = try stubbedClient(status: 500, body: "")
        let result = await client.createRequest(for: idea(id: "title:dune"), mediums: [.ebook])
        #expect(result == .failure(.invalidWorkID))
        #expect(ShelfarrStubURLProtocol.requests.isEmpty)
    }

    private func idea(
        id: String,
        cover: URL? = nil,
        year: Int? = nil,
    ) -> ReadingIdea {
        ReadingIdea(
            id: id,
            title: "Dune",
            author: "Frank Herbert",
            coverURL: cover,
            blurb: nil,
            reason: "test",
            score: 1,
            isbn: "9780441172719",
            year: year,
        )
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func failureMessage(_ result: Result<Void, ShelfarrError>) -> String? {
        if case .failure(let error) = result { return error.userMessage }
        return nil
    }

    private func httpBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody, !body.isEmpty { return body }
        guard let stream = request.httpBodyStream else { return request.httpBody }
        stream.open()
        defer { stream.close() }
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        var data = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private func stubbedClient(
        baseURL: String = "https://shelfarr.example.com",
        status: Int,
        headers: [String: String] = ["Content-Type": "application/json"],
        body: String,
    ) throws -> ShelfarrClient {
        ShelfarrStubURLProtocol.reset(status: status, headers: headers, body: Data(body.utf8))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShelfarrStubURLProtocol.self]
        configuration.timeoutIntervalForRequest = 3
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        return ShelfarrClient(baseURL: baseURL, token: token, session: session)
    }
}

final class ShelfarrStubURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var status = 200
    static var headers: [String: String] = [:]
    static var body = Data()

    static func reset(status: Int, headers: [String: String], body: Data) {
        lock.lock()
        requests = []
        self.status = status
        self.headers = headers
        self.body = body
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let status = Self.status
        let headers = Self.headers
        let body = Self.body
        Self.lock.unlock()

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
