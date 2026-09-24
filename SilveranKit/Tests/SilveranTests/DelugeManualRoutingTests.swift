//
//  DelugeManualRoutingTests.swift
//  SilveranTests
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit
import Testing

@Suite("Deluge manual routing")
struct DelugeManualRoutingTests {
    private let incoming = NASDownloadSettingsSnapshot.defaultDelugeIncomingFolder
    private let completed = NASDownloadSettingsSnapshot.defaultDelugeCompletedFolder
    private let ebookFinal = "/volume1/media/books/books"
    private let audioFinal = "/volume1/media/books/audiobooks"

    @Test func incompleteInIncomingDoesNotMove() {
        let decision = DelugeManualRouting.evaluate(
            snapshot: torrent(progress: 0.4, finished: false, path: incoming),
            finalDestination: ebookFinal,
            incomingFolder: incoming,
            completedFolder: completed,
        )
        #expect(decision == .observe(.downloading))
    }

    @Test func completeStillInIncomingDoesNotMove() {
        let decision = DelugeManualRouting.evaluate(
            snapshot: torrent(progress: 1, finished: true, path: incoming, state: "Seeding"),
            finalDestination: ebookFinal,
            incomingFolder: incoming,
            completedFolder: completed,
        )
        #expect(decision == .waitForDelugeCompleted(.delugeFinishing))
    }

    @Test func completeInCompletedRequestsMove() {
        let decision = DelugeManualRouting.evaluate(
            snapshot: torrent(progress: 1, finished: true, path: completed, state: "Seeding"),
            finalDestination: ebookFinal,
            incomingFolder: incoming,
            completedFolder: completed,
        )
        #expect(decision == .requestMove)
    }

    @Test func alreadyAtFinalDestinationIsIdempotentComplete() {
        let decision = DelugeManualRouting.evaluate(
            snapshot: torrent(progress: 1, finished: true, path: ebookFinal, state: "Seeding"),
            finalDestination: ebookFinal,
            incomingFolder: incoming,
            completedFolder: completed,
        )
        #expect(decision == .alreadyAtDestination)
    }

    @Test func ebookSelectionUsesConfiguredEbookDestination() async {
        let jobs = RecordingManualDownloadJobStore()
        let transport = DelugeRouteScript(savePath: completed)
        var settings = NASDownloadSettingsSnapshot(
            torrentClient: .deluge,
            delugeBaseURL: "http://deluge.example:8112",
            audiobookFolder: audioFinal,
            ebookFolder: ebookFinal,
        )
        settings.delugeIncomingFolder = incoming
        settings.delugeCompletedFolder = completed
        let refresh = ManualDownloadStatusRefresh(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: settings,
                    credentials: NASBackendCredentials(delugePassword: "secret"),
                )
            ),
            deluge: DelugeWebClient(transport: transport),
            jobs: jobs,
        )
        await jobs.record(
            ManualDownloadJob(
                title: "Dune",
                author: "Frank Herbert",
                sourceURL: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567",
                sourceHost: "magnet",
                backend: .deluge,
                mediaType: .ebook,
                destination: ebookFinal,
                backendJobID: "0123456789abcdef0123456789abcdef01234567",
                status: .downloading,
                progress: 1,
            )
        )
        let updated = await refresh.refresh()
        #expect(transport.moveDestinations == [ebookFinal])
        #expect(updated[0].status == .routing)
        #expect(updated[0].mediaType == .ebook)
        #expect(updated[0].destination == ebookFinal)
    }

    @Test func audiobookSelectionUsesConfiguredAudiobookDestination() async {
        let jobs = RecordingManualDownloadJobStore()
        let transport = DelugeRouteScript(savePath: completed)
        var settings = NASDownloadSettingsSnapshot(
            torrentClient: .deluge,
            delugeBaseURL: "http://deluge.example:8112",
            audiobookFolder: audioFinal,
            ebookFolder: ebookFinal,
        )
        settings.delugeIncomingFolder = incoming
        settings.delugeCompletedFolder = completed
        let refresh = ManualDownloadStatusRefresh(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: settings,
                    credentials: NASBackendCredentials(delugePassword: "secret"),
                )
            ),
            deluge: DelugeWebClient(transport: transport),
            jobs: jobs,
        )
        await jobs.record(
            ManualDownloadJob(
                title: "Dune",
                author: "Frank Herbert",
                sourceURL: "magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                sourceHost: "magnet",
                backend: .deluge,
                mediaType: .audiobook,
                destination: audioFinal,
                backendJobID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                status: .readyToRoute,
                progress: 1,
            )
        )
        let updated = await refresh.refresh()
        #expect(transport.moveDestinations == [audioFinal])
        #expect(updated[0].status == .routing)
        #expect(updated[0].destination == audioFinal)
    }

    @Test func successfulMoveThenPathUpdateMarksComplete() async {
        let jobs = RecordingManualDownloadJobStore()
        let transport = DelugeRouteScript(savePath: completed)
        var settings = NASDownloadSettingsSnapshot(
            torrentClient: .deluge,
            delugeBaseURL: "http://deluge.example:8112",
            ebookFolder: ebookFinal,
        )
        settings.delugeIncomingFolder = incoming
        settings.delugeCompletedFolder = completed
        let refresh = ManualDownloadStatusRefresh(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: settings,
                    credentials: NASBackendCredentials(delugePassword: "secret"),
                )
            ),
            deluge: DelugeWebClient(transport: transport),
            jobs: jobs,
        )
        let hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        await jobs.record(
            ManualDownloadJob(
                title: "Book",
                author: "Author",
                sourceHost: "magnet",
                backend: .deluge,
                mediaType: .ebook,
                destination: ebookFinal,
                backendJobID: hash,
                status: .routing,
                progress: 1,
            )
        )
        // First refresh: still at completed → request move again is fine (idempotent path check after).
        // Point save path at final so reconciliation completes without another move.
        transport.savePath = ebookFinal
        let updated = await refresh.refresh()
        #expect(updated[0].status == .complete)
        #expect(transport.moveDestinations.isEmpty)
    }

    @Test func moveFailureMarksFailedWithoutDeleting() async {
        let jobs = RecordingManualDownloadJobStore()
        let transport = DelugeRouteScript(savePath: completed, moveShouldFail: true)
        var settings = NASDownloadSettingsSnapshot(
            torrentClient: .deluge,
            delugeBaseURL: "http://deluge.example:8112",
            ebookFolder: ebookFinal,
        )
        settings.delugeIncomingFolder = incoming
        settings.delugeCompletedFolder = completed
        let refresh = ManualDownloadStatusRefresh(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: settings,
                    credentials: NASBackendCredentials(delugePassword: "secret"),
                )
            ),
            deluge: DelugeWebClient(transport: transport),
            jobs: jobs,
        )
        let hash = "cccccccccccccccccccccccccccccccccccccccc"
        await jobs.record(
            ManualDownloadJob(
                title: "Book",
                author: "Author",
                sourceHost: "magnet",
                backend: .deluge,
                mediaType: .ebook,
                destination: ebookFinal,
                backendJobID: hash,
                status: .downloading,
                progress: 1,
            )
        )
        let updated = await refresh.refresh()
        #expect(updated[0].status == .failed)
        #expect(updated[0].lastError?.contains("move_storage") == true)
        #expect(updated[0].hasReachedDelugeFinalRouting)
        #expect(updated[0].canRetryRoutingNow)
        #expect(transport.moveDestinations == [ebookFinal])
    }

    @Test func moveStorageRPCEncoding() async throws {
        let transport = DelugeRouteScript(savePath: completed)
        let client = DelugeWebClient(transport: transport)
        try await client.moveStorage(
            baseURL: "http://deluge.example:8112",
            password: "secret",
            torrentIDs: ["dddddddddddddddddddddddddddddddddddddddd"],
            destination: ebookFinal,
        )
        #expect(transport.lastMoveParams?.ids == ["dddddddddddddddddddddddddddddddddddddddd"])
        #expect(transport.lastMoveParams?.destination == ebookFinal)
        #expect(transport.lastMoveMethod == "core.move_storage")
    }

    @Test func statusRefreshResumesPendingRoutingAfterRelaunch() async {
        let jobs = RecordingManualDownloadJobStore()
        let transport = DelugeRouteScript(savePath: completed)
        var settings = NASDownloadSettingsSnapshot(
            torrentClient: .deluge,
            delugeBaseURL: "http://deluge.example:8112",
            ebookFolder: ebookFinal,
        )
        settings.delugeIncomingFolder = incoming
        settings.delugeCompletedFolder = completed
        let refresh = ManualDownloadStatusRefresh(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: settings,
                    credentials: NASBackendCredentials(delugePassword: "secret"),
                )
            ),
            deluge: DelugeWebClient(transport: transport),
            jobs: jobs,
        )
        // Persisted job as if the app was killed while waiting to route.
        await jobs.record(
            ManualDownloadJob(
                title: "Persisted",
                author: "Author",
                sourceHost: "magnet",
                backend: .deluge,
                mediaType: .ebook,
                destination: ebookFinal,
                backendJobID: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
                status: .submitted,
                progress: 1,
            )
        )
        let updated = await refresh.refresh()
        #expect(updated[0].status == .routing)
        #expect(transport.moveDestinations == [ebookFinal])
    }

    @Test func hundredPercentInIncomingNeverRequestsMove() async {
        let jobs = RecordingManualDownloadJobStore()
        let transport = DelugeRouteScript(savePath: incoming)
        var settings = NASDownloadSettingsSnapshot(
            torrentClient: .deluge,
            delugeBaseURL: "http://deluge.example:8112",
            ebookFolder: ebookFinal,
        )
        settings.delugeIncomingFolder = incoming
        settings.delugeCompletedFolder = completed
        let refresh = ManualDownloadStatusRefresh(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: settings,
                    credentials: NASBackendCredentials(delugePassword: "secret"),
                )
            ),
            deluge: DelugeWebClient(transport: transport),
            jobs: jobs,
        )
        await jobs.record(
            ManualDownloadJob(
                title: "Wait",
                author: "Author",
                sourceHost: "magnet",
                backend: .deluge,
                mediaType: .ebook,
                destination: ebookFinal,
                backendJobID: "ffffffffffffffffffffffffffffffffffffffff",
                status: .downloading,
                progress: 1,
            )
        )
        let updated = await refresh.refresh()
        #expect(updated[0].status == .delugeFinishing)
        #expect(transport.moveDestinations.isEmpty)
    }

    private func torrent(
        progress: Double,
        finished: Bool,
        path: String?,
        state: String = "Downloading",
    ) -> DelugeTorrentSnapshot {
        DelugeTorrentSnapshot(
            id: "hash",
            name: "Book",
            state: state,
            progress: progress,
            savePath: path,
            isFinished: finished,
        )
    }
}

private final class DelugeRouteScript: DelugeTransport, @unchecked Sendable {
    var savePath: String
    var moveShouldFail: Bool
    var moveDestinations: [String] = []
    var lastMoveMethod: String?
    var lastMoveParams: (ids: [String], destination: String)?

    init(savePath: String, moveShouldFail: Bool = false) {
        self.savePath = savePath
        self.moveShouldFail = moveShouldFail
    }

    func send(
        url _: URL,
        method _: String,
        body: Data,
        cookie _: String?,
        timeout _: TimeInterval,
    ) async throws -> DelugeHTTP {
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let rpc = payload?["method"] as? String ?? ""
        switch rpc {
            case "auth.login":
                return DelugeHTTP(
                    status: 200,
                    body: Data(#"{"result":true,"error":null,"id":1}"#.utf8),
                    setCookie: "_session_id=abc; Path=/",
                )
            case "web.connected":
                return DelugeHTTP(status: 200, body: Data(#"{"result":true,"error":null,"id":2}"#.utf8))
            case "core.get_torrents_status":
                let pathJSON = savePath
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let hashes = [
                    "0123456789abcdef0123456789abcdef01234567",
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                    "cccccccccccccccccccccccccccccccccccccccc",
                    "dddddddddddddddddddddddddddddddddddddddd",
                    "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
                    "ffffffffffffffffffffffffffffffffffffffff",
                    "hash",
                ]
                var entries: [String] = []
                for hash in hashes {
                    entries.append(
                        """
                        "\(hash)":{"name":"Book","state":"Seeding","progress":100,"download_payload_rate":0,"eta":0,"save_path":"\(pathJSON)","total_size":10,"total_done":10,"time_added":1700000000,"completed_time":1700000001,"hash":"\(hash)","is_finished":true}
                        """
                    )
                }
                let multi = "{\"result\":{\(entries.joined(separator: ","))},\"error\":null,\"id\":6}"
                return DelugeHTTP(status: 200, body: Data(multi.utf8))
            case "core.move_storage":
                lastMoveMethod = rpc
                let params = payload?["params"] as? [Any]
                let ids = params?[0] as? [String] ?? []
                let destination = params?[1] as? String ?? ""
                lastMoveParams = (ids, destination)
                moveDestinations.append(destination)
                if moveShouldFail {
                    return DelugeHTTP(
                        status: 200,
                        body: Data(
                            #"{"result":null,"error":{"message":"Unable to move","code":1},"id":12}"#
                                .utf8
                        ),
                    )
                }
                return DelugeHTTP(
                    status: 200,
                    body: Data(#"{"result":true,"error":null,"id":12}"#.utf8),
                )
            default:
                _ = body
                return DelugeHTTP(status: 200, body: Data(#"{"result":null,"error":null,"id":0}"#.utf8))
        }
    }
}
