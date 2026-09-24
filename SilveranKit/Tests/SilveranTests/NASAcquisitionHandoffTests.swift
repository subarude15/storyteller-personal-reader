//
//  NASAcquisitionHandoffTests.swift
//  SilveranTests
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit
import Testing

@Suite("NAS acquisition handoff")
struct NASAcquisitionHandoffTests {
    private let audiobook = ManualSearchBookContext(
        title: "The Hobbit",
        authors: ["J.R.R. Tolkien"],
        requestedMediaType: .audiobook,
    )
    private let ebook = ManualSearchBookContext(
        title: "The Hobbit",
        authors: ["J.R.R. Tolkien"],
        requestedMediaType: .ebook,
    )

    private func synologySettings() -> NASDownloadSettingsSnapshot {
        NASDownloadSettingsSnapshot(
            torrentClient: .qbittorrent,
            qbittorrentBaseURL: "http://qb.example:8080",
            synologyBaseURL: "http://nas.example:5000",
            synologyUsername: "josh",
            audiobookFolder: "/volume1/media/books/audiobooks",
            ebookFolder: "/volume1/media/books/books",
        )
    }

    @Test func magnetRoutesToQBittorrentWithAudiobookDestination() async {
        let qb = QBittorrentCapture()
        let jobs = RecordingManualDownloadJobStore()
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: synologySettings(),
                    credentials: NASBackendCredentials(qbittorrentPassword: "secret"),
                )
            ),
            qbittorrent: QBittorrentClient(transport: qb),
            jobs: jobs,
        )
        let result = await handler.handle(
            ManualAcquisitionCandidate(
                sourceURL: URL(string: "magnet:?xt=urn:btih:abc")!,
                detectedType: .magnet,
                bookMetadata: audiobook,
            )
        )
        #expect(result.isSubmitted)
        #expect(result.message == "The download was added to qBittorrent.")
        #expect(!result.message.lowercased().contains("complete"))
        #expect(qb.addedURLs == ["magnet:?xt=urn:btih:abc"])
        #expect(qb.savePaths == ["/volume1/media/books/audiobooks"])
        #expect(jobs.jobs[0].status == .submitted)
        #expect(jobs.jobs[0].backend == .qbittorrent)
        #expect(jobs.jobs[0].destination == "/volume1/media/books/audiobooks")
    }

    @Test func magnetPersistsExplicitBtihHash() async {
        let jobs = RecordingManualDownloadJobStore()
        let magnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: synologySettings(),
                    credentials: NASBackendCredentials(qbittorrentPassword: "secret"),
                )
            ),
            qbittorrent: QBittorrentClient(transport: QBittorrentCapture()),
            jobs: jobs,
        )
        _ = await handler.handle(
            ManualAcquisitionCandidate(
                sourceURL: URL(string: magnet)!,
                detectedType: .magnet,
                bookMetadata: audiobook,
            )
        )
        #expect(jobs.jobs[0].backendJobID == "0123456789abcdef0123456789abcdef01234567")
        #expect(jobs.jobs[0].status == .submitted)
    }

    @Test func epubDownloadsThenUploadsToEbookFolder() async throws {
        let download = FileDownloadCapture(contents: Data("epub-bytes".utf8))
        let upload = UploadCapture()
        let jobs = RecordingManualDownloadJobStore()
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(settings: synologySettings())
            ),
            downloader: ManualFileDownloader(transport: download),
            uploaderFactory: { _ in upload },
            jobs: jobs,
        )
        let result = await handler.handle(
            ManualAcquisitionCandidate(
                sourceURL: URL(string: "https://files.example/hobbit.epub")!,
                detectedType: .epub,
                filename: "The Hobbit.epub",
                bookMetadata: ebook,
            )
        )
        guard case .completed = result else {
            Issue.record("expected completed upload, got \(result)")
            return
        }
        #expect(download.callCount == 1)
        #expect(upload.destinations.map(\.volumePath) == ["/volume1/media/books/books"])
        #expect(upload.destinations.map(\.filename) == ["The Hobbit.epub"])
        #expect(jobs.jobs[0].status == .complete)
        #expect(jobs.jobs[0].backend == .synology)
        #expect(jobs.jobs[0].stagedFilePath == nil)
        #expect(!FileManager.default.fileExists(atPath: download.lastDestination?.path ?? ""))
    }

    @Test func m4bUploadsToAudiobookFolder() async {
        let download = FileDownloadCapture(contents: Data("m4b".utf8))
        let upload = UploadCapture()
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(settings: synologySettings())
            ),
            downloader: ManualFileDownloader(transport: download),
            uploaderFactory: { _ in upload },
            jobs: RecordingManualDownloadJobStore(),
        )
        _ = await handler.handle(
            ManualAcquisitionCandidate(
                sourceURL: URL(string: "https://files.example/hobbit.m4b")!,
                detectedType: .m4b,
                filename: "The Hobbit.m4b",
                bookMetadata: audiobook,
            )
        )
        #expect(upload.destinations.map(\.volumePath) == ["/volume1/media/books/audiobooks"])
    }

    @Test func successMeansSubmittedNotCompletedForTorrents() async {
        let qb = QBittorrentCapture()
        let jobs = RecordingManualDownloadJobStore()
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(settings: synologySettings())
            ),
            qbittorrent: QBittorrentClient(transport: qb),
            jobs: jobs,
        )
        let result = await handler.handle(
            ManualAcquisitionCandidate(
                sourceURL: URL(string: "magnet:?xt=urn:btih:abc")!,
                detectedType: .magnet,
                bookMetadata: audiobook,
            )
        )
        guard case .submitted = result else {
            Issue.record("expected submitted")
            return
        }
        #expect(jobs.jobs[0].status != .complete)
        #expect(jobs.jobs[0].status != .downloading)
    }

    @Test func failedUploadKeepsStagedFileAndRetryDoesNotRedownload() async {
        let download = FileDownloadCapture(contents: Data("keep-me".utf8))
        let upload = UploadCapture(shouldFail: true)
        let jobs = RecordingManualDownloadJobStore()
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(settings: synologySettings())
            ),
            downloader: ManualFileDownloader(transport: download),
            uploaderFactory: { _ in upload },
            jobs: jobs,
        )
        let result = await handler.handle(
            ManualAcquisitionCandidate(
                sourceURL: URL(string: "https://files.example/hobbit.epub")!,
                detectedType: .epub,
                filename: "The Hobbit.epub",
                bookMetadata: ebook,
            )
        )
        guard case .failed(let message) = result else {
            Issue.record("expected upload failure")
            return
        }
        #expect(message.contains("still saved"))
        #expect(download.callCount == 1)
        #expect(jobs.jobs[0].hasStagedFile)
        let staged = jobs.jobs[0].stagedFilePath
        #expect(staged != nil)

        upload.shouldFail = false
        let retry = await handler.retryUpload(job: jobs.jobs[0])
        guard case .completed = retry else {
            Issue.record("retry should upload the staged file")
            return
        }
        #expect(download.callCount == 1)
        #expect(jobs.jobs[0].status == .complete)
        #expect(jobs.jobs[0].stagedFilePath == nil)
        if let staged {
            #expect(!FileManager.default.fileExists(atPath: staged))
        }
    }

    @Test func downloadFailureDoesNotUpload() async {
        let download = FileDownloadCapture(status: 404)
        let upload = UploadCapture()
        let jobs = RecordingManualDownloadJobStore()
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(settings: synologySettings())
            ),
            downloader: ManualFileDownloader(transport: download),
            uploaderFactory: { _ in upload },
            jobs: jobs,
        )
        let result = await handler.handle(
            ManualAcquisitionCandidate(
                sourceURL: URL(string: "https://files.example/missing.epub")!,
                detectedType: .epub,
                bookMetadata: ebook,
            )
        )
        #expect(result == .failed(message: NASHandoffError.downloadFailed.message))
        #expect(upload.destinations.isEmpty)
        #expect(jobs.jobs[0].status == .failed)
        #expect(!jobs.jobs[0].hasStagedFile)
    }

    @Test func torrentDoesNotDownloadOrUpload() async {
        let download = FileDownloadCapture(contents: Data("nope".utf8))
        let upload = UploadCapture()
        let qb = QBittorrentCapture()
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(settings: synologySettings())
            ),
            qbittorrent: QBittorrentClient(transport: qb),
            downloader: ManualFileDownloader(transport: download),
            uploaderFactory: { _ in upload },
        )
        _ = await handler.handle(
            ManualAcquisitionCandidate(
                sourceURL: URL(string: "https://files.example/hobbit.torrent")!,
                detectedType: .torrent,
                bookMetadata: ebook,
            )
        )
        #expect(download.callCount == 0)
        #expect(upload.destinations.isEmpty)
        #expect(qb.addedURLs == ["https://files.example/hobbit.torrent"])
        #expect(qb.addedTorrentFilenames.isEmpty)
        #expect(qb.savePaths == ["/volume1/media/books/books"])
    }

    @Test func stagedAudiobookTorrentSubmitsFileNotURLAndDeletesOnSuccess() async throws {
        let qb = QBittorrentCapture()
        let download = FileDownloadCapture(contents: Data("nope".utf8))
        let upload = UploadCapture()
        let jobs = RecordingManualDownloadJobStore()
        let staged = try ManualDownloadStaging.prepareTorrent(
            suggestedFilename: "some-book.torrent",
            jobID: "staged-audio",
        )
        try Data("d8:announce".utf8).write(to: staged)
        #expect(ManualDownloadStaging.exists(staged))
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: synologySettings(),
                    credentials: NASBackendCredentials(qbittorrentPassword: "secret"),
                )
            ),
            qbittorrent: QBittorrentClient(transport: qb),
            downloader: ManualFileDownloader(transport: download),
            uploaderFactory: { _ in upload },
            jobs: jobs,
        )
        let result = await handler.handle(
            ManualAcquisitionCandidate(
                sourceURL: URL(string: "https://tracker.example/one-time/dl")!,
                detectedType: .torrent,
                filename: "some-book.torrent",
                bookMetadata: audiobook,
                localTorrentFileURL: staged,
            )
        )
        #expect(result.isSubmitted)
        #expect(download.callCount == 0)
        #expect(upload.destinations.isEmpty)
        #expect(qb.addedURLs.isEmpty)
        #expect(qb.addedTorrentFilenames == ["some-book.torrent"])
        #expect(qb.savePaths == ["/volume1/media/books/audiobooks"])
        #expect(qb.lastContentType?.contains("multipart/form-data") == true)
        #expect(!ManualDownloadStaging.exists(staged))
        #expect(jobs.jobs[0].status == .submitted)
        #expect(jobs.jobs[0].hasStagedFile == false)
        #expect(jobs.jobs[0].destination == "/volume1/media/books/audiobooks")
    }

    @Test func stagedEbookTorrentRoutesToEbookFolder() async throws {
        let qb = QBittorrentCapture()
        let staged = try ManualDownloadStaging.prepareTorrent(
            suggestedFilename: "ebook.torrent",
            jobID: "staged-ebook",
        )
        try Data("d8:announce".utf8).write(to: staged)
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: synologySettings(),
                    credentials: NASBackendCredentials(qbittorrentPassword: "secret"),
                )
            ),
            qbittorrent: QBittorrentClient(transport: qb),
        )
        _ = await handler.handle(
            ManualAcquisitionCandidate(
                sourceURL: URL(string: "https://tracker.example/ebook")!,
                detectedType: .torrent,
                bookMetadata: ebook,
                localTorrentFileURL: staged,
            )
        )
        #expect(qb.savePaths == ["/volume1/media/books/books"])
        #expect(qb.addedTorrentFilenames == ["ebook.torrent"])
    }

    @Test func failedStagedTorrentKeepsFileForRetryWithoutRedownload() async throws {
        let qb = QBittorrentCapture()
        qb.rejectAdds = true
        let jobs = RecordingManualDownloadJobStore()
        let staged = try ManualDownloadStaging.prepareTorrent(
            suggestedFilename: "retry-me.torrent",
            jobID: "staged-retry",
        )
        let payload = Data("d8:announce13:http://a.com".utf8)
        try payload.write(to: staged)
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: synologySettings(),
                    credentials: NASBackendCredentials(qbittorrentPassword: "secret"),
                )
            ),
            qbittorrent: QBittorrentClient(transport: qb),
            jobs: jobs,
        )
        let failed = await handler.handle(
            ManualAcquisitionCandidate(
                sourceURL: URL(string: "https://tracker.example/once")!,
                detectedType: .torrent,
                filename: "retry-me.torrent",
                bookMetadata: audiobook,
                localTorrentFileURL: staged,
            )
        )
        #expect(failed.isFailed)
        #expect(ManualDownloadStaging.exists(staged))
        #expect(jobs.jobs[0].hasStagedFile)
        #expect(jobs.jobs[0].retryAction == .retryTorrent)

        qb.rejectAdds = false
        qb.addedTorrentFilenames = []
        let retried = await handler.retryDownload(job: jobs.jobs[0])
        #expect(retried.isSubmitted)
        #expect(qb.addedTorrentFilenames == ["retry-me.torrent"])
        #expect(qb.addedURLs.isEmpty)
        #expect(!ManualDownloadStaging.exists(staged))
        #expect(jobs.jobs[0].status == .submitted)
        #expect(!jobs.jobs[0].hasStagedFile)
    }

    @Test func stagedTorrentNeverRoutesThroughSynologyUpload() async throws {
        let download = FileDownloadCapture(contents: Data("nope".utf8))
        let upload = UploadCapture()
        let deluge = DelugeCapture()
        let jobs = RecordingManualDownloadJobStore()
        var settings = synologySettings()
        settings.torrentClient = .deluge
        settings.delugeBaseURL = "http://deluge.example:8112"
        let staged = try ManualDownloadStaging.prepareTorrent(
            suggestedFilename: "deluge.torrent",
            jobID: "staged-deluge",
        )
        let bytes = Data("d8:announce".utf8)
        try bytes.write(to: staged)
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: settings,
                    credentials: NASBackendCredentials(delugePassword: "secret"),
                )
            ),
            deluge: DelugeWebClient(transport: deluge),
            downloader: ManualFileDownloader(transport: download),
            uploaderFactory: { _ in upload },
            jobs: jobs,
        )
        _ = await handler.handle(
            ManualAcquisitionCandidate(
                sourceURL: URL(string: "https://tracker.example/deluge")!,
                detectedType: .torrent,
                bookMetadata: audiobook,
                localTorrentFileURL: staged,
            )
        )
        #expect(download.callCount == 0)
        #expect(upload.destinations.isEmpty)
        #expect(deluge.torrentFilenames == ["deluge.torrent"])
        #expect(deluge.torrentFiledumps == [bytes.base64EncodedString()])
        #expect(deluge.torrentURLs.isEmpty)
        #expect(deluge.locations == ["/volume1/data/torrents/incoming"])
        #expect(jobs.jobs[0].destination == "/volume1/media/books/audiobooks")
        #expect(!ManualDownloadStaging.exists(staged))
    }

    @Test func magnetRoutesToDelugeWithEbookDestination() async {
        let deluge = DelugeCapture()
        let jobs = RecordingManualDownloadJobStore()
        var settings = synologySettings()
        settings.torrentClient = .deluge
        settings.delugeBaseURL = "http://deluge.example:8112"
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: settings,
                    credentials: NASBackendCredentials(delugePassword: "secret"),
                )
            ),
            deluge: DelugeWebClient(transport: deluge),
            jobs: jobs,
        )
        let result = await handler.handle(
            ManualAcquisitionCandidate(
                sourceURL: URL(string: "magnet:?xt=urn:btih:abc")!,
                detectedType: .magnet,
                bookMetadata: ebook,
            )
        )
        #expect(result.isSubmitted)
        #expect(deluge.magnets == ["magnet:?xt=urn:btih:abc"])
        #expect(deluge.locations == ["/volume1/data/torrents/incoming"])
        #expect(jobs.jobs[0].backend == .deluge)
        #expect(jobs.jobs[0].destination == "/volume1/media/books/books")
        #expect(jobs.jobs[0].status == .submitted)
        #expect(jobs.jobs[0].delugeReachedFinalRouting != true)
    }

    @Test func failedDelugeMagnetSubmitWithBTIHUsesTorrentRetryNotMove() async {
        let deluge = DelugeAuthFailCapture()
        let jobs = RecordingManualDownloadJobStore()
        var settings = synologySettings()
        settings.torrentClient = .deluge
        settings.delugeBaseURL = "http://deluge.example:8112"
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: settings,
                    credentials: NASBackendCredentials(delugePassword: "wrong"),
                )
            ),
            deluge: DelugeWebClient(transport: deluge),
            jobs: jobs,
        )
        let magnet =
            "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=The%20Hobbit"
        let result = await handler.handle(
            ManualAcquisitionCandidate(
                sourceURL: URL(string: magnet)!,
                detectedType: .magnet,
                bookMetadata: ebook,
            )
        )
        #expect(!result.isSuccess)
        #expect(jobs.jobs.count == 1)
        let job = jobs.jobs[0]
        #expect(job.status == .failed)
        #expect(job.backend == .deluge)
        #expect(job.backendJobID == "0123456789abcdef0123456789abcdef01234567")
        #expect(job.delugeReachedFinalRouting != true)
        #expect(!job.canRetryRoutingNow)
        #expect(job.canRetryTorrentNow)
        #expect(job.retryAction == .retryTorrent)
    }

    @Test func torrentURLRoutesToDelugeAsSubmitted() async {
        let deluge = DelugeCapture()
        let jobs = RecordingManualDownloadJobStore()
        var settings = synologySettings()
        settings.torrentClient = .deluge
        settings.delugeBaseURL = "http://deluge.example:8112"
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: settings,
                    credentials: NASBackendCredentials(delugePassword: "secret"),
                )
            ),
            deluge: DelugeWebClient(transport: deluge),
            jobs: jobs,
        )
        let result = await handler.handle(
            ManualAcquisitionCandidate(
                sourceURL: URL(string: "https://files.example/hobbit.torrent")!,
                detectedType: .torrent,
                bookMetadata: audiobook,
            )
        )
        #expect(result.isSubmitted)
        #expect(jobs.jobs[0].status == .submitted)
        #expect(jobs.jobs[0].destination == "/volume1/media/books/audiobooks")
    }

    @Test func unverifiedUploadIsNotMarkedComplete() async {
        let download = FileDownloadCapture(contents: Data("epub-bytes".utf8))
        let upload = UploadCapture(verified: false, omitByteCount: true)
        let jobs = RecordingManualDownloadJobStore()
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(settings: synologySettings())
            ),
            downloader: ManualFileDownloader(transport: download),
            uploaderFactory: { _ in upload },
            jobs: jobs,
        )
        let result = await handler.handle(
            ManualAcquisitionCandidate(
                sourceURL: URL(string: "https://files.example/hobbit.epub")!,
                detectedType: .epub,
                filename: "The Hobbit.epub",
                bookMetadata: ebook,
            )
        )
        guard case .failed = result else {
            Issue.record("unverified upload must not complete")
            return
        }
        #expect(jobs.jobs[0].status == .failed)
        #expect(jobs.jobs[0].hasStagedFile)
    }

    @Test func confirmationCopyDistinguishesTorrentAndDirect() {
        let magnet = ManualAcquisitionCandidate(
            sourceURL: URL(string: "magnet:?xt=urn:btih:abc")!,
            detectedType: .magnet,
            bookMetadata: audiobook,
        )
        let epub = ManualAcquisitionCandidate(
            sourceURL: URL(string: "https://files.example/hobbit.epub")!,
            detectedType: .epub,
            bookMetadata: ebook,
        )
        let torrentPreview = NASHandoffPreview.make(candidate: magnet, settings: synologySettings())
        let directPreview = NASHandoffPreview.make(candidate: epub, settings: synologySettings())
        #expect(torrentPreview.backendLabel == "qBittorrent")
        #expect(torrentPreview.methodNote == nil)
        #expect(directPreview.backendLabel == "Download on this device, then upload to NAS")
        #expect(directPreview.methodNote?.contains("Temporary local copy") == true)
        #expect(directPreview.destination == "/volume1/media/books/books")
        #expect(torrentPreview.destination == "/volume1/media/books/audiobooks")
    }

    @Test func secretsAreRedacted() {
        let text = NASHandoffMessages.redact(
            "password=super-secret sid=super-secret",
            secrets: ["super-secret"],
        )
        #expect(!text.contains("super-secret"))
        #expect(text.contains("••••"))
    }

    @Test func successfulQBittorrentRetryReusesFailedJob() async {
        let qb = QBittorrentCapture()
        let jobs = RecordingManualDownloadJobStore()
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: synologySettings(),
                    credentials: NASBackendCredentials(qbittorrentPassword: "secret"),
                )
            ),
            qbittorrent: QBittorrentClient(transport: qb),
            jobs: jobs,
        )
        let failed = failedTorrentJob(backend: .qbittorrent)
        await jobs.record(failed)
        let result = await handler.retryDownload(job: failed)
        #expect(result.isSubmitted)
        #expect(jobs.jobs.count == 1)
        #expect(jobs.jobs[0].id == failed.id)
        #expect(jobs.jobs[0].status == .submitted)
        #expect(jobs.jobs[0].lastError == nil)
        #expect(jobs.jobs[0].retryAction == .none)
        let buckets = ManualDownloadBuckets.partition(jobs.jobs)
        #expect(buckets.failed.isEmpty)
        #expect(buckets.active.map(\.id) == [failed.id])
        #expect(buckets.attentionCount == 1)
        #expect(qb.addedURLs.count == 1)

        let stale = failed
        let again = await handler.retryDownload(job: stale)
        #expect(again.isSubmitted)
        #expect(qb.addedURLs.count == 1)
        #expect(jobs.jobs.count == 1)
        #expect(jobs.jobs[0].id == failed.id)
        #expect(jobs.jobs[0].status == .submitted)
        #expect(jobs.jobs[0].retryAction == .none)
    }

    @Test func successfulDelugeRetryReusesFailedJob() async {
        let deluge = DelugeCapture()
        let jobs = RecordingManualDownloadJobStore()
        var settings = synologySettings()
        settings.torrentClient = .deluge
        settings.delugeBaseURL = "http://deluge.example:8112"
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: settings,
                    credentials: NASBackendCredentials(delugePassword: "secret"),
                )
            ),
            deluge: DelugeWebClient(transport: deluge),
            jobs: jobs,
        )
        let failed = failedTorrentJob(backend: .deluge)
        await jobs.record(failed)
        let result = await handler.retryDownload(job: failed)
        #expect(result.isSubmitted)
        #expect(jobs.jobs.count == 1)
        #expect(jobs.jobs[0].id == failed.id)
        #expect(jobs.jobs[0].status == .submitted)
        #expect(jobs.jobs[0].lastError == nil)
        #expect(jobs.jobs[0].retryAction == .none)
        #expect(ManualDownloadBuckets.partition(jobs.jobs).failed.isEmpty)
        #expect(deluge.magnets.count == 1)
    }

    @Test func failedTorrentRetryLeavesOriginalJobRetryable() async {
        let qb = QBittorrentCapture()
        qb.rejectAdds = true
        let jobs = RecordingManualDownloadJobStore()
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: synologySettings(),
                    credentials: NASBackendCredentials(qbittorrentPassword: "secret"),
                )
            ),
            qbittorrent: QBittorrentClient(transport: qb),
            jobs: jobs,
        )
        let failed = failedTorrentJob(backend: .qbittorrent)
        await jobs.record(failed)
        let result = await handler.retryDownload(job: failed)
        guard case .failed = result else {
            Issue.record("retry should stay failed")
            return
        }
        #expect(jobs.jobs.count == 1)
        #expect(jobs.jobs[0].id == failed.id)
        #expect(jobs.jobs[0].status == .failed)
        #expect(jobs.jobs[0].retryAction == .retryTorrent)
        #expect(ManualDownloadBuckets.partition(jobs.jobs).failed.map(\.id) == [failed.id])
    }

    private func failedTorrentJob(backend: NASDownloadBackend) -> ManualDownloadJob {
        ManualDownloadJob(
            id: "failed-\(backend.rawValue)",
            title: "The Hobbit",
            author: "J.R.R. Tolkien",
            sourceURL: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567",
            sourceHost: "example",
            backend: backend,
            mediaType: .audiobook,
            destination: "/volume1/media/books/audiobooks",
            submittedAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: .failed,
            lastError: "qBittorrent rejected the add.",
        )
    }
}

private final class QBittorrentCapture: QBittorrentTransport, @unchecked Sendable {
    var addedURLs: [String] = []
    var addedTorrentFilenames: [String] = []
    var savePaths: [String] = []
    var rejectAdds = false
    var lastContentType: String?

    func send(
        url: URL,
        method _: String,
        body: Data?,
        contentType: String?,
        cookie _: String?,
        timeout _: TimeInterval,
    ) async throws -> QBittorrentHTTP {
        if url.path.hasSuffix("/auth/login") {
            return QBittorrentHTTP(status: 200, body: Data("Ok.".utf8), setCookie: "SID=x")
        }
        lastContentType = contentType
        if let contentType, contentType.lowercased().hasPrefix("multipart/form-data") {
            let text = String(data: body ?? Data(), encoding: .utf8) ?? ""
            if let name = multipartFilename(in: text) {
                addedTorrentFilenames.append(name)
            }
            if let path = multipartField("savepath", in: text) {
                savePaths.append(path)
            }
        } else {
            let form = String(data: body ?? Data(), encoding: .utf8) ?? ""
            if let urls = value(named: "urls", in: form) {
                addedURLs.append(urls.removingPercentEncoding ?? urls)
            }
            if let path = value(named: "savepath", in: form) {
                savePaths.append(path.removingPercentEncoding ?? path)
            }
        }
        if rejectAdds, url.path.hasSuffix("/torrents/add") {
            return QBittorrentHTTP(status: 200, body: Data("Fails.".utf8))
        }
        return QBittorrentHTTP(status: 200, body: Data("Ok.".utf8))
    }

    private func value(named key: String, in form: String) -> String? {
        for pair in form.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.first == key { return parts.count > 1 ? parts[1] : "" }
        }
        return nil
    }

    private func multipartFilename(in body: String) -> String? {
        guard let range = body.range(of: "filename=\"") else { return nil }
        let rest = body[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private func multipartField(_ name: String, in body: String) -> String? {
        let marker = "name=\"\(name)\""
        guard let range = body.range(of: marker) else { return nil }
        var rest = body[range.upperBound...]
        if let headerEnd = rest.range(of: "\r\n\r\n") {
            rest = rest[headerEnd.upperBound...]
        } else if let headerEnd = rest.range(of: "\n\n") {
            rest = rest[headerEnd.upperBound...]
        }
        if let boundary = rest.range(of: "\r\n--") {
            return String(rest[..<boundary.lowerBound])
        }
        if let boundary = rest.range(of: "\n--") {
            return String(rest[..<boundary.lowerBound])
        }
        return String(rest)
    }
}

private final class FileDownloadCapture: ManualFileDownloadTransport, @unchecked Sendable {
    var contents: Data
    var status: Int
    var callCount = 0
    var lastDestination: URL?

    init(contents: Data = Data("file".utf8), status: Int = 200) {
        self.contents = contents
        self.status = status
    }

    func downloadToFile(request _: URLRequest, destination: URL) async throws -> (
        fileURL: URL, status: Int, suggestedFilename: String?, byteCount: Int64
    ) {
        callCount += 1
        lastDestination = destination
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try contents.write(to: destination)
        return (destination, status, destination.lastPathComponent, Int64(contents.count))
    }
}

private final class UploadCapture: NASFileUploading, @unchecked Sendable {
    var destinations: [NASUploadDestination] = []
    var shouldFail: Bool
    var verified: Bool
    var omitByteCount: Bool

    init(shouldFail: Bool = false, verified: Bool = true, omitByteCount: Bool = false) {
        self.shouldFail = shouldFail
        self.verified = verified
        self.omitByteCount = omitByteCount
    }

    func upload(localFile: URL, destination: NASUploadDestination) async throws -> NASUploadResult {
        destinations.append(destination)
        if shouldFail { throw NASHandoffError.uploadRejected }
        let size: Int64?
        if omitByteCount {
            size = nil
        } else {
            size =
                (try FileManager.default.attributesOfItem(atPath: localFile.path)[.size] as? NSNumber)?
                .int64Value
        }
        return NASUploadResult(remotePath: destination.volumePath, byteCount: size, verified: verified)
    }
}

private final class DelugeCapture: DelugeTransport, @unchecked Sendable {
    var magnets: [String] = []
    var torrentURLs: [String] = []
    var torrentFilenames: [String] = []
    var torrentFiledumps: [String] = []
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
            case "core.add_torrent_magnet", "core.add_torrent_url", "core.add_torrent_file":
                let params = payload?["params"] as? [Any]
                if rpc == "core.add_torrent_magnet", let magnet = params?[0] as? String {
                    magnets.append(magnet)
                }
                if rpc == "core.add_torrent_url", let torrentURL = params?[0] as? String {
                    torrentURLs.append(torrentURL)
                }
                if rpc == "core.add_torrent_file" {
                    if let name = params?[0] as? String { torrentFilenames.append(name) }
                    if let dump = params?[1] as? String { torrentFiledumps.append(dump) }
                }
                let optionsIndex = rpc == "core.add_torrent_file" ? 2 : 1
                if let options = params?[optionsIndex] as? [String: Any],
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

/// Auth failure before any torrent is added — still leaves a magnet-derived backendJobID.
private final class DelugeAuthFailCapture: DelugeTransport, @unchecked Sendable {
    func send(
        url _: URL,
        method _: String,
        body: Data,
        cookie _: String?,
        timeout _: TimeInterval,
    ) async throws -> DelugeHTTP {
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let rpc = payload?["method"] as? String ?? ""
        if rpc == "auth.login" {
            return DelugeHTTP(
                status: 200,
                body: Data(#"{"result":false,"error":null,"id":1}"#.utf8),
            )
        }
        return DelugeHTTP(status: 200, body: Data(#"{"result":null,"error":null,"id":0}"#.utf8))
    }
}
