import Foundation
import Testing

@testable import SilveranKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Characterization of lowest-level Storyteller HTTP execution (R10).
///
/// Transport must return HTTP responses for **any** status code (callers own
/// Storyteller semantics). It must not rewrite headers/body, retry, or auth.
@Suite("Storyteller HTTP transport", .serialized)
struct StorytellerHTTPTransportTests {

    // MARK: - Status codes returned as HTTP responses (not thrown)

    @Test func returnsHTTPResponseFor200() async throws {
        TransportStubURLProtocol.reset(mode: .http(status: 200, body: #"{"ok":true}"#, headers: [
            "Content-Type": "application/json",
            "X-Test": "keep-me",
        ]))
        let transport = makeTransport()
        var request = URLRequest(url: URL(string: "https://storyteller.test/api/v2/books")!)
        request.httpMethod = "GET"
        request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")

        let response = try await transport.send(request)

        #expect(response.statusCode == 200)
        #expect(String(data: response.data, encoding: .utf8) == #"{"ok":true}"#)
        #expect(response.response.value(forHTTPHeaderField: "X-Test") == "keep-me")
        #expect(response.response.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func returnsHTTPResponseFor204WithEmptyBody() async throws {
        TransportStubURLProtocol.reset(mode: .http(status: 204, body: "", headers: [:]))
        let transport = makeTransport()
        var request = URLRequest(url: URL(string: "https://storyteller.test/api/v2/books/x/positions")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"timestamp":1}"#.utf8)

        let response = try await transport.send(request)

        #expect(response.statusCode == 204)
        #expect(response.data.isEmpty)
    }

    @Test func returnsHTTPResponseFor404() async throws {
        TransportStubURLProtocol.reset(mode: .http(status: 404, body: "missing", headers: [:]))
        let transport = makeTransport()
        let request = URLRequest(url: URL(string: "https://storyteller.test/api/v2/missing")!)

        let response = try await transport.send(request)

        #expect(response.statusCode == 404)
        #expect(String(data: response.data, encoding: .utf8) == "missing")
    }

    @Test func returnsHTTPResponseFor500() async throws {
        TransportStubURLProtocol.reset(mode: .http(status: 500, body: "boom", headers: [:]))
        let transport = makeTransport()
        let request = URLRequest(url: URL(string: "https://storyteller.test/api/v2/books")!)

        let response = try await transport.send(request)

        #expect(response.statusCode == 500)
        #expect(String(data: response.data, encoding: .utf8) == "boom")
    }

    // MARK: - Request passthrough (headers / body untouched)

    @Test func forwardsMethodHeadersAndBodyUnchanged() async throws {
        TransportStubURLProtocol.reset(mode: .http(status: 200, body: "", headers: [:]))
        let transport = makeTransport()
        var request = URLRequest(url: URL(string: "https://storyteller.test/api/v2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer do-not-rewrite", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("grant_type=password".utf8)
        request.timeoutInterval = 15

        _ = try await transport.send(request)

        let sent = try #require(TransportStubURLProtocol.requests.last)
        #expect(sent.httpMethod == "POST")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer do-not-rewrite")
        #expect(sent.httpBody == Data("grant_type=password".utf8) || TransportStubURLProtocol.lastBody == Data("grant_type=password".utf8))
        #expect(sent.timeoutInterval == 15)
        #expect(sent.url?.absoluteString == "https://storyteller.test/api/v2/token")
    }

    // MARK: - Transport failures

    @Test func networkErrorPropagates() async {
        TransportStubURLProtocol.reset(mode: .fail(URLError(.timedOut)))
        let transport = makeTransport()
        let request = URLRequest(url: URL(string: "https://storyteller.test/api/v2/books")!)

        do {
            _ = try await transport.send(request)
            Issue.record("expected timedOut to throw")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        } catch {
            Issue.record("expected URLError, got \(error)")
        }
    }

    @Test func nonHTTPResponseThrowsTransportError() async {
        TransportStubURLProtocol.reset(mode: .nonHTTP)
        let transport = makeTransport()
        let request = URLRequest(url: URL(string: "https://storyteller.test/api/v2/books")!)

        do {
            _ = try await transport.send(request)
            Issue.record("expected non-HTTP response to throw")
        } catch let error as StorytellerHTTPTransport.TransportError {
            #expect(error == .nonHTTPResponse)
        } catch {
            Issue.record("expected TransportError.nonHTTPResponse, got \(error)")
        }
    }

    // MARK: - Helpers

    private func makeTransport() -> StorytellerHTTPTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransportStubURLProtocol.self]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        return StorytellerHTTPTransport(session: session)
    }
}

// MARK: - URLProtocol stub

private final class TransportStubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode: Sendable {
        case http(status: Int, body: String, headers: [String: String])
        case fail(URLError)
        case nonHTTP
    }

    private static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var lastBody: Data?
    static var mode: Mode = .http(status: 200, body: "", headers: [:])

    static func reset(mode: Mode) {
        lock.lock()
        requests = []
        lastBody = nil
        Self.mode = mode
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        if let body = request.httpBody {
            Self.lastBody = body
        } else if let stream = request.httpBodyStream {
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
            Self.lastBody = data
        }
        let mode = Self.mode
        Self.lock.unlock()

        switch mode {
            case .http(let status, let body, let headers):
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: headers,
                )!
                let data = Data(body.utf8)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if !data.isEmpty {
                    client?.urlProtocol(self, didLoad: data)
                }
                client?.urlProtocolDidFinishLoading(self)
            case .fail(let error):
                client?.urlProtocol(self, didFailWithError: error)
            case .nonHTTP:
                let response = URLResponse(
                    url: request.url!,
                    mimeType: nil,
                    expectedContentLength: 0,
                    textEncodingName: nil,
                )
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
