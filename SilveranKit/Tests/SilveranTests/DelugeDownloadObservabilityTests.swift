import Foundation
import Testing

@testable import SilveranKit

@Suite("Deluge download observability")
struct DelugeDownloadObservabilityTests {

    // MARK: - Client

    @Test func authSuccessListsTorrents() async {
        let transport = DelugeScript()
        transport.handler = { method, _, cookie in
            switch method {
                case "auth.login":
                    return DelugeHTTP(
                        status: 200,
                        body: Data(#"{"result":true,"error":null,"id":1}"#.utf8),
                        setCookie: "_session_id=abc; Path=/",
                    )
                case "web.connected":
                    return DelugeHTTP(
                        status: 200,
                        body: Data(#"{"result":true,"error":null,"id":2}"#.utf8),
                        setCookie: cookie,
                    )
                case "core.get_torrents_status":
                    #expect(cookie?.contains("_session_id=abc") == true)
                    return DelugeHTTP(
                        status: 200,
                        body: Data(
                            #"""
                            {"result":{"hash1":{"name":"The Reddening","state":"Downloading","progress":42.5,"download_payload_rate":1000,"eta":1200,"save_path":"/downloads","total_size":100,"total_done":42,"time_added":1700000000,"completed_time":0,"hash":"hash1","is_finished":false}},"error":null,"id":6}
                            """#.utf8
                        ),
                    )
                default:
                    return DelugeHTTP(status: 200, body: Data(#"{"result":null,"error":null,"id":0}"#.utf8))
            }
        }
        let client = DelugeWebClient(transport: transport)
        let result = await client.fetchTorrentIndex(
            baseURL: "http://deluge.example:8112",
            password: "secret",
        )
        switch result {
            case .success(let index):
                #expect(index.torrents.count == 1)
                #expect(index.torrents[0].name == "The Reddening")
                #expect(index.torrents[0].progress == 0.425)
            case .failure(let error):
                Issue.record("unexpected \(error)")
        }
        #expect(await client.testConnection(baseURL: "http://deluge.example:8112", password: "secret") == .ok)
    }

    @Test func badPasswordMapsToAuthenticationFailed() async {
        let transport = DelugeScript()
        transport.handler = { method, _, _ in
            if method == "auth.login" {
                return DelugeHTTP(
                    status: 200,
                    body: Data(#"{"result":false,"error":null,"id":1}"#.utf8),
                )
            }
            return DelugeHTTP(status: 200, body: Data(#"{"result":null,"error":null,"id":0}"#.utf8))
        }
        let client = DelugeWebClient(transport: transport)
        #expect(
            await client.testConnection(baseURL: "http://deluge.example:8112", password: "nope")
                == .authenticationFailed
        )
    }

    @Test func invalidURLRejected() async {
        let client = DelugeWebClient(transport: DelugeScript())
        #expect(await client.testConnection(baseURL: "not-a-url", password: "x") == .invalidURL)
    }

    @Test func timeoutMapsCleanly() async {
        let transport = DelugeScript()
        transport.throwError = URLError(.timedOut)
        let client = DelugeWebClient(transport: transport)
        #expect(
            await client.testConnection(baseURL: "http://deluge.example:8112", password: "x")
                == .timeout
        )
    }

    @Test func invalidJSONRPCResponse() async {
        let transport = DelugeScript()
        transport.handler = { _, _, _ in
            DelugeHTTP(status: 200, body: Data("not-json".utf8), setCookie: "_session_id=x")
        }
        let client = DelugeWebClient(transport: transport)
        #expect(
            await client.testConnection(baseURL: "http://deluge.example:8112", password: "x")
                == .invalidResponse
        )
    }

    @Test func addMagnetUsesDownloadLocation() async throws {
        let transport = DelugeScript()
        transport.handler = { method, body, cookie in
            switch method {
                case "auth.login":
                    return DelugeHTTP(
                        status: 200,
                        body: Data(#"{"result":true,"error":null,"id":1}"#.utf8),
                        setCookie: "_session_id=abc; Path=/",
                    )
                case "web.connected":
                    return DelugeHTTP(
                        status: 200,
                        body: Data(#"{"result":true,"error":null,"id":2}"#.utf8),
                        setCookie: cookie,
                    )
                case "core.add_torrent_magnet":
                    #expect(cookie?.contains("_session_id=abc") == true)
                    let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
                    let params = json?["params"] as? [Any]
                    #expect(params?[0] as? String == "magnet:?xt=urn:btih:abc")
                    let options = params?[1] as? [String: Any]
                    #expect(options?["download_location"] as? String == "/media/audiobooks")
                    #expect(options?["add_paused"] as? Bool == false)
                    return DelugeHTTP(
                        status: 200,
                        body: Data(#"{"result":"hashabc","error":null,"id":10}"#.utf8),
                    )
                default:
                    return DelugeHTTP(status: 200, body: Data(#"{"result":null,"error":null,"id":0}"#.utf8))
            }
        }
        let client = DelugeWebClient(transport: transport)
        let hash = try await client.addMagnet(
            baseURL: "http://deluge.example:8112",
            password: "secret",
            uri: "magnet:?xt=urn:btih:abc",
            downloadLocation: "/media/audiobooks",
            start: true,
        )
        #expect(hash == "hashabc")
    }

    @Test func addTorrentURLUsesDownloadLocation() async throws {
        let transport = DelugeScript()
        transport.handler = { method, body, cookie in
            switch method {
                case "auth.login":
                    return DelugeHTTP(
                        status: 200,
                        body: Data(#"{"result":true,"error":null,"id":1}"#.utf8),
                        setCookie: "_session_id=abc; Path=/",
                    )
                case "web.connected":
                    return DelugeHTTP(
                        status: 200,
                        body: Data(#"{"result":true,"error":null,"id":2}"#.utf8),
                        setCookie: cookie,
                    )
                case "core.add_torrent_url":
                    #expect(cookie?.contains("_session_id=abc") == true)
                    let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
                    let params = json?["params"] as? [Any]
                    #expect(params?[0] as? String == "https://files.example/hobbit.torrent")
                    let options = params?[1] as? [String: Any]
                    #expect(options?["download_location"] as? String == "/volume1/media/books/books")
                    return DelugeHTTP(
                        status: 200,
                        body: Data(#"{"result":"hashdef","error":null,"id":10}"#.utf8),
                    )
                default:
                    return DelugeHTTP(status: 200, body: Data(#"{"result":null,"error":null,"id":0}"#.utf8))
            }
        }
        let client = DelugeWebClient(transport: transport)
        let hash = try await client.addTorrentURL(
            baseURL: "http://deluge.example:8112",
            password: "secret",
            url: "https://files.example/hobbit.torrent",
            downloadLocation: "/volume1/media/books/books",
            start: true,
        )
        #expect(hash == "hashdef")
    }

    @Test func jsonNullErrorIsNotAFailure() {
        let null = try? JSONSerialization.jsonObject(with: Data(#"{"error":null}"#.utf8)) as? [String: Any]
        #expect(DelugeWebClient.jsonValue(null?["error"]) == nil)
        #expect(DelugeWebClient.jsonValue(NSNull()) == nil)
        #expect(DelugeWebClient.jsonValue("ok") as? String == "ok")
    }

    @Test func realErrorObjectRejectsAdd() async {
        let transport = DelugeScript()
        transport.handler = { method, _, cookie in
            switch method {
                case "auth.login":
                    return DelugeHTTP(
                        status: 200,
                        body: Data(#"{"result":true,"error":null,"id":1}"#.utf8),
                        setCookie: "_session_id=abc; Path=/",
                    )
                case "web.connected":
                    return DelugeHTTP(
                        status: 200,
                        body: Data(#"{"result":true,"error":null,"id":2}"#.utf8),
                        setCookie: cookie,
                    )
                case "core.add_torrent_magnet":
                    return DelugeHTTP(
                        status: 200,
                        body: Data(
                            #"{"result":null,"error":{"message":"Unable to add torrent","code":1},"id":10}"#
                                .utf8
                        ),
                    )
                default:
                    return DelugeHTTP(status: 200, body: Data(#"{"result":null,"error":null,"id":0}"#.utf8))
            }
        }
        let client = DelugeWebClient(transport: transport)
        do {
            _ = try await client.addMagnet(
                baseURL: "http://deluge.example:8112",
                password: "secret",
                uri: "magnet:?xt=urn:btih:abc",
                downloadLocation: "/volume1/media/books/audiobooks",
                start: true,
            )
            Issue.record("real Deluge error should reject")
        } catch let error as DelugeClientError {
            #expect(error == .rejected)
            #expect(error.handoff == .rejected(.deluge))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func addMagnetAuthFailure() async {
        let transport = DelugeScript()
        transport.handler = { method, _, _ in
            if method == "auth.login" {
                return DelugeHTTP(
                    status: 200,
                    body: Data(#"{"result":false,"error":null,"id":1}"#.utf8),
                )
            }
            return DelugeHTTP(status: 200, body: Data(#"{"result":null,"error":null,"id":0}"#.utf8))
        }
        let client = DelugeWebClient(transport: transport)
        do {
            _ = try await client.addMagnet(
                baseURL: "http://deluge.example:8112",
                password: "nope",
                uri: "magnet:?xt=urn:btih:abc",
                downloadLocation: "/media/audiobooks",
                start: true,
            )
            Issue.record("should fail auth")
        } catch let error as DelugeClientError {
            #expect(error == .authenticationFailed)
            #expect(error.handoff == .authenticationFailed(.deluge))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func addMagnetConnectionFailure() async {
        let transport = DelugeScript()
        transport.throwError = URLError(.cannotConnectToHost)
        let client = DelugeWebClient(transport: transport)
        do {
            _ = try await client.addMagnet(
                baseURL: "http://deluge.example:8112",
                password: "x",
                uri: "magnet:?xt=urn:btih:abc",
                downloadLocation: "/media/audiobooks",
                start: true,
            )
            Issue.record("should fail")
        } catch let error as DelugeClientError {
            #expect(error == .cannotReachServer)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    // MARK: - State mapping

    @Test func mapsDelugeStates() {
        #expect(DelugeWebClient.mapState(torrent(state: "Downloading", progress: 0.4)) == .downloading)
        #expect(DelugeWebClient.mapState(torrent(state: "Queued", progress: 0)) == .queued)
        #expect(DelugeWebClient.mapState(torrent(state: "Checking", progress: 0.5)) == .checking)
        #expect(DelugeWebClient.mapState(torrent(state: "Paused", progress: 0.2)) == .stalled)
        #expect(
            DelugeWebClient.mapState(torrent(state: "Seeding", progress: 1, finished: true)) == .completed
        )
        #expect(
            DelugeWebClient.mapState(
                torrent(state: "Error", progress: 0.1, error: "Tracker failed")
            ) == .error
        )
    }

    // MARK: - Matcher

    @Test func strongTitleMatch() {
        let item = request(title: "The Reddening", author: "Adam Nevill")
        let index = DelugeTorrentIndex(torrents: [
            torrent(id: "1", name: "The Reddening", state: "Downloading", progress: 0.2)
        ])
        switch DelugeRequestMatcher.match(item: item, format: .audiobook, index: index) {
            case .matched(let snap): #expect(snap.id == "1")
            default: Issue.record("expected match")
        }
    }

    @Test func titleAuthorMatch() {
        let item = request(title: "Dune", author: "Frank Herbert")
        let index = DelugeTorrentIndex(torrents: [
            torrent(id: "1", name: "Dune Frank Herbert", state: "Downloading", progress: 0.2)
        ])
        switch DelugeRequestMatcher.match(item: item, format: .ebook, index: index) {
            case .matched: break
            default: Issue.record("expected match")
        }
    }

    @Test func isbnMatch() {
        let item = request(title: "Pride", author: "Jane Austen", isbn: "9780141439518")
        let index = DelugeTorrentIndex(torrents: [
            torrent(id: "1", name: "book-9780141439518", state: "Downloading", progress: 0.2)
        ])
        switch DelugeRequestMatcher.match(item: item, format: .ebook, index: index) {
            case .matched: break
            default: Issue.record("expected isbn match")
        }
    }

    @Test func ambiguousTorrentsDoNotGuess() {
        let item = request(title: "The Reddening", author: "Adam Nevill")
        let index = DelugeTorrentIndex(torrents: [
            torrent(id: "1", name: "The Reddening", state: "Downloading", progress: 0.2),
            torrent(id: "2", name: "The Reddening Audiobook", state: "Downloading", progress: 0.3),
        ])
        #expect(DelugeRequestMatcher.match(item: item, format: .audiobook, index: index) == .ambiguous)
    }

    @Test func similarWrongTitleDoesNotMatch() {
        let item = request(title: "The Reddening", author: "Adam Nevill")
        let index = DelugeTorrentIndex(torrents: [
            torrent(id: "1", name: "The Reckoning", state: "Downloading", progress: 0.2)
        ])
        #expect(DelugeRequestMatcher.match(item: item, format: .audiobook, index: index) == .noMatch)
    }

    @Test func persistedTorrentIDWins() {
        var item = request(title: "Other", author: "Author")
        item.downloadStates = [
            RequestFormatDownloadState(
                format: .audiobook,
                status: .downloading,
                torrentID: "known",
                torrentName: "Known",
            )
        ]
        let index = DelugeTorrentIndex(torrents: [
            torrent(id: "known", name: "Completely Different Name", state: "Downloading", progress: 0.5)
        ])
        switch DelugeRequestMatcher.match(item: item, format: .audiobook, index: index) {
            case .matched(let snap): #expect(snap.id == "known")
            default: Issue.record("expected persisted id match")
        }
    }

    // MARK: - Format-aware matching

    @Test func audiobookTorrentDoesNotMatchEbook() {
        let item = request(
            title: "The Reddening",
            author: "Adam Nevill",
            formats: [.ebook, .audiobook],
        )
        let index = DelugeTorrentIndex(torrents: [
            torrent(
                id: "audio-1",
                name: "The Reddening Adam Nevill Audiobook.m4b",
                state: "Downloading",
                progress: 0.4,
            )
        ])
        switch DelugeRequestMatcher.match(item: item, format: .audiobook, index: index) {
            case .matched(let snap): #expect(snap.id == "audio-1")
            default: Issue.record("expected audiobook match")
        }
        #expect(DelugeRequestMatcher.match(item: item, format: .ebook, index: index) == .noMatch)

        let updated = RequestDownloadObservability.applying(item, index: index, now: Date())
        #expect(updated.downloadState(for: .audiobook)?.torrentID == "audio-1")
        #expect(updated.downloadState(for: .ebook)?.torrentID == nil)
        #expect(updated.downloadState(for: .ebook)?.status != .downloading)
    }

    @Test func ebookTorrentDoesNotMatchAudiobook() {
        let item = request(
            title: "The Reddening",
            author: "Adam Nevill",
            formats: [.ebook, .audiobook],
        )
        let index = DelugeTorrentIndex(torrents: [
            torrent(
                id: "ebook-1",
                name: "The Reddening - Adam Nevill.epub",
                state: "Downloading",
                progress: 0.3,
            )
        ])
        switch DelugeRequestMatcher.match(item: item, format: .ebook, index: index) {
            case .matched(let snap): #expect(snap.id == "ebook-1")
            default: Issue.record("expected ebook match")
        }
        #expect(DelugeRequestMatcher.match(item: item, format: .audiobook, index: index) == .noMatch)

        let updated = RequestDownloadObservability.applying(item, index: index, now: Date())
        #expect(updated.downloadState(for: .ebook)?.torrentID == "ebook-1")
        #expect(updated.downloadState(for: .audiobook)?.torrentID == nil)
    }

    @Test func twoFormatSpecificTorrentsMapIndependently() {
        let item = request(
            title: "The Reddening",
            author: "Adam Nevill",
            formats: [.ebook, .audiobook],
        )
        let index = DelugeTorrentIndex(torrents: [
            torrent(id: "ebook-1", name: "The Reddening - EPUB", state: "Downloading", progress: 0.2),
            torrent(
                id: "audio-1",
                name: "The Reddening - Audiobook M4B",
                state: "Downloading",
                progress: 0.7,
            ),
        ])
        let updated = RequestDownloadObservability.applying(item, index: index, now: Date())
        #expect(updated.downloadState(for: .ebook)?.torrentID == "ebook-1")
        #expect(updated.downloadState(for: .audiobook)?.torrentID == "audio-1")
        #expect(updated.downloadState(for: .ebook)?.torrentID
            != updated.downloadState(for: .audiobook)?.torrentID)
    }

    @Test func formatUnknownTorrentDoesNotClaimBothFormats() {
        let item = request(
            title: "The Reddening",
            author: "Adam Nevill",
            formats: [.ebook, .audiobook],
        )
        let index = DelugeTorrentIndex(torrents: [
            torrent(id: "shared", name: "The Reddening - Adam Nevill", state: "Downloading", progress: 0.5)
        ])
        #expect(DelugeRequestMatcher.match(item: item, format: .ebook, index: index) == .noMatch)
        #expect(DelugeRequestMatcher.match(item: item, format: .audiobook, index: index) == .noMatch)

        let updated = RequestDownloadObservability.applying(item, index: index, now: Date())
        #expect(updated.downloadState(for: .ebook)?.torrentID == nil)
        #expect(updated.downloadState(for: .audiobook)?.torrentID == nil)
    }

    @Test func singleFormatUnknownTorrentStillMatches() {
        let item = request(
            title: "The Reddening",
            author: "Adam Nevill",
            formats: [.audiobook],
        )
        let index = DelugeTorrentIndex(torrents: [
            torrent(id: "1", name: "The Reddening - Adam Nevill", state: "Downloading", progress: 0.5)
        ])
        switch DelugeRequestMatcher.match(item: item, format: .audiobook, index: index) {
            case .matched(let snap): #expect(snap.id == "1")
            default: Issue.record("expected single-format match")
        }
    }

    @Test func audiobookDownloadDoesNotSuppressEbookFallback() {
        let now = Date()
        var item = request(
            title: "The Reddening",
            author: "Adam Nevill",
            formats: [.ebook, .audiobook],
            status: .needsAttention,
        )
        let index = DelugeTorrentIndex(torrents: [
            torrent(
                id: "audio-1",
                name: "The Reddening Adam Nevill Audiobook.m4b",
                state: "Downloading",
                progress: 0.4,
            )
        ])
        let updated = RequestDownloadObservability.applying(item, index: index, now: now)
        #expect(updated.downloadState(for: .audiobook)?.status == .downloading)
        #expect(
            RequestDownloadObservability.suppressesAutomaticFallback(
                item: updated,
                format: .audiobook,
                now: now,
            )
        )
        #expect(updated.downloadState(for: .ebook)?.torrentID == nil)
        #expect(
            !RequestDownloadObservability.suppressesAutomaticFallback(
                item: updated,
                format: .ebook,
                now: now,
            )
        )
    }

    @Test func audiobookImportGraceDoesNotAffectEbook() {
        let now = Date()
        var item = request(
            title: "The Reddening",
            author: "Adam Nevill",
            formats: [.ebook, .audiobook],
        )
        let index = DelugeTorrentIndex(torrents: [
            torrent(
                id: "audio-1",
                name: "The Reddening Adam Nevill Audiobook.m4b",
                state: "Seeding",
                progress: 1,
                finished: true,
                completedAt: now.addingTimeInterval(-13 * 3600),
            )
        ])
        let updated = RequestDownloadObservability.applying(item, index: index, now: now)
        #expect(updated.downloadState(for: .audiobook)?.status == .waitingForImport)
        #expect(updated.status(for: .audiobook)?.status == .needsAttention)
        #expect(updated.downloadState(for: .ebook)?.status != .waitingForImport)
        #expect(updated.downloadState(for: .ebook)?.torrentID == nil)
        #expect(updated.status(for: .ebook)?.status != .needsAttention)
    }

    @Test func audiobookWithPDFBookletMatchesAudiobookOnly() {
        let item = request(
            title: "The Reddening",
            author: "Adam Nevill",
            formats: [.ebook, .audiobook],
        )
        let index = DelugeTorrentIndex(torrents: [
            torrent(
                id: "audio-pdf",
                name: "The Reddening Adam Nevill Audiobook M4B + booklet.pdf",
                state: "Downloading",
                progress: 0.5,
            )
        ])
        #expect(
            DelugeRequestMatcher.formatEvidence(
                name: "The Reddening Adam Nevill Audiobook M4B + booklet.pdf",
                savePath: nil,
            ) == .audiobook
        )
        let updated = RequestDownloadObservability.applying(item, index: index, now: Date())
        #expect(updated.downloadState(for: .audiobook)?.torrentID == "audio-pdf")
        #expect(updated.downloadState(for: .ebook)?.torrentID == nil)
    }

    @Test func mp3AudiobookWithPDFMatchesAudiobookOnly() {
        let item = request(
            title: "The Reddening",
            author: "Adam Nevill",
            formats: [.ebook, .audiobook],
        )
        let index = DelugeTorrentIndex(torrents: [
            torrent(
                id: "mp3-pdf",
                name: "The Reddening Audiobook MP3 PDF",
                state: "Downloading",
                progress: 0.3,
            )
        ])
        #expect(
            DelugeRequestMatcher.formatEvidence(
                name: "The Reddening Audiobook MP3 PDF",
                savePath: nil,
            ) == .audiobook
        )
        let updated = RequestDownloadObservability.applying(item, index: index, now: Date())
        #expect(updated.downloadState(for: .audiobook)?.torrentID == "mp3-pdf")
        #expect(updated.downloadState(for: .ebook)?.torrentID == nil)
    }

    @Test func ebookEPUBMatchesEbookOnly() {
        let item = request(
            title: "The Reddening",
            author: "Adam Nevill",
            formats: [.ebook, .audiobook],
        )
        let index = DelugeTorrentIndex(torrents: [
            torrent(
                id: "ebook-1",
                name: "The Reddening Ebook EPUB",
                state: "Downloading",
                progress: 0.2,
            )
        ])
        let updated = RequestDownloadObservability.applying(item, index: index, now: Date())
        #expect(updated.downloadState(for: .ebook)?.torrentID == "ebook-1")
        #expect(updated.downloadState(for: .audiobook)?.torrentID == nil)
    }

    @Test func genuinelyMixedStrongSignalsStayUnresolvedForBothRequest() {
        let item = request(
            title: "The Reddening",
            author: "Adam Nevill",
            formats: [.ebook, .audiobook],
        )
        let name = "The Reddening Ebook EPUB Audiobook M4B"
        #expect(DelugeRequestMatcher.formatEvidence(name: name, savePath: nil) == .mixed)
        let index = DelugeTorrentIndex(torrents: [
            torrent(id: "mixed-1", name: name, state: "Downloading", progress: 0.4)
        ])
        #expect(DelugeRequestMatcher.match(item: item, format: .ebook, index: index) == .noMatch)
        #expect(DelugeRequestMatcher.match(item: item, format: .audiobook, index: index) == .noMatch)

        let updated = RequestDownloadObservability.applying(item, index: index, now: Date())
        #expect(updated.downloadState(for: .ebook)?.torrentID == nil)
        #expect(updated.downloadState(for: .audiobook)?.torrentID == nil)
    }

    @Test func singleFormatAudiobookWithPDFBookletStillMatches() {
        let item = request(
            title: "The Reddening",
            author: "Adam Nevill",
            formats: [.audiobook],
        )
        let index = DelugeTorrentIndex(torrents: [
            torrent(
                id: "1",
                name: "The Reddening Audiobook M4B PDF",
                state: "Downloading",
                progress: 0.6,
            )
        ])
        switch DelugeRequestMatcher.match(item: item, format: .audiobook, index: index) {
            case .matched(let snap): #expect(snap.id == "1")
            default: Issue.record("expected audiobook-only match")
        }
    }

    // MARK: - Events

    @Test func downloadStartedEmitsOnce() {
        let now = Date()
        var item = request(title: "The Reddening", author: "Adam Nevill")
        item.formatStatuses = [
            RequestFormatStatus(format: .audiobook, status: .snatched, updatedAt: now)
        ]
        let index = DelugeTorrentIndex(torrents: [
            torrent(id: "1", name: "The Reddening", state: "Downloading", progress: 0.2)
        ])
        let first = RequestDownloadObservability.applying(item, index: index, now: now)
        #expect(first.downloadState(for: .audiobook)?.status == .downloading)
        #expect(first.events?.filter { $0.kind == .downloadStarted }.count == 1)

        let second = RequestDownloadObservability.applying(first, index: index, now: now.addingTimeInterval(10))
        #expect(second.events?.filter { $0.kind == .downloadStarted }.count == 1)
    }

    @Test func downloadCompletedThenWaitingForImport() {
        let now = Date()
        var item = request(title: "The Reddening", author: "Adam Nevill")
        item.formatStatuses = [
            RequestFormatStatus(format: .audiobook, status: .snatched, updatedAt: now)
        ]
        item.downloadStates = [
            RequestFormatDownloadState(
                format: .audiobook,
                status: .downloading,
                progress: 0.4,
                torrentID: "1",
                torrentName: "The Reddening",
                updatedAt: now,
            )
        ]
        let index = DelugeTorrentIndex(torrents: [
            torrent(id: "1", name: "The Reddening", state: "Seeding", progress: 1, finished: true)
        ])
        let updated = RequestDownloadObservability.applying(item, index: index, now: now)
        #expect(updated.downloadState(for: .audiobook)?.status == .waitingForImport)
        #expect(updated.events?.contains { $0.kind == .downloadCompleted } == true)
        #expect(updated.events?.contains { $0.kind == .waitingForImport } == true)
        let again = RequestDownloadObservability.applying(
            updated,
            index: index,
            now: now.addingTimeInterval(60),
        )
        #expect(again.events?.filter { $0.kind == .downloadCompleted }.count == 1)
        #expect(again.events?.filter { $0.kind == .waitingForImport }.count == 1)
    }

    // MARK: - Storyteller / grace

    @Test func waitingForImportWithinGrace() {
        let now = Date()
        var item = request(title: "The Reddening", author: "Adam Nevill")
        item.formatStatuses = [
            RequestFormatStatus(format: .audiobook, status: .snatched, updatedAt: now)
        ]
        let index = DelugeTorrentIndex(torrents: [
            torrent(
                id: "1",
                name: "The Reddening",
                state: "Seeding",
                progress: 1,
                finished: true,
                completedAt: now.addingTimeInterval(-2 * 3600),
            )
        ])
        let updated = RequestDownloadObservability.applying(item, index: index, now: now)
        #expect(updated.downloadState(for: .audiobook)?.status == .waitingForImport)
        #expect(updated.status(for: .audiobook)?.status != .needsAttention)
    }

    @Test func importGraceEscalatesAfterTwelveHours() {
        let now = Date()
        var item = request(title: "The Reddening", author: "Adam Nevill")
        item.formatStatuses = [
            RequestFormatStatus(format: .audiobook, status: .snatched, updatedAt: now)
        ]
        let index = DelugeTorrentIndex(torrents: [
            torrent(
                id: "1",
                name: "The Reddening",
                state: "Seeding",
                progress: 1,
                finished: true,
                completedAt: now.addingTimeInterval(-13 * 3600),
            )
        ])
        let updated = RequestDownloadObservability.applying(item, index: index, now: now)
        #expect(updated.status(for: .audiobook)?.status == .needsAttention)
        #expect(
            updated.attentionReason == "Downloaded, but not yet available in Storyteller."
        )
    }

    @Test func storytellerArrivalWinsOverDeluge() {
        let now = Date()
        var item = request(title: "The Reddening", author: "Adam Nevill")
        item.formatStatuses = [
            RequestFormatStatus(format: .audiobook, status: .availableInLibrary, updatedAt: now)
        ]
        item.downloadStates = [
            RequestFormatDownloadState(
                format: .audiobook,
                status: .waitingForImport,
                torrentID: "1",
                torrentName: "The Reddening",
                completedAt: now.addingTimeInterval(-20 * 3600),
                updatedAt: now,
            )
        ]
        let index = DelugeTorrentIndex(torrents: [
            torrent(id: "1", name: "The Reddening", state: "Seeding", progress: 1, finished: true)
        ])
        let updated = RequestDownloadObservability.applying(item, index: index, now: now)
        #expect(updated.status(for: .audiobook)?.status == .availableInLibrary)
        #expect(updated.downloadState(for: .audiobook)?.status == .completed)
        #expect(updated.status(for: .audiobook)?.status != .needsAttention)
    }

    // MARK: - Fallback suppression

    @Test func activeDownloadSuppressesAutomaticFallback() {
        let now = Date()
        var item = request(title: "The Reddening", author: "Adam Nevill")
        item.formatStatuses = [
            RequestFormatStatus(format: .audiobook, status: .needsAttention, updatedAt: now)
        ]
        item.downloadStates = [
            RequestFormatDownloadState(
                format: .audiobook,
                status: .downloading,
                progress: 0.4,
                torrentID: "1",
                updatedAt: now,
            )
        ]
        #expect(
            RequestDownloadObservability.suppressesAutomaticFallback(
                item: item,
                format: .audiobook,
                now: now,
            )
        )

        let decision = AutomaticFallbackPolicy.decide(
            item: item,
            history: [item],
            settings: AutomaticFallbackSettingsSnapshot(
                enabled: true,
                delay: .immediately,
            ),
            context: RequestActivityActionContext(
                lazyLibrarianEnabled: true,
                lazyLibrarianBaseURL: "https://lazy.example",
                shelfarrBaseURL: "https://shelf.example",
                lazyLibrarianHasAPIKey: true,
                shelfarrHasToken: true,
            ),
            now: now,
        )
        #expect(decision == .none)
    }

    @Test func downloaderErrorDoesNotSuppressFallback() {
        let now = Date()
        var item = request(title: "The Reddening", author: "Adam Nevill")
        item.formatStatuses = [
            RequestFormatStatus(format: .audiobook, status: .needsAttention, updatedAt: now)
        ]
        item.downloadStates = [
            RequestFormatDownloadState(
                format: .audiobook,
                status: .error,
                detail: "Deluge reported an error",
                torrentID: "1",
                updatedAt: now,
            )
        ]
        #expect(
            !RequestDownloadObservability.suppressesAutomaticFallback(
                item: item,
                format: .audiobook,
                now: now,
            )
        )
    }

    // MARK: - Chain presentation

    @Test func chainPrefersDownloadingOverSnatched() {
        let now = Date()
        var item = request(title: "The Reddening", author: "Adam Nevill")
        item.formatStatuses = [
            RequestFormatStatus(format: .audiobook, status: .snatched, updatedAt: now)
        ]
        item.downloadStates = [
            RequestFormatDownloadState(
                format: .audiobook,
                status: .downloading,
                progress: 0.4,
                torrentID: "1",
                updatedAt: now,
            )
        ]
        let chain = RequestActivityChains.build(from: [item], now: now).chains[0]
        #expect(chain.currentStatusLabel == "Downloading")
        #expect(RequestActivityChains.section(for: chain, now: now) == .inProgress)
        #expect(chain.effectiveProviderLabel == "Deluge")
    }

    @Test func historicalAttentionDoesNotWinWhileDownloading() {
        let now = Date()
        let root = request(
            id: "ll",
            title: "The Reddening",
            author: "Adam Nevill",
            status: .needsAttention,
        )
        var child = request(
            id: "shelf",
            title: "The Reddening",
            author: "Adam Nevill",
            provider: .shelfarr,
            status: .requested,
        )
        child.fallbackFromRequestID = "ll"
        child.fallbackKind = .automatic
        child.downloadStates = [
            RequestFormatDownloadState(
                format: .audiobook,
                status: .downloading,
                progress: 0.5,
                torrentID: "1",
                updatedAt: now,
            )
        ]
        let chain = RequestActivityChains.build(from: [root, child], now: now).chains[0]
        #expect(RequestActivityChains.section(for: chain, now: now) == .inProgress)
        #expect(chain.currentStatusLabel == "Downloading")
    }

    @Test func legacyRowsDecodeWithoutDownloadFields() throws {
        let json = Data(
            #"""
            {"id":"1","canonicalWorkID":"w","title":"T","author":"A","provider":"lazyLibrarian","requestedFormats":["audiobook"],"createdAt":0,"updatedAt":0,"formatStatuses":[]}
            """#.utf8
        )
        let item = try JSONDecoder().decode(RequestActivityItem.self, from: json)
        #expect(item.downloadStates == nil)
        #expect(item.title == "T")
    }

    // MARK: - Helpers

    private func request(
        id: String = "req-1",
        title: String,
        author: String,
        provider: BookRequestProviderKind = .lazyLibrarian,
        formats: [BookRequestFormat] = [.audiobook],
        status: RequestActivityStatus = .snatched,
        isbn: String? = nil,
    ) -> RequestActivityItem {
        RequestActivityItem(
            id: id,
            canonicalWorkID: "work/\(id)",
            title: title,
            author: author,
            provider: provider,
            requestedFormats: formats,
            formatStatuses: formats.map {
                RequestFormatStatus(format: $0, status: status, updatedAt: Date())
            },
            isbn: isbn,
        )
    }

    private func torrent(
        id: String = "hash",
        name: String = "Book",
        state: String,
        progress: Double,
        finished: Bool? = nil,
        error: String? = nil,
        completedAt: Date? = nil,
    ) -> DelugeTorrentSnapshot {
        DelugeTorrentSnapshot(
            id: id,
            name: name,
            state: state,
            progress: progress,
            isFinished: finished ?? (progress >= 0.999),
            error: error,
            completedAt: completedAt,
        )
    }
}

private final class DelugeScript: DelugeTransport, @unchecked Sendable {
    var throwError: URLError?
    var handler: ((String, Data, String?) -> DelugeHTTP)?

    func send(
        url: URL,
        method: String,
        body: Data,
        cookie: String?,
        timeout _: TimeInterval,
    ) async throws -> DelugeHTTP {
        if let throwError { throw throwError }
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let rpcMethod = payload?["method"] as? String ?? ""
        return handler?(rpcMethod, body, cookie)
            ?? DelugeHTTP(status: 200, body: Data(#"{"result":null,"error":null,"id":0}"#.utf8))
    }
}
