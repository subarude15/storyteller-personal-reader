import Foundation
import SilveranKit

#if canImport(WidgetKit) && (os(iOS) || os(macOS))
import WidgetKit
#endif

public enum ContinueWidgetKindTag: String, Codable, Sendable {
    case ebook
    case audiobook
    case readaloud
    case podcast

    public var label: String {
        switch self {
            case .ebook: return "READ"
            case .audiobook: return "LISTEN"
            case .readaloud: return "SYNC"
            case .podcast: return "POD"
        }
    }
}

/// Home-screen Continue card payload shared via App Group (not Keychain).
///
/// The App Group identifier must be resolved at runtime — see
/// `SilveranWidgetSnapshotStore.appGroupCandidates(bundle:)`. Hard-coding
/// `group.com.punkrally.reader` stores the payload somewhere the widget cannot
/// read on an AltStore-signed build, because AltStore adds the signing team id
/// to every granted group (`<group>.<TEAMID>`).
public struct ContinueWidgetSnapshot: Codable, Sendable, Hashable {
    public var generatedAt: Date
    public var title: String?
    public var subtitle: String?
    public var coverFilename: String?
    public var isPlaying: Bool
    public var kind: ContinueWidgetKindTag?
    /// Absolute deep link into ink+amp (`punkrally://continue`).
    public var deepLink: String?
    /// Whole-item progress (0...1) when known — book position or episode progress.
    public var progress: Double?
    public var elapsedSeconds: Double?
    public var durationSeconds: Double?
    /// Real current/longest-independent streak count from SessionTracker.
    public var streakDays: Int?
    /// Local calendar day (`yyyy-MM-dd`) of the activity that anchors `streakDays`.
    /// Dated to real activity, not each subsequent audio/snapshot publish.
    public var streakActivityDayKey: String?
    /// True while the app holds a live audio session, i.e. transport buttons can
    /// actually do something. False for the "Home Continue" fallback card.
    public var hasLiveSession: Bool?
    public var rate: Double?

    public init(
        generatedAt: Date = Date(),
        title: String? = nil,
        subtitle: String? = nil,
        coverFilename: String? = nil,
        isPlaying: Bool = false,
        kind: ContinueWidgetKindTag? = nil,
        deepLink: String? = nil,
        progress: Double? = nil,
        elapsedSeconds: Double? = nil,
        durationSeconds: Double? = nil,
        hasLiveSession: Bool? = nil,
        rate: Double? = nil,
        streakDays: Int? = nil,
        streakActivityDayKey: String? = nil,
    ) {
        self.generatedAt = generatedAt
        self.title = title
        self.subtitle = subtitle
        self.coverFilename = coverFilename
        self.isPlaying = isPlaying
        self.kind = kind
        self.deepLink = deepLink
        self.progress = progress.flatMap { $0.isFinite ? $0 : nil }
        self.elapsedSeconds = elapsedSeconds.flatMap { $0.isFinite ? $0 : nil }
        self.durationSeconds = durationSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.streakDays = streakDays.map { max(0, $0) }
        self.streakActivityDayKey = streakActivityDayKey.flatMap { key in
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        self.hasLiveSession = hasLiveSession
        self.rate = rate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    public static let empty = ContinueWidgetSnapshot()

    public var hasItem: Bool {
        guard let title else { return false }
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Transport buttons only make sense while the app owns a live session.
    /// Otherwise the tile offers a tap-to-continue deep link instead, so a tap
    /// always does something instead of silently failing.
    public var supportsTransportControls: Bool {
        hasItem && (hasLiveSession ?? false)
    }

    public var isLive: Bool {
        (hasLiveSession ?? false)
    }

    public var clampedProgress: Double? {
        progress.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
    }

    public var percentComplete: Int? {
        clampedProgress.map { Int(($0 * 100).rounded()) }
    }

    /// "12m left" / "1h 5m left" when a duration is known.
    public var remainingText: String? {
        guard let timing = widgetTiming,
            let remaining = timing.remainingWallSeconds,
            remaining > 0
        else { return nil }
        return Self.durationText(remaining) + " left"
    }

    public var remainingStatusText: String? {
        guard isTimedKind else { return nil }
        return isFinished ? "Finished" : (remainingText ?? "Remaining time unknown")
    }

    public var elapsedText: String? {
        guard let timing = widgetTiming else { return nil }
        return Self.durationText(timing.elapsedSeconds)
    }

    public var lengthText: String? {
        guard kind != .ebook else { return nil }
        guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        return Self.durationText(durationSeconds)
    }

    public var elapsedLengthText: String? {
        guard let elapsedText, let lengthText else { return nil }
        return elapsedText + " / " + lengthText
    }

    public var streakText: String? {
        guard let streakDays else { return nil }
        return streakDays == 0 ? "Start a streak today" : String(streakDays) + "-day streak"
    }

    /// Expire stale streak counts on local calendar rollover while preserving
    /// today/yesterday grace. Activity day is the anchor; `generatedAt` is only
    /// a legacy fallback for snapshots written before the dated field existed.
    public func resolvingStreak(
        at now: Date,
        calendar: Calendar = .current
    ) -> ContinueWidgetSnapshot {
        var copy = self
        copy.streakDays = Self.resolvedStreakDays(
            streakDays: streakDays,
            activityDayKey: streakActivityDayKey,
            generatedAt: generatedAt,
            now: now,
            calendar: calendar
        )
        return copy
    }

    public static func resolvedStreakDays(
        streakDays: Int?,
        activityDayKey: String?,
        generatedAt: Date,
        now: Date,
        calendar: Calendar
    ) -> Int? {
        guard let streakDays else { return nil }
        let today = ReadingMotivationCalculations.localDayKey(now, calendar: calendar)
        let anchor = activityDayKey
            ?? ReadingMotivationCalculations.localDayKey(generatedAt, calendar: calendar)
        if anchor == today { return streakDays }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) {
            let yesterdayKey = ReadingMotivationCalculations.localDayKey(yesterday, calendar: calendar)
            if anchor == yesterdayKey { return streakDays }
        }
        return 0
    }

    /// Compact "31% · 12m left" style caption for the tile.
    public var progressCaption: String? {
        var parts: [String] = []
        if let percentComplete { parts.append("\(percentComplete)%") }
        if let elapsedLengthText { parts.append(elapsedLengthText) }
        if let remainingText {
            parts.append(remainingText)
        } else if isTimedKind && !isFinished {
            parts.append("Remaining unknown")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    public static func durationText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0m" }
        if seconds == 0 { return "0m" }
        if seconds < 60 { return "<1m" }
        let total = Int(min(seconds.rounded(), Double(Int.max / 2)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(max(minutes, 1))m"
    }

    /// Identity for "did anything the widget paints change?" comparisons —
    /// deliberately excludes `generatedAt`.
    var paintSignature: String {
        [
            title ?? "",
            subtitle ?? "",
            coverFilename ?? "",
            isPlaying ? "1" : "0",
            kind?.rawValue ?? "",
            deepLink ?? "",
            (hasLiveSession ?? false) ? "1" : "0",
            percentComplete.map(String.init) ?? "",
            elapsedLengthText ?? "",
            remainingText ?? "",
            streakText ?? "",
        ].joined(separator: "|")
    }

    /// Transport state identity — changes flip the play/pause glyph right away.
    var transportSignature: String {
        [title ?? "", isPlaying ? "1" : "0", kind?.rawValue ?? "",
         (hasLiveSession ?? false) ? "1" : "0"].joined(separator: "|")
    }

    private var widgetTiming: ContinueWidgetTiming? {
        guard kind != .ebook else { return nil }
        return ContinueWidgetTiming.calculate(
            progress: progress,
            elapsedSeconds: elapsedSeconds,
            durationSeconds: durationSeconds,
            rate: rate,
        )
    }

    private var isTimedKind: Bool {
        switch kind {
            case .audiobook, .readaloud, .podcast: return true
            case .ebook, .none: return false
        }
    }

    private var isFinished: Bool {
        clampedProgress == 1 || widgetTiming?.remainingWallSeconds == 0
    }
}

/// Injectable App Group / file seam for Continue snapshot publication tests.
public protocol ContinueWidgetSnapshotFileStoring: Sendable {
    func resolveContainer() -> URL?
    func ensureDirectories(in container: URL) throws
    func readSnapshot(in container: URL) -> ContinueWidgetSnapshot?
    func writeSnapshotData(_ data: Data, to container: URL) throws
    func existingCoverFilename(in container: URL) -> String?
    func writeCoverData(_ data: Data, to container: URL) throws -> String
}

public struct AppGroupContinueWidgetSnapshotFileStore: ContinueWidgetSnapshotFileStoring {
    public init() {}

    public func resolveContainer() -> URL? {
        SilveranWidgetSnapshotStore.sharedContainerURL()
    }

    public func ensureDirectories(in container: URL) throws {
        try FileManager.default.createDirectory(
            at: container, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: ContinueWidgetSnapshotStore.coversDirectory(in: container),
            withIntermediateDirectories: true
        )
    }

    public func readSnapshot(in container: URL) -> ContinueWidgetSnapshot? {
        ContinueWidgetSnapshotStore.readSnapshotFile(in: container)
    }

    public func writeSnapshotData(_ data: Data, to container: URL) throws {
        try data.write(
            to: ContinueWidgetSnapshotStore.snapshotURL(in: container),
            options: [.atomic]
        )
    }

    public func existingCoverFilename(in container: URL) -> String? {
        readSnapshot(in: container)?.coverFilename
    }

    public func writeCoverData(_ data: Data, to container: URL) throws -> String {
        let name = "continue_cover.dat"
        let url = ContinueWidgetSnapshotStore.coversDirectory(in: container)
            .appendingPathComponent(name, isDirectory: false)
        try data.write(to: url, options: [.atomic])
        return name
    }
}

public enum ContinueWidgetSnapshotStore {
    private static let snapshotFilename = "continue-now.json"
    private static let coversDirectoryName = "ContinueCovers"
    private static let lastTitleDefaultsKey = "inkamp.continueWidget.lastTitle"
    private static let lastSnapshotDefaultsKey = "inkamp.continueWidget.lastSnapshot"

    /// Minimum gap between WidgetKit reload requests while playback advances.
    /// iOS budgets widget reloads; progress ticks must not burn them all.
    private static let progressReloadInterval: TimeInterval = 20

    private static let publishLock = NSLock()
    nonisolated(unsafe) private static var lastPublishedPaintSignature: String?
    nonisolated(unsafe) private static var lastPublishedTransportSignature: String?
    nonisolated(unsafe) private static var lastReloadDate: Date = .distantPast

    public static func loadSnapshot(bundle: Bundle = .main) -> ContinueWidgetSnapshot {
        guard let container = SilveranWidgetSnapshotStore.sharedContainerURL(bundle: bundle)
        else {
            return localFallbackSnapshot()
        }
        let url = snapshotURL(in: container)
        // Reachable container is authoritative: nothing published yet means an
        // empty tile, not a stale item resurrected from local cache.
        guard let data = try? Data(contentsOf: url) else {
            return .empty
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(ContinueWidgetSnapshot.self, from: data),
            snapshot.hasItem
        else {
            return .empty
        }
        // Widget-extension local memory: survives empty reloads if the App Group blips.
        rememberLastSnapshot(snapshot)
        return snapshot
    }

    // MARK: - Extension-local fallback

    /// Last snapshot this process (app or widget extension) successfully read or
    /// wrote, kept in process-local `UserDefaults` so a missing/blank shared
    /// container still paints the last known item instead of an empty tile.
    public static func rememberLastSnapshot(_ snapshot: ContinueWidgetSnapshot) {
        guard snapshot.hasItem else { return }
        if let title = snapshot.title, !title.isEmpty {
            UserDefaults.standard.set(title, forKey: lastTitleDefaultsKey)
        }
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: lastSnapshotDefaultsKey)
        }
    }

    public static func localFallbackSnapshot() -> ContinueWidgetSnapshot {
        if let data = UserDefaults.standard.data(forKey: lastSnapshotDefaultsKey),
            let snapshot = try? JSONDecoder().decode(ContinueWidgetSnapshot.self, from: data),
            snapshot.hasItem
        {
            var stale = snapshot
            // Cached paint only — never claim playback is live from a local cache.
            stale.isPlaying = false
            stale.hasLiveSession = false
            return stale
        }
        return .empty
    }

    /// Widget-extension local title fallback when the shared snapshot is empty.
    public static func lastTitleFallback() -> String? {
        let value = UserDefaults.standard.string(forKey: lastTitleDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    public static func coverURL(for filename: String, bundle: Bundle = .main) -> URL? {
        guard let container = SilveranWidgetSnapshotStore.sharedContainerURL(bundle: bundle)
        else { return nil }
        return coversDirectory(in: container).appendingPathComponent(filename, isDirectory: false)
    }

    // MARK: - Publishing

    /// Publish the Continue / Now Playing tile. Pass `coverData` when available;
    /// nil keeps the previous cover file when a title is present. Title-only
    /// writes are OK (cover bytes may be nil for ebook / uncached covers).
    public static func publish(
        title: String?,
        subtitle: String?,
        isPlaying: Bool,
        kind: ContinueWidgetKindTag?,
        coverData: Data?,
        deepLink: String = InkAmpContinueLink.continueURL.absoluteString,
        progress: Double? = nil,
        elapsedSeconds: Double? = nil,
        durationSeconds: Double? = nil,
        hasLiveSession: Bool = false,
        rate: Double? = nil,
        streakDays: Int? = nil,
        streakActivityDayKey: String? = nil,
        fileStore: (any ContinueWidgetSnapshotFileStoring)? = nil,
    ) {
        SilveranWidgetSnapshotStore.logAppGroupAvailability(source: "publish")
        let store = fileStore ?? AppGroupContinueWidgetSnapshotFileStore()
        guard let container = store.resolveContainer() else {
            print("[ContinueWidget] publish skipped — App group container unavailable")
            return
        }

        // Serialize read → streak/cover preserve → write → signature update so a
        // concurrent audio tick cannot overwrite a fresher Home streak with a
        // stale previous snapshot. reloadTimelines stays outside the lock.
        var shouldReload = false
        publishLock.lock()
        do {
            try store.ensureDirectories(in: container)

            var coverFilename: String?
            if let coverData, !coverData.isEmpty {
                coverFilename = try store.writeCoverData(coverData, to: container)
            } else if title != nil {
                // Keep last cover while the same session refreshes without image bytes.
                coverFilename = store.existingCoverFilename(in: container)
            }

            let previous = store.readSnapshot(in: container)
            let snapshot = ContinueWidgetSnapshot(
                generatedAt: Date(),
                title: title,
                subtitle: subtitle,
                coverFilename: coverFilename,
                isPlaying: isPlaying,
                kind: kind,
                deepLink: title == nil ? nil : deepLink,
                progress: progress,
                elapsedSeconds: elapsedSeconds,
                durationSeconds: durationSeconds,
                hasLiveSession: hasLiveSession,
                rate: rate,
                streakDays: streakDays ?? previous?.streakDays,
                // Preserve the activity anchor across audio-only publishes; never
                // re-date it from generatedAt or progress ticks.
                streakActivityDayKey: streakActivityDayKey ?? previous?.streakActivityDayKey,
            )

            let previousPaint = lastPublishedPaintSignature
            let previousTransport = lastPublishedTransportSignature
            let previousReload = lastReloadDate
            let paintChanged = previousPaint != snapshot.paintSignature
            let transportChanged = previousTransport != snapshot.transportSignature
            let now = Date()
            guard paintChanged || transportChanged else {
                publishLock.unlock()
                return
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            try store.writeSnapshotData(data, to: container)
            // UserDefaults only — must not re-enter publishLock.
            rememberLastSnapshot(snapshot)

            let progressTickDue =
                now.timeIntervalSince(previousReload) >= progressReloadInterval
            shouldReload =
                transportChanged || (paintChanged && progressTickDue)
                || now.timeIntervalSince(previousReload) >= 300

            lastPublishedPaintSignature = snapshot.paintSignature
            lastPublishedTransportSignature = snapshot.transportSignature
            if shouldReload { lastReloadDate = now }
            publishLock.unlock()
        } catch {
            publishLock.unlock()
            print("[ContinueWidget] publish failed: \(error)")
            return
        }

        if shouldReload {
            reloadTimelines()
        }
    }

    /// Re-publish straight from the live audio session. Used by widget transport
    /// intents, which run inside the app process but must not depend on the app's
    /// UI having appeared (a WidgetKit background launch may never show a scene).
    /// Cover bytes are intentionally nil — `publish` keeps the previous cover.
    public static func publishFromLiveSession() async {
        let session = await AudioSessionActor.shared.currentSnapshot()
        guard let session else {
            markSessionInactive()
            return
        }
        let kind: ContinueWidgetKindTag
        switch session.kind {
            case .audiobook: kind = .audiobook
            case .readaloud: kind = .readaloud
            case .podcast: kind = .podcast
        }
        publish(
            title: session.title,
            subtitle: session.author ?? session.chapterLabel,
            isPlaying: session.isPlaying,
            kind: kind,
            coverData: nil,
            progress: session.bookProgress,
            elapsedSeconds: session.elapsedSeconds,
            durationSeconds: session.durationSeconds,
            hasLiveSession: true,
            rate: session.playbackRate,
            streakDays: loadSnapshot().streakDays,
            streakActivityDayKey: loadSnapshot().streakActivityDayKey,
        )
    }

    /// Session ended (or the app relaunched cold with nothing playing): keep the
    /// last item for tap-to-continue, but stop claiming it is playing.
    public static func markSessionInactive() {
        let last = loadSnapshot()
        guard last.hasItem else { return }
        publish(
            title: last.title,
            subtitle: last.subtitle,
            isPlaying: false,
            kind: last.kind,
            coverData: nil,
            progress: last.progress,
            elapsedSeconds: last.elapsedSeconds,
            durationSeconds: last.durationSeconds,
            hasLiveSession: false,
            rate: last.rate,
            streakDays: last.streakDays,
            streakActivityDayKey: last.streakActivityDayKey,
        )
    }

    public static func reloadTimelines() {
        #if canImport(WidgetKit) && (os(iOS) || os(macOS))
        WidgetCenter.shared.reloadTimelines(ofKind: SilveranWidgetConstants.continueWidgetKind)
        #endif
    }

    // MARK: - Paths

    static func readSnapshotFile(in container: URL) -> ContinueWidgetSnapshot? {
        let url = snapshotURL(in: container)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ContinueWidgetSnapshot.self, from: data)
    }

    static func snapshotURL(in container: URL) -> URL {
        container.appendingPathComponent(snapshotFilename, isDirectory: false)
    }

    static func coversDirectory(in container: URL) -> URL {
        container.appendingPathComponent(coversDirectoryName, isDirectory: true)
    }

    /// Test hook: reset in-process publish signatures between injectable-store runs.
    public static func resetPublishSignaturesForTesting() {
        publishLock.lock()
        lastPublishedPaintSignature = nil
        lastPublishedTransportSignature = nil
        lastReloadDate = .distantPast
        publishLock.unlock()
    }
}

/// Deep links for the Continue widget (`punkrally` scheme — already registered).
public enum InkAmpContinueLink {
    public static let continueURL = URL(string: "punkrally://continue")!
    public static let toggleURL = URL(string: "punkrally://continue?action=toggle")!

    public static func isContinueURL(_ url: URL) -> Bool {
        guard url.scheme == "punkrally" else { return false }
        let host = url.host() ?? url.host
        return host == "continue"
    }

    public static func wantsToggle(_ url: URL) -> Bool {
        guard isContinueURL(url) else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        return items?.contains(where: { $0.name == "action" && $0.value == "toggle" }) == true
    }
}
