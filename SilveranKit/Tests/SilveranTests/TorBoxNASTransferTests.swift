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
            audiobookFolder: "/volume1/media/books/audiobooks",
            ebookFolder: "/volume1/media/books/books",
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

    @Test func createWithoutTaskIDStillStartsExactlyOneNASTask() async {
        let store = RecordingManualDownloadJobStore()
        let transfer = MockRemoteTransfer()
        transfer.omitTaskIDFromCreate = true
        transfer.holdTaskIDs = true
        let torbox = TorBoxScript()
        var requested = 0
        torbox.handler = { url, _, _, _, _ in
            if url.path.hasSuffix("/torrents/requestdl") {
                requested += 1
                return TorBoxHTTP(
                    status: 200,
                    body: Data(
                        #"{"success":true,"error":null,"detail":"ok","data":"https://cdn.example/sig"}"#
                            .utf8
                    ),
                )
            }
            return TorBoxHTTP(status: 404, body: Data())
        }
        let job = readyJob(
            mediaType: .ebook,
            files: [.init(id: "1", name: "The Hobbit.epub", size: 10)],
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
        let first = await service.transfer(job: job)
        #expect(first.status == .transferring)
        #expect(first.transferFiles?.first?.status == .started)
        #expect(transfer.startCount == 1)
        #expect(requested == 1)
        // Discovery attaches the missing task ID without a second create.
        #expect(first.transferFiles?.first?.nasTaskID == "task-1")

        let second = await service.reconcile(autoStartReady: false)
        #expect(transfer.startCount == 1)
        #expect(requested == 1)
        #expect(second.first?.transferFiles?.first?.nasTaskID == "task-1")
    }

    @Test func multipleReconcilePassesDoNotDuplicateStartedWithoutTaskID() async {
        let store = RecordingManualDownloadJobStore()
        let transfer = MockRemoteTransfer()
        transfer.omitTaskIDFromCreate = true
        transfer.holdTaskIDs = true
        let torbox = TorBoxScript()
        var requested = 0
        torbox.handler = { url, _, _, _, _ in
            if url.path.hasSuffix("/torrents/requestdl") {
                requested += 1
                return TorBoxHTTP(
                    status: 200,
                    body: Data(
                        #"{"success":true,"error":null,"detail":"ok","data":"https://cdn.example/sig"}"#
                            .utf8
                    ),
                )
            }
            return TorBoxHTTP(status: 404, body: Data())
        }
        var job = readyJob(
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
        job = await service.transfer(job: job)
        // Simulate relaunch: persisted started with no task ID yet discovered.
        var persisted = job
        persisted.transferFiles?[0].nasTaskID = nil
        persisted.transferFiles?[0].status = .started
        persisted.status = .transferring
        await store.record(persisted)

        for _ in 0..<3 {
            _ = await service.reconcile(autoStartReady: false)
        }
        #expect(transfer.startCount == 1)
        #expect(requested == 1)
        let latest = await store.job(id: job.id)
        #expect(latest?.status == .transferring)
        #expect(latest?.transferFiles?.first?.status == .started)
    }

    @Test func landedFileCompletesWithoutCreatingAnotherTask() async {
        let store = RecordingManualDownloadJobStore()
        let transfer = MockRemoteTransfer()
        let job = readyJob(
            mediaType: .ebook,
            files: [.init(id: "1", name: "a.epub", size: 10)],
            destination: "/volume1/media/books/books/A/B",
        )
        var transferring = job
        transferring.status = .transferring
        transferring.transferFiles = [
            RemoteTransferFileState(
                id: "1",
                filename: "a.epub",
                relativePath: "a.epub",
                expectedSize: 10,
                nasTaskID: nil,
                status: .started,
            ),
        ]
        transfer.existingFilenames = ["a.epub"]
        await store.record(transferring)
        let service = TorBoxNASTransferService(
            environment: env(auto: true),
            torbox: TorBoxClient(transport: TorBoxScript()),
            jobs: store,
            transferFactory: { _ in transfer },
            gate: TorBoxTransferGate(),
        )
        let updated = await service.reconcile(autoStartReady: false)
        #expect(updated.first?.status == .complete)
        #expect(transfer.startCount == 0)
    }

    @Test func renameOnlyUsesTaskTitleNeverArbitraryDirectoryFiles() async {
        let store = RecordingManualDownloadJobStore()
        let transfer = MockRemoteTransfer()
        transfer.dsOutputTitle = "temporary-name.epub"
        transfer.existingFilenames = ["cover.jpg", "old-book.epub", "notes.txt"]
        let torbox = TorBoxScript()
        torbox.handler = { url, _, _, _, _ in
            if url.path.hasSuffix("/torrents/requestdl") {
                return TorBoxHTTP(
                    status: 200,
                    body: Data(
                        #"{"success":true,"error":null,"detail":"ok","data":"https://cdn.example/sig"}"#
                            .utf8
                    ),
                )
            }
            return TorBoxHTTP(status: 404, body: Data())
        }
        let job = readyJob(
            mediaType: .ebook,
            files: [.init(id: "1", name: "The Hobbit.epub", size: 10)],
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
        let result = await service.transfer(job: job)
        #expect(result.status == .complete)
        #expect(transfer.renamedPairs == [(from: "temporary-name.epub", to: "The Hobbit.epub")])
        #expect(transfer.existingFilenames.contains("cover.jpg"))
        #expect(transfer.existingFilenames.contains("old-book.epub"))
        #expect(transfer.existingFilenames.contains("notes.txt"))
        #expect(transfer.existingFilenames.contains("The Hobbit.epub"))
        #expect(!transfer.existingFilenames.contains("temporary-name.epub"))
    }

    @Test func unidentifiedOutputDoesNotRenameUnrelatedFiles() async {
        let store = RecordingManualDownloadJobStore()
        let transfer = MockRemoteTransfer()
        // Finished task with empty title — cannot safely identify output.
        transfer.dsOutputTitle = ""
        transfer.existingFilenames = ["cover.jpg", "old-book.epub", "mystery.bin"]
        let torbox = TorBoxScript()
        torbox.handler = { url, _, _, _, _ in
            if url.path.hasSuffix("/torrents/requestdl") {
                return TorBoxHTTP(
                    status: 200,
                    body: Data(
                        #"{"success":true,"error":null,"detail":"ok","data":"https://cdn.example/sig"}"#
                            .utf8
                    ),
                )
            }
            return TorBoxHTTP(status: 404, body: Data())
        }
        let job = readyJob(
            mediaType: .ebook,
            files: [.init(id: "1", name: "The Hobbit.epub", size: 10)],
            destination: "/volume1/media/books/books/Tolkien/The Hobbit",
        )
        await store.record(job)
        // Force a finished snapshot with blank title after create.
        let service = TorBoxNASTransferService(
            environment: env(auto: true),
            torbox: TorBoxClient(transport: torbox),
            jobs: store,
            transferFactory: { _ in transfer },
            gate: TorBoxTransferGate(),
        )
        // Manually drive rename path via reconcileTask semantics: start then finish blank title.
        transfer.holdTaskIDs = true
        transfer.dsOutputTitle = "   "
        let started = await service.transfer(job: job)
        #expect(started.status == .transferring)
        if let taskID = started.transferFiles?.first?.nasTaskID {
            transfer.markTaskFinished(taskID, placeOutput: false)
        }
        await store.record(started)
        let after = await service.reconcile(autoStartReady: false)
        #expect(after.first?.status == .failed)
        #expect(after.first?.lastError?.contains("could not be identified") == true)
        #expect(transfer.renamedPairs.isEmpty)
        #expect(transfer.existingFilenames.contains("cover.jpg"))
        #expect(transfer.existingFilenames.contains("old-book.epub"))
        #expect(transfer.existingFilenames.contains("mystery.bin"))
    }
}

@Suite("Download Station task identity")
struct SynologyDownloadStationIdentityTests {
    @Test func identifyCreatedTaskUsesBeforeAfterDiff() {
        let before = [
            SynologyDownloadTaskSnapshot(
                id: "dbid_1",
                title: "old.epub",
                size: 1,
                status: .finished,
                destination: "media/books/books",
            ),
        ]
        let after = before + [
            SynologyDownloadTaskSnapshot(
                id: "dbid_2",
                title: "The Hobbit.epub",
                size: 10,
                status: .downloading,
                destination: "media/books/books/Tolkien/The Hobbit",
            ),
        ]
        let found = SynologyDownloadStationClient.identifyCreatedTask(
            before: before,
            after: after,
            destination: "media/books/books/Tolkien/The Hobbit",
            expectedFilename: "The Hobbit.epub",
        )
        #expect(found?.id == "dbid_2")
    }

    @Test func identifyCreatedTaskDoesNotUseAmbiguousPeers() {
        let before: [SynologyDownloadTaskSnapshot] = []
        let after = [
            SynologyDownloadTaskSnapshot(
                id: "a",
                title: "one.epub",
                size: 1,
                status: .downloading,
                destination: "media/books/books",
            ),
            SynologyDownloadTaskSnapshot(
                id: "b",
                title: "two.epub",
                size: 2,
                status: .downloading,
                destination: "media/books/books",
            ),
        ]
        let found = SynologyDownloadStationClient.identifyCreatedTask(
            before: before,
            after: after,
            destination: "media/books/books",
            expectedFilename: "missing.epub",
        )
        #expect(found == nil)
    }

    @Test func createURLTaskRecoversIDWhenResponseOmitsTaskID() async throws {
        let transport = DownloadStationScript()
        var listCalls = 0
        var knownTasks: [[String: Any]] = [
            [
                "id": "dbid_old",
                "title": "prior.epub",
                "size": 1,
                "status": "finished",
                "additional": ["detail": ["destination": "media/books/books"]],
            ],
        ]
        transport.handler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("auth.cgi"), request.httpMethod == "POST" {
                return SynologyHTTP(
                    status: 200,
                    body: Data(#"{"success":true,"data":{"sid":"sid-1"}}"#.utf8),
                )
            }
            if url.contains("method=list") {
                listCalls += 1
                let payload: [String: Any] = [
                    "success": true,
                    "data": ["tasks": knownTasks],
                ]
                let data = try! JSONSerialization.data(withJSONObject: payload)
                return SynologyHTTP(status: 200, body: data)
            }
            if url.contains("method=create") {
                #expect(url.contains("destination=media"))
                knownTasks.append([
                    "id": "dbid_new",
                    "title": "The Hobbit.epub",
                    "size": 10,
                    "status": "downloading",
                    "additional": [
                        "detail": ["destination": "media/books/books/Tolkien/The Hobbit"],
                    ],
                ])
                // DSM success with no task_id — the bug case.
                return SynologyHTTP(status: 200, body: Data(#"{"success":true}"#.utf8))
            }
            if url.contains("method=logout") {
                return SynologyHTTP(status: 200, body: Data(#"{"success":true}"#.utf8))
            }
            return SynologyHTTP(status: 200, body: Data(#"{"success":true}"#.utf8))
        }
        let client = SynologyDownloadStationClient(transport: transport)
        let id = try await client.createURLTask(
            baseURL: "http://nas.example:5000",
            username: "josh",
            password: "secret",
            sourceURL: URL(string: "https://cdn.example/file?sig=temp-token")!,
            destination: "media/books/books/Tolkien/The Hobbit",
            expectedFilename: "The Hobbit.epub",
        )
        #expect(id == "dbid_new")
        #expect(listCalls >= 2)
    }
}

private final class DownloadStationScript: SynologyTransport, @unchecked Sendable {
    var handler: ((URLRequest) -> SynologyHTTP)?

    func send(_ request: URLRequest) async throws -> SynologyHTTP {
        handler?(request)
            ?? SynologyHTTP(status: 200, body: Data(#"{"success":true,"data":{"sid":"x"}}"#.utf8))
    }

    func upload(request: URLRequest, fileURL: URL) async throws -> SynologyHTTP {
        SynologyHTTP(status: 200, body: Data(#"{"success":true}"#.utf8))
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
                audiobookFolder: "/volume1/media/books/audiobooks",
                ebookFolder: "/volume1/media/books/books",
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
    /// Simulate DSM create responses that omit `task_id`.
    var omitTaskIDFromCreate = false
    /// Download Station title/basename for the created task (may differ from expected).
    var dsOutputTitle: String?
    var renamedPairs: [(from: String, to: String)] = []
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
        taskCounter += 1
        let id = "task-\(taskCounter)"
        let title = dsOutputTitle ?? source.filename
        let dsDest = SynologyDownloadStationClient.downloadStationDestination(
            fromVolumePath: destination.volumePath
        )
        let status: SynologyDownloadTaskStatus = holdTaskIDs ? .downloading : .finished
        tasks[id] = SynologyDownloadTaskSnapshot(
            id: id,
            title: title,
            size: source.expectedSize ?? 0,
            status: status,
            destination: dsDest,
        )
        if holdTaskIDs {
            return omitTaskIDFromCreate ? nil : id
        }
        // Instant finish: place the DS output name on disk (may need rename).
        existingFilenames.insert(title)
        return omitTaskIDFromCreate ? nil : id
    }

    func taskSnapshot(taskID: String) async throws -> SynologyDownloadTaskSnapshot? {
        tasks[taskID]
    }

    func findMatchingTask(
        destination: NASTransferDestination,
        expectedFilename: String,
        expectedSize: Int64?,
    ) async throws -> SynologyDownloadTaskSnapshot? {
        let dsDest = SynologyDownloadStationClient.downloadStationDestination(
            fromVolumePath: destination.volumePath
        ) ?? ""
        return SynologyDownloadStationClient.identifyCreatedTask(
            before: [],
            after: Array(tasks.values),
            destination: dsDest,
            expectedFilename: expectedFilename,
        ) ?? SynologyDownloadStationClient.identifyCreatedTask(
            before: [],
            after: Array(tasks.values),
            destination: dsDest,
            expectedFilename: dsOutputTitle,
        )
    }

    func listDestinationFilenames(destination: NASTransferDestination) async throws -> [String] {
        Array(existingFilenames).sorted()
    }

    func renameInDestination(
        destination: NASTransferDestination,
        from: String,
        to: String,
    ) async throws {
        renamedPairs.append((from, to))
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

    func markTaskFinished(_ taskID: String, placeOutput: Bool = true) {
        guard var snap = tasks[taskID] else { return }
        snap.status = .finished
        tasks[taskID] = snap
        if placeOutput {
            let name = SynologyDownloadStationClient.outputFilename(from: snap) ?? snap.title
            existingFilenames.insert(name)
        }
    }
}
