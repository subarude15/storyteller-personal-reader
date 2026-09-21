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
        #expect(qb.savePaths == ["/volume1/media/books/books"])
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
        #expect(deluge.locations == ["/volume1/media/books/books"])
        #expect(jobs.jobs[0].backend == .deluge)
        #expect(jobs.jobs[0].status == .submitted)
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
}

private final class QBittorrentCapture: QBittorrentTransport, @unchecked Sendable {
    var addedURLs: [String] = []
    var savePaths: [String] = []

    func send(
        url: URL,
        method _: String,
        body: Data?,
        contentType _: String?,
        cookie _: String?,
        timeout _: TimeInterval,
    ) async throws -> QBittorrentHTTP {
        if url.path.hasSuffix("/auth/login") {
            return QBittorrentHTTP(status: 200, body: Data("Ok.".utf8), setCookie: "SID=x")
        }
        let form = String(data: body ?? Data(), encoding: .utf8) ?? ""
        if let urls = value(named: "urls", in: form) {
            addedURLs.append(urls.removingPercentEncoding ?? urls)
        }
        if let path = value(named: "savepath", in: form) {
            savePaths.append(path.removingPercentEncoding ?? path)
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
                if let magnet = params?[0] as? String { magnets.append(magnet) }
                if let options = params?[1] as? [String: Any],
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
