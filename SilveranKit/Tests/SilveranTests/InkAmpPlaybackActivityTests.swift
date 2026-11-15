import Foundation
import SilveranAppleWidgets
import SilveranKit
import Testing

@Suite("Live Activity content state")
struct InkAmpPlaybackActivityTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(
        isPlaying: Bool = true,
        rate: Double = 1,
        at: Date? = nil,
        position: TimeInterval = 100,
        chapter: String? = "Chapter 1",
        chapterEnd: TimeInterval? = 400,
    ) -> InkAmpPlaybackActivityState {
        InkAmpPlaybackActivityState(
            itemKind: .audiobook,
            itemID: "audio/src/book",
            title: "Title",
            author: "Author",
            coverFilename: "cover-abc-1.jpg",
            tint: nil,
            chapter: chapter,
            isPlaying: isPlaying,
            rate: rate,
            positionAt: at ?? t0,
            position: position,
            chapterEnd: chapterEnd,
            itemEnd: 3600,
        )
    }

    private var palette: CoverTintPalette {
        CoverTintPalette(
            base: CoverRGB8(red: 200, green: 40, blue: 40),
            light: CoverTintSchemeColors(
                surface: CoverRGB8(red: 255, green: 240, blue: 240),
                control: CoverRGB8(red: 160, green: 30, blue: 30),
                onControl: CoverRGB8(red: 255, green: 255, blue: 255),
            ),
            dark: CoverTintSchemeColors(
                surface: CoverRGB8(red: 40, green: 10, blue: 10),
                control: CoverRGB8(red: 240, green: 120, blue: 120),
                onControl: CoverRGB8(red: 17, green: 17, blue: 17),
            ),
        )
    }

    @Test(arguments: [
        String(repeating: "Ü", count: 5000),
        String(repeating: "👨‍👩‍👧‍👦", count: 2000),
        String(repeating: "e\u{301}", count: 5000),
    ])
    func payloadStaysUnderActivityKitLimit(long: String) throws {
        let snapshot = AudioSessionSnapshot(
            kind: .podcast(String(repeating: "https://feeds.example/episode/", count: 20)),
            title: long,
            author: long,
            isPlaying: true,
            chapterLabel: long,
            bookProgress: 0.5,
            playbackRate: 1.5,
            elapsedSeconds: 10,
            durationSeconds: 100,
        )
        let state = InkAmpPlaybackActivityState(
            snapshot: snapshot,
            coverFilename: InkAmpPlaybackActivityStore.thumbnailFilename(itemID: "x", revision: 999_999),
            tint: palette,
            now: t0,
        )
        #expect(state.payloadByteCount < InkAmpPlaybackActivityState.maximumPayloadBytes / 2)
        #expect(state.title.utf8.count <= 240)
        #expect(long.hasPrefix(state.title))
        #expect(state.title.last == long.last)
        #expect(state.itemID.hasPrefix("h:"))
        #expect(state.itemID == InkAmpPlaybackActivityState.activityItemID(for: snapshot.kind))
        let decoded = try JSONDecoder().decode(InkAmpPlaybackActivityState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
    }

    @Test func snapshotMapsChapterEndAndRate() {
        let snapshot = AudioSessionSnapshot(
            kind: .readaloud(BookID(sourceID: "src", uuid: "u")),
            title: "T",
            author: nil,
            isPlaying: false,
            chapterLabel: "Ch",
            bookProgress: 0,
            playbackRate: 0,
            elapsedSeconds: 50,
            durationSeconds: 500,
            chapterRemainingSeconds: 25,
        )
        let state = InkAmpPlaybackActivityState(snapshot: snapshot, coverFilename: nil, tint: nil, now: t0)
        #expect(state.itemKind == .readaloud)
        #expect(state.itemID == ContinueWidgetItemID.from(sessionKind: snapshot.kind))
        #expect(state.chapterEnd == 75)
        #expect(state.itemEnd == 500)
        #expect(state.rate == 1)
    }

    @Test func invalidNumbersNeverProduceTimerRanges() {
        let snapshot = AudioSessionSnapshot(
            kind: .podcast("p"),
            title: "T",
            author: nil,
            isPlaying: true,
            chapterLabel: nil,
            bookProgress: 0,
            playbackRate: .nan,
            elapsedSeconds: .infinity,
            durationSeconds: .nan,
            chapterRemainingSeconds: .greatestFiniteMagnitude,
        )
        let state = InkAmpPlaybackActivityState(snapshot: snapshot, coverFilename: nil, tint: nil, now: t0)
        #expect(state.position == 0)
        #expect(state.rate == 1)
        #expect(state.itemEnd == 0)
        #expect(state.itemTimerInterval == nil)

        #expect(self.state(position: .greatestFiniteMagnitude, chapterEnd: .infinity).remainingTimerInterval == nil)
        #expect(self.state(rate: .infinity).itemTimerInterval == nil)
        #expect(self.state(at: Date(timeIntervalSinceReferenceDate: .infinity)).itemTimerInterval == nil)
    }

    @Test func progressTicksDoNotUpdate() {
        let rendered = state(rate: 1.5)
        // Ticks every ~0.5s with a few hundred ms of stamping jitter either way.
        for (wall, media) in [(0.5, 100.75), (10, 115.4), (60, 189.6), (3600, 5500.0)] {
            #expect(!rendered.needsUpdate(to: state(rate: 1.5, at: t0.addingTimeInterval(wall), position: media)))
        }
        #expect(!state(isPlaying: false).needsUpdate(to: state(isPlaying: false, at: t0.addingTimeInterval(30))))
    }

    @Test func seeksAndTransportChangesUpdate() {
        let rendered = state()
        // Fine seeks: 2s while playing, 1s while paused.
        #expect(rendered.needsUpdate(to: state(at: t0.addingTimeInterval(5), position: 107)))
        #expect(rendered.needsUpdate(to: state(at: t0.addingTimeInterval(5), position: 103)))
        #expect(state(isPlaying: false).needsUpdate(to: state(isPlaying: false, position: 101)))
        #expect(rendered.needsUpdate(to: state(at: t0.addingTimeInterval(5), position: 135)))
        #expect(rendered.needsUpdate(to: state(isPlaying: false, at: t0.addingTimeInterval(5), position: 105)))
        #expect(rendered.needsUpdate(to: state(rate: 1.25)))
        #expect(rendered.needsUpdate(to: state(chapter: "Chapter 2")))
        #expect(rendered.needsUpdate(to: state(chapterEnd: nil)))
        #expect(rendered.needsUpdate(to: state(chapterEnd: 900)))
        var other = state()
        other.itemID = "podcast/x"
        #expect(rendered.needsUpdate(to: other))
        var covered = state()
        covered.coverFilename = "cover-abc-2.jpg"
        #expect(rendered.needsUpdate(to: covered))
        var tinted = state()
        tinted.tint = palette
        #expect(rendered.needsUpdate(to: tinted))
    }

    @Test func naturalFinishIsDistinctFromPause() {
        #expect(state(isPlaying: false, position: 3599.2).isFinished)
        #expect(state(isPlaying: false, position: 3600).isFinished)
        #expect(!state(isPlaying: false, position: 3500).isFinished)
        #expect(!state(isPlaying: true, position: 3599.9).isFinished)
        var unknownLength = state(isPlaying: false, position: 0)
        unknownLength.itemEnd = 0
        #expect(!unknownLength.isFinished)
    }

    @Test func timerIntervalsAreRateCorrect() throws {
        let playing = state(rate: 2, position: 100, chapterEnd: 400)
        let item = try #require(playing.itemTimerInterval)
        #expect(item.lowerBound == t0.addingTimeInterval(-50))
        #expect(item.upperBound == t0.addingTimeInterval(1750))
        let remaining = try #require(playing.remainingTimerInterval)
        #expect(remaining.upperBound == t0.addingTimeInterval(150))
        #expect(playing.expectedPosition(at: t0.addingTimeInterval(10)) == 120)
        #expect(state(isPlaying: false).expectedPosition(at: t0.addingTimeInterval(10)) == 100)
        #expect(state(chapterEnd: 50).remainingTimerInterval == state().itemTimerInterval)
    }

    @Test func thumbnailNamesAreOpaquePerRevisionAndValidated() {
        let name = InkAmpPlaybackActivityStore.thumbnailFilename(itemID: "audio/src/Secret Title", revision: 1)
        #expect(name.hasPrefix("cover-") && name.hasSuffix("-1.jpg"))
        #expect(!name.contains("Secret"))
        #expect(name != InkAmpPlaybackActivityStore.thumbnailFilename(itemID: "audio/src/Secret Title", revision: 2))
        let dir = URL(fileURLWithPath: "/tmp/la")
        #expect(InkAmpPlaybackActivityStore.thumbnailURL(filename: name, in: dir) != nil)
        #expect(InkAmpPlaybackActivityStore.thumbnailURL(filename: "../cover-x.jpg", in: dir) == nil)
        #expect(InkAmpPlaybackActivityStore.thumbnailURL(filename: "cover-x.png", in: dir) == nil)
        #expect(InkAmpPlaybackActivityStore.thumbnailURL(filename: "palettes.jpg", in: dir) == nil)
    }

    @Test func supersededThumbnailsOutliveTheLockScreenRetention() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        try InkAmpPlaybackActivityStore.writeThumbnail(Data([1]), filename: "cover-a-1.jpg", in: dir, now: now)
        try InkAmpPlaybackActivityStore.writeThumbnail(Data([2]), filename: "cover-b-2.jpg", in: dir, now: now)
        // Still referenced by an ended activity's retained final state.
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("cover-a-1.jpg").path))

        let later = now.addingTimeInterval(InkAmpPlaybackActivityStore.thumbnailRetention + 60)
        try InkAmpPlaybackActivityStore.writeThumbnail(Data([3]), filename: "cover-c-3.jpg", in: dir, now: later)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left == ["cover-c-3.jpg"])

        for revision in 4...12 {
            try InkAmpPlaybackActivityStore.writeThumbnail(Data([4]), filename: "cover-d-\(revision).jpg", in: dir, now: now)
        }
        let bounded = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(bounded.count == InkAmpPlaybackActivityStore.maximumRetainedThumbnails)
        #expect(bounded.contains("cover-d-12.jpg"))
    }

    @Test func liveActivityUsesThirtySecondSkipAndIsOnByDefault() {
        #expect(InkAmpLiveActivitySettings.skipInterval == 30)
        #expect(InkAmpLiveActivitySettings.defaultEnabled)
    }
}

@Suite("Live Activity lifecycle gate")
struct InkAmpLiveActivityGateTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func startsOnPlayAndRestartsOnlyAfterAPlayTransition() {
        var gate = InkAmpLiveActivityGate()
        gate.observe(isPlaying: false)
        #expect(!gate.mayStart(isPlaying: false))
        gate.observe(isPlaying: true)
        #expect(gate.mayStart(isPlaying: true))

        // Swiped away or 8h limit while still playing: progress ticks must not restart it.
        gate.activityEndedExternally(sessionActive: true)
        gate.observe(isPlaying: true)
        gate.observe(isPlaying: true)
        #expect(!gate.mayStart(isPlaying: true))

        gate.observe(isPlaying: false)
        gate.observe(isPlaying: true)
        #expect(gate.mayStart(isPlaying: true))
    }

    @Test func userCloseIsImmediateOnlyForTheClosedItem() throws {
        var gate = InkAmpLiveActivityGate()
        gate.observe(isPlaying: true)
        gate.userClosed(itemID: "podcast/a")
        gate.observe(isPlaying: false)
        #expect(gate.dismissalDate(renderedItemID: "podcast/a", now: now) == nil)

        // Close of A coalesced with B starting: B's eventual end keeps the 15 min retention.
        #expect(gate.dismissalDate(renderedItemID: "audio/b", now: now) == now.addingTimeInterval(15 * 60))

        gate.observe(isPlaying: true)
        #expect(gate.closedItemID == nil)
        #expect(gate.dismissalDate(renderedItemID: "podcast/a", now: now) == now.addingTimeInterval(15 * 60))

        gate.userClosed(itemID: "podcast/a")
        gate.sessionEnded()
        #expect(gate == InkAmpLiveActivityGate())
    }

    @Test func adoptionKeepsOneActiveActivityOnlyWithASession() {
        let existing = [(id: "old", isActive: false), (id: "a", isActive: true), (id: "b", isActive: true)]
        let withSession = InkAmpLiveActivityGate.adoptionPlan(existing: existing, hasSession: true)
        #expect(withSession.keep == "a")
        #expect(withSession.end == ["old", "b"])

        let noSession = InkAmpLiveActivityGate.adoptionPlan(existing: existing, hasSession: false)
        #expect(noSession.keep == nil)
        #expect(noSession.end == ["old", "a", "b"])
    }
}
