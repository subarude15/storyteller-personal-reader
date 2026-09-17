import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PlaytorioFetcher

/// Test-only HTTP client that serves fixture bytes. Never touches the network.
struct MockHTTPClient: HTTPClient {
    /// Maps URL path (and optional host) substrings to fixture payloads.
    var responses: [(match: String, data: Data, status: Int)]

    func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let haystack = url.absoluteString
        guard let hit = responses.first(where: { haystack.contains($0.match) }) else {
            throw URLError(.fileDoesNotExist)
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: hit.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html"]
        )!
        return (hit.data, response)
    }

    static func fixturesDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    static func fixtureData(_ name: String) throws -> Data {
        let url = fixturesDirectory().appendingPathComponent(name)
        return try Data(contentsOf: url)
    }
}
