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

    @Test func magnetRoutesToQBittorrentWithAudiobookDestination() async {
        let qb = QBittorrentCapture()
        let jobs = RecordingManualDownloadJobStore()
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: NASDownloadSettingsSnapshot(
                        torrentClient: .qbittorrent,
                        qbittorrentBaseURL: "http://qb.example:8080",
                        qbittorrentUsername: "admin",
                        audiobookFolder: "/media/audiobooks",
                        ebookFolder: "/media/books",
                    ),
                    credentials: NASBackendCredentials(qbittorrentPassword: "secret"),
                )
            ),
            qbittorrent: QBittorrentClient(transport: qb),
            jobs: jobs,
        )
        let candidate = ManualAcquisitionCandidate(
            sourceURL: URL(string: "magnet:?xt=urn:btih:abc")!,
            detectedType: .magnet,
            bookMetadata: audiobook,
        )
        let result = await handler.handle(candidate)
        #expect(result.isSubmitted)
        #expect(result.message == "The download was added to qBittorrent.")
        #expect(!result.message.lowercased().contains("complete"))
        #expect(qb.addedURLs == ["magnet:?xt=urn:btih:abc"])
        #expect(qb.savePaths == ["/media/audiobooks"])
        #expect(jobs.jobs.count == 1)
        #expect(jobs.jobs[0].status == .queued)
        #expect(jobs.jobs[0].backend == .qbittorrent)
        #expect(jobs.jobs[0].destination == "/media/audiobooks")
    }

    @Test func epubRoutesToAria2WithEbookDestination() async {
        let aria = Aria2Capture()
        let jobs = RecordingManualDownloadJobStore()
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: NASDownloadSettingsSnapshot(
                        torrentClient: .qbittorrent,
                        qbittorrentBaseURL: "http://qb.example:8080",
                        aria2RPCURL: "http://aria.example:6800",
                        audiobookFolder: "/media/audiobooks",
                        ebookFolder: "/media/books",
                    ),
                    credentials: NASBackendCredentials(aria2Secret: "tok"),
                )
            ),
            aria2: Aria2Client(transport: aria),
            jobs: jobs,
        )
        let candidate = ManualAcquisitionCandidate(
            sourceURL: URL(string: "https://files.example/hobbit.epub")!,
            detectedType: .epub,
            filename: "The Hobbit.epub",
            bookMetadata: ebook,
        )
        let result = await handler.handle(candidate)
        #expect(result.isSubmitted)
        #expect(result.message == "The download was added to aria2.")
        #expect(aria.uris == ["https://files.example/hobbit.epub"])
        #expect(aria.directories == ["/media/books"])
        #expect(aria.filenames == ["The Hobbit.epub"])
        #expect(jobs.jobs[0].status == .queued)
        #expect(jobs.jobs[0].backend == .aria2)
    }

    @Test func successMeansSubmittedNotCompleted() async {
        let qb = QBittorrentCapture()
        let jobs = RecordingManualDownloadJobStore()
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: NASDownloadSettingsSnapshot(
                        torrentClient: .qbittorrent,
                        qbittorrentBaseURL: "http://qb.example:8080",
                        audiobookFolder: "/media/audiobooks",
                    )
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
        guard case .submitted = result else {
            Issue.record("expected submitted")
            return
        }
        #expect(jobs.jobs[0].status != .complete)
        #expect(jobs.jobs[0].status != .downloading)
    }

    @Test func unreachablePreservesFailureForRetry() async {
        let transport = QBittorrentFailing(error: URLError(.cannotConnectToHost))
        let jobs = RecordingManualDownloadJobStore()
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: NASDownloadSettingsSnapshot(
                        torrentClient: .qbittorrent,
                        qbittorrentBaseURL: "http://qb.example:8080",
                        audiobookFolder: "/media/audiobooks",
                    )
                )
            ),
            qbittorrent: QBittorrentClient(transport: transport),
            jobs: jobs,
        )
        let candidate = ManualAcquisitionCandidate(
            sourceURL: URL(string: "magnet:?xt=urn:btih:abc")!,
            detectedType: .magnet,
            bookMetadata: audiobook,
        )
        let result = await handler.handle(candidate)
        guard case .failed(let message) = result else {
            Issue.record("expected failure")
            return
        }
        #expect(message.contains("qBittorrent"))
        #expect(!message.contains("secret"))
        #expect(jobs.jobs[0].status == .failed)
        let retry = await handler.handle(candidate)
        guard case .failed = retry else {
            Issue.record("retry should still fail while unreachable")
            return
        }
        #expect(jobs.jobs.count >= 1)
    }

    @Test func malformedMagnetIsRejected() async {
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: NASDownloadSettingsSnapshot(
                        torrentClient: .qbittorrent,
                        qbittorrentBaseURL: "http://qb.example:8080",
                        audiobookFolder: "/media/audiobooks",
                    )
                )
            )
        )
        let result = await handler.handle(
            ManualAcquisitionCandidate(
                sourceURL: URL(string: "magnet:invalid")!,
                detectedType: .magnet,
                bookMetadata: audiobook,
            )
        )
        #expect(result == .failed(message: NASHandoffError.malformedMagnet.message))
    }

    @Test func torrentDoesNotUseAria2() async {
        let aria = Aria2Capture()
        let qb = QBittorrentCapture()
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: NASDownloadSettingsSnapshot(
                        torrentClient: .qbittorrent,
                        qbittorrentBaseURL: "http://qb.example:8080",
                        aria2RPCURL: "http://aria.example:6800",
                        ebookFolder: "/media/books",
                    )
                )
            ),
            qbittorrent: QBittorrentClient(transport: qb),
            aria2: Aria2Client(transport: aria),
        )
        _ = await handler.handle(
            ManualAcquisitionCandidate(
                sourceURL: URL(string: "https://files.example/hobbit.torrent")!,
                detectedType: .torrent,
                bookMetadata: ebook,
            )
        )
        #expect(aria.uris.isEmpty)
        #expect(qb.addedURLs == ["https://files.example/hobbit.torrent"])
        #expect(qb.savePaths == ["/media/books"])
    }

    @Test func secretsAreRedacted() {
        let text = NASHandoffMessages.redact(
            "password=super-secret token:super-secret",
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

private final class QBittorrentFailing: QBittorrentTransport, @unchecked Sendable {
    var error: URLError

    init(error: URLError) {
        self.error = error
    }

    func send(
        url _: URL,
        method _: String,
        body _: Data?,
        contentType _: String?,
        cookie _: String?,
        timeout _: TimeInterval,
    ) async throws -> QBittorrentHTTP {
        throw error
    }
}

private final class Aria2Capture: Aria2Transport, @unchecked Sendable {
    var uris: [String] = []
    var directories: [String] = []
    var filenames: [String] = []

    func send(url _: URL, body: Data, timeout _: TimeInterval) async throws -> Aria2HTTP {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let params = json?["params"] as? [Any] ?? []
        let start = (params.first as? String)?.hasPrefix("token:") == true ? 1 : 0
        if let list = params.dropFirst(start).first as? [String] {
            uris.append(contentsOf: list)
        }
        if let options = params.dropFirst(start + 1).first as? [String: String] {
            if let dir = options["dir"] { directories.append(dir) }
            if let out = options["out"] { filenames.append(out) }
        }
        return Aria2HTTP(
            status: 200,
            body: Data(#"{"jsonrpc":"2.0","id":2,"result":"gid1"}"#.utf8),
        )
    }
}
