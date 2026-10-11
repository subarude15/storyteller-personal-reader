//
//  RaveBSDClientTests.swift
//  SilveranTests
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit
import Testing

@Suite("RaveBSD client and parsing")
struct RaveBSDClientTests {
    @Test func parsesSearchPayload() throws {
        let json = """
        {
          "source": "all",
          "results": [
            {
              "id": "abc123",
              "title": "Pride and Prejudice",
              "author": "Jane Austen",
              "format": "epub",
              "filesize": 1594721,
              "language": "eng",
              "source": "Internet Archive",
              "downloadUrl": "https://archive.org/details/pride",
              "directUrl": "https://archive.org/download/pride/pride.epub",
              "directReady": true
            },
            {
              "id": "mag1",
              "title": "Dune",
              "author": "Frank Herbert",
              "format": "m4b",
              "filesize": 0,
              "language": "English",
              "source": "AudiobookBay",
              "magnet": "magnet:?xt=urn:btih:abcdef",
              "downloadUrl": "https://audiobookbay.lu/dune"
            },
            {
              "title": "",
              "author": "skip me"
            }
          ],
          "meta": { "archive": 1, "audiobookbay": 1, "libgen": 0 }
        }
        """.data(using: .utf8)!
        let parsed = try RaveBSDResponseParsing.search(data: json)
        #expect(parsed.results.count == 2)
        #expect(parsed.results[0].title == "Pride and Prejudice")
        #expect(parsed.results[0].acquisitionMethod == .directHTTP)
        #expect(parsed.results[0].formatDisplay == "EPUB")
        #expect(parsed.results[0].filesizeDisplay != nil)
        #expect(parsed.results[1].acquisitionMethod == .magnet)
        #expect(parsed.meta.counts["archive"] == 1)
    }

    @Test func malformedRootFails() {
        #expect(throws: RaveBSDClientError.self) {
            _ = try RaveBSDResponseParsing.search(data: Data("[]".utf8))
        }
    }

    @Test func healthOKDetection() {
        #expect(RaveBSDResponseParsing.isHealthOK(Data("ok".utf8), status: 200))
        #expect(!RaveBSDResponseParsing.isHealthOK(Data("ok".utf8), status: 500))
        #expect(!RaveBSDResponseParsing.isHealthOK(Data("nope".utf8), status: 200))
    }

    @Test func resolveParsingAndExpired() throws {
        let ok = """
        {"id":"x","directUrl":"https://example.com/a.epub","magnet":"","filesize":12,"format":"epub"}
        """.data(using: .utf8)!
        let resolved = try RaveBSDResponseParsing.resolve(data: ok)
        #expect(resolved.directURL.contains("a.epub"))

        let expired = #"{"error":"Unknown or expired result","results":[]}"#.data(using: .utf8)!
        do {
            _ = try RaveBSDResponseParsing.resolve(data: expired)
            Issue.record("expected expired error")
        } catch let error as RaveBSDClientError {
            guard case .expiredOrUnknownResult = error else {
                Issue.record("wrong error \(error)")
                return
            }
        }
    }

    @Test func connectionSuccessAndCloudflare() async {
        let transport = RaveScript()
        transport.handler = { request in
            if request.url?.path.hasSuffix("/health") == true {
                return RaveBSDHTTPResponse(status: 200, data: Data("ok".utf8), contentType: "text/plain")
            }
            return RaveBSDHTTPResponse(status: 404, data: Data())
        }
        let ok = await RaveBSDClient(transport: transport).testConnection(
            baseURL: "http://192.168.1.2:8686"
        )
        #expect(ok.isSuccess)

        transport.handler = { _ in
            RaveBSDHTTPResponse(
                status: 403,
                data: Data("<html>Just a moment... challenges.cloudflare.com</html>".utf8),
                contentType: "text/html",
            )
        }
        let blocked = await RaveBSDClient(transport: transport).testConnection(
            baseURL: "https://rave.punkandrally.com"
        )
        guard case .authOrCloudflare = blocked else {
            Issue.record("expected cloudflare status, got \(blocked)")
            return
        }
    }

    @Test func searchUsesApiPathWhenKeyPresent() async throws {
        let transport = RaveScript()
        transport.handler = { request in
            #expect(request.url?.path.contains("/api/v1/search") == true)
            #expect(request.value(forHTTPHeaderField: "X-API-Key") == "secret")
            let body = """
            {"source":"all","results":[{"id":"1","title":"Hobbit","author":"Tolkien","format":"epub","directUrl":"https://x/a.epub","source":"LibGen"}],"meta":{}}
            """.data(using: .utf8)!
            return RaveBSDHTTPResponse(status: 200, data: body, contentType: "application/json")
        }
        let response = try await RaveBSDClient(transport: transport).search(
            baseURL: "http://192.168.1.2:8686",
            query: RaveBSDSearchQuery(title: "Hobbit", author: "Tolkien", mode: .ebooks),
            apiKey: "secret",
        )
        #expect(response.results.count == 1)
        #expect(response.results[0].title == "Hobbit")
        #expect(response.results[0].searchMode == .ebooks)
    }

    @Test func searchStampsAudiobookModeOnResults() async throws {
        let transport = RaveScript()
        transport.handler = { _ in
            let body = """
            {"source":"all","results":[{"id":"a1","title":"Dune","author":"Herbert","format":"m4b","magnet":"magnet:?xt=urn:btih:aa","source":"ABB"}],"meta":{}}
            """.data(using: .utf8)!
            return RaveBSDHTTPResponse(status: 200, data: body)
        }
        let response = try await RaveBSDClient(transport: transport).search(
            baseURL: "http://192.168.1.2:8686",
            query: RaveBSDSearchQuery(freeText: "dune", mode: .audiobooks),
        )
        #expect(response.results.count == 1)
        #expect(response.results[0].searchMode == .audiobooks)
    }

    @Test func errorOnlySearchPayloadThrows() {
        let data = #"{"error":"upstream failed","results":[]}"#.data(using: .utf8)!
        do {
            _ = try RaveBSDResponseParsing.search(data: data)
            Issue.record("expected error-only payload to throw")
        } catch let error as RaveBSDClientError {
            guard case .unsupportedAPIResponse(let message) = error else {
                Issue.record("wrong error \(error)")
                return
            }
            #expect(message.contains("upstream failed"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func malformedResultsFieldThrows() {
        let data = #"{"results":{"not":"an array"}}"#.data(using: .utf8)!
        #expect(throws: RaveBSDClientError.self) {
            _ = try RaveBSDResponseParsing.search(data: data)
        }
    }

    @Test func searchHTTPErrorSurfacesMessage() async {
        let transport = RaveScript()
        transport.handler = { _ in
            RaveBSDHTTPResponse(
                status: 502,
                data: Data(#"{"error":"bad gateway from index"}"#.utf8),
            )
        }
        do {
            _ = try await RaveBSDClient(transport: transport).search(
                baseURL: "http://192.168.1.2:8686",
                query: RaveBSDSearchQuery(freeText: "x", mode: .ebooks),
            )
            Issue.record("expected HTTP error to throw")
        } catch let error as RaveBSDClientError {
            #expect(error.message.contains("bad gateway from index"))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func searchForbiddenIsAuthError() async {
        let transport = RaveScript()
        transport.handler = { _ in
            RaveBSDHTTPResponse(status: 403, data: Data("denied".utf8))
        }
        do {
            _ = try await RaveBSDClient(transport: transport).search(
                baseURL: "http://192.168.1.2:8686",
                query: RaveBSDSearchQuery(freeText: "x", mode: .ebooks),
            )
            Issue.record("expected 403 to throw")
        } catch let error as RaveBSDClientError {
            guard case .authOrCloudflare = error else {
                Issue.record("wrong \(error)")
                return
            }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func searchUsesSearchAllWithoutKey() async throws {
        let transport = RaveScript()
        transport.handler = { request in
            #expect(request.url?.path.hasSuffix("/search/all") == true)
            #expect(request.value(forHTTPHeaderField: "X-API-Key") == nil)
            let body = #"{"source":"all","results":[],"meta":{}}"#.data(using: .utf8)!
            return RaveBSDHTTPResponse(status: 200, data: body)
        }
        let response = try await RaveBSDClient(transport: transport).search(
            baseURL: "http://192.168.1.2:8686",
            query: RaveBSDSearchQuery(freeText: "pride", mode: .ebooks),
        )
        #expect(response.results.isEmpty)
    }

    @Test func timeoutMapsToClientError() async {
        let transport = RaveScript()
        transport.handler = { _ in throw URLError(.timedOut) }
        do {
            _ = try await RaveBSDClient(transport: transport).search(
                baseURL: "http://192.168.1.2:8686",
                query: RaveBSDSearchQuery(freeText: "x", mode: .ebooks),
            )
            Issue.record("expected timeout")
        } catch let error as RaveBSDClientError {
            guard case .timeout = error else {
                Issue.record("wrong \(error)")
                return
            }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func invalidEndpointRejected() async {
        let status = await RaveBSDClient(transport: RaveScript()).testConnection(baseURL: "ftp://nope")
        guard case .invalidEndpoint = status else {
            Issue.record("expected invalidEndpoint")
            return
        }
    }
}

@Suite("RaveBSD normalization and routing")
struct RaveBSDNormalizationTests {
    @Test func ebookFilterDropsAudioFormats() {
        let rows = [
            RaveBSDSearchResult(id: "1", title: "A", format: "epub"),
            RaveBSDSearchResult(id: "2", title: "B", format: "m4b"),
            RaveBSDSearchResult(id: "3", title: "C", format: ""),
        ]
        let kept = RaveBSDResultFiltering.matching(rows, mode: .ebooks)
        #expect(kept.map(\.id) == ["1", "3"])
    }

    @Test func audiobookFilterDropsEbookFormats() {
        let rows = [
            RaveBSDSearchResult(id: "1", title: "A", format: "epub"),
            RaveBSDSearchResult(id: "2", title: "B", format: "mp3"),
        ]
        let kept = RaveBSDResultFiltering.matching(rows, mode: .audiobooks)
        #expect(kept.map(\.id) == ["2"])
    }

    @Test func dedupeKeepsDistinctSources() {
        let rows = [
            RaveBSDSearchResult(id: "1", title: "Dune", author: "Herbert", format: "epub", source: "LibGen", directURL: "https://a/x.epub"),
            RaveBSDSearchResult(id: "2", title: "Dune", author: "Herbert", format: "epub", source: "LibGen", directURL: "https://a/x.epub"),
            RaveBSDSearchResult(id: "3", title: "Dune", author: "Herbert", format: "epub", source: "Anna's Archive", directURL: "https://b/x.epub"),
        ]
        #expect(RaveBSDResultFiltering.deduplicated(rows).map(\.id) == ["1", "3"])
    }

    @Test func localPreferredWhenReachable() {
        let selected = RaveBSDEndpointRouting.select(
            localURL: "http://192.168.1.2:8686",
            remoteURL: "https://rave.punkandrally.com",
            localReachable: true,
        )
        #expect(selected?.route == .local)
        #expect(selected?.baseURL == "http://192.168.1.2:8686")
    }

    @Test func remoteUsedWhenLocalDown() {
        let selected = RaveBSDEndpointRouting.select(
            localURL: "http://192.168.1.2:8686",
            remoteURL: "https://rave.punkandrally.com",
            localReachable: false,
        )
        #expect(selected?.route == .remote)
    }

    @Test func probeRequiresPlainHealthOK() async {
        let transport = RaveScript()
        transport.handler = { _ in
            RaveBSDHTTPResponse(status: 200, data: Data("welcome".utf8), contentType: "text/plain")
        }
        let anyHTTP = await RaveBSDEndpointRouting.probeReachability(
            baseURL: "http://192.168.1.2:8686",
            transport: transport,
        )
        #expect(anyHTTP == false)

        transport.handler = { _ in
            RaveBSDHTTPResponse(status: 200, data: Data("ok".utf8), contentType: "text/plain")
        }
        let ok = await RaveBSDEndpointRouting.probeReachability(
            baseURL: "http://192.168.1.2:8686",
            transport: transport,
        )
        #expect(ok == true)

        transport.handler = { _ in
            RaveBSDHTTPResponse(
                status: 403,
                data: Data("<html>Just a moment... challenges.cloudflare.com</html>".utf8),
                contentType: "text/html",
            )
        }
        let cf = await RaveBSDEndpointRouting.probeReachability(
            baseURL: "https://rave.punkandrally.com",
            transport: transport,
        )
        #expect(cf == false)

        transport.handler = { _ in
            RaveBSDHTTPResponse(status: 401, data: Data("auth".utf8))
        }
        let unauthorized = await RaveBSDEndpointRouting.probeReachability(
            baseURL: "https://rave.punkandrally.com",
            transport: transport,
        )
        #expect(unauthorized == false)
    }

    @Test func resolveLiveSkipsLocalWhenHealthNotOK() async {
        let transport = RaveScript()
        transport.handler = { request in
            if request.url?.host == "192.168.1.2" {
                return RaveBSDHTTPResponse(status: 200, data: Data("<html>nginx</html>".utf8))
            }
            return RaveBSDHTTPResponse(status: 200, data: Data("ok".utf8))
        }
        let selected = await RaveBSDEndpointRouting.resolveLive(
            localURL: "http://192.168.1.2:8686",
            remoteURL: "https://rave.punkandrally.com",
            transport: transport,
        )
        #expect(selected?.route == .remote)
    }

    @Test func providerPreferenceDefaultsToRaveBSD() {
        #expect(BookSearchProviderKind.preference(from: "") == .raveBSD)
        #expect(BookSearchProviderKind.preference(from: "manual") == .manual)
        #expect(BookSearchProviderKind.preference(from: "lazyLibrarian") == .lazyLibrarian)
    }

    @Test func queryFromBookFillsTitleAuthorAndMode() {
        let book = ManualSearchBookContext(
            title: "The Hobbit",
            authors: ["J.R.R. Tolkien"],
            requestedMediaType: .audiobook,
        )
        let query = RaveBSDSearchQuery.from(book: book)
        #expect(query.title == "The Hobbit")
        #expect(query.author.contains("Tolkien"))
        #expect(query.mode == .audiobooks)
    }

    @Test func titleAuthorEditInvalidatesStaleFreeText() {
        let stale = RaveBSDSearchQueryBuilding.make(
            title: "Dune",
            author: "Herbert",
            freeText: "pride and prejudice",
            mode: .ebooks,
        )
        #expect(stale.freeText == "pride and prejudice")
        #expect(stale.title.isEmpty)

        let synced = RaveBSDSearchQueryBuilding.syncedFreeText(title: "Dune", author: "Herbert")
        let next = RaveBSDSearchQueryBuilding.make(
            title: "Dune",
            author: "Herbert",
            freeText: synced,
            mode: .ebooks,
        )
        #expect(next.title == "Dune")
        #expect(next.author == "Herbert")
        #expect(next.freeText.isEmpty)
    }

    @Test func matchingComposedFreeTextUsesStructuredFields() {
        let composed = RaveBSDSearchQueryBuilding.composedQuery(title: "The Hobbit", author: "Tolkien")
        let query = RaveBSDSearchQueryBuilding.make(
            title: "The Hobbit",
            author: "Tolkien",
            freeText: composed,
            mode: .ebooks,
        )
        #expect(query.title == "The Hobbit")
        #expect(query.author == "Tolkien")
        #expect(query.freeText.isEmpty)
    }
}

@Suite("RaveBSD acquisition mapping")
struct RaveBSDAcquisitionTests {
    private let book = ManualSearchBookContext(title: "The Hobbit", authors: ["Tolkien"], requestedMediaType: .ebook)

    @Test func directURLBecomesHTTPCandidate() throws {
        let result = RaveBSDSearchResult(
            id: "1",
            title: "The Hobbit",
            format: "epub",
            source: "Internet Archive",
            directURL: "https://archive.org/download/x/x.epub",
        )
        let candidate = try RaveBSDAcquisition.candidate(from: result, book: book)
        #expect(candidate.detectedType == .epub)
        #expect(candidate.transportKind == .directHTTP)
        #expect(candidate.providerID == "ravebsd")
    }

    @Test func magnetBecomesMagnetCandidate() throws {
        let result = RaveBSDSearchResult(
            id: "2",
            title: "Dune",
            format: "m4b",
            source: "AudiobookBay",
            magnet: "magnet:?xt=urn:btih:deadbeef",
        )
        let candidate = try RaveBSDAcquisition.candidate(from: result, book: book)
        #expect(candidate.detectedType == .magnet)
        #expect(candidate.transportKind == .magnet)
    }

    @Test func stampedSearchModeSurvivesLaterUIMediaChange() throws {
        // Row came from an audiobook search; UI picker later flipped to ebooks.
        let result = RaveBSDSearchResult(
            id: "2",
            title: "Dune",
            format: "m4b",
            source: "AudiobookBay",
            magnet: "magnet:?xt=urn:btih:deadbeef",
            searchMode: .audiobooks,
        )
        let uiChangedBook = ManualSearchBookContext(
            title: "Dune",
            authors: ["Herbert"],
            requestedMediaType: .ebook,
        )
        let candidate = try RaveBSDAcquisition.candidate(from: result, book: uiChangedBook)
        #expect(candidate.bookMetadata.requestedMediaType == .audiobook)
        #expect(candidate.transportKind == .magnet)
    }

    @Test func pageOnlyCannotDownload() {
        let result = RaveBSDSearchResult(
            id: "local-0-x",
            title: "Forum topic",
            source: "Mobilism",
            downloadURL: "https://forum.mobilism.org/viewtopic.php?t=1",
        )
        #expect(result.canAttemptDownload == false)
        #expect(throws: RaveBSDAcquisitionError.self) {
            _ = try RaveBSDAcquisition.candidate(from: result, book: book)
        }
    }

    @Test func unresolvedWithoutLinksCannotBecomeCandidate() {
        let result = RaveBSDSearchResult(
            id: "need-resolve",
            title: "Needs resolve",
            source: "LibGen",
            downloadURL: "https://libgen.example/ads.php?md5=1",
        )
        #expect(result.canAttemptDownload == true)
        #expect(throws: RaveBSDAcquisitionError.self) {
            // Without calling prepareCandidate/resolve, direct candidate build fails safely.
            _ = try RaveBSDAcquisition.candidate(from: result, book: book)
        }
    }

    @Test func prepareCandidateResolvesWhenNeeded() async throws {
        let transport = RaveScript()
        transport.handler = { request in
            if request.url?.path.hasSuffix("/resolve") == true {
                let body = """
                {"id":"need","directUrl":"https://cdn.example/book.pdf","magnet":"","format":"pdf","filesize":9}
                """.data(using: .utf8)!
                return RaveBSDHTTPResponse(status: 200, data: body)
            }
            return RaveBSDHTTPResponse(status: 404, data: Data())
        }
        let result = RaveBSDSearchResult(
            id: "need",
            title: "Resolved Book",
            format: "",
            source: "Library Genesis",
            downloadURL: "https://libgen.example/ads.php?md5=1",
        )
        let candidate = try await RaveBSDAcquisition.prepareCandidate(
            result: result,
            book: book,
            baseURL: "http://192.168.1.2:8686",
            client: RaveBSDClient(transport: transport),
        )
        #expect(candidate.detectedType == .pdf)
        #expect(candidate.sourceURL.absoluteString.contains("book.pdf"))
    }
}

@Suite("RaveBSD settings defaults")
struct RaveBSDSettingsDefaultsTests {
    @Test func globalConfigDefaults() {
        let config = SilveranGlobalConfig()
        #expect(config.bookSearchLANBaseURL == RaveBSDURL.defaultLocal)
        #expect(config.raveBSDRemoteURL == RaveBSDURL.defaultRemote)
        #expect(
            BookSearchProviderKind.preference(from: config.bookSearchDefaultProvider) == .raveBSD
        )
        #expect(config.bookSearchLANEnabled == true)
    }

    @Test func missingKeysMigrateToIntendedDefaults() throws {
        let config = try JSONDecoder().decode(SilveranGlobalConfig.self, from: Data("{}".utf8))
        #expect(config.bookSearchLANEnabled == true)
        #expect(config.bookSearchLANBaseURL == RaveBSDURL.defaultLocal)
        #expect(config.raveBSDRemoteURL == RaveBSDURL.defaultRemote)
        #expect(config.bookSearchDefaultProvider == BookSearchProviderKind.raveBSD.rawValue)
    }

    @Test func savedDisabledIsPreservedOnDecode() throws {
        let json = #"{"bookSearchLANEnabled":false}"#.data(using: .utf8)!
        let config = try JSONDecoder().decode(SilveranGlobalConfig.self, from: json)
        #expect(config.bookSearchLANEnabled == false)
    }

    @Test func customizedURLsAreNotOverwritten() throws {
        let json = """
        {
          "bookSearchLANBaseURL": "http://10.0.0.5:9999",
          "raveBSDRemoteURL": "https://books.example.com",
          "bookSearchDefaultProvider": "manual"
        }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(SilveranGlobalConfig.self, from: json)
        #expect(config.bookSearchLANBaseURL == "http://10.0.0.5:9999")
        #expect(config.raveBSDRemoteURL == "https://books.example.com")
        #expect(config.bookSearchDefaultProvider == "manual")
    }

    @Test func intentionallyEmptyURLsArePreserved() throws {
        let json = """
        {"bookSearchLANBaseURL":"","raveBSDRemoteURL":""}
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(SilveranGlobalConfig.self, from: json)
        #expect(config.bookSearchLANBaseURL == "")
        #expect(config.raveBSDRemoteURL == "")
    }

    @Test func lazyLibrarianProviderKindStillExists() {
        #expect(BookRequestProviderKind.lazyLibrarian.rawValue == "lazyLibrarian")
        #expect(BookRequestProviderKind.allCases.contains(.lazyLibrarian))
    }
}

private final class RaveScript: RaveBSDTransport, @unchecked Sendable {
    var handler: ((URLRequest) async throws -> RaveBSDHTTPResponse)?

    func send(_ request: URLRequest) async throws -> RaveBSDHTTPResponse {
        if let handler {
            return try await handler(request)
        }
        return RaveBSDHTTPResponse(status: 500, data: Data())
    }
}
