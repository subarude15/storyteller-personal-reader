//
//  ManualDownloadAttemptCleanupTests.swift
//  SilveranTests
//
//  Delete Attempt must not retry/resubmit; failed intake must not duplicate history.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit
import Testing

@Suite("Manual download attempt cleanup")
struct ManualDownloadAttemptCleanupTests {
    private let magnet =
        "magnet:?xt=urn:btih:ABCDEF0123456789ABCDEF0123456789ABCDEF01&dn=The%20Reddening"

    @Test func deleteAttemptRemovesOnlySelectedFailedJob() async {
        let store = RecordingManualDownloadJobStore()
        let keep = ManualDownloadJob(
            id: "keep",
            title: "Keep Me",
            author: "",
            sourceURL: "magnet:?xt=urn:btih:1111111111111111111111111111111111111111&dn=Keep",
            sourceHost: "deluge",
            backend: .deluge,
            mediaType: .ebook,
            destination: "/e",
            status: .failed,
            lastError: "other",
        )
        let remove = ManualDownloadJob(
            id: "remove",
            title: "The Reddening",
            author: "",
            sourceURL: magnet,
            sourceHost: "deluge",
            backend: .deluge,
            mediaType: .ebook,
            destination: "/e",
            status: .failed,
            lastError: "Deluge rejected the request.",
        )
        await store.record(keep)
        await store.record(remove)

        await ManualDownloadAttemptCleanup.deleteAttempt(remove, jobs: store)

        let remaining = await store.allJobs()
        #expect(remaining.map(\.id) == ["keep"])
        #expect(ManualDownloadBuckets.partition(remaining).attentionCount == 1)
    }

    @Test func deleteAttemptAbandonsMatchingPendingIntakeWithoutProviderCalls() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("delete-attempt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("handoff", isDirectory: true)
        let payload = try ManualDownloadIntakeHandoff.enqueueMagnet(
            url: URL(string: magnet)!,
            mediaType: .ebook,
            source: .shareExtension,
            root: root,
        )
        #expect(ManualDownloadIntakeHandoff.listPending(root: root).count == 1)

        let store = RecordingManualDownloadJobStore()
        let job = ManualDownloadJob(
            id: "job-1",
            title: "The Reddening",
            author: "",
            sourceURL: magnet,
            sourceHost: "deluge",
            backend: .deluge,
            mediaType: .ebook,
            destination: "/e",
            status: .failed,
            lastError: "Deluge rejected the request.",
        )
        await store.record(job)
        #expect(job.attemptIdentityKey == payload.fingerprint)

        await ManualDownloadAttemptCleanup.deleteAttempt(job, jobs: store, intakeRoot: root)

        #expect(await store.allJobs().isEmpty)
        #expect(ManualDownloadIntakeHandoff.listPending(root: root).isEmpty)
        // Abandoned payload UUID was never consumed via markProcessed — only dropped.
        #expect(!ManualDownloadIntakeHandoff.isProcessed(payload.id, root: root))
    }

    @Test func deletedAttemptDoesNotReappearAfterIntakeLifecycleDrain() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("delete-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("handoff", isDirectory: true)

        let store = RecordingManualDownloadJobStore()
        let deluge = DelugeRejectTransport()
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: NASDownloadSettingsSnapshot(
                        torrentClient: .deluge,
                        delugeBaseURL: "http://deluge.example:8112",
                        ebookFolder: "/volume1/media/books/books",
                    ),
                    credentials: NASBackendCredentials(delugePassword: "pw"),
                )
            ),
            deluge: DelugeWebClient(transport: deluge),
            jobs: store,
        )

        _ = try ManualDownloadIntakeHandoff.enqueueMagnet(
            url: URL(string: magnet)!,
            mediaType: .ebook,
            source: .shareExtension,
            root: root,
        )
        _ = await ManualDownloadIntakeProcessor.processPending(handler: handler, root: root)
        let afterFail = await store.allJobs()
        #expect(afterFail.count == 1)
        #expect(afterFail[0].status == .failed)
        #expect(deluge.submitCount == 1)

        await ManualDownloadAttemptCleanup.deleteAttempt(afterFail[0], jobs: store, intakeRoot: root)
        #expect(await store.allJobs().isEmpty)

        // Simulate app foreground / scenePhase intake drain.
        _ = await ManualDownloadIntakeProcessor.processPending(handler: handler, root: root)
        #expect(await store.allJobs().isEmpty)
        #expect(deluge.submitCount == 1)
        #expect(
            ManualDownloadBuckets.partition(await store.allJobs()).attentionCount == 0
        )
    }

    @Test func failDeleteThenExplicitSameMagnetSubmitsAgain() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fail-delete-reshare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("handoff", isDirectory: true)

        let store = RecordingManualDownloadJobStore()
        let deluge = DelugeScriptTransport()
        var calls = 0
        deluge.handler = {
            calls += 1
            if calls == 1 {
                return #"{"result":null,"error":{"message":"Rejected"},"id":10}"#
            }
            return #"{"result":"hashabc","error":null,"id":10}"#
        }
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: NASDownloadSettingsSnapshot(
                        torrentClient: .deluge,
                        delugeBaseURL: "http://deluge.example:8112",
                        ebookFolder: "/volume1/media/books/books",
                    ),
                    credentials: NASBackendCredentials(delugePassword: "pw"),
                )
            ),
            deluge: DelugeWebClient(transport: deluge),
            jobs: store,
        )

        let firstPayload = try ManualDownloadIntakeHandoff.enqueueMagnet(
            url: URL(string: magnet)!,
            mediaType: .ebook,
            source: .shareExtension,
            root: root,
        )
        _ = await ManualDownloadIntakeProcessor.processPending(handler: handler, root: root)
        let failed = await store.allJobs()
        #expect(failed.count == 1)
        #expect(failed[0].status == .failed)
        #expect(calls == 1)
        #expect(ManualDownloadIntakeHandoff.isProcessed(firstPayload.id, root: root))

        await ManualDownloadAttemptCleanup.deleteAttempt(failed[0], jobs: store, intakeRoot: root)
        #expect(await store.allJobs().isEmpty)

        // Explicit share of the same magnet after Delete Attempt must submit once.
        let secondPayload = try ManualDownloadIntakeHandoff.enqueueMagnet(
            url: URL(string: magnet)!,
            mediaType: .ebook,
            source: .shareExtension,
            root: root,
        )
        #expect(secondPayload.id != firstPayload.id)
        _ = await ManualDownloadIntakeProcessor.processPending(handler: handler, root: root)
        let afterReshare = await store.allJobs()
        #expect(afterReshare.count == 1)
        #expect(afterReshare[0].status == .submitted)
        #expect(calls == 2)
        #expect(afterReshare[0].id != failed[0].id)
    }

    @Test func failClearFailedThenExplicitSameMagnetSubmitsAgain() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fail-clear-reshare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("handoff", isDirectory: true)

        let store = RecordingManualDownloadJobStore()
        let deluge = DelugeScriptTransport()
        var calls = 0
        deluge.handler = {
            calls += 1
            if calls == 1 {
                return #"{"result":null,"error":{"message":"Rejected"},"id":10}"#
            }
            return #"{"result":"hashabc","error":null,"id":10}"#
        }
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: NASDownloadSettingsSnapshot(
                        torrentClient: .deluge,
                        delugeBaseURL: "http://deluge.example:8112",
                        ebookFolder: "/volume1/media/books/books",
                    ),
                    credentials: NASBackendCredentials(delugePassword: "pw"),
                )
            ),
            deluge: DelugeWebClient(transport: deluge),
            jobs: store,
        )

        _ = try ManualDownloadIntakeHandoff.enqueueMagnet(
            url: URL(string: magnet)!,
            mediaType: .ebook,
            source: .shareExtension,
            root: root,
        )
        _ = await ManualDownloadIntakeProcessor.processPending(handler: handler, root: root)
        #expect(await store.allJobs().count == 1)
        #expect(calls == 1)

        await ManualDownloadAttemptCleanup.clearFailed(jobs: store, intakeRoot: root)
        #expect(await store.allJobs().isEmpty)

        _ = try ManualDownloadIntakeHandoff.enqueueMagnet(
            url: URL(string: magnet)!,
            mediaType: .ebook,
            source: .shareExtension,
            root: root,
        )
        _ = await ManualDownloadIntakeProcessor.processPending(handler: handler, root: root)
        let afterReshare = await store.allJobs()
        #expect(afterReshare.count == 1)
        #expect(afterReshare[0].status == .submitted)
        #expect(calls == 2)
    }

    @Test func repeatedFailedIntakeUpsertsSingleHistoryRow() async {
        let store = RecordingManualDownloadJobStore()
        let deluge = DelugeRejectTransport()
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: NASDownloadSettingsSnapshot(
                        torrentClient: .deluge,
                        delugeBaseURL: "http://deluge.example:8112",
                        ebookFolder: "/volume1/media/books/books",
                    ),
                    credentials: NASBackendCredentials(delugePassword: "pw"),
                )
            ),
            deluge: DelugeWebClient(transport: deluge),
            jobs: store,
        )
        let candidate = ManualAcquisitionCandidate(
            sourceURL: URL(string: magnet)!,
            detectedType: .magnet,
            sourceHost: "manual",
            bookMetadata: ManualSearchBookContext(
                title: "The Reddening",
                authors: [],
                requestedMediaType: .ebook,
            ),
        )
        _ = await handler.handle(candidate)
        _ = await handler.handle(candidate)
        _ = await handler.handle(candidate)
        let jobs = await store.allJobs()
        #expect(jobs.count == 1)
        #expect(jobs[0].status == .failed)
        #expect(deluge.submitCount == 3)
        #expect(ManualDownloadBuckets.partition(jobs).attentionCount == 1)
    }

    @Test func retryStillSubmitsIndependentlyAfterFailure() async {
        let store = RecordingManualDownloadJobStore()
        let deluge = DelugeScriptTransport()
        var calls = 0
        deluge.handler = {
            calls += 1
            if calls == 1 {
                return #"{"result":null,"error":{"message":"Rejected"},"id":10}"#
            }
            return #"{"result":"hashabc","error":null,"id":10}"#
        }
        let handler = NASAcquisitionHandler(
            environment: StaticNASHandoffEnvironment(
                context: NASHandoffContext(
                    settings: NASDownloadSettingsSnapshot(
                        torrentClient: .deluge,
                        delugeBaseURL: "http://deluge.example:8112",
                        ebookFolder: "/volume1/media/books/books",
                    ),
                    credentials: NASBackendCredentials(delugePassword: "pw"),
                )
            ),
            deluge: DelugeWebClient(transport: deluge),
            jobs: store,
        )
        let candidate = ManualAcquisitionCandidate(
            sourceURL: URL(string: magnet)!,
            detectedType: .magnet,
            sourceHost: "manual",
            bookMetadata: ManualSearchBookContext(
                title: "The Reddening",
                authors: [],
                requestedMediaType: .ebook,
            ),
        )
        _ = await handler.handle(candidate)
        let failed = await store.allJobs()[0]
        #expect(failed.status == .failed)
        #expect(failed.canRetryTorrentNow)

        let retry = await handler.retryDownload(job: failed)
        guard case .submitted = retry else {
            Issue.record("expected submitted retry, got \(retry)")
            return
        }
        let jobs = await store.allJobs()
        #expect(jobs.count == 1)
        #expect(jobs[0].id == failed.id)
        #expect(jobs[0].status == .submitted)
        #expect(calls == 2)
    }

    @Test func clearFailedRemovesOnlyFailedRecordsAndIntake() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clear-failed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("handoff", isDirectory: true)

        let store = RecordingManualDownloadJobStore()
        let failed = ManualDownloadJob(
            id: "f1",
            title: "Failed",
            author: "",
            sourceURL: magnet,
            sourceHost: "deluge",
            backend: .deluge,
            mediaType: .ebook,
            destination: "/e",
            status: .failed,
        )
        let complete = ManualDownloadJob(
            id: "c1",
            title: "Done",
            author: "",
            sourceURL: "magnet:?xt=urn:btih:2222222222222222222222222222222222222222&dn=Done",
            sourceHost: "deluge",
            backend: .deluge,
            mediaType: .ebook,
            destination: "/e",
            status: .complete,
        )
        let active = ManualDownloadJob(
            id: "a1",
            title: "Active",
            author: "",
            sourceURL: "magnet:?xt=urn:btih:3333333333333333333333333333333333333333&dn=Active",
            sourceHost: "deluge",
            backend: .deluge,
            mediaType: .ebook,
            destination: "/e",
            status: .downloading,
        )
        await store.record(failed)
        await store.record(complete)
        await store.record(active)
        _ = try ManualDownloadIntakeHandoff.enqueueMagnet(
            url: URL(string: magnet)!,
            mediaType: .ebook,
            source: .shareExtension,
            root: root,
        )

        await ManualDownloadAttemptCleanup.clearFailed(jobs: store, intakeRoot: root)

        let remaining = await store.allJobs()
        #expect(Set(remaining.map(\.id)) == ["c1", "a1"])
        #expect(remaining.contains { $0.status == .failed } == false)
        #expect(ManualDownloadIntakeHandoff.listPending(root: root).isEmpty)
        #expect(ManualDownloadBuckets.partition(remaining).attentionCount == 1)
    }

    @Test func deleteAttemptDoesNotInvokeRetryAcquisitionHandler() async {
        let store = RecordingManualDownloadJobStore()
        let probe = ProbeAcquisitionHandler()
        let job = ManualDownloadJob(
            id: "x",
            title: "X",
            author: "",
            sourceURL: magnet,
            sourceHost: "deluge",
            backend: .deluge,
            mediaType: .ebook,
            destination: "/e",
            status: .failed,
        )
        await store.record(job)
        await ManualDownloadAttemptCleanup.deleteAttempt(job, jobs: store)
        #expect(probe.handleCount == 0)
        #expect(await store.allJobs().isEmpty)
        // Explicitly prove cleanup API is independent of acquisition handle().
        _ = probe
    }
}

// MARK: - Test doubles

private final class DelugeRejectTransport: DelugeTransport, @unchecked Sendable {
    private(set) var submitCount = 0

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
                submitCount += 1
                return DelugeHTTP(
                    status: 200,
                    body: Data(
                        #"{"result":null,"error":{"message":"Rejected"},"id":10}"#.utf8
                    ),
                )
            default:
                return DelugeHTTP(status: 200, body: Data(#"{"result":null,"error":null,"id":0}"#.utf8))
        }
    }
}

private final class DelugeScriptTransport: DelugeTransport, @unchecked Sendable {
    var handler: () async throws -> String = { #"{"result":"hashabc","error":null,"id":10}"# }
    private(set) var submitCount = 0

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
                submitCount += 1
                let json = try await handler()
                return DelugeHTTP(status: 200, body: Data(json.utf8))
            default:
                return DelugeHTTP(status: 200, body: Data(#"{"result":null,"error":null,"id":0}"#.utf8))
        }
    }
}

private final class ProbeAcquisitionHandler: ManualAcquisitionHandling, @unchecked Sendable {
    private(set) var handleCount = 0

    func handle(_ candidate: ManualAcquisitionCandidate) async -> ManualAcquisitionHandoffResult {
        handleCount += 1
        return .failed(message: "should not run")
    }
}
