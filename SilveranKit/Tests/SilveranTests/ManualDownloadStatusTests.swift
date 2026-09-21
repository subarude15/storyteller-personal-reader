//
//  ManualDownloadStatusTests.swift
//  SilveranTests
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit
import Testing

@Suite("Downloads navigation")
struct DownloadsNavigationTests {
    @Test func settingsAndDownloadsAreSeparateDestinations() {
        #expect(DownloadsNavigation.settingsDestination == "NAS Downloads")
        #expect(DownloadsNavigation.downloadsDestination == "Downloads")
        #expect(DownloadsNavigation.settingsDestination != DownloadsNavigation.downloadsDestination)
        #expect(DownloadsNavigation.settingsContainsOperationalList == false)
        #expect(DownloadsNavigation.settingsKeepsNASConfiguration)
        #expect(DownloadsNavigation.moreDestination == "More")
        #expect(DownloadsNavigation.statsLivesUnderMore)
        #expect(!DownloadsNavigation.primaryTabBarIncludesStats)
    }
}

@Suite("Manual download status mapping")
struct ManualDownloadStatusMappingTests {
    @Test func qbittorrentDownloadingMapsToDownloading() {
        #expect(ManualDownloadStatusMapping.qbittorrent(state: "downloading", progress: 0.4) == .downloading)
        #expect(ManualDownloadStatusMapping.qbittorrent(state: "stalledDL", progress: 0.2) == .downloading)
        #expect(ManualDownloadStatusMapping.qbittorrent(state: "checkingDL", progress: 0.1) == .downloading)
    }

    @Test func qbittorrentSeedingMapsToComplete() {
        #expect(ManualDownloadStatusMapping.qbittorrent(state: "uploading", progress: 1) == .complete)
        #expect(ManualDownloadStatusMapping.qbittorrent(state: "stalledUP", progress: 1) == .complete)
        #expect(ManualDownloadStatusMapping.qbittorrent(state: "pausedUP", progress: 1) == .complete)
    }

    @Test func qbittorrentPausedIncompleteIsNotComplete() {
        #expect(ManualDownloadStatusMapping.qbittorrent(state: "pausedDL", progress: 0.4) == .downloading)
    }

    @Test func qbittorrentUnavailableStaysUnknownNotFailed() {
        let job = sampleJob(backend: .qbittorrent, status: .submitted, hash: "abc")
        let next = ManualDownloadStatusMapping.markUnknown(job)
        #expect(next.status == .unknown)
        #expect(next.status != .failed)
    }

    @Test func delugeDownloadingAndSeeding() {
        #expect(
            ManualDownloadStatusMapping.deluge(state: "Downloading", progress: 0.3, isFinished: false)
                == .downloading
        )
        // Finished with no save_path yet — wait for Deluge completed staging, never Complete.
        #expect(
            ManualDownloadStatusMapping.deluge(state: "Seeding", progress: 1, isFinished: true)
                == .delugeFinishing
        )
        #expect(
            ManualDownloadStatusMapping.deluge(state: "Queued", progress: 0, isFinished: false)
                == .queued
        )
        #expect(
            ManualDownloadStatusMapping.deluge(
                state: "Seeding",
                progress: 1,
                isFinished: true,
                savePath: NASDownloadSettingsSnapshot.defaultDelugeCompletedFolder,
                incomingFolder: NASDownloadSettingsSnapshot.defaultDelugeIncomingFolder,
                completedFolder: NASDownloadSettingsSnapshot.defaultDelugeCompletedFolder,
                finalDestination: "/volume1/media/books/books",
            ) == .readyToRoute
        )
        #expect(
            ManualDownloadStatusMapping.deluge(
                state: "Seeding",
                progress: 1,
                isFinished: true,
                savePath: "/volume1/media/books/books",
                incomingFolder: NASDownloadSettingsSnapshot.defaultDelugeIncomingFolder,
                completedFolder: NASDownloadSettingsSnapshot.defaultDelugeCompletedFolder,
                finalDestination: "/volume1/media/books/books",
            ) == .complete
        )
    }

    @Test func delugeUnavailableIsUnknown() {
        let job = sampleJob(backend: .deluge, status: .submitted, hash: "hashabc")
        #expect(ManualDownloadStatusMapping.markUnknown(job).status == .unknown)
    }

    @Test func magnetHashIsExtractedNotGuessed() {
        #expect(TorrentHash.fromMagnet("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567") == "0123456789abcdef0123456789abcdef01234567")
        #expect(TorrentHash.fromMagnet("https://files.example/hobbit.torrent") == nil)
        #expect(TorrentHash.retryDetectedType(sourceURL: "magnet:?xt=urn:btih:abc", mediaType: .ebook) == .magnet)
        #expect(
            TorrentHash.retryDetectedType(
                sourceURL: "https://files.example/hobbit.torrent",
                mediaType: .audiobook,
            ) == .torrent
        )
    }

    @Test func retryTypeUsesURLPathNotQueryOrFragment() {
        #expect(
            TorrentHash.retryDetectedType(
                sourceURL: "https://files.example/hobbit.torrent",
                mediaType: .ebook,
            ) == .torrent
        )
        #expect(
            TorrentHash.retryDetectedType(
                sourceURL: "https://files.example/hobbit.torrent?token=abc",
                mediaType: .ebook,
            ) == .torrent
        )
        #expect(
            TorrentHash.retryDetectedType(
                sourceURL: "https://files.example/hobbit.torrent#fragment",
                mediaType: .ebook,
            ) == .torrent
        )
        #expect(
            TorrentHash.retryDetectedType(
                sourceURL: "https://files.example/hobbit.torrent?token=abc#fragment",
                mediaType: .ebook,
            ) == .torrent
        )
        #expect(
            TorrentHash.retryDetectedType(
                sourceURL: "https://files.example/HOBBIT.TORRENT?token=abc",
                mediaType: .audiobook,
            ) == .torrent
        )
        #expect(
            TorrentHash.retryDetectedType(
                sourceURL: "https://files.example/hobbit.epub?token=abc",
                mediaType: .ebook,
            ) == .epub
        )
        #expect(
            TorrentHash.retryDetectedType(
                sourceURL: "https://files.example/download?id=12",
                mediaType: .ebook,
            ) == .epub
        )
        #expect(
            TorrentHash.retryDetectedType(
                sourceURL: "https://files.example/download?file=book.torrent",
                mediaType: .ebook,
            ) == .epub
        )
    }

    @Test func infoHashNormalizesHexAndBase32() {
        let hex = "0123456789abcdef0123456789abcdef01234567"
        #expect(TorrentHash.canonicalInfoHash(hex) == hex)
        #expect(TorrentHash.canonicalInfoHash(hex.uppercased()) == hex)
        #expect(TorrentHash.fromMagnet("magnet:?xt=urn:btih:\(hex.uppercased())") == hex)
        #expect(TorrentHash.canonicalInfoHash("AERUKZ4JVPG66AJDIVTYTK6N54ASGRLH") == hex)
        #expect(TorrentHash.canonicalInfoHash("aerukz4jvpg66ajdivtytk6n54asgrlh") == hex)
        #expect(TorrentHash.fromMagnet("magnet:?xt=urn:btih:AERUKZ4JVPG66AJDIVTYTK6N54ASGRLH") == hex)
        #expect(TorrentHash.canonicalInfoHash("AERUKZ4JVPG66AJDIVTYTK6N54ASGRL1") == nil)
        #expect(TorrentHash.canonicalInfoHash("0123456789abcdef0123456789abcdef0123456") == nil)
        #expect(TorrentHash.canonicalInfoHash("0123456789abcdef0123456789abcdef012345678") == nil)
        #expect(TorrentHash.fromMagnet("magnet:?xt=urn:btih:not-a-hash") == nil)
    }
}

@Suite("Manual download history buckets")
struct ManualDownloadHistoryTests {
    @Test func completedAppearsInRecentAndFailedStayOnClear() async {
        let store = RecordingManualDownloadJobStore()
        let active = sampleJob(id: "a", status: .downloading)
        let failed = sampleJob(id: "f", status: .failed, staged: true)
        let done = sampleJob(id: "c", status: .complete)
        await store.record(active)
        await store.record(failed)
        await store.record(done)
        let buckets = ManualDownloadBuckets.partition(await store.allJobs())
        #expect(buckets.active.map(\.id) == ["a"])
        #expect(buckets.failed.map(\.id) == ["f"])
        #expect(buckets.recent.map(\.id) == ["c"])
        #expect(buckets.attentionCount == 2)
        await store.clearCompleted()
        let after = ManualDownloadBuckets.partition(await store.allJobs())
        #expect(after.recent.isEmpty)
        #expect(after.failed.map(\.id) == ["f"])
        #expect(after.active.map(\.id) == ["a"])
    }

    @Test func failedUploadExposesRetryUploadNotRedownload() {
        let job = sampleJob(backend: .synology, status: .failed, staged: true)
        #expect(job.canRetryUploadNow)
        #expect(!job.canRetryDownloadNow)
        #expect(!job.canRetryTorrentNow)
        #expect(job.retryAction == .retryUpload)
    }

    @Test func failedDirectDownloadExposesRetryDownload() {
        let job = sampleJob(backend: .synology, status: .failed, staged: false)
        #expect(job.canRetryDownloadNow)
        #expect(!job.canRetryUploadNow)
        #expect(job.retryAction == .retryDownload)
    }

    @Test func failedTorrentExposesRetryWhenSourceRemains() {
        let job = sampleJob(backend: .qbittorrent, status: .failed)
        #expect(job.canRetryTorrentNow)
        #expect(!job.canRetryDownloadNow)
        #expect(job.retryAction == .retryTorrent)
    }

    @Test func failedDelugeRoutingExposesRetryMove() {
        var job = sampleJob(backend: .deluge, status: .failed, hash: "hashabc")
        job.delugeReachedFinalRouting = true
        #expect(job.canRetryRoutingNow)
        #expect(!job.canRetryTorrentNow)
        #expect(job.retryAction == .retryRouting)
    }

    @Test func failedDelugeSubmitWithMagnetHashUsesTorrentRetryNotMove() {
        // makeJob derives backendJobID from magnet BTIH even when addMagnet fails.
        let magnet =
            "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Example"
        let hash = TorrentHash.fromMagnet(magnet)
        #expect(hash == "0123456789abcdef0123456789abcdef01234567")
        let job = ManualDownloadJob(
            title: "Example",
            author: "",
            sourceURL: magnet,
            sourceHost: "magnet",
            backend: .deluge,
            mediaType: .ebook,
            destination: "/volume1/media/books/books",
            backendJobID: hash,
            status: .failed,
            lastError: "Deluge rejected the credentials.\nCheck the Deluge connection in Settings.",
            delugeReachedFinalRouting: nil,
        )
        #expect(!job.hasReachedDelugeFinalRouting)
        #expect(!job.canRetryRoutingNow)
        #expect(job.canRetryTorrentNow)
        #expect(job.retryAction == .retryTorrent)
    }
}

@Suite("Manual download status refresh")
struct ManualDownloadStatusRefreshTests {
    @Test func qbittorrentPollFailureMarksUnknownNotFailed() async {
        let jobs = RecordingManualDownloadJobStore()
        let job = sampleJob(backend: .qbittorrent, status: .submitted, hash: "abc")
        await jobs.record(job)
        let transport = FailingQBittorrent()
        let refresh = ManualDownloadStatusRefresh(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: NASDownloadSettingsSnapshot(
                        torrentClient: .qbittorrent,
                        qbittorrentBaseURL: "http://qb.example:8080",
                    ),
                    credentials: NASBackendCredentials(qbittorrentPassword: "x"),
                )
            ),
            qbittorrent: QBittorrentClient(transport: transport),
            jobs: jobs,
        )
        _ = await refresh.refresh()
        #expect(jobs.jobs[0].status == .unknown)
        #expect(jobs.jobs[0].status != .failed)
    }

    @Test func qbittorrentRefreshMatchesJobCreatedFromBase32Btih() async {
        let hex = "0123456789abcdef0123456789abcdef01234567"
        let jobs = RecordingManualDownloadJobStore()
        let magnet = "magnet:?xt=urn:btih:AERUKZ4JVPG66AJDIVTYTK6N54ASGRLH"
        #expect(TorrentHash.fromMagnet(magnet) == hex)
        await jobs.record(
            sampleJob(backend: .qbittorrent, status: .submitted, hash: TorrentHash.fromMagnet(magnet))
        )
        let transport = SnapshotQBittorrent(
            hash: hex,
            state: "downloading",
            progress: 0.5,
        )
        let refresh = ManualDownloadStatusRefresh(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: NASDownloadSettingsSnapshot(
                        torrentClient: .qbittorrent,
                        qbittorrentBaseURL: "http://qb.example:8080",
                    ),
                    credentials: NASBackendCredentials(qbittorrentPassword: "x"),
                )
            ),
            qbittorrent: QBittorrentClient(transport: transport),
            jobs: jobs,
        )
        _ = await refresh.refresh()
        #expect(jobs.jobs.count == 1)
        #expect(jobs.jobs[0].backendJobID == hex)
        #expect(jobs.jobs[0].status == .downloading)
        #expect(jobs.jobs[0].progress == 0.5)
        #expect(jobs.jobs[0].status != .failed)
        #expect(jobs.jobs[0].status != .unknown)
    }

    @Test func delugePollFailureMarksUnknown() async {
        let jobs = RecordingManualDownloadJobStore()
        await jobs.record(sampleJob(backend: .deluge, status: .submitted, hash: "hashabc"))
        let transport = FailingDeluge()
        let refresh = ManualDownloadStatusRefresh(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: NASDownloadSettingsSnapshot(
                        torrentClient: .deluge,
                        delugeBaseURL: "http://deluge.example:8112",
                    ),
                    credentials: NASBackendCredentials(delugePassword: "x"),
                )
            ),
            deluge: DelugeWebClient(transport: transport),
            jobs: jobs,
        )
        _ = await refresh.refresh()
        #expect(jobs.jobs[0].status == .unknown)
    }
}

private func sampleJob(
    id: String = "job",
    backend: NASDownloadBackend = .qbittorrent,
    status: ManualDownloadJobStatus,
    hash: String? = nil,
    staged: Bool = false,
) -> ManualDownloadJob {
    let stagedPath: String?
    if staged {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inkamp-\(id).epub")
        try? Data("x".utf8).write(to: url)
        stagedPath = url.path
    } else {
        stagedPath = nil
    }
    return ManualDownloadJob(
        id: id,
        title: "The Hobbit",
        author: "J.R.R. Tolkien",
        sourceURL: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567",
        sourceHost: "example",
        backend: backend,
        mediaType: .audiobook,
        destination: "/volume1/media/books/audiobooks",
        stagedFilePath: stagedPath,
        backendJobID: hash,
        status: status,
    )
}

private final class SnapshotQBittorrent: QBittorrentTransport, @unchecked Sendable {
    var hash: String
    var state: String
    var progress: Double

    init(hash: String, state: String, progress: Double) {
        self.hash = hash
        self.state = state
        self.progress = progress
    }

    func send(
        url: URL,
        method _: String,
        body _: Data?,
        contentType _: String?,
        cookie _: String?,
        timeout _: TimeInterval,
    ) async throws -> QBittorrentHTTP {
        if url.path.hasSuffix("/auth/login") {
            return QBittorrentHTTP(status: 200, body: Data("Ok.".utf8), setCookie: "SID=x")
        }
        let body = Data(
            """
            [{"hash":"\(hash)","state":"\(state)","progress":\(progress),"dlspeed":1,"size":100,"completed":50}]
            """.utf8
        )
        return QBittorrentHTTP(status: 200, body: body)
    }
}

private final class FailingQBittorrent: QBittorrentTransport, @unchecked Sendable {
    func send(
        url: URL,
        method _: String,
        body _: Data?,
        contentType _: String?,
        cookie _: String?,
        timeout _: TimeInterval,
    ) async throws -> QBittorrentHTTP {
        if url.path.hasSuffix("/auth/login") {
            return QBittorrentHTTP(status: 200, body: Data("Ok.".utf8), setCookie: "SID=x")
        }
        throw URLError(.cannotConnectToHost)
    }
}

private final class FailingDeluge: DelugeTransport, @unchecked Sendable {
    func send(
        url _: URL,
        method _: String,
        body _: Data,
        cookie _: String?,
        timeout _: TimeInterval,
    ) async throws -> DelugeHTTP {
        throw URLError(.cannotConnectToHost)
    }
}
