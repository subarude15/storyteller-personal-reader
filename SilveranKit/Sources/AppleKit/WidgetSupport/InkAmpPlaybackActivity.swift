import Foundation
import SilveranKit
#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import AppIntents
#endif

/// Live Activity content. Everything is content state (not static attributes) so item
/// switches, late cover thumbnails and late tints update one activity in place.
/// Positions are media seconds; `positionAt` is the wall clock when `position` was read.
public struct InkAmpPlaybackActivityState: Codable, Hashable, Sendable {
    public enum ItemKind: String, Codable, Hashable, Sendable {
        case audiobook, readaloud, podcast
    }

    public var itemKind: ItemKind
    public var itemID: String
    public var title: String
    public var author: String?
    /// File name inside `InkAmpPlaybackActivityStore.directory` (never image bytes).
    public var coverFilename: String?
    /// nil = app accent (tint off, Increase Contrast, or no usable cover hue).
    public var tint: CoverTintPalette?
    public var chapter: String?
    public var isPlaying: Bool
    public var rate: Double
    public var positionAt: Date
    public var position: TimeInterval
    public var chapterEnd: TimeInterval?
    public var itemEnd: TimeInterval

    public init(
        itemKind: ItemKind,
        itemID: String,
        title: String,
        author: String?,
        coverFilename: String?,
        tint: CoverTintPalette?,
        chapter: String?,
        isPlaying: Bool,
        rate: Double,
        positionAt: Date,
        position: TimeInterval,
        chapterEnd: TimeInterval?,
        itemEnd: TimeInterval,
    ) {
        self.itemKind = itemKind
        self.itemID = itemID
        self.title = title
        self.author = author
        self.coverFilename = coverFilename
        self.tint = tint
        self.chapter = chapter
        self.isPlaying = isPlaying
        self.rate = rate
        self.positionAt = positionAt
        self.position = position
        self.chapterEnd = chapterEnd
        self.itemEnd = itemEnd
    }

    /// ActivityKit caps static attributes + content state at 4KB of encoded data.
    public static let maximumPayloadBytes = 4096
    /// UTF-8 byte caps; worst case (all three full, plus tint and ids) stays near 1.5KB.
    static let maximumTitleBytes = 240
    static let maximumSecondaryBytes = 160
    static let maximumItemIDBytes = 120

    public init(
        snapshot: AudioSessionSnapshot,
        coverFilename: String?,
        tint: CoverTintPalette?,
        now: Date = Date(),
    ) {
        let kind: ItemKind
        switch snapshot.kind {
            case .audiobook: kind = .audiobook
            case .readaloud: kind = .readaloud
            case .podcast: kind = .podcast
        }
        let position = snapshot.elapsedSeconds.isFinite ? max(0, snapshot.elapsedSeconds) : 0
        let chapterEnd = snapshot.chapterRemainingSeconds.map { position + max(0, $0) }
        self.init(
            itemKind: kind,
            itemID: Self.activityItemID(for: snapshot.kind),
            title: Self.clip(snapshot.title, maxBytes: Self.maximumTitleBytes) ?? "Now Playing",
            author: Self.clip(snapshot.author, maxBytes: Self.maximumSecondaryBytes),
            coverFilename: coverFilename,
            tint: tint,
            chapter: Self.clip(snapshot.chapterLabel, maxBytes: Self.maximumSecondaryBytes),
            isPlaying: snapshot.isPlaying,
            rate: snapshot.playbackRate.isFinite && snapshot.playbackRate > 0 ? snapshot.playbackRate : 1,
            positionAt: now,
            position: position,
            chapterEnd: chapterEnd.flatMap { $0.isFinite ? $0 : nil },
            itemEnd: snapshot.durationSeconds.isFinite ? max(0, snapshot.durationSeconds) : 0,
        )
    }

    /// Only compared for identity, so long podcast GUIDs collapse to a hash.
    public static func activityItemID(for kind: AudioSessionKind) -> String {
        let id = ContinueWidgetItemID.from(sessionKind: kind)
        return id.utf8.count <= maximumItemIDBytes ? id : "h:" + CoverTintMath.fingerprint(rgbaPixels: Array(id.utf8))
    }

    /// Longest whole-character prefix of `text` that fits in `maxBytes` of UTF-8.
    static func clip(_ text: String?, maxBytes: Int) -> String? {
        guard let text, text.utf8.count > maxBytes else { return text }
        var clipped = ""
        var bytes = 0
        for character in text {
            bytes += character.utf8.count
            guard bytes <= maxBytes else { break }
            clipped.append(character)
        }
        return clipped
    }

    /// Encoded content state plus the (empty) static attributes, as ActivityKit counts them.
    public var payloadByteCount: Int {
        ((try? JSONEncoder().encode(self).count) ?? Self.maximumPayloadBytes) + 2
    }

    /// Media position the activity is showing at `date` (extrapolated while playing).
    public func expectedPosition(at date: Date) -> TimeInterval {
        guard isPlaying else { return position }
        return position + date.timeIntervalSince(positionAt) * rate
    }

    /// Wall-clock span over which `position` runs from 0 to `itemEnd` at `rate`, for
    /// `Text(timerInterval:)` / `ProgressView(timerInterval:)`. nil when unknown length.
    public var itemTimerInterval: ClosedRange<Date>? {
        timerInterval(end: itemEnd, start: 0)
    }

    /// Wall-clock span for the time left in the chapter (falls back to the whole item).
    public var remainingTimerInterval: ClosedRange<Date>? {
        guard let chapterEnd, chapterEnd > position else { return itemTimerInterval }
        return timerInterval(end: chapterEnd, start: position)
    }

    private func timerInterval(end: TimeInterval, start: TimeInterval) -> ClosedRange<Date>? {
        guard [end, start, position, rate, positionAt.timeIntervalSinceReferenceDate].allSatisfy(\.isFinite),
            end > 0, end > start, rate > 0
        else { return nil }
        let lowerOffset = -(position - start) / rate
        let upperOffset = (end - position) / rate
        guard lowerOffset.isFinite, upperOffset.isFinite else { return nil }
        let lower = positionAt.addingTimeInterval(lowerOffset)
        let upper = positionAt.addingTimeInterval(upperOffset)
        guard lower.timeIntervalSinceReferenceDate.isFinite, upper.timeIntervalSinceReferenceDate.isFinite
        else { return nil }
        return lower...max(lower, upper)
    }

    /// Players stop within a frame of the end but report positions slightly short of it.
    public static let finishTolerance: TimeInterval = 1.5

    /// Stopped at the end of the item (natural completion), as opposed to an ordinary
    /// pause, which leaves the position short of `itemEnd`.
    public var isFinished: Bool {
        !isPlaying && itemEnd > 0 && position >= itemEnd - Self.finishTolerance
    }

    /// Seek detection threshold while playing. Snapshots are stamped when they arrive
    /// (≤0.5s apart, millisecond jitter) and media time advances at `rate` per wall
    /// second, so a tick lands within a few tenths of the extrapolation; a 1s gap can
    /// only come from a seek, a chapter jump or a stall. Sub-second seeks are not
    /// pushed: the timers render whole seconds.
    public static let playingSeekTolerance: TimeInterval = 1
    /// Paused position never moves on its own, so any visible change is a seek.
    public static let pausedSeekTolerance: TimeInterval = 0.5

    /// Whether `next` differs from what this state already renders. Progress ticks are
    /// ignored: a playing activity extrapolates with timers, so only play/pause, seek,
    /// chapter, rate, item, cover and tint changes push an update.
    public func needsUpdate(to next: InkAmpPlaybackActivityState) -> Bool {
        if itemKind != next.itemKind || itemID != next.itemID || title != next.title
            || author != next.author || coverFilename != next.coverFilename || tint != next.tint
            || chapter != next.chapter || isPlaying != next.isPlaying
            || abs(rate - next.rate) > 0.001
        {
            return true
        }
        let seekTolerance = isPlaying ? Self.playingSeekTolerance : Self.pausedSeekTolerance
        if !(abs(expectedPosition(at: next.positionAt) - next.position) <= seekTolerance) { return true }
        if abs(itemEnd - next.itemEnd) > 2 { return true }
        switch (chapterEnd, next.chapterEnd) {
            case (nil, nil): return false
            case let (lhs?, rhs?): return abs(lhs - rhs) > 2
            default: return true
        }
    }
}

/// App Group location of Live Activity cover thumbnails, readable by the widget extension.
public enum InkAmpPlaybackActivityStore {
    public static let thumbnailPixelSide = 120
    public static let directoryName = "LiveActivity"

    public static func directory(bundle: Bundle = .main) -> URL? {
        AppGroupContainer.sharedContainerURL(bundle: bundle)?
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Ended activities stay on the Lock Screen up to 15 minutes and keep pointing at
    /// their cover, so superseded files are kept a little longer than that.
    public static let thumbnailRetention: TimeInterval = 20 * 60
    public static let maximumRetainedThumbnails = 6

    /// Non-identifying file name per item and cover revision (no titles or ids in paths).
    /// A new revision gets a new name so the activity state changes and re-renders.
    public static func thumbnailFilename(itemID: String, revision: Int) -> String {
        "cover-\(CoverTintMath.fingerprint(rgbaPixels: Array(itemID.utf8)))-\(revision).jpg"
    }

    public static func thumbnailURL(filename: String, in directory: URL? = directory()) -> URL? {
        guard filename == (filename as NSString).lastPathComponent, filename.hasPrefix("cover-"),
            filename.hasSuffix(".jpg")
        else { return nil }
        return directory?.appendingPathComponent(filename)
    }

    /// Writes JPEG bytes readable while the device is locked after first unlock (the Lock
    /// Screen renders the activity then), then prunes superseded thumbnails.
    public static func writeThumbnail(
        _ jpeg: Data,
        filename: String,
        in directory: URL? = directory(),
        now: Date = Date(),
    ) throws {
        guard let directory, let url = thumbnailURL(filename: filename, in: directory) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try jpeg.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try jpeg.write(to: url, options: .atomic)
        #endif
        prune(directory: directory, keeping: filename, now: now)
    }

    /// Removes thumbnails older than `thumbnailRetention`, and the oldest beyond
    /// `maximumRetainedThumbnails`; never the current one.
    static func prune(directory: URL, keeping current: String, now: Date) {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
        )) ?? []
        let dated = files
            .filter { $0.lastPathComponent != current }
            .map { url in
                (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
        for (index, file) in dated.enumerated()
        where index >= maximumRetainedThumbnails - 1 || now.timeIntervalSince(file.1) > thumbnailRetention {
            try? manager.removeItem(at: file.0)
        }
    }
}

/// Start/stop rules for the single playback activity, kept free of ActivityKit so they
/// can be tested. Fed every snapshot (not only the coalesced ones that reach ActivityKit)
/// so no pause → play transition is missed.
public struct InkAmpLiveActivityGate: Equatable, Sendable {
    public static let sessionEndRetention: TimeInterval = 15 * 60

    public private(set) var wasPlaying = false
    /// The system or the user ended the activity while the session continued; stay off
    /// until the next pause → play transition rather than restarting on a progress tick.
    public private(set) var suppressed = false
    /// Item the user explicitly closed; its activity is removed immediately.
    public private(set) var closedItemID: String?

    public init() {}

    public mutating func observe(isPlaying: Bool?) {
        let playing = isPlaying ?? false
        if playing, !wasPlaying {
            suppressed = false
            closedItemID = nil
        }
        wasPlaying = playing
    }

    public mutating func userClosed(itemID: String) {
        closedItemID = itemID
    }

    public mutating func activityEndedExternally(sessionActive: Bool) {
        if sessionActive { suppressed = true }
    }

    public func mayStart(isPlaying: Bool) -> Bool {
        isPlaying && !suppressed
    }

    /// nil = remove now; otherwise keep the final paused state visible until the date.
    /// `Activity.end` always ends immediately; this only sets Lock Screen retention.
    public func dismissalDate(renderedItemID: String?, now: Date) -> Date? {
        closedItemID != nil && closedItemID == renderedItemID ? nil : now.addingTimeInterval(Self.sessionEndRetention)
    }

    public mutating func sessionEnded() {
        self = InkAmpLiveActivityGate()
    }

    /// One activity at most: keep the first active one only while a session can drive it.
    public static func adoptionPlan(
        existing: [(id: String, isActive: Bool)],
        hasSession: Bool,
    ) -> (keep: String?, end: [String]) {
        let keep = hasSession ? existing.first(where: { $0.isActive })?.id : nil
        return (keep, existing.map { $0.id }.filter { $0 != keep })
    }
}

public enum InkAmpLiveActivitySettings {
    public static let enabledKey = "inkamp.liveActivity.enabled"
    public static let defaultEnabled = true
    /// Live Activity and CarPlay use 30s; the Continue widget keeps `podcastSkipInterval`.
    public static let skipInterval: TimeInterval = 30

    public static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }
}

#if os(iOS) && canImport(ActivityKit)
public struct InkAmpPlaybackAttributes: ActivityAttributes {
    public typealias ContentState = InkAmpPlaybackActivityState

    public init() {}
}

/// Ends every playback activity immediately; used when no session can back them
/// (process relaunched by an intent with nothing playing).
public enum InkAmpPlaybackActivityCleanup {
    public static func endAllImmediately() async {
        for activity in Activity<InkAmpPlaybackAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

/// Live Activity buttons. `LiveActivityIntent` runs `perform()` in the app process, so
/// these drive the same `AudioSessionActor` as the player, even from the Lock Screen.
/// The type must be compiled into both the app and the widget extension; both link
/// `SilveranAppleWidgets`.
public struct InkAmpLiveTogglePlayIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Play or Pause"
    public static let isDiscoverable = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        guard await AudioSessionActor.shared.currentSnapshot() != nil else {
            await InkAmpPlaybackActivityCleanup.endAllImmediately()
            return .result()
        }
        try await AudioSessionActor.shared.transport(.togglePlayPause)
        return .result()
    }
}

public struct InkAmpLiveSkipIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Skip"
    public static let isDiscoverable = false

    @Parameter(title: "Seconds")
    public var seconds: Int

    public init() {}

    public init(seconds: Int) {
        self.seconds = seconds
    }

    public func perform() async throws -> some IntentResult {
        guard await AudioSessionActor.shared.currentSnapshot() != nil else {
            await InkAmpPlaybackActivityCleanup.endAllImmediately()
            return .result()
        }
        let limit = Int(InkAmpLiveActivitySettings.skipInterval)
        await AudioSessionActor.shared.skipPlayback(by: TimeInterval(min(max(seconds, -limit), limit)))
        return .result()
    }
}
#endif
