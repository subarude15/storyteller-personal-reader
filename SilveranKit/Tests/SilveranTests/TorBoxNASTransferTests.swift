//
//  TorBoxNASTransferTests.swift
//  SilveranTests
//
//  TorBox Phase 2: file selection, Ready → NAS transfer, idempotency.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit
import Testing

@Suite("TorBox media file selection")
struct TorBoxMediaFileSelectionTests {
    @Test func ebookChoosesEpubAndIgnoresJunk() {
        let files: [TorrentJobFile] = [
            .init(id: "1", name: "The Hobbit.epub", size: 2_800_000),
            .init(id: "2", name: "cover.jpg", size: 40_000),
            .init(id: "3", name: "readme.txt", size: 120),
            .init(id: "4", name: "sample.epub", size: 10_000),
        ]
        let selected = TorBoxMediaFileSelection.select(files: files, mediaType: .ebook)
        #expect(selected.map(\.name) == ["The Hobbit.epub"])
    }

    @Test func ebookPrefersEpubOverPdf() {
        let files: [TorrentJobFile] = [
            .init(id: "1", name: "book.pdf", size: 5_000_000),
            .init(id: "2", name: "book.epub", size: 1_000_000),
        ]
        let selected = TorBoxMediaFileSelection.select(files: files, mediaType: .ebook)
        #expect(selected.map(\.name) == ["book.epub"])
    }

    @Test func audiobookPreservesMultipleTracksAndOrder() {
        let files: [TorrentJobFile] = [
            .init(id: "3", name: "Book/03 Chapter Three.mp3", size: 10),
            .init(id: "1", name: "Book/01 Chapter One.mp3", size: 10),
            .init(id: "2", name: "Book/02 Chapter Two.mp3", size: 10),
            .init(id: "4", name: "Book/cover.jpg", size: 5),
            .init(id: "5", name: "Book/metadata.nfo", size: 1),
        ]
        let selected = TorBoxMediaFileSelection.select(files: files, mediaType: .audiobook)
        #expect(selected.map(\.name) == [
            "01 Chapter One.mp3",
            "02 Chapter Two.mp3",
            "03 Chapter Three.mp3",
        ])
        #expect(selected[0].relativePath.contains("01 Chapter One.mp3"))
    }

    @Test func archivesAreNotSelected() {
        let files: [TorrentJobFile] = [
            .init(id: "1", name: "book.zip", size: 9),
            .init(id: "2", name: "audio.rar", size: 9),
        ]
        #expect(TorBoxMediaFileSelection.select(files: files, mediaType: .ebook).isEmpty)
        #expect(TorBoxMediaFileSelection.select(files: files, mediaType: .audiobook).isEmpty)
        #expect(TorBoxMediaFileSelection.unsupportedArchiveNames(in: files).count == 2)
    }
}

@Suite("TorBox NAS transfer")
struct TorBoxNASTransferTests {
    @Test func readyEbookRoutesToEbookDestination() {
        let settings = NASDownloadSettingsSnapshot(
            torrentClient: .torbox,
            torboxEnabled: true,
            ebookFolder: "/volume1/media/books/books",
            audiobookFolder: "/volume1/media/books/audiobooks",
        )
        #expect(settings.folder(for: .ebook) == "/volume1/media/books/books")
        #expect(settings.folder(for: .audiobook) == "/volume1/media/books/audiobooks")
    }

    @Test func autoTransferStartsWhenEnabled() async {
        let store = RecordingManualDownloadJobStore()
        let transfer = MockRemoteTransfer()
        let torbox = TorBoxScript()
        var requestedURLs = 0
        torbox.handler = { url, _, _, _, _ in
            if url.path.hasSuffix("/torrents/requestdl") {
                requestedURLs += 1
                #expect(!url.absoluteString.contains("Bearer"))
                return TorBoxHTTP(
                    status: 200,
                    body: Data(
                        #"{"success":true,"error":null,"detail":"ok","data":"https://cdn.example/file?sig=temp"}"#
                            .utf8
                    ),
                )
            }
            Issue.record("unexpected \(url)")
            return TorBoxHTTP(status: 500, body: Data())
        }
        let job = readyJob(
            mediaType: .ebook,
            files: [.init(id: "7", name: "The Hobbit.epub", size: 100)],
            destination: "/volume1/media/books/books/Tolkien/The Hobbit",
        )
        await store.record(job)
        let service = TorBoxNASTransferService(
            environment: env(auto: true),
            torbox: TorBoxClient(transport: torbox),
            jobs: store,
            transferFactory: { _ in transfer },
            gate: TorBoxTransferGate(),
        )
        let changed = await service.reconcile(autoStartReady: true)
        #expect(!changed.isEmpty)
        let updated = await store.job(id: job.id)
        #expect(updated?.status == .complete)
        #expect(requestedURLs == 1)
        #expect(transfer.startedFilenames == ["The Hobbit.epub"])
    }

    @Test func autoTransferDisabledWaitsForManual() async {
        let store = RecordingManualDownloadJobStore()
        let transfer = MockRemoteTransfer()
        let job = readyJob(
            mediaType: .ebook,
            files: [.init(id: "7", name: "book.epub", size: 10)],
            destination: "/volume1/media/books/books/A/B",
        )
        await store.record(job)
        let service = TorBoxNASTransferService(
            environment: env(auto: false),
            torbox: TorBoxClient(transport: TorBoxScript()),
            jobs: store,
            transferFactory: { _ in transfer },
            gate: TorBoxTransferGate(),
        )
        let changed = await service.reconcile(autoStartReady: true)
        #expect(changed.isEmpty)
        #expect(await store.job(id: job.id)?.status == .ready)
        #expect(transfer.startedFilenames.isEmpty)
        #expect(job.canTransferToNASNow)
    }

    @Test func downloadURLRequestedOnlyWhenTransferBegins() async {
        let store = RecordingManualDownloadJobStore()
        let transfer = MockRemoteTransfer()
        var requested = 0
        let torbox = TorBoxScript()
        torbox.handler = { url, _, _, _, _ in
            if url.path.hasSuffix("/torrents/requestdl") {
                requested += 1
                return TorBoxHTTP(
                    status: 200,
                    body: Data(
                        #"{"success":true,"error":null,"detail":"ok","data":"https://cdn.example/x"}"#
                            .utf8
                    ),
                )
            }
            return TorBoxHTTP(status: 404, body: Data())
        }
        let job = readyJob(
            mediaType: .ebook,
            files: [.init(id: "1", name: "a.epub", size: 5)],
            destination: "/volume1/media/books/books/A/B",
        )
        await store.record(job)
        #expect(requested == 0)
        let service = TorBoxNASTransferService(
            environment: env(auto: true),
            torbox: TorBoxClient(transport: torbox),
            jobs: store,
            transferFactory: { _ in transfer },
            gate: TorBoxTransferGate(),
        )
        _ = await service.transfer(job: job)
        #expect(requested == 1)
        let saved = await store.job(id: job.id)
        let encoded = try! JSONEncoder().encode(saved)
        let json = String(data: encoded, encoding: .utf8) ?? ""
        #expect(!json.contains("cdn.example"))
        #expect(!json.contains("sig="))
    }

    @Test func successfulMultiFileTransferCompletes() async {
        let store = RecordingManualDownloadJobStore()
        let transfer = MockRemoteTransfer()
        let torbox = TorBoxScript()
        torbox.handler = { url, _, _, _, _ in
            if url.path.hasSuffix("/torrents/requestdl") {
                return TorBoxHTTP(
                    status: 200,
                    body: Data(
                        #"{"success":true,"error":null,"detail":"ok","data":"https://cdn.example/a"}"#
                            .utf8
                    ),
                )
            }
            return TorBoxHTTP(status: 404, body: Data())
        }
        let job = readyJob(
            mediaType: .audiobook,
            files: [
                .init(id: "1", name: "Book/01.mp3", size: 10),
                .init(id: "2", name: "Book/02.mp3", size: 10),
            ],
            destination: "/volume1/media/books/audiobooks/Author/Title",
        )
        await store.record(job)
        let service = TorBoxNASTransferService(
            environment: env(auto: true),
            torbox: TorBoxClient(transport: torbox),
            jobs: store,
            transferFactory: { _ in transfer },
            gate: TorBoxTransferGate(),
        )
        let result = await service.transfer(job: job)
        #expect(result.status == .complete)
        #expect(result.transferFiles?.count == 2)
        #expect(result.transferFiles?.allSatisfy { $0.status == .complete } == true)
    }

    @Test func partialMultiFileFailureIsNotComplete() async {
        let store = RecordingManualDownloadJobStore()
        let transfer = MockRemoteTransfer()
        transfer.failFilenames = ["02.mp3"]
        let torbox = TorBoxScript()
        torbox.handler = { url, _, _, _, _ in
            if url.path.hasSuffix("/torrents/requestdl") {
                return TorBoxHTTP(
                    status: 200,
                    body: Data(
                        #"{"success":true,"error":null,"detail":"ok","data":"https://cdn.example/a"}"#
                            .utf8
                    ),
                )
            }
            return TorBoxHTTP(status: 404, body: Data())
        }
        let job = readyJob(
            mediaType: .audiobook,
            files: [
                .init(id: "1", name: "01.mp3", size: 10),
                .init(id: "2", name: "02.mp3", size: 10),
            ],
            destination: "/volume1/media/books/audiobooks/A/T",
        )
        await store.record(job)
        let service = TorBoxNASTransferService(
            environment: env(auto: true),
            torbox: TorBoxClient(transport: torbox),
            jobs: store,
            transferFactory: { _ in transfer },
            gate: TorBoxTransferGate(),
        )
        let result = await service.transfer(job: job)
        #expect(result.status == .failed)
        #expect(result.status != .complete)
        #expect(result.canRetryTransferNow)
        #expect(result.retryAction == .retryTransfer)
        let complete = result.transferFiles?.filter { $0.status == .complete }.count
        let failed = result.transferFiles?.filter { $0.status == .failed }.count
        #expect(complete == 1)
        #expect(failed == 1)
    }

    @Test func retryDoesNotDuplicateCompletedFiles() async {
        let store = RecordingManualDownloadJobStore()
        let transfer = MockRemoteTransfer()
        transfer.failFilenames = ["02.mp3"]
        let torbox = TorBoxScript()
        torbox.handler = { url, _, _, _, _ in
            if url.path.hasSuffix("/torrents/requestdl") {
                return TorBoxHTTP(
                    status: 200,
                    body: Data(
                        #"{"success":true,"error":null,"detail":"ok","data":"https://cdn.example/a"}"#
                            .utf8
                    ),
                )
            }
            return TorBoxHTTP(status: 404, body: Data())
        }
        let job = readyJob(
            mediaType: .audiobook,
            files: [
                .init(id: "1", name: "01.mp3", size: 10),
                .init(id: "2", name: "02.mp3", size: 10),
            ],
            destination: "/volume1/media/books/audiobooks/A/T",
        )
        await store.record(job)
        let service = TorBoxNASTransferService(
            environment: env(auto: true),
            torbox: TorBoxClient(transport: torbox),
            jobs: store,
            transferFactory: { _ in transfer },
            gate: TorBoxTransferGate(),
        )
        let failed = await service.transfer(job: job)
        #expect(failed.status == .failed)
        transfer.failFilenames = []
        transfer.existingFilenames = ["01.mp3"]
        let startsBefore = transfer.startCount
        let recovered = await service.transfer(job: failed)
        #expect(recovered.status == .complete)
        // Only the missing file should be started again.
        #expect(transfer.startCount - startsBefore == 1)
        #expect(transfer.startedFilenames.last == "02.mp3")
    }

    @Test func repeatedTransferWhileInFlightIsIdempotent() async {
        let store = RecordingManualDownloadJobStore()
        let transfer = MockRemoteTransfer()
        transfer.holdTaskIDs = true
        let torbox = TorBoxScript()
        torbox.handler = { url, _, _, _, _ in
            if url.path.hasSuffix("/torrents/requestdl") {
                return TorBoxHTTP(
                    status: 200,
                    body: Data(
                        #"{"success":true,"error":null,"detail":"ok","data":"https://cdn.example/a"}"#
                            .utf8
                    ),
                )
            }
            return TorBoxHTTP(status: 404, body: Data())
        }
        let job = readyJob(
            mediaType: .ebook,
            files: [.init(id: "1", name: "a.epub", size: 10)],
            destination: "/volume1/media/books/books/A/B",
        )
        await store.record(job)
        let gate = TorBoxTransferGate()
        #expect(await gate.begin(job.id))
        let service = TorBoxNASTransferService(
            environment: env(auto: true),
            torbox: TorBoxClient(transport: torbox),
            jobs: store,
            transferFactory: { _ in transfer },
            gate: gate,
        )
        // Gate already held — transfer must no-op without starting NAS work.
        let blocked = await service.transfer(job: job)
        #expect(blocked.status == .ready)
        #expect(transfer.startCount == 0)
        await gate.end(job.id)
        let started = await service.transfer(job: job)
        #expect(started.status == .transferring)
        #expect(transfer.startCount == 1)
    }

    @Test func nasUnavailableSurfacesUsefulError() async {
        let store = RecordingManualDownloadJobStore()
        let transfer = MockRemoteTransfer()
        transfer.ensureFailsWith = .nasUnreachable
        let job = readyJob(
            mediaType: .ebook,
            files: [.init(id: "1", name: "a.epub", size: 10)],
            destination: "/volume1/media/books/books/A/B",
        )
        await store.record(job)
        let service = TorBoxNASTransferService(
            environment: env(auto: true),
            torbox: TorBoxClient(transport: TorBoxScript()),
            jobs: store,
            transferFactory: { _ in transfer },
            gate: TorBoxTransferGate(),
        )
        let result = await service.transfer(job: job)
        #expect(result.status == .failed)
        #expect(result.lastError?.contains("Could not reach the NAS") == true)
        #expect(result.lastError?.contains("still safe in the cloud") == true)
    }

    @Test func destinationMissingSurfacesUsefulError() async {
        let store = RecordingManualDownloadJobStore()
        let transfer = MockRemoteTransfer()
        transfer.ensureFailsWith = .destinationMissing
        let job = readyJob(
            mediaType: .ebook,
            files: [.init(id: "1", name: "a.epub", size: 10)],
            destination: "/volume1/media/books/books/A/B",
        )
        await store.record(job)
        let service = TorBoxNASTransferService(
            environment: env(auto: true),
            torbox: TorBoxClient(transport: TorBoxScript()),
            jobs: store,
            transferFactory: { _ in transfer },
            gate: TorBoxTransferGate(),
        )
        let result = await service.transfer(job: job)
        #expect(result.status == .failed)
        #expect(result.lastError?.contains("destination folder") == true)
    }

    @Test func expiredURLRequestsFreshLinkOnRetry() async {
        let store = RecordingManualDownloadJobStore()
        let transfer = MockRemoteTransfer()
        transfer.expireOnceFilenames = ["a.epub"]
        var requested = 0
        let torbox = TorBoxScript()
        torbox.handler = { url, _, _, _, _ in
            if url.path.hasSuffix("/torrents/requestdl") {
                requested += 1
                return TorBoxHTTP(
                    status: 200,
                    body: Data(
                        #"{"success":true,"error":null,"detail":"ok","data":"https://cdn.example/fresh"}"#
                            .utf8
                    ),
                )
            }
            return TorBoxHTTP(status: 404, body: Data())
        }
        let job = readyJob(
            mediaType: .ebook,
            files: [.init(id: "1", name: "a.epub", size: 10)],
            destination: "/volume1/media/books/books/A/B",
        )
        await store.record(job)
        let service = TorBoxNASTransferService(
            environment: env(auto: true),
            torbox: TorBoxClient(transport: torbox),
            jobs: store,
            transferFactory: { _ in transfer },
            gate: TorBoxTransferGate(),
        )
        let result = await service.transfer(job: job)
        #expect(result.status == .complete)
        #expect(requested == 2)
    }

    @Test func transferringStatusIsActiveAndLabeled() {
        #expect(ManualDownloadJobStatus.transferring.isActive)
        #expect(ManualDownloadJobStatus.transferring.label == "Transferring to NAS")
        #expect(ManualDownloadJobStatus.ready.isActive == false)
        #expect(ManualDownloadJobStatus.ready.label == "Ready")
    }

    @Test func downloadStationDestinationStripsVolume() {
        let dest = SynologyDownloadStationClient.downloadStationDestination(
            fromVolumePath: "/volume1/media/books/books/Author/Title"
        )
        #expect(dest == "media/books/books/Author/Title")
    }
}

// MARK: - Helpers

private func env(auto: Bool) -> StaticNASHandoffEnvironment {
    StaticNASHandoffEnvironment(
        context: NASHandoffContext(
            settings: NASDownloadSettingsSnapshot(
                torrentClient: .torbox,
                torboxEnabled: true,
                torboxAutoTransferToNAS: auto,
                synologyBaseURL: "http://nas.example:5000",
                synologyUsername: "josh",
                ebookFolder: "/volume1/media/books/books",
                audiobookFolder: "/volume1/media/books/audiobooks",
            ),
            credentials: NASBackendCredentials(
                synologyPassword: "pw",
                torboxAPIKey: "key",
            ),
        )
    )
}

private func readyJob(
    mediaType: NASMediaKind,
    files: [TorrentJobFile],
    destination: String,
) -> ManualDownloadJob {
    ManualDownloadJob(
        title: "The Hobbit",
        author: "Tolkien",
        sourceHost: "torbox",
        backend: .torbox,
        mediaType: mediaType,
        destination: destination,
        backendJobID: "42",
        status: .ready,
        providerFiles: files,
    )
}

private final class TorBoxScript: TorBoxTransport, @unchecked Sendable {
    var handler: @Sendable (URL, String, [String: String], Data?, String?) async throws -> TorBoxHTTP = {
        _, _, _, _, _ in TorBoxHTTP(status: 500, body: Data())
    }

    func send(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        contentType: String?,
        timeout: TimeInterval,
    ) async throws -> TorBoxHTTP {
        try await handler(url, method, headers, body, contentType)
    }
}

private final class MockRemoteTransfer: RemoteMediaTransferring, @unchecked Sendable {
    var startedFilenames: [String] = []
    var startCount = 0
    var existingFilenames: Set<String> = []
    var failFilenames: Set<String> = []
    var expireOnceFilenames: Set<String> = []
    var ensureFailsWith: RemoteTransferError?
    var holdTaskIDs = false
    private var taskCounter = 0
    private var tasks: [String: SynologyDownloadTaskSnapshot] = [:]

    func ensureDestination(_ destination: NASTransferDestination) async throws {
        if let ensureFailsWith { throw ensureFailsWith }
    }

    func remoteFileExists(
        destination: NASTransferDestination,
        filename: String,
        expectedSize: Int64?,
    ) async throws -> Bool {
        existingFilenames.contains(filename)
    }

    func startDownload(
        source: RemoteDownloadSource,
        destination: NASTransferDestination,
    ) async throws -> String? {
        // Never log or retain source.url beyond this call.
        _ = source.url
        if expireOnceFilenames.contains(source.filename) {
            expireOnceFilenames.remove(source.filename)
            throw RemoteTransferError.linkExpired
        }
        if failFilenames.contains(source.filename) {
            throw RemoteTransferError.rejected
        }
        startCount += 1
        startedFilenames.append(source.filename)
        if holdTaskIDs {
            taskCounter += 1
            let id = "task-\(taskCounter)"
            tasks[id] = SynologyDownloadTaskSnapshot(
                id: id,
                title: source.filename,
                size: source.expectedSize ?? 0,
                status: .downloading,
            )
            return id
        }
        existingFilenames.insert(source.filename)
        return nil
    }

    func taskSnapshot(taskID: String) async throws -> SynologyDownloadTaskSnapshot? {
        tasks[taskID]
    }

    func listDestinationFilenames(destination: NASTransferDestination) async throws -> [String] {
        Array(existingFilenames)
    }

    func renameInDestination(
        destination: NASTransferDestination,
        from: String,
        to: String,
    ) async throws {
        if existingFilenames.remove(from) != nil {
            existingFilenames.insert(to)
        }
    }

    func verifyFile(
        destination: NASTransferDestination,
        filename: String,
        expectedSize: Int64?,
    ) async throws -> Bool {
        existingFilenames.contains(filename)
    }
}
