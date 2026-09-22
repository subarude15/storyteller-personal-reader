//
//  TorBoxClientTests.swift
//  SilveranTests
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit
import Testing

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("TorBox client")
struct TorBoxClientTests {
    @Test func validatesAPIKey() async {
        let transport = TorBoxScript()
        transport.handler = { url, _, headers, _, _ in
            #expect(url.path.hasSuffix("/user/me"))
            #expect(headers["Authorization"] == "Bearer test-key")
            return TorBoxHTTP(
                status: 200,
                body: Data(#"{"success":true,"error":null,"detail":"ok","data":{"id":1}}"#.utf8),
            )
        }
        let client = TorBoxClient(transport: transport)
        #expect(await client.testConnection(apiKey: "test-key") == .ok)
    }

    @Test func invalidAPIKeyMapsToRejectedMessage() async {
        let transport = TorBoxScript()
        transport.handler = { _, _, _, _, _ in
            TorBoxHTTP(
                status: 403,
                body: Data(
                    #"{"success":false,"error":"BAD_TOKEN","detail":"Invalid token","data":null}"#
                        .utf8
                ),
            )
        }
        let client = TorBoxClient(transport: transport)
        #expect(await client.testConnection(apiKey: "bad") == .invalidAPIKey)
        #expect(
            TorBoxConnection.invalidAPIKey.message == "TorBox rejected this API key."
        )
    }

    @Test func unauthorizedAndRateLimitedAndNetworkFailures() async {
        let transport = TorBoxScript()
        transport.handler = { _, _, _, _, _ in TorBoxHTTP(status: 401, body: Data()) }
        #expect(await TorBoxClient(transport: transport).testConnection(apiKey: "k") == .unauthorized)

        transport.handler = { _, _, _, _, _ in TorBoxHTTP(status: 429, body: Data()) }
        #expect(await TorBoxClient(transport: transport).testConnection(apiKey: "k") == .rateLimited)

        transport.handler = { _, _, _, _, _ in TorBoxHTTP(status: 503, body: Data()) }
        #expect(
            await TorBoxClient(transport: transport).testConnection(apiKey: "k") == .serverUnavailable
        )

        transport.handler = { _, _, _, _, _ in throw URLError(.notConnectedToInternet) }
        #expect(
            await TorBoxClient(transport: transport).testConnection(apiKey: "k") == .cannotReachServer
        )

        transport.handler = { _, _, _, _, _ in throw URLError(.timedOut) }
        #expect(await TorBoxClient(transport: transport).testConnection(apiKey: "k") == .timeout)

        #expect(await TorBoxClient(transport: transport).testConnection(apiKey: "") == .missingAPIKey)
    }

    @Test func addsMagnetAndParsesCreateResponse() async throws {
        let transport = TorBoxScript()
        transport.handler = { url, method, _, body, contentType in
            #expect(method == "POST")
            #expect(url.path.hasSuffix("/torrents/createtorrent"))
            #expect(contentType?.contains("multipart/form-data") == true)
            let text = String(data: body ?? Data(), encoding: .utf8) ?? ""
            #expect(text.contains("name=\"magnet\""))
            #expect(text.contains("magnet:?xt=urn:btih:"))
            return TorBoxHTTP(
                status: 200,
                body: Data(
                    #"{"success":true,"error":null,"detail":"ok","data":{"torrent_id":42,"hash":"abc","auth_id":"auth"}}"#
                        .utf8
                ),
            )
        }
        let client = TorBoxClient(transport: transport)
        let result = try await client.addMagnet(
            apiKey: "key",
            magnet: "magnet:?xt=urn:btih:ABCDEF0123456789ABCDEF0123456789ABCDEF01&dn=Sample",
        )
        #expect(result.torrentID == 42)
        #expect(result.hash == "abc")
        #expect(result.authID == "auth")
        #expect(result.jobID == "42")
    }

    @Test func uploadsTorrentFileAsMultipart() async throws {
        let transport = TorBoxScript()
        transport.handler = { _, _, _, body, contentType in
            #expect(contentType?.contains("multipart/form-data") == true)
            let text = String(data: body ?? Data(), encoding: .utf8) ?? ""
            #expect(text.contains("name=\"file\""))
            #expect(text.contains("filename=\"book.torrent\""))
            #expect(text.contains("d8:announce"))
            return TorBoxHTTP(
                status: 200,
                body: Data(
                    #"{"success":true,"error":null,"detail":"ok","data":{"torrent_id":9}}"#.utf8
                ),
            )
        }
        let client = TorBoxClient(transport: transport)
        let result = try await client.addTorrentFile(
            apiKey: "key",
            data: Data("d8:announce13:http://a.come".utf8),
            filename: "book.torrent",
        )
        #expect(result.torrentID == 9)
    }

    @Test func decodesCachedReadyTorrent() async throws {
        let transport = TorBoxScript()
        transport.handler = { _, _, _, _, _ in
            TorBoxHTTP(
                status: 200,
                body: Data(
                    """
                    {"success":true,"error":null,"detail":"ok","data":{
                      "id": 7,
                      "name": "The Hobbit",
                      "hash": "deadbeef",
                      "auth_id": "a1",
                      "download_state": "cached",
                      "download_finished": true,
                      "download_present": true,
                      "progress": 1,
                      "size": 2800000000,
                      "files": [{"id":1,"name":"hobbit.epub","size":12345,"mimetype":"application/epub+zip"}]
                    }}
                    """.utf8
                ),
            )
        }
        let info = try await TorBoxClient(transport: transport).getTorrent(apiKey: "key", id: "7")
        #expect(info.isDownloadReady)
        #expect(TorBoxStatusMapping.jobStatus(for: info) == .ready)
        #expect(TorBoxStatusMapping.manualStatus(for: info) == .ready)
        let job = TorBoxStatusMapping.torrentJob(from: info)
        #expect(job.provider == .torbox)
        #expect(job.status == .ready)
        #expect(job.files.count == 1)
        #expect(job.providerAuthID == "a1")
    }

    @Test func mapsDownloadingAndFailedStates() {
        let downloading = TorBoxTorrentInfo(
            id: 1,
            name: "A",
            hash: "h",
            downloadState: "downloading",
            downloadFinished: false,
            downloadPresent: false,
            progress: 0.4,
        )
        #expect(TorBoxStatusMapping.jobStatus(for: downloading) == .downloading)

        let failed = TorBoxTorrentInfo(
            id: 2,
            name: "B",
            hash: "h",
            downloadState: "error",
            downloadFinished: false,
            downloadPresent: false,
            progress: 0,
        )
        #expect(TorBoxStatusMapping.jobStatus(for: failed) == .failed)
    }

    @Test func instantReadyAfterCreateDoesNotStickOnSubmitted() {
        var job = ManualDownloadJob(
            title: "Magnet abcd",
            author: "",
            sourceHost: "torbox",
            backend: .torbox,
            mediaType: .ebook,
            destination: "/volume1/media/books/books",
            backendJobID: "7",
            status: .submitted,
        )
        let info = TorBoxTorrentInfo(
            id: 7,
            name: "The Hobbit",
            hash: "deadbeef",
            authID: "a1",
            downloadState: "cached",
            downloadFinished: true,
            downloadPresent: true,
            progress: 1,
            size: 100,
            files: [TorBoxTorrentFile(id: 1, name: "hobbit.epub", size: 100)],
        )
        job = TorBoxStatusMapping.apply(info, to: job)
        #expect(job.status == .ready)
        #expect(job.title == "The Hobbit")
        #expect(job.providerFiles?.count == 1)
        #expect(job.providerAuthID == "a1")
        #expect(job.providerInfoHash == "deadbeef")
    }

    @Test func deleteTorrentPostsControlOperation() async throws {
        let transport = TorBoxScript()
        transport.handler = { url, method, _, body, contentType in
            #expect(method == "POST")
            #expect(url.path.hasSuffix("/torrents/controltorrent"))
            #expect(contentType == "application/json")
            let obj = try JSONSerialization.jsonObject(with: body!) as? [String: Any]
            #expect(obj?["torrent_id"] as? Int == 42)
            #expect(obj?["operation"] as? String == "delete")
            return TorBoxHTTP(
                status: 200,
                body: Data(#"{"success":true,"error":null,"detail":"ok","data":null}"#.utf8),
            )
        }
        try await TorBoxClient(transport: transport).deleteTorrent(apiKey: "key", id: "42")
    }

    @Test func redactsAuthorizationAndTokenQuery() {
        #expect(TorBoxClient.redactAuthorizationHeader("Bearer secret-token") == "Bearer ••••••••")
        let url = URL(
            string: "https://api.torbox.app/v1/api/torrents/requestdl?token=super-secret&file_id=1"
        )!
        let redacted = TorBoxClient.redactSensitiveURL(url)
        #expect(redacted.contains("token=••••••••"))
        #expect(!redacted.contains("super-secret"))
    }

    @Test func rejectsMalformedMagnetWithoutNetworking() async {
        let transport = TorBoxScript()
        transport.handler = { _, _, _, _, _ in
            Issue.record("network should not be called")
            return TorBoxHTTP(status: 500, body: Data())
        }
        do {
            _ = try await TorBoxClient(transport: transport).addMagnet(apiKey: "key", magnet: "nope")
            Issue.record("expected malformed magnet")
        } catch let error as TorBoxClientError {
            #expect(error == .malformedMagnet)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

@Suite("TorBox provider selection")
struct TorBoxProviderSelectionTests {
    @Test func torboxIsSelectedWhenEnabled() {
        let settings = NASDownloadSettingsSnapshot(
            torrentClient: .torbox,
            torboxEnabled: true,
            audiobookFolder: "/a",
            ebookFolder: "/e",
        )
        #expect(NASBackendRouting.backend(transport: .magnet, settings: settings) == .success(.torbox))
        #expect(NASBackendRouting.backend(transport: .torrent, settings: settings) == .success(.torbox))
    }

    @Test func torboxDisabledFailsCleanly() {
        let settings = NASDownloadSettingsSnapshot(torrentClient: .torbox, torboxEnabled: false)
        #expect(
            NASBackendRouting.backend(transport: .magnet, settings: settings)
                == .failure(.backendNotConfigured(.torbox))
        )
    }

    @Test func existingDelugeSelectionStillWorks() {
        let settings = NASDownloadSettingsSnapshot(
            torrentClient: .deluge,
            delugeBaseURL: "http://deluge.example:8112",
        )
        #expect(NASBackendRouting.backend(transport: .magnet, settings: settings) == .success(.deluge))
    }

    @Test func readyJobsBucketAsRecentAndAreNotActive() {
        let ready = ManualDownloadJob(
            title: "Ready",
            author: "",
            sourceHost: "torbox",
            backend: .torbox,
            mediaType: .ebook,
            destination: "/e",
            status: .ready,
        )
        #expect(ready.status.isActive == false)
        let buckets = ManualDownloadBuckets.partition([ready])
        #expect(buckets.recent.count == 1)
        #expect(buckets.active.isEmpty)
    }

    @Test func failedTorBoxJobCanRetry() {
        let failed = ManualDownloadJob(
            title: "Fail",
            author: "",
            sourceURL: "magnet:?xt=urn:btih:ABCDEF0123456789ABCDEF0123456789ABCDEF01",
            sourceHost: "torbox",
            backend: .torbox,
            mediaType: .ebook,
            destination: "/e",
            status: .failed,
            lastError: "Could not retrieve torrent metadata",
        )
        #expect(failed.canRetryTorrentNow)
        #expect(failed.retryAction == .retryTorrent)
    }
}

@Suite("TorBox acquisition handoff")
struct TorBoxAcquisitionHandoffTests {
    @Test func magnetSubmissionCreatesJobAndHandlesCachedReady() async throws {
        let transport = TorBoxScript()
        transport.handler = { url, method, _, body, _ in
            if url.path.hasSuffix("/torrents/createtorrent") {
                return TorBoxHTTP(
                    status: 200,
                    body: Data(
                        #"{"success":true,"error":null,"detail":"ok","data":{"torrent_id":11,"hash":"abc"}}"#
                            .utf8
                    ),
                )
            }
            if url.path.hasSuffix("/torrents/mylist") {
                return TorBoxHTTP(
                    status: 200,
                    body: Data(
                        """
                        {"success":true,"error":null,"detail":"ok","data":{
                          "id":11,"name":"Hail Mary","hash":"abc",
                          "download_state":"cached","download_finished":true,
                          "download_present":true,"progress":1,"size":50,
                          "files":[{"id":1,"name":"book.epub","size":50}]
                        }}
                        """.utf8
                    ),
                )
            }
            Issue.record("unexpected \(method) \(url)")
            return TorBoxHTTP(status: 500, body: Data())
        }
        let store = RecordingManualDownloadJobStore()
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: NASDownloadSettingsSnapshot(
                        torrentClient: .torbox,
                        torboxEnabled: true,
                        ebookFolder: "/volume1/media/books/books",
                    ),
                    credentials: NASBackendCredentials(torboxAPIKey: "key"),
                )
            ),
            torbox: TorBoxClient(transport: transport),
            jobs: store,
        )
        let candidate = ManualAcquisitionCandidate(
            sourceURL: URL(
                string: "magnet:?xt=urn:btih:ABCDEF0123456789ABCDEF0123456789ABCDEF01&dn=Hail%20Mary"
            )!,
            detectedType: .magnet,
            sourceHost: "manual",
            bookMetadata: ManualSearchBookContext(
                title: "Hail Mary",
                authors: [],
                requestedMediaType: .ebook,
            ),
        )
        let result = await handler.handle(candidate)
        guard case .submitted = result else {
            Issue.record("expected submitted, got \(result)")
            return
        }
        let jobs = await store.allJobs()
        #expect(jobs.count == 1)
        #expect(jobs[0].backend == .torbox)
        #expect(jobs[0].backendJobID == "11")
        #expect(jobs[0].status == .ready)
        #expect(jobs[0].providerFiles?.first?.name == "book.epub")
    }

    @Test func deleteRemovesRemoteTorBoxTorrent() async throws {
        let transport = TorBoxScript()
        var deleted = false
        transport.handler = { url, _, _, body, _ in
            if url.path.hasSuffix("/torrents/controltorrent") {
                deleted = true
                let obj = try JSONSerialization.jsonObject(with: body!) as? [String: Any]
                #expect(obj?["operation"] as? String == "delete")
                return TorBoxHTTP(
                    status: 200,
                    body: Data(#"{"success":true,"error":null,"detail":"ok","data":null}"#.utf8),
                )
            }
            return TorBoxHTTP(status: 404, body: Data())
        }
        let store = RecordingManualDownloadJobStore()
        let job = ManualDownloadJob(
            title: "X",
            author: "",
            sourceHost: "torbox",
            backend: .torbox,
            mediaType: .ebook,
            destination: "/e",
            backendJobID: "99",
            status: .ready,
        )
        await store.record(job)
        let refresh = ManualDownloadStatusRefresh(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: NASDownloadSettingsSnapshot(torrentClient: .torbox, torboxEnabled: true),
                    credentials: NASBackendCredentials(torboxAPIKey: "key"),
                )
            ),
            torbox: TorBoxClient(transport: transport),
            jobs: store,
        )
        await refresh.deleteRemoteIfNeeded(job: job)
        #expect(deleted)
    }
}

private final class TorBoxScript: TorBoxTransport, @unchecked Sendable {
    var handler:
        @Sendable (URL, String, [String: String], Data?, String?) async throws -> TorBoxHTTP = {
            _, _, _, _, _ in
            TorBoxHTTP(status: 500, body: Data())
        }

    func send(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        contentType: String?,
        timeout: TimeInterval,
    ) async throws -> TorBoxHTTP {
        _ = timeout
        return try await handler(url, method, headers, body, contentType)
    }
}
