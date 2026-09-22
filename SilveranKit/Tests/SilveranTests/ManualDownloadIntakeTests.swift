//
//  ManualDownloadIntakeTests.swift
//  SilveranTests
//
//  Share Sheet / Shortcuts intake into the PR71 manual-download pipeline.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit
import Testing

@Suite("Manual download intake")
struct ManualDownloadIntakeTests {
    private let validMagnet =
        "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Example%20Book"
    private let malformedMagnet = "magnet:?dn=NoHash"

    @Test func magnetURISharedAsURL() {
        let url = URL(string: validMagnet)!
        let result = ManualDownloadIntake.classify(url: url)
        guard case .magnet(let magnetURL, let title) = result else {
            Issue.record("expected magnet, got \(result)")
            return
        }
        #expect(magnetURL.absoluteString == validMagnet)
        #expect(title == "Example Book")
    }

    @Test func magnetURISharedAsText() {
        let result = ManualDownloadIntake.classify(text: "  \(validMagnet)  ")
        guard case .magnet(_, let title) = result else {
            Issue.record("expected magnet, got \(result)")
            return
        }
        #expect(title == "Example Book")
    }

    @Test func validTorrentFileIntake() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("intake-torrent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Example Book.torrent")
        try Data("d8:announce".utf8).write(to: file)

        let classified = ManualDownloadIntake.classifyTorrentFile(url: file)
        guard case .torrent(let filename, let title) = classified else {
            Issue.record("expected torrent, got \(classified)")
            return
        }
        #expect(filename == "Example Book.torrent")
        #expect(title == "Example Book")

        let root = dir.appendingPathComponent("handoff", isDirectory: true)
        let payload = try ManualDownloadIntakeHandoff.enqueueTorrent(
            from: file,
            mediaType: .ebook,
            source: .shareExtension,
            root: root,
        )
        #expect(payload.kind == .torrentFile)
        #expect(ManualDownloadIntakeHandoff.stagedTorrentURL(payload, root: root) != nil)
        #expect(ManualDownloadIntakeHandoff.listPending(root: root).count == 1)
    }

    @Test func webpageURLRejectedWithGuidance() {
        let url = URL(string: "https://example.com/download-page")!
        let result = ManualDownloadIntake.classify(url: url)
        guard case .rejected(let error) = result else {
            Issue.record("expected rejection, got \(result)")
            return
        }
        #expect(error == .webpageNotMagnetOrTorrent)
        #expect(error.message.contains("magnet link or .torrent file"))
    }

    @Test func ebookChoicePreservedInCandidate() {
        let url = URL(string: validMagnet)!
        let payload = ManualDownloadIntakePayload.magnet(
            url: url,
            mediaType: .ebook,
            source: .shareExtension,
        )
        #expect(payload.mediaType == .ebook)
        guard case .success(let candidate) = payload.makeCandidate() else {
            Issue.record("expected candidate")
            return
        }
        #expect(candidate.bookMetadata.requestedMediaType == .ebook)
    }

    @Test func audiobookChoicePreservedInCandidate() {
        let url = URL(string: validMagnet)!
        let payload = ManualDownloadIntakePayload.magnet(
            url: url,
            mediaType: .audiobook,
            source: .appIntent,
        )
        #expect(payload.mediaType == .audiobook)
        guard case .success(let candidate) = payload.makeCandidate() else {
            Issue.record("expected candidate")
            return
        }
        #expect(candidate.bookMetadata.requestedMediaType == .audiobook)
    }

    @Test func stagedTorrentSurvivesHandoffForAppSubmission() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("intake-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("KeepMe.torrent")
        let bytes = Data("torrent-bytes-stay".utf8)
        try bytes.write(to: file)
        let root = dir.appendingPathComponent("handoff", isDirectory: true)

        let payload = try ManualDownloadIntakeHandoff.enqueueTorrent(
            from: file,
            mediaType: .ebook,
            source: .shareExtension,
            root: root,
        )
        // Simulate extension exit: source temp may vanish; staged copy must remain.
        try FileManager.default.removeItem(at: file)
        guard let staged = ManualDownloadIntakeHandoff.stagedTorrentURL(payload, root: root) else {
            Issue.record("staged torrent missing")
            return
        }
        #expect(try Data(contentsOf: staged) == bytes)

        let imported = try ManualDownloadIntakeHandoff.importTorrentIntoAppStaging(
            payload,
            root: root,
        )
        #expect(try Data(contentsOf: imported) == bytes)
        ManualDownloadStaging.remove(imported)
    }

    @Test func malformedMagnetRejected() {
        #expect(ManualDownloadIntake.classify(text: malformedMagnet) == .rejected(.malformedMagnet))
        #expect(
            ManualDownloadIntake.classify(url: URL(string: malformedMagnet)!)
                == .rejected(.malformedMagnet)
        )
    }

    @Test func unsupportedFileRejected() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("intake-bad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appendingPathComponent("book.pdf")
        try Data("%PDF".utf8).write(to: pdf)
        #expect(ManualDownloadIntake.classifyTorrentFile(url: pdf) == .rejected(.unsupportedFile))
    }

    @Test func shareAndAppIntentFeedSamePayloadPipeline() throws {
        let url = URL(string: validMagnet)!
        let fromShare = ManualDownloadIntakePayload.magnet(
            url: url,
            mediaType: .ebook,
            source: .shareExtension,
        )
        let fromIntent = ManualDownloadIntakePayload.magnet(
            url: url,
            mediaType: .ebook,
            source: .appIntent,
        )
        #expect(fromShare.fingerprint == fromIntent.fingerprint)
        #expect(fromShare.kind == fromIntent.kind)
        guard case .success = fromShare.makeCandidate() else {
            Issue.record("share candidate failed")
            return
        }
        guard case .success = fromIntent.makeCandidate() else {
            Issue.record("intent candidate failed")
            return
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("intake-sources-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("handoff", isDirectory: true)

        _ = try ManualDownloadIntakeHandoff.enqueueMagnet(
            url: url,
            mediaType: .ebook,
            source: .shareExtension,
            root: root,
        )
        _ = try ManualDownloadIntakeHandoff.enqueueMagnet(
            url: url,
            mediaType: .ebook,
            source: .appIntent,
            root: root,
        )
        #expect(ManualDownloadIntakeHandoff.listPending(root: root).count == 2)
    }

    @Test func magnetHandoffFailureLeavesPayloadForRetry() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("intake-magnet-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("handoff", isDirectory: true)
        let url = URL(string: validMagnet)!
        let payload = try ManualDownloadIntakeHandoff.enqueueMagnet(
            url: url,
            mediaType: .ebook,
            source: .shareExtension,
            root: root,
        )

        let failing = SequenceIntakeHandler(results: [.failed(message: "Deluge auth")])
        let failPass = await ManualDownloadIntakeProcessor.processPending(
            handler: failing,
            root: root,
        )
        #expect(failPass == 0)
        #expect(failing.handled.count == 1)
        #expect(!ManualDownloadIntakeHandoff.isProcessed(payload.id, root: root))
        #expect(!ManualDownloadIntakeHandoff.isFingerprintProcessed(payload.fingerprint, root: root))
        #expect(ManualDownloadIntakeHandoff.listPending(root: root).count == 1)

        let succeeding = SequenceIntakeHandler(results: [.submitted(message: "ok")])
        let okPass = await ManualDownloadIntakeProcessor.processPending(
            handler: succeeding,
            root: root,
        )
        #expect(okPass == 1)
        #expect(succeeding.handled.count == 1)
        #expect(ManualDownloadIntakeHandoff.isProcessed(payload.id, root: root))
        #expect(ManualDownloadIntakeHandoff.listPending(root: root).isEmpty)
    }

    @Test func torrentHandoffFailurePreservesStagedCopyForRetry() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("intake-torrent-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("RetryMe.torrent")
        let bytes = Data("torrent-retry-bytes".utf8)
        try bytes.write(to: file)
        let root = dir.appendingPathComponent("handoff", isDirectory: true)
        let payload = try ManualDownloadIntakeHandoff.enqueueTorrent(
            from: file,
            mediaType: .audiobook,
            source: .shareExtension,
            root: root,
        )
        guard let stagedBefore = ManualDownloadIntakeHandoff.stagedTorrentURL(payload, root: root) else {
            Issue.record("missing staged torrent")
            return
        }

        let failing = SequenceIntakeHandler(results: [.failed(message: "network")])
        _ = await ManualDownloadIntakeProcessor.processPending(handler: failing, root: root)
        #expect(failing.handled.count == 1)
        #expect(!ManualDownloadIntakeHandoff.isProcessed(payload.id, root: root))
        #expect(ManualDownloadIntakeHandoff.listPending(root: root).count == 1)
        guard let stagedAfterFail = ManualDownloadIntakeHandoff.stagedTorrentURL(payload, root: root) else {
            Issue.record("staged torrent removed after failed handoff")
            return
        }
        #expect(try Data(contentsOf: stagedAfterFail) == bytes)
        #expect(stagedAfterFail == stagedBefore)

        let succeeding = SequenceIntakeHandler(results: [.submitted(message: "ok")])
        let okPass = await ManualDownloadIntakeProcessor.processPending(
            handler: succeeding,
            root: root,
        )
        #expect(okPass == 1)
        #expect(ManualDownloadIntakeHandoff.isProcessed(payload.id, root: root))
        #expect(ManualDownloadIntakeHandoff.stagedTorrentURL(payload, root: root) == nil)
    }

    @Test func duplicateHandoffDoesNotSubmitTwice() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("intake-dedupe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("handoff", isDirectory: true)
        let url = URL(string: validMagnet)!

        let first = try ManualDownloadIntakeHandoff.enqueueMagnet(
            url: url,
            mediaType: .ebook,
            source: .shareExtension,
            root: root,
        )
        // Second identical fingerprint (different id) — processor must submit once.
        _ = try ManualDownloadIntakeHandoff.enqueueMagnet(
            url: url,
            mediaType: .ebook,
            source: .appIntent,
            root: root,
        )
        #expect(first.fingerprint.contains("ebook"))

        let handler = RecordingIntakeHandler()
        let firstPass = await ManualDownloadIntakeProcessor.processPending(
            handler: handler,
            root: root,
        )
        #expect(firstPass == 1)
        #expect(handler.handled.count == 1)

        // Re-enqueue same fingerprint after first was marked processed.
        _ = try ManualDownloadIntakeHandoff.enqueueMagnet(
            url: url,
            mediaType: .ebook,
            source: .shareExtension,
            root: root,
        )
        let secondPass = await ManualDownloadIntakeProcessor.processPending(
            handler: handler,
            root: root,
        )
        #expect(secondPass == 0)
        #expect(handler.handled.count == 1)
    }

    @Test func deepLinkRecognizesAddDownload() {
        #expect(ManualDownloadIntakeDeepLink.isAddDownloadURL(URL(string: "punkrally://add-download")!))
        #expect(
            ManualDownloadIntakeDeepLink.isAddDownloadURL(URL(string: "punkrally:///add-download")!)
        )
        #expect(!ManualDownloadIntakeDeepLink.isAddDownloadURL(URL(string: "punkrally://continue")!))
    }
}

private final class RecordingIntakeHandler: ManualAcquisitionHandling, @unchecked Sendable {
    private(set) var handled: [ManualAcquisitionCandidate] = []

    func handle(_ candidate: ManualAcquisitionCandidate) async -> ManualAcquisitionHandoffResult {
        handled.append(candidate)
        return .submitted(message: "test")
    }
}

private final class SequenceIntakeHandler: ManualAcquisitionHandling, @unchecked Sendable {
    private var results: [ManualAcquisitionHandoffResult]
    private(set) var handled: [ManualAcquisitionCandidate] = []

    init(results: [ManualAcquisitionHandoffResult]) {
        self.results = results
    }

    func handle(_ candidate: ManualAcquisitionCandidate) async -> ManualAcquisitionHandoffResult {
        handled.append(candidate)
        if results.isEmpty {
            return .failed(message: "unexpected extra handle")
        }
        return results.removeFirst()
    }
}
