import Foundation
import Testing
@testable import PlaytorioFetcher

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct MockTorBoxHTTPClient: TorBoxHTTPClient {
    var getHandler: @Sendable (URL, [String: String]) async throws -> (Data, HTTPURLResponse)
    var postHandler: @Sendable (URL, [String: String], [String: String]) async throws -> (Data, HTTPURLResponse)

    func get(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        try await getHandler(url, headers)
    }

    func postForm(
        _ url: URL,
        headers: [String: String],
        fields: [String: String]
    ) async throws -> (Data, HTTPURLResponse) {
        try await postHandler(url, headers, fields)
    }

    static func response(url: URL, status: Int, json: String) -> (Data, HTTPURLResponse) {
        let data = Data(json.utf8)
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}

@Test func testTorBoxMagnetValidation() {
    #expect(TorBoxClient.isValidMagnet("magnet:?xt=urn:btih:ABCDEF0123456789ABCDEF0123456789ABCDEF01"))
    #expect(!TorBoxClient.isValidMagnet("https://example.com/file.torrent"))
    #expect(!TorBoxClient.isValidMagnet("magnet:?dn=only-name"))
}

@Test func testTorBoxPreferredFilePicksEPUB() {
    let files = [
        TorBoxTorrentFile(id: 1, name: "readme.txt", size: 10),
        TorBoxTorrentFile(id: 2, name: "Book Title.epub", size: 1_000_000),
        TorBoxTorrentFile(id: 3, name: "Book Title.pdf", size: 2_000_000),
    ]
    let preferred = TorBoxClient.preferredFile(in: files, prefer: ["epub", "pdf"])
    #expect(preferred?.id == 2)
    #expect(preferred?.name == "Book Title.epub")
}

@Test func testTorBoxAddMagnetAndRequestDownloadURL() async throws {
    let http = MockTorBoxHTTPClient(
        getHandler: { url, _ in
            if url.path.contains("requestdl") {
                return MockTorBoxHTTPClient.response(
                    url: url,
                    status: 200,
                    json: #"{"success":true,"error":null,"detail":"ok","data":"https://cdn.example/file.epub"}"#
                )
            }
            if url.path.contains("mylist") {
                return MockTorBoxHTTPClient.response(
                    url: url,
                    status: 200,
                    json: """
                    {"success":true,"error":null,"detail":"ok","data":{
                      "id": 42,
                      "name": "Sample Book",
                      "hash": "abc",
                      "download_state": "cached",
                      "download_finished": true,
                      "download_present": true,
                      "progress": 1,
                      "files": [{"id":7,"name":"Sample.epub","size":12345,"mimetype":"application/epub+zip"}]
                    }}
                    """
                )
            }
            if url.path.contains("user/me") {
                return MockTorBoxHTTPClient.response(
                    url: url,
                    status: 200,
                    json: #"{"success":true,"error":null,"detail":"ok","data":{"id":1}}"#
                )
            }
            throw URLError(.badURL)
        },
        postHandler: { url, _, fields in
            #expect(fields["magnet"]?.hasPrefix("magnet:") == true)
            return MockTorBoxHTTPClient.response(
                url: url,
                status: 200,
                json: #"{"success":true,"error":null,"detail":"ok","data":{"torrent_id":42,"hash":"abc"}}"#
            )
        }
    )

    let client = TorBoxClient(apiKey: "test-key", http: http)
    try await client.validateAPIKey()
    let id = try await client.addMagnet(
        "magnet:?xt=urn:btih:ABCDEF0123456789ABCDEF0123456789ABCDEF01&dn=Sample"
    )
    #expect(id == 42)
    let info = try await client.getTorrent(id: 42)
    #expect(info.isDownloadReady)
    #expect(info.files.first?.name == "Sample.epub")
    let url = try await client.requestDownloadURL(torrentID: 42, fileID: 7)
    #expect(url.absoluteString == "https://cdn.example/file.epub")
}

@Test func testTorBoxInvalidAPIKey() async {
    let http = MockTorBoxHTTPClient(
        getHandler: { url, _ in
            MockTorBoxHTTPClient.response(
                url: url,
                status: 403,
                json: #"{"success":false,"error":"BAD_TOKEN","detail":"Invalid token","data":null}"#
            )
        },
        postHandler: { _, _, _ in throw URLError(.badURL) }
    )
    let client = TorBoxClient(apiKey: "bad", http: http)
    do {
        try await client.validateAPIKey()
        Issue.record("expected invalid API key")
    } catch let error as TorBoxError {
        #expect(error == .invalidAPIKey)
    } catch {
        Issue.record("unexpected \(error)")
    }
}

@Test func testTorBoxMalformedMagnetRejected() async {
    let http = MockTorBoxHTTPClient(
        getHandler: { _, _ in throw URLError(.badURL) },
        postHandler: { _, _, _ in throw URLError(.badURL) }
    )
    let client = TorBoxClient(apiKey: "key", http: http)
    do {
        _ = try await client.addMagnet("not-a-magnet")
        Issue.record("expected malformed magnet")
    } catch let error as TorBoxError {
        #expect(error == .malformedMagnet)
    } catch {
        Issue.record("unexpected \(error)")
    }
}

@Test func testTorBoxResolverWaitsThenSucceeds() async throws {
    actor CallCounter {
        var mylist = 0
        func bump() -> Int {
            mylist += 1
            return mylist
        }
    }
    let counter = CallCounter()
    let http = MockTorBoxHTTPClient(
        getHandler: { url, _ in
            if url.path.contains("mylist") {
                let n = await counter.bump()
                if n == 1 {
                    return MockTorBoxHTTPClient.response(
                        url: url,
                        status: 200,
                        json: """
                        {"success":true,"error":null,"detail":"ok","data":{
                          "id": 9,
                          "name": "Slow",
                          "hash": "h",
                          "download_state": "downloading",
                          "download_finished": false,
                          "download_present": false,
                          "progress": 0.2,
                          "files": []
                        }}
                        """
                    )
                }
                return MockTorBoxHTTPClient.response(
                    url: url,
                    status: 200,
                    json: """
                    {"success":true,"error":null,"detail":"ok","data":{
                      "id": 9,
                      "name": "Slow",
                      "hash": "h",
                      "download_state": "cached",
                      "download_finished": true,
                      "download_present": true,
                      "progress": 1,
                      "files": [{"id":1,"name":"Slow.epub","size":10,"mimetype":"application/epub+zip"}]
                    }}
                    """
                )
            }
            if url.path.contains("requestdl") {
                return MockTorBoxHTTPClient.response(
                    url: url,
                    status: 200,
                    json: #"{"success":true,"error":null,"detail":"ok","data":"https://cdn.example/slow.epub"}"#
                )
            }
            throw URLError(.badURL)
        },
        postHandler: { url, _, _ in
            MockTorBoxHTTPClient.response(
                url: url,
                status: 200,
                json: #"{"success":true,"error":null,"detail":"ok","data":{"torrent_id":9}}"#
            )
        }
    )

    final class PhaseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [TorBoxMagnetResolver.Phase] = []
        func append(_ phase: TorBoxMagnetResolver.Phase) {
            lock.lock()
            values.append(phase)
            lock.unlock()
        }
        func snapshot() -> [TorBoxMagnetResolver.Phase] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }
    let phases = PhaseBox()
    let resolved = try await TorBoxMagnetResolver.resolve(
        magnet: "magnet:?xt=urn:btih:ABCDEF0123456789ABCDEF0123456789ABCDEF01",
        apiKey: "key",
        http: http,
        onPhase: { phase in phases.append(phase) }
    )
    #expect(resolved.file.name == "Slow.epub")
    #expect(resolved.downloadURL.absoluteString.contains("slow.epub"))
    let seen = phases.snapshot()
    #expect(seen.contains(.waitingForCache))
    #expect(seen.contains(.ready))
}
