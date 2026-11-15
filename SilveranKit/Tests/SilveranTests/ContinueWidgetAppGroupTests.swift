import Foundation
import SilveranAppleWidgets
import Testing

/// Regression coverage for the sideloaded Continue widget's two historical
/// failure modes: a hard-coded App Group id (blank tile on AltStore-resigned
/// builds) and a payload without transport state.
@Suite("Continue widget App Group resolution")
struct ContinueWidgetAppGroupTests {
    @Test func altStoreGroupsWinOverConfiguredValue() {
        let candidates = SilveranWidgetSnapshotStore.groupCandidates(
            altStoreGroups: ["group.com.punkrally.reader.ABCDE12345"],
            configured: "group.com.punkrally.reader",
            fallback: "group.com.punkrally.reader",
        )
        // AltStore appends the team id; the Info.plist literal must not win.
        #expect(candidates.first == "group.com.punkrally.reader.ABCDE12345")
        #expect(candidates.count == 2)
    }

    @Test func backfillsConfiguredAndFallbackInOrder() {
        let candidates = SilveranWidgetSnapshotStore.groupCandidates(
            altStoreGroups: nil,
            configured: "group.custom.reader",
            fallback: "group.com.punkrally.reader",
        )
        #expect(candidates == ["group.custom.reader", "group.com.punkrally.reader"])
    }

    @Test func rejectsEmptyAndUnexpandedIdentifiers() {
        let candidates = SilveranWidgetSnapshotStore.groupCandidates(
            altStoreGroups: ["", "   ", "$(APP_GROUP_ID)"],
            configured: "$(SILVERAN_WIDGET_APP_GROUP)",
            fallback: "group.com.punkrally.reader",
        )
        #expect(candidates == ["group.com.punkrally.reader"])
    }

    @Test func deduplicatesRepeatedGroups() {
        let candidates = SilveranWidgetSnapshotStore.groupCandidates(
            altStoreGroups: ["group.com.punkrally.reader"],
            configured: "group.com.punkrally.reader",
            fallback: "group.com.punkrally.reader",
        )
        #expect(candidates == ["group.com.punkrally.reader"])
    }

    @Test func altStoreInfoKeyMatchesAltStoreResignContract() {
        // AltStore's ResignAppOperation writes the granted groups here.
        #expect(SilveranWidgetConstants.altStoreAppGroupsInfoKey == "ALTAppGroups")
        #expect(SilveranWidgetConstants.appGroupInfoKey == "SILVERAN_WIDGET_APP_GROUP")
    }

    @Test func continueKindNeverCollidesWithRetiredTiles() {
        let kind = SilveranWidgetConstants.continueWidgetKind
        #expect(kind == "InkAmpContinueWidget")
        #expect(kind != SilveranWidgetConstants.readingWidgetKind)
        // The parked static tiles must never be registered or reloaded again.
        for legacy in SilveranWidgetConstants.legacySideloadContinueWidgetKinds {
            #expect(legacy != kind)
        }
    }
}

@Suite("Continue widget snapshot payload")
struct ContinueWidgetSnapshotTests {
    @Test func transportControlsNeedALiveSession() {
        var snapshot = ContinueWidgetSnapshot(title: "Piranesi")
        #expect(snapshot.hasItem)
        // No live session → the tile must offer a deep link, not a dead button.
        #expect(!snapshot.supportsTransportControls)
        #expect(!snapshot.isLive)

        snapshot.hasLiveSession = true
        #expect(snapshot.supportsTransportControls)
    }

    @Test func emptyTitlesDoNotCountAsItems() {
        let snapshot = ContinueWidgetSnapshot(title: "   ")
        #expect(!snapshot.hasItem)
        #expect(!snapshot.supportsTransportControls)
    }

    @Test func progressCaptionCombinesPercentAndRemaining() {
        let snapshot = ContinueWidgetSnapshot(
            title: "Piranesi",
            progress: 0.5,
            durationSeconds: 3600,
            rate: 1,
        )
        #expect(snapshot.percentComplete == 50)
        #expect(snapshot.remainingText == "30m left")
        #expect(snapshot.progressCaption == "50% · 30m / 1h · 30m left")
    }

    @Test func clampingAndDurationFormatting() {
        #expect(ContinueWidgetSnapshot(progress: 1.4).clampedProgress == 1)
        #expect(ContinueWidgetSnapshot(progress: -0.2).clampedProgress == 0)
        #expect(ContinueWidgetSnapshot.durationText(90) == "1m")
        #expect(ContinueWidgetSnapshot.durationText(3600) == "1h")
        #expect(ContinueWidgetSnapshot.durationText(3900) == "1h 5m")
    }

    @Test func decodesSnapshotsWrittenBeforeTransportFieldsExisted() throws {
        // v3/v4 payloads on disk have no progress / live-session fields.
        let legacyJSON = """
            {
              "generatedAt": "2026-09-16T12:00:00Z",
              "isPlaying": true,
              "kind": "audiobook",
              "title": "Piranesi",
              "subtitle": "Susanna Clarke"
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(
            ContinueWidgetSnapshot.self,
            from: Data(legacyJSON.utf8),
        )
        #expect(snapshot.hasItem)
        #expect(snapshot.isPlaying)
        #expect(snapshot.hasLiveSession == nil)
        // A legacy payload must not render dead transport buttons.
        #expect(!snapshot.supportsTransportControls)
    }

    @Test func concurrentPublishPreservesFresherStreakAcrossAudioHomeRace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("continue-publish-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            ContinueWidgetSnapshotStore.resetPublishSignaturesForTesting()
        }

        let store = PausableContinueWidgetFileStore(root: root)
        ContinueWidgetSnapshotStore.resetPublishSignaturesForTesting()
        ContinueWidgetSnapshotStore.publish(
            title: "Piranesi",
            subtitle: "Clarke",
            isPlaying: false,
            kind: .ebook,
            coverData: nil,
            streakDays: 3,
            streakActivityDayKey: "2026-11-14",
            fileStore: store
        )
        #expect(store.readSnapshot(in: root)?.streakDays == 3)

        store.pauseNextRead()
        let audioDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            // Audio tick: nil streak should preserve whatever it read.
            ContinueWidgetSnapshotStore.publish(
                title: "Piranesi",
                subtitle: "Clarke",
                isPlaying: true,
                kind: .audiobook,
                coverData: nil,
                hasLiveSession: true,
                streakDays: nil,
                streakActivityDayKey: nil,
                fileStore: store
            )
            audioDone.signal()
        }
        store.waitForPausedRead()
        // Home publishes a fresher streak while audio still holds the publish lock.
        let homeDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            ContinueWidgetSnapshotStore.publish(
                title: "Piranesi",
                subtitle: "Clarke",
                isPlaying: false,
                kind: .ebook,
                coverData: nil,
                streakDays: 5,
                streakActivityDayKey: "2026-11-15",
                fileStore: store
            )
            homeDone.signal()
        }
        // Without an atomic publish lock, home would finish first and audio would
        // overwrite streak 5 with the stale preserved 3 after resume.
        Thread.sleep(forTimeInterval: 0.05)
        store.resumePausedRead()
        #expect(audioDone.wait(timeout: .now() + 2) == .success)
        #expect(homeDone.wait(timeout: .now() + 2) == .success)

        let final = store.readSnapshot(in: root)
        #expect(final?.streakDays == 5)
        #expect(final?.streakActivityDayKey == "2026-11-15")
    }

    @Test func paintSignatureTracksProgressTimingStreakAndExcludesGeneratedAt() {
        let base = ContinueWidgetSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            title: "Piranesi",
            subtitle: "Clarke",
            isPlaying: false,
            kind: .audiobook,
            progress: 0.25,
            elapsedSeconds: 900,
            durationSeconds: 3600,
            hasLiveSession: true,
            rate: 1,
            streakDays: 2,
            streakActivityDayKey: "2026-11-14"
        )
        var laterStamp = base
        laterStamp.generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(base.paintSignature == laterStamp.paintSignature)

        var progressChanged = base
        progressChanged.progress = 0.5
        #expect(progressChanged.paintSignature != base.paintSignature)

        var timingChanged = base
        timingChanged.elapsedSeconds = 1800
        #expect(timingChanged.paintSignature != base.paintSignature)

        var streakChanged = base
        streakChanged.streakDays = 5
        #expect(streakChanged.paintSignature != base.paintSignature)
    }

    @Test func publishLiveMirrorSeamPreservesFresherHomeStreakDuringAudioRace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("continue-live-mirror-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            ContinueWidgetSnapshotStore.resetPublishSignaturesForTesting()
        }

        let store = PausableContinueWidgetFileStore(root: root)
        ContinueWidgetSnapshotStore.resetPublishSignaturesForTesting()
        ContinueWidgetSnapshotStore.publish(
            title: "Piranesi",
            subtitle: "Clarke",
            isPlaying: false,
            kind: .ebook,
            coverData: nil,
            streakDays: 3,
            streakActivityDayKey: "2026-11-14",
            fileStore: store
        )

        store.pauseNextRead()
        let audioDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            // Real publisher/audio seam: no pre-read streak re-assert.
            ContinueWidgetSnapshotStore.publishLiveMirror(
                title: "Piranesi",
                subtitle: "Clarke",
                isPlaying: true,
                kind: .audiobook,
                coverData: nil,
                hasLiveSession: true,
                fileStore: store
            )
            audioDone.signal()
        }
        store.waitForPausedRead()
        let homeDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            ContinueWidgetSnapshotStore.publish(
                title: "Piranesi",
                subtitle: "Clarke",
                isPlaying: false,
                kind: .ebook,
                coverData: nil,
                streakDays: 7,
                streakActivityDayKey: "2026-11-15",
                fileStore: store
            )
            homeDone.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)
        store.resumePausedRead()
        #expect(audioDone.wait(timeout: .now() + 2) == .success)
        #expect(homeDone.wait(timeout: .now() + 2) == .success)

        let final = store.readSnapshot(in: root)
        #expect(final?.streakDays == 7)
        #expect(final?.streakActivityDayKey == "2026-11-15")
    }

    @Test func unchangedPaintPersistsNewStreakAnchor() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("continue-anchor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            ContinueWidgetSnapshotStore.resetPublishSignaturesForTesting()
        }
        let store = PausableContinueWidgetFileStore(root: root)
        ContinueWidgetSnapshotStore.resetPublishSignaturesForTesting()
        for anchor in ["2026-11-10", "2026-11-15"] {
            ContinueWidgetSnapshotStore.publish(
                title: "Piranesi", subtitle: "Clarke", isPlaying: false,
                kind: .ebook, coverData: nil, streakDays: 1,
                streakActivityDayKey: anchor, fileStore: store
            )
        }
        let saved = try #require(store.readSnapshot(in: root))
        #expect(saved.streakDays == 1)
        #expect(saved.streakActivityDayKey == "2026-11-15")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 15)))
        #expect(saved.resolvingStreak(at: today, calendar: calendar).streakDays == 1)
    }

    @Test func continueWidgetPublisherSourceDoesNotPreassertStoredStreak() throws {
        let publisherURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AppleKit/MobileDesktop/ContinueWidgetPublisher.swift")
        let source = try String(contentsOf: publisherURL, encoding: .utf8)
        #expect(source.contains("publishLiveMirror("))
        #expect(!source.contains("streakDays: last.streakDays"))
        #expect(!source.contains("streakActivityDayKey: last.streakActivityDayKey"))
        #expect(!source.contains("streakDays: streakDays ?? last.streakDays"))
    }
}

/// Directory-backed Continue publish seam with a suspension point on snapshot read.
private final class PausableContinueWidgetFileStore: ContinueWidgetSnapshotFileStoring, @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var pauseRead = false
    private let readStarted = DispatchSemaphore(value: 0)
    private let readGate = DispatchSemaphore(value: 0)

    init(root: URL) { self.root = root }

    func resolveContainer() -> URL? { root }

    func ensureDirectories(in container: URL) throws {
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: ContinueWidgetSnapshotStore.coversDirectory(in: container),
            withIntermediateDirectories: true
        )
    }

    func readSnapshot(in container: URL) -> ContinueWidgetSnapshot? {
        lock.lock()
        let shouldPause = pauseRead
        if shouldPause { pauseRead = false }
        lock.unlock()
        if shouldPause {
            readStarted.signal()
            readGate.wait()
        }
        return ContinueWidgetSnapshotStore.readSnapshotFile(in: container)
    }

    func writeSnapshotData(_ data: Data, to container: URL) throws {
        try data.write(
            to: ContinueWidgetSnapshotStore.snapshotURL(in: container),
            options: [.atomic]
        )
    }

    func existingCoverFilename(in container: URL) -> String? {
        ContinueWidgetSnapshotStore.readSnapshotFile(in: container)?.coverFilename
    }

    func writeCoverData(_ data: Data, to container: URL) throws -> String {
        let name = "continue_cover.dat"
        let url = ContinueWidgetSnapshotStore.coversDirectory(in: container)
            .appendingPathComponent(name, isDirectory: false)
        try data.write(to: url, options: [.atomic])
        return name
    }

    func pauseNextRead() {
        lock.lock()
        pauseRead = true
        lock.unlock()
    }

    func waitForPausedRead() {
        readStarted.wait()
    }

    func resumePausedRead() {
        readGate.signal()
    }

}
