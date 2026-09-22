//
//  TorBoxarrStatusTests.swift
//  SilveranTests
//
//  TorBoxarr manual jobs poll the qBittorrent bridge and move one payload
//  from the completed folder to the job destination. No TorBox cloud API.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit
import Testing

@Suite("TorBoxarr manual job lifecycle")
struct TorBoxarrStatusTests {
    private let hash = "0123456789abcdef0123456789abcdef01234567"
    private let completed = TorBoxarrConnectionSettings.completedFolder
    private let ebook = "/volume1/media/books/books"
    private let audiobook = "/volume1/media/books/audiobooks"

    @Test func submittedJobIsPolledThroughTheTorBoxarrBridge() async {
        let bridge = BridgeStatusScript()
        bridge.infoBody = infoJSON(state: "downloading", progress: 0.5)
        let cloud = CloudSpy()
        let nas = NASScript()
        let jobs = StatusHistory()
        await jobs.record(sample(status: .submitted))
        let refresh = makeRefresh(jobs: jobs, bridge: bridge, cloud: cloud, nas: nas)
        _ = await refresh.refresh()

        #expect(jobs.jobs.count == 1)
        #expect(jobs.jobs[0].status == .downloading)
        #expect(bridge.urls.allSatisfy { $0.host == "192.168.1.2" && $0.port == 8085 })
        #expect(bridge.urls.contains { $0.path.contains("/torrents/info") })
        #expect(bridge.urls.allSatisfy { !$0.path.contains("/torrents/files") })
        #expect(bridge.loginBodies.contains { $0.contains("username=admin") && $0.contains("password=bridge-secret") })
        #expect(bridge.loginBodies.allSatisfy { !$0.contains("qbit-secret") && !$0.contains("cloud-key") })
        #expect(cloud.calls == 0)
        #expect(nas.called == false)
    }

    @Test func downloadingStateUpdatesProgressFromTheBridge() async {
        let bridge = BridgeStatusScript()
        bridge.infoBody = infoJSON(state: "downloading", progress: 0.5, speed: 1200, size: 9000, completedBytes: 4000)
        let jobs = StatusHistory()
        await jobs.record(sample(status: .submitted))
        _ = await makeRefresh(jobs: jobs, bridge: bridge, cloud: CloudSpy(), nas: NASScript()).refresh()
        let job = jobs.jobs[0]
        #expect(job.status == .downloading)
        #expect(job.progress == 0.5)
        #expect(job.downloadRate == 1200)
        #expect(job.totalSize == 9000)
        #expect(job.byteCount == 4000)
        #expect(job.destination == ebook)
    }

    @Test func bridgeNetworkFailureBecomesUnknownNotFailed() async {
        let bridge = BridgeStatusScript()
        bridge.errorOnInfo = true
        let jobs = StatusHistory()
        await jobs.record(sample(status: .submitted))
        _ = await makeRefresh(jobs: jobs, bridge: bridge, cloud: CloudSpy(), nas: NASScript()).refresh()
        #expect(jobs.jobs[0].status == .unknown)
        #expect(jobs.jobs[0].status != .failed)
        #expect(jobs.statuses.contains(.complete) == false)
    }

    @Test func missingTorrentIsAnActionableFailure() async {
        let bridge = BridgeStatusScript()
        bridge.infoBody = "[]"
        let jobs = StatusHistory()
        await jobs.record(sample(status: .downloading))
        _ = await makeRefresh(jobs: jobs, bridge: bridge, cloud: CloudSpy(), nas: NASScript()).refresh()
        #expect(jobs.jobs[0].status == .failed)
        #expect(jobs.jobs[0].lastError?.contains("no longer in TorBox") == true)
        #expect(jobs.jobs[0].lastError?.contains("bridge-secret") != true)
    }

    @Test func completedTorrentRoutesOnlyItsPayloadAndStaysRoutingUntilTheLibraryHasIt() async {
        let bridge = BridgeStatusScript()
        bridge.infoBody = infoJSON(
            state: "uploading",
            progress: 1,
            contentPath: completed + "/Selected Title",
            torrentName: "API Name That Is Wrong",
        )
        let cloud = CloudSpy()
        let nas = NASScript()
        nas.revealAfterMove = false
        let jobs = StatusHistory()
        await jobs.record(sample(status: .submitted, destination: ebook, media: .ebook))
        _ = await makeRefresh(jobs: jobs, bridge: bridge, cloud: cloud, nas: nas).refresh()

        #expect(jobs.statuses.contains(.routing))
        #expect(jobs.jobs[0].status == .routing)
        #expect(jobs.jobs[0].status != .complete)
        #expect(jobs.jobs[0].destination == ebook)
        #expect(movedVolumePaths(nas.movedPaths) == ["/data/torrents/completed/Selected Title"])
        #expect(nas.destinations == ["/media/books/books"])
        #expect(nas.removeSrc == ["true"])
        #expect(nas.movedPaths.allSatisfy { !$0.contains("Other Book") && !$0.contains("API Name") && !$0.contains("Magnet Display") })
        #expect(bridge.urls.allSatisfy { !$0.path.contains("/torrents/files") })
        #expect(bridge.urls.allSatisfy { !$0.path.contains("setLocation") && !$0.path.contains("torrents/delete") })
        #expect(cloud.calls == 0)
        #expect(jobs.jobs[0].lastError?.contains("nas-secret") != true)
        #expect(jobs.jobs[0].lastError?.contains("bridge-secret") != true)
    }

    @Test func ebookDestinationIsKeptAndJobCompletesOnlyAfterTheMoveLands() async {
        let landed = await routeUntilListed(destination: ebook, media: .ebook)
        #expect(landed.job.status == .complete)
        #expect(landed.job.destination == ebook)
        #expect(landed.job.mediaType == .ebook)
        #expect(landed.routingIndex < landed.completeIndex)
        #expect(movedVolumePaths(landed.moved) == ["/data/torrents/completed/Selected Title"])
        #expect(landed.destinations == ["/media/books/books"])
        #expect(landed.cloudCalls == 0)
    }

    @Test func audiobookDestinationIsKeptAndJobCompletesOnlyAfterTheMoveLands() async {
        let landed = await routeUntilListed(destination: audiobook, media: .audiobook)
        #expect(landed.job.status == .complete)
        #expect(landed.job.destination == audiobook)
        #expect(landed.job.mediaType == .audiobook)
        #expect(landed.routingIndex < landed.completeIndex)
        #expect(landed.destinations == ["/media/books/audiobooks"])
        #expect(landed.cloudCalls == 0)
    }

    @Test func multifileTorrentMovesTheTopLevelFolderOnce() async {
        let bridge = BridgeStatusScript()
        bridge.infoBody = infoJSON(
            state: "stalledUP",
            progress: 1,
            contentPath: completed,
            torrentName: "Magnet Display Name",
        )
        bridge.filesBody = """
        [{"name":"Selected Title/chapter 1.mp3"},{"name":"Selected Title/chapter 2.mp3"}]
        """
        let nas = NASScript()
        nas.revealAfterMove = true
        nas.listNames = ["Selected Title"]
        let cloud = CloudSpy()
        let jobs = StatusHistory()
        await jobs.record(sample(status: .downloading, destination: audiobook, media: .audiobook))
        _ = await makeRefresh(jobs: jobs, bridge: bridge, cloud: cloud, nas: nas).refresh()

        #expect(bridge.urls.contains { $0.path.contains("/torrents/files") })
        #expect(movedVolumePaths(nas.movedPaths) == ["/data/torrents/completed/Selected Title"])
        #expect(nas.destinations == ["/media/books/audiobooks"])
        #expect(jobs.jobs[0].status == .complete)
        #expect(jobs.jobs[0].destination == audiobook)
        #expect(cloud.calls == 0)
    }

    @Test func cloudTransferIsNotUsedForTorBoxarrJobs() async {
        let cloud = CloudSpy()
        let jobs = StatusHistory()
        let ready = sample(status: .ready, destination: ebook, media: .ebook)
        await jobs.record(ready)
        #expect(ready.canTransferToNASNow == false)
        let environment = StaticNASHandoffEnvironment(context: handoff())
        let service = TorBoxNASTransferService(
            environment: environment,
            torbox: TorBoxClient(transport: cloud),
            jobs: jobs,
        )
        let transferred = await service.transfer(job: ready)
        #expect(transferred.status == .ready)
        #expect(transferred.viaTorBoxarr == true)
        _ = await makeRefresh(jobs: jobs, bridge: BridgeStatusScript(), cloud: cloud, nas: NASScript()).refresh()
        #expect(cloud.calls == 0)
        #expect(jobs.jobs[0].status == .ready)
        #expect(jobs.jobs[0].status != .transferring)
    }

    @Test func deletingATorBoxarrJobDoesNotCallTheCloudDeleteAPI() async {
        let cloud = CloudSpy()
        let jobs = StatusHistory()
        let job = sample(status: .failed, destination: ebook, media: .ebook)
        await jobs.record(job)
        let refresh = makeRefresh(jobs: jobs, bridge: BridgeStatusScript(), cloud: cloud, nas: NASScript())
        await refresh.deleteRemoteIfNeeded(job: job)
        #expect(cloud.calls == 0)
        #expect(jobs.jobs.count == 1)
    }

    @Test func locatorPrefersContentPathOverDisplayNameAndSiblings() {
        let items = TorBoxarrPayloadLocator.items(
            contentPath: completed + "/Selected Title/book.epub",
            savePath: completed,
            torrentName: "Magnet Display Name",
            fileNames: ["Other Book/a.epub", "Selected Title/book.epub"],
            completedFolder: completed,
        )
        #expect(items.map(\.name) == ["Selected Title"])
        #expect(items.first?.sourceVolumePath == completed + "/Selected Title")
    }

    @Test func locatorRefusesToSweepTheCompletedFolder() {
        let items = TorBoxarrPayloadLocator.items(
            contentPath: completed,
            savePath: completed,
            torrentName: nil,
            fileNames: ["../secrets", ""],
            completedFolder: completed,
        )
        #expect(items.isEmpty)
    }

    private func routeUntilListed(destination: String, media: NASMediaKind) async -> Landed {
        let bridge = BridgeStatusScript()
        bridge.infoBody = infoJSON(
            state: "pausedUP",
            progress: 1,
            contentPath: completed + "/Selected Title",
            torrentName: "Magnet Display Name",
        )
        let nas = NASScript()
        nas.revealAfterMove = true
        nas.listNames = ["Selected Title"]
        let cloud = CloudSpy()
        let jobs = StatusHistory()
        await jobs.record(sample(status: .submitted, destination: destination, media: media))
        _ = await makeRefresh(jobs: jobs, bridge: bridge, cloud: cloud, nas: nas).refresh()
        return Landed(
            job: jobs.jobs[0],
            routingIndex: jobs.statuses.firstIndex(of: .routing) ?? -1,
            completeIndex: jobs.statuses.lastIndex(of: .complete) ?? -1,
            moved: nas.movedPaths,
            destinations: nas.destinations,
            cloudCalls: cloud.calls,
        )
    }

    private func sample(
        status: ManualDownloadJobStatus,
        destination: String? = nil,
        media: NASMediaKind = .ebook,
    ) -> ManualDownloadJob {
        ManualDownloadJob(
            id: "tb",
            title: "Magnet Display Name",
            author: "Ada",
            sourceURL: "magnet:?xt=urn:btih:\(hash)&dn=Magnet%20Display%20Name",
            sourceHost: "magnet",
            backend: .torbox,
            mediaType: media,
            destination: destination ?? ebook,
            backendJobID: hash,
            status: status,
            providerFiles: [TorrentJobFile(id: "1", name: "book.epub", size: 10)],
            viaTorBoxarr: true,
        )
    }

    private func handoff() -> NASHandoffContext {
        NASHandoffContext(
            settings: NASDownloadSettingsSnapshot(
                torrentClient: .qbittorrent,
                torboxEnabled: true,
                torboxAutoTransferToNAS: true,
                qbittorrentBaseURL: "http://qb.example:8080",
                qbittorrentUsername: "qbit-user",
                synologyBaseURL: "http://nas.example:5000",
                synologyUsername: "josh",
                audiobookFolder: audiobook,
                ebookFolder: ebook,
            ),
            credentials: NASBackendCredentials(
                qbittorrentPassword: "qbit-secret",
                synologyPassword: "nas-secret",
                torboxAPIKey: "cloud-key",
                torboxarrPassword: "bridge-secret",
            ),
            torboxarr: TorBoxarrConnectionSettings(host: "192.168.1.2", port: 8085, username: "admin"),
        )
    }

    private func makeRefresh(
        jobs: StatusHistory,
        bridge: BridgeStatusScript,
        cloud: CloudSpy,
        nas: NASScript,
    ) -> ManualDownloadStatusRefresh {
        ManualDownloadStatusRefresh(
            environment: StaticNASHandoffEnvironment(context: handoff()),
            qbittorrent: QBittorrentClient(transport: bridge),
            torbox: TorBoxClient(transport: cloud),
            fileStation: SynologyFileStationClient(transport: nas),
            jobs: jobs,
        )
    }

    private func movedVolumePaths(_ encoded: [String]) -> [String] {
        encoded.flatMap { raw in
            (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String]) ?? []
        }
    }

    private func infoJSON(
        state: String,
        progress: Double,
        contentPath: String? = nil,
        savePath: String? = nil,
        torrentName: String = "Selected Title",
        speed: Int = 0,
        size: Int = 100,
        completedBytes: Int = 0,
    ) -> String {
        let content = contentPath.map { "\"\($0)\"" } ?? "null"
        let save = (savePath ?? completed)
        return """
        [{"hash":"\(hash)","state":"\(state)","progress":\(progress),"dlspeed":\(speed),"size":\(size),"completed":\(completedBytes),"name":"\(torrentName)","save_path":"\(save)","content_path":\(content)}]
        """
    }
}

private struct Landed {
    var job: ManualDownloadJob
    var routingIndex: Int
    var completeIndex: Int
    var moved: [String]
    var destinations: [String]
    var cloudCalls: Int
}

private final class StatusHistory: ManualDownloadJobStoring, @unchecked Sendable {
    var jobs: [ManualDownloadJob] = []
    var statuses: [ManualDownloadJobStatus] = []

    func record(_ job: ManualDownloadJob) async {
        statuses.append(job.status)
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.insert(job, at: 0)
        }
    }

    func allJobs() async -> [ManualDownloadJob] { jobs }
    func job(id: String) async -> ManualDownloadJob? { jobs.first { $0.id == id } }
    func jobMatchingAttemptIdentity(_ key: String) async -> ManualDownloadJob? {
        jobs.first { $0.attemptIdentityKey == key }
    }
    func delete(id: String) async { jobs.removeAll { $0.id == id } }
    func clearCompleted() async { jobs.removeAll { $0.status == .complete } }
    func clearFailed() async { jobs.removeAll { $0.status == .failed } }
}

private final class BridgeStatusScript: QBittorrentTransport, @unchecked Sendable {
    var urls: [URL] = []
    var loginBodies: [String] = []
    var infoBody = "[]"
    var filesBody = "[]"
    var errorOnInfo = false

    func send(
        url: URL,
        method _: String,
        body: Data?,
        contentType _: String?,
        cookie _: String?,
        timeout _: TimeInterval,
    ) async throws -> QBittorrentHTTP {
        urls.append(url)
        let text = String(data: body ?? Data(), encoding: .utf8) ?? ""
        if url.path.hasSuffix("/auth/login") {
            loginBodies.append(text)
            return QBittorrentHTTP(status: 200, body: Data("Ok.".utf8), setCookie: "SID=bridge")
        }
        if errorOnInfo { throw URLError(.cannotConnectToHost) }
        if url.path.contains("/torrents/files") {
            return QBittorrentHTTP(status: 200, body: Data(filesBody.utf8))
        }
        return QBittorrentHTTP(status: 200, body: Data(infoBody.utf8))
    }
}

private final class CloudSpy: TorBoxTransport, @unchecked Sendable {
    var calls = 0

    func send(
        url _: URL,
        method _: String,
        headers _: [String: String],
        body _: Data?,
        contentType _: String?,
        timeout _: TimeInterval,
    ) async throws -> TorBoxHTTP {
        calls += 1
        return TorBoxHTTP(status: 500, body: Data())
    }
}

private final class NASScript: SynologyTransport, @unchecked Sendable {
    var called = false
    var movedPaths: [String] = []
    var destinations: [String] = []
    var removeSrc: [String] = []
    var listNames: [String] = []
    var listCalls = 0
    var revealAfterMove = false

    func send(_ request: URLRequest) async throws -> SynologyHTTP {
        called = true
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        if request.url?.path.contains("auth.cgi") == true {
            let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            #expect(!body.contains("bridge-secret"))
            return SynologyHTTP(status: 200, body: Data(#"{"success":true,"data":{"sid":"sid"}}"#.utf8))
        }
        if value("api") == "SYNO.FileStation.CopyMove", value("method") == "start" {
            movedPaths.append(value("path") ?? "")
            destinations.append(value("dest_folder_path") ?? "")
            removeSrc.append(value("remove_src") ?? "")
            return SynologyHTTP(
                status: 200,
                body: Data(#"{"success":true,"data":{"taskid":"task-1"}}"#.utf8),
            )
        }
        if value("api") == "SYNO.FileStation.CopyMove", value("method") == "status" {
            return SynologyHTTP(
                status: 200,
                body: Data(#"{"success":true,"data":{"finished":true}}"#.utf8),
            )
        }
        if value("method") == "list" {
            listCalls += 1
            let show = revealAfterMove && listCalls >= 2
            let files = show
                ? listNames.map { "{\"name\":\"\($0.replacingOccurrences(of: "\"", with: ""))\"}" }.joined(separator: ",")
                : ""
            return SynologyHTTP(
                status: 200,
                body: Data("{\"success\":true,\"data\":{\"files\":[\(files)]}}".utf8),
            )
        }
        return SynologyHTTP(status: 200, body: Data(#"{"success":true}"#.utf8))
    }

    func upload(request _: URLRequest, fileURL _: URL) async throws -> SynologyHTTP {
        called = true
        return SynologyHTTP(status: 200, body: Data(#"{"success":true}"#.utf8))
    }
}
