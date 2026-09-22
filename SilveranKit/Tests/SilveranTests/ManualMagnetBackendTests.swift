//
//  ManualMagnetBackendTests.swift
//  SilveranTests
//
//  Manual magnet backend selection. Network is stubbed; nothing contacts TorBoxarr.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit
import Testing

@Suite("Manual magnet backend")
struct ManualMagnetBackendTests {
    private let password = "s3cret-bridge"
    private let magnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Last+Days"
    private let otherMagnet = "magnet:?xt=urn:btih:abcdefabcdefabcdefabcdefabcdefabcdefabcd&dn=Other"

    @Test func torBoxIsTheFreshDefault() {
        let defaults = UserDefaults(suiteName: "magnet-backend-\(UUID().uuidString)")!
        #expect(ManualMagnetBackendSettings.backend(in: defaults) == .torBox)
        #expect(ManualMagnetBackendSettings.host(in: defaults) == TorBoxarrConnectionSettings.defaultHost)
        #expect(ManualMagnetBackendSettings.port(in: defaults) == TorBoxarrConnectionSettings.defaultPort)
        #expect(ManualMagnetBackendSettings.username(in: defaults) == TorBoxarrConnectionSettings.defaultUsername)
        let settings = TorBoxarrConnectionSettings.current(in: defaults)
        #expect(settings.baseURL == "http://192.168.1.2:8085")
    }

    @Test func backendSelectionRestores() {
        let defaults = UserDefaults(suiteName: "magnet-backend-\(UUID().uuidString)")!
        ManualMagnetBackendSettings.setBackend(.deluge, in: defaults)
        #expect(ManualMagnetBackendSettings.backend(in: defaults) == .deluge)
        ManualMagnetBackendSettings.setBackend(.torBox, in: defaults)
        #expect(ManualMagnetBackendSettings.backend(in: defaults) == .torBox)
    }

    @Test func connectionTestLogsInAndReadsVersionWithoutAdding() async {
        let script = BridgeScript()
        let client = QBittorrentClient(transport: script)
        let status = await TorBoxarrProbe.testConnection(
            settings: TorBoxarrConnectionSettings(),
            password: password,
            client: client,
        )
        #expect(status == .ok)
        #expect(status.message == "Connected")
        #expect(!status.message.contains(password))
        let paths = script.paths
        #expect(paths.contains { $0.hasSuffix("/api/v2/auth/login") })
        #expect(paths.contains { $0.hasSuffix("/api/v2/app/version") })
        #expect(!paths.contains { $0.contains("/torrents/add") })
        let login = script.bodies.first { $0.contains("username=") } ?? ""
        #expect(login.contains("username=admin"))
        #expect(login.contains("password=\(password)"))
    }

    @Test func torBoxSubmissionUsesQBittorrentAdd() async {
        let script = BridgeScript()
        let (handler, jobs) = makeHandler(script: script)
        let result = await handler.handle(candidate(magnet, media: .ebook), manualBackend: .torBox)
        #expect(result.message == "Accepted by TorBox")
        #expect(result.isSubmitted)
        #expect(!result.message.contains(password))
        let paths = script.paths
        #expect(paths.contains { $0 == "/api/v2/auth/login" })
        #expect(paths.contains { $0 == "/api/v2/torrents/add" })
        let add = script.bodies.first { $0.contains("urls=") } ?? ""
        #expect(add.removingPercentEncoding?.contains(magnet) == true)
        #expect(script.savePaths == [TorBoxarrConnectionSettings.completedFolder])
        #expect(jobs.jobs.count == 1)
        #expect(jobs.jobs[0].backend == .torbox)
        #expect(jobs.jobs[0].viaTorBoxarr == true)
        #expect(jobs.jobs[0].status == .submitted)
        #expect(jobs.jobs[0].destination == "/volume1/media/books/books")
        #expect(jobs.jobs[0].destination != TorBoxarrConnectionSettings.completedFolder)
    }

    @Test func authFailureDoesNotExposeThePassword() async {
        let script = BridgeScript()
        script.loginBody = "Fails."
        let (handler, _) = makeHandler(script: script)
        let result = await handler.handle(candidate(magnet, media: .ebook), manualBackend: .torBox)
        #expect(result.message.contains("credential"))
        #expect(!result.message.contains(password))
        #expect(!result.message.contains("Fails."))
    }

    @Test func networkFailureIsDistinct() async {
        let script = BridgeScript()
        script.error = URLError(.cannotConnectToHost)
        let (handler, _) = makeHandler(script: script)
        let result = await handler.handle(candidate(magnet, media: .ebook), manualBackend: .torBox)
        #expect(result.message.contains("reach"))
        #expect(!result.message.contains(password))
    }

    @Test func rejectedMagnetDoesNotEchoTheServerBody() async {
        let script = BridgeScript()
        script.addBody = "Fails. \(password)"
        let (handler, _) = makeHandler(script: script)
        let result = await handler.handle(candidate(magnet, media: .ebook), manualBackend: .torBox)
        #expect(result.message.contains("rejected"))
        #expect(!result.message.contains(password))
    }

    @Test func missingPasswordIsNotConfiguredAndDoesNotCallTheNetwork() async {
        let script = BridgeScript()
        let (handler, _) = makeHandler(script: script, password: "")
        let result = await handler.handle(candidate(magnet, media: .ebook), manualBackend: .torBox)
        #expect(result.message.contains("not configured"))
        #expect(script.paths.isEmpty)
    }

    @Test func invalidMagnetIsRejectedBeforeSubmission() async {
        let script = BridgeScript()
        let (handler, _) = makeHandler(script: script)
        let result = await handler.handle(
            candidate("magnet:?dn=Nope", media: .ebook),
            manualBackend: .torBox,
        )
        #expect(result.message.contains("malformed"))
        #expect(script.paths.isEmpty)
    }

    @Test func delugeSelectionStillUsesTheDelugeClient() async {
        let script = BridgeScript()
        let deluge = DelugeMagnetScript()
        let (handler, jobs) = makeHandler(script: script, deluge: deluge)
        let result = await handler.handle(candidate(magnet, media: .ebook), manualBackend: .deluge)
        #expect(result.isSubmitted)
        #expect(result.message == "The download was added to Deluge.")
        #expect(deluge.magnets == [magnet])
        #expect(deluge.locations == ["/volume1/data/torrents/incoming"])
        #expect(script.paths.isEmpty)
        #expect(jobs.jobs[0].backend == .deluge)
        #expect(jobs.jobs[0].viaTorBoxarr == nil)
        #expect(jobs.jobs[0].destination == "/volume1/media/books/books")
    }

    @Test func changingBackendDoesNotChangeTheFinalFolder() async {
        let torboxScript = BridgeScript()
        let (torboxHandler, torboxJobs) = makeHandler(script: torboxScript)
        _ = await torboxHandler.handle(candidate(magnet, media: .audiobook), manualBackend: .torBox)

        let deluge = DelugeMagnetScript()
        let (delugeHandler, delugeJobs) = makeHandler(script: BridgeScript(), deluge: deluge)
        _ = await delugeHandler.handle(candidate(otherMagnet, media: .audiobook), manualBackend: .deluge)

        #expect(torboxJobs.jobs[0].destination == "/volume1/media/books/audiobooks")
        #expect(delugeJobs.jobs[0].destination == torboxJobs.jobs[0].destination)
        #expect(torboxScript.savePaths == [TorBoxarrConnectionSettings.completedFolder])
        #expect(deluge.locations == ["/volume1/data/torrents/incoming"])
    }

    @Test func retryUpdatesTheSameHistoryRow() async {
        let script = BridgeScript()
        script.loginBody = "Fails."
        let deluge = DelugeMagnetScript()
        let (handler, jobs) = makeHandler(script: script, deluge: deluge)
        let failed = await handler.handle(candidate(magnet, media: .ebook), manualBackend: .torBox)
        #expect(!failed.isSubmitted)
        #expect(jobs.jobs.count == 1)
        let originalID = jobs.jobs[0].id
        #expect(jobs.jobs[0].status == .failed)

        let retried = await handler.retryDownload(job: jobs.jobs[0], manualBackend: .deluge)
        #expect(retried.isSubmitted)
        #expect(jobs.jobs.count == 1)
        #expect(jobs.jobs[0].id == originalID)
        #expect(jobs.jobs[0].backend == .deluge)
        #expect(jobs.jobs[0].destination == "/volume1/media/books/books")
        #expect(deluge.magnets == [magnet])
    }

    @Test func retryTorBoxarrDoesNotCreateASecondRow() async {
        let script = BridgeScript()
        script.loginBody = "Fails."
        let (handler, jobs) = makeHandler(script: script)
        let failed = await handler.handle(candidate(magnet, media: .ebook), manualBackend: .torBox)
        #expect(!failed.isSubmitted)
        #expect(jobs.jobs.count == 1)
        let originalID = jobs.jobs[0].id
        #expect(jobs.jobs[0].viaTorBoxarr == true)

        script.loginBody = "Ok."
        let retried = await handler.retryDownload(job: jobs.jobs[0], manualBackend: .torBox)
        #expect(retried.isSubmitted)
        #expect(jobs.jobs.count == 1)
        #expect(jobs.jobs[0].id == originalID)
        #expect(jobs.jobs[0].backend == .torbox)
        #expect(jobs.jobs[0].viaTorBoxarr == true)
        #expect(jobs.jobs[0].status == .submitted)
        #expect(jobs.jobs[0].destination == "/volume1/media/books/books")
    }

    private func candidate(_ magnet: String, media: NASMediaKind) -> ManualAcquisitionCandidate {
        ManualAcquisitionCandidate(
            sourceURL: URL(string: magnet)!,
            detectedType: .magnet,
            bookMetadata: ManualSearchBookContext(
                title: "Last Days",
                authors: ["Adam Nevill"],
                requestedMediaType: media == .audiobook ? .audiobook : .ebook,
            ),
        )
    }

    private func makeHandler(
        script: BridgeScript,
        deluge: DelugeMagnetScript = DelugeMagnetScript(),
        password: String = "s3cret-bridge",
    ) -> (NASAcquisitionHandler, RecordingManualDownloadJobStore) {
        let jobs = RecordingManualDownloadJobStore()
        let settings = NASDownloadSettingsSnapshot(
            torrentClient: .none,
            delugeBaseURL: "http://deluge.example:8112",
            audiobookFolder: "/volume1/media/books/audiobooks",
            ebookFolder: "/volume1/media/books/books",
        )
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: settings,
                    credentials: NASBackendCredentials(
                        delugePassword: "deluge-secret",
                        torboxarrPassword: password,
                    ),
                    torboxarr: TorBoxarrConnectionSettings(
                        host: "192.168.1.2",
                        port: 8085,
                        username: "admin",
                    ),
                )
            ),
            qbittorrent: QBittorrentClient(transport: script),
            deluge: DelugeWebClient(transport: deluge),
            jobs: jobs,
        )
        return (handler, jobs)
    }
}

private final class BridgeScript: QBittorrentTransport, @unchecked Sendable {
    var paths: [String] = []
    var bodies: [String] = []
    var savePaths: [String] = []
    var error: URLError?
    var loginBody = "Ok."
    var addBody = "Ok."
    var version = "v5.0.0"
    private let lock = NSLock()

    func send(
        url: URL,
        method _: String,
        body: Data?,
        contentType _: String?,
        cookie _: String?,
        timeout _: TimeInterval,
    ) async throws -> QBittorrentHTTP {
        if let error { throw error }
        let text = String(data: body ?? Data(), encoding: .utf8) ?? ""
        lock.lock()
        paths.append(url.path)
        bodies.append(text)
        if let path = formValue("savepath", in: text) {
            savePaths.append(path.removingPercentEncoding ?? path)
        }
        lock.unlock()
        if url.path.hasSuffix("/auth/login") {
            return QBittorrentHTTP(status: 200, body: Data(loginBody.utf8), setCookie: "SID=abc")
        }
        if url.path.hasSuffix("/app/version") {
            return QBittorrentHTTP(status: 200, body: Data(version.utf8))
        }
        return QBittorrentHTTP(status: 200, body: Data(addBody.utf8))
    }

    private func formValue(_ name: String, in form: String) -> String? {
        for pair in form.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0] == name { return parts[1] }
        }
        return nil
    }
}

private final class DelugeMagnetScript: DelugeTransport, @unchecked Sendable {
    var magnets: [String] = []
    var locations: [String] = []

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
            case "core.add_torrent_magnet":
                let params = payload?["params"] as? [Any]
                if let magnet = params?.first as? String { magnets.append(magnet) }
                if let options = params?.dropFirst().first as? [String: Any],
                    let location = options["download_location"] as? String
                {
                    locations.append(location)
                }
                return DelugeHTTP(
                    status: 200,
                    body: Data(#"{"result":"hashabc","error":null,"id":10}"#.utf8),
                )
            default:
                return DelugeHTTP(status: 200, body: Data(#"{"result":null,"error":null,"id":0}"#.utf8))
        }
    }
}
