import Foundation
import OSLog
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

    public var symbolName: String {
        switch self {
            case .ebook: return "book.closed.fill"
            case .audiobook: return "headphones"
            case .readaloud: return "text.book.closed.fill"
            case .podcast: return "mic.fill"
        }
    }
}

/// One Up next row in the Continue widget. Same identity string as `HomeMixedItem.id`
/// (`book:<source>/<uuid>` or `pod:<episodeID>`).
public struct ContinueWidgetQueueItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var coverFilename: String?
    public var kind: ContinueWidgetKindTag?
    public var deepLink: String
    public var progress: Double?

    public var clampedProgress: Double? {
        guard let progress, progress > 0 else { return nil }
        return min(max(progress, 0), 1)
    }

    public var percentComplete: Int? {
        guard let clampedProgress else { return nil }
        let pct = Int((clampedProgress * 100).rounded())
        return pct > 0 ? pct : nil
    }

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        coverFilename: String? = nil,
        kind: ContinueWidgetKindTag? = nil,
        deepLink: String,
        progress: Double? = nil,
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.coverFilename = coverFilename
        self.kind = kind
        self.deepLink = deepLink
        self.progress = progress
    }
}

/// App-side draft for an Up next row. Cover bytes are written into the shared
/// container by `ContinueWidgetSnapshotStore`; the widget only sees the filename.
public struct ContinueWidgetUpNextDraft: Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var kind: ContinueWidgetKindTag?
    public var deepLink: String
    public var progress: Double?
    public var coverData: Data?

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        kind: ContinueWidgetKindTag? = nil,
        deepLink: String,
        progress: Double? = nil,
        coverData: Data? = nil,
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.deepLink = deepLink
        self.progress = progress
        self.coverData = coverData
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
    /// Today's combined active reading + listening seconds.
    public var todayActiveSeconds: Double?
    /// Daily active goal in minutes (default 30 when unset).
    public var dailyGoalMinutes: Int?
    /// Local calendar day (`yyyy-MM-dd`) for `todayActiveSeconds`.
    public var todayGoalDayKey: String?
    /// Longest-ever recorded streak in days.
    public var longestStreakDays: Int?
    /// True while the app holds a live audio session, i.e. transport buttons can
    /// actually do something. False for the "Home Continue" fallback card.
    public var hasLiveSession: Bool?
    public var rate: Double?
    /// Following Home mixed-queue rows (not a second queue). Nil on snapshots
    /// written before Up next existed.
    public var upNext: [ContinueWidgetQueueItem]?
    /// Stable book / episode / session id (`book:<source>/<uuid>` or `pod:<id>`).
    /// Optional so snapshots written before this field still decode.
    public var itemID: String?

    public static let upNextLimit = 3

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
        upNext: [ContinueWidgetQueueItem]? = nil,
        itemID: String? = nil,
        streakDays: Int? = nil,
        streakActivityDayKey: String? = nil,
        todayActiveSeconds: Double? = nil,
        dailyGoalMinutes: Int? = nil,
        todayGoalDayKey: String? = nil,
        longestStreakDays: Int? = nil,
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
        self.todayActiveSeconds = todayActiveSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.dailyGoalMinutes = dailyGoalMinutes.map { max(1, $0) }
        self.todayGoalDayKey = todayGoalDayKey.flatMap { key in
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        self.longestStreakDays = longestStreakDays.map { max(0, $0) }
        self.hasLiveSession = hasLiveSession
        self.rate = rate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.upNext = upNext
        self.itemID = itemID
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

    /// "12m left" / "1h 5m left" when a duration is known, adjusted for playback rate.
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
        guard let elapsedText else { return nil }
        if let lengthText {
            return elapsedText + " / " + lengthText
        }
        // Known elapsed with unknown total: still paint an elapsed caption.
        return elapsedText + " elapsed"
    }

    public var streakText: String? {
        guard let streakDays else { return nil }
        return streakDays == 0 ? "Start a streak today" : String(streakDays) + "-day streak"
    }

    /// Expire stale streak counts on local calendar rollover while preserving
    /// today/yesterday grace. Activity day is the anchor; `generatedAt` is only
    /// a legacy fallback for snapshots written before the dated field existed.
    /// Widget/app-group boundary for Gregorian local-day identities with device TZ.
    public static func normalizedLocalCalendar(
        from calendar: Calendar = .current
    ) -> Calendar {
        ReadingMotivationCalculations.normalizedLocalCalendar(from: calendar)
    }

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
        let normalized = Self.normalizedLocalCalendar(from: calendar)
        let todayKey = ReadingMotivationCalculations.localDayKey(now, calendar: normalized)
        let goalAnchor = todayGoalDayKey
            ?? ReadingMotivationCalculations.localDayKey(generatedAt, calendar: normalized)
        if goalAnchor != todayKey {
            copy.todayActiveSeconds = 0
            copy.todayGoalDayKey = todayKey
        }
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
        let calendar = Self.normalizedLocalCalendar(from: calendar)
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

    /// Up next rows the tile actually paints (at most `upNextLimit`).
    public var upNextItems: [ContinueWidgetQueueItem] {
        Array((upNext ?? []).prefix(Self.upNextLimit))
    }

    /// Which item is Now Listening. Prefers the stable item id; title is display.
    public var mediaIdentity: String {
        Self.mediaIdentity(itemID: itemID, kind: kind, title: title, deepLink: deepLink)
    }

    public static func mediaIdentity(
        itemID: String?,
        kind: ContinueWidgetKindTag?,
        title: String?,
        deepLink: String?,
    ) -> String {
        if let itemID {
            let trimmed = itemID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return [
            kind?.rawValue ?? "",
            title ?? "",
            deepLink ?? "",
        ].joined(separator: "|")
    }

    /// Keep the last cover only when Now Listening is the same item.
    public static func shouldKeepPreviousCover(
        previous: ContinueWidgetSnapshot,
        nextItemID: String?,
        nextTitle: String?,
        nextKind: ContinueWidgetKindTag?,
        nextDeepLink: String?,
    ) -> Bool {
        guard nextTitle != nil, previous.coverFilename != nil else { return false }
        return previous.mediaIdentity == mediaIdentity(
            itemID: nextItemID,
            kind: nextKind,
            title: nextTitle,
            deepLink: nextDeepLink,
        )
    }

    /// Determines whether an existing audio session should take priority over the
    /// Home mixed-queue's top `continueItem`. Active playback always wins, and a
    /// paused session wins when there is no newer Home item or when the Home item
    /// is the same book/episode. A paused session does not block a more recently
    /// read ebook from becoming the Continue widget's Now card.
    public static func shouldPreferLiveSession(
        sessionIsPlaying: Bool,
        sessionItemID: String,
        homeItemID: String?,
    ) -> Bool {
        if sessionIsPlaying { return true }
        guard let homeItemID = homeItemID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !homeItemID.isEmpty
        else {
            return true
        }
        return sessionItemID == homeItemID
    }

    /// Identity for "did anything the widget paints change?" comparisons —
    /// deliberately excludes `generatedAt`.
    public var paintSignature: String {
        // Typed intermediates avoid `String.init` overload explosion that made
        // Swift 6.2 unable to type-check this expression in reasonable time.
        let percent: String
        if let percentComplete {
            percent = String(percentComplete)
        } else {
            percent = ""
        }
        let todayDoneMinutes: String
        if let todayActiveSeconds, todayActiveSeconds.isFinite, todayActiveSeconds >= 0 {
            todayDoneMinutes = String(Int(todayActiveSeconds / 60))
        } else {
            todayDoneMinutes = ""
        }
        let goalMinutesText: String = dailyGoalMinutes.map { String($0) } ?? ""
        let longestStreakText: String = longestStreakDays.map { String($0) } ?? ""
        let parts: [String] = [
            mediaIdentity,
            title ?? "",
            subtitle ?? "",
            coverFilename ?? "",
            isPlaying ? "1" : "0",
            (hasLiveSession ?? false) ? "1" : "0",
            percent,
            elapsedLengthText ?? "",
            remainingText ?? "",
            streakText ?? "",
            todayDoneMinutes,
            goalMinutesText,
            longestStreakText,
            queueSignature,
        ]
        return parts.joined(separator: "|")
    }

    /// Up next identity. Changes reload the tile immediately (not on the
    /// progress-tick budget).
    var queueSignature: String {
        upNextItems.map { item in
            [
                item.id,
                item.title,
                item.coverFilename ?? "",
                item.deepLink,
                item.kind?.rawValue ?? "",
            ].joined(separator: ":")
        }.joined(separator: ";")
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
        try SilveranWidgetSnapshotStore.prepareTransientState(in: container)
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
    private static let logger = Logger(subsystem: "com.punkrally.reader", category: "ContinueWidget")
    private static let snapshotFilename = ContinueWidgetCurrentSnapshot.storageKey
    private static let coversDirectoryName = "ContinueCovers"
    private static let lastTitleDefaultsKey = "inkamp.continueWidget.lastTitle"
    private static let lastSnapshotDefaultsKey = "inkamp.continueWidget.lastSnapshot"

    private static let publishLock = NSLock()
    nonisolated(unsafe) private static var lastReloadDate: Date = .distantPast

    public static func loadSnapshot(bundle: Bundle = .main) -> ContinueWidgetSnapshot {
        let bundleRole = bundle.bundleURL.pathExtension == "appex" ? "widget" : "app"
        let fallback = localFallbackSnapshot()
        guard let container = SilveranWidgetSnapshotStore.sharedContainerURL(bundle: bundle)
        else {
            logger.notice("snapshot bundle=\(bundleRole, privacy: .public) container=false")
            let snapshot = ContinueWidgetCurrentSnapshot.select(
                shared: nil,
                localFallback: fallback,
                sharedContainerReachable: false,
            )
            logger.notice("snapshot bundle=\(bundleRole, privacy: .public) selectedHasItem=\(snapshot.hasItem, privacy: .public)")
            return snapshot
        }
        let url = snapshotURL(in: container)
        let exists = FileManager.default.fileExists(atPath: url.path)
        logger.notice("snapshot bundle=\(bundleRole, privacy: .public) container=true exists=\(exists, privacy: .public)")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let shared: ContinueWidgetSnapshot?
        do {
            let data = try Data(contentsOf: url)
            logger.notice("snapshot bundle=\(bundleRole, privacy: .public) read=success")
            do {
                shared = try decoder.decode(ContinueWidgetSnapshot.self, from: data)
                logger.notice("snapshot bundle=\(bundleRole, privacy: .public) decode=success")
            } catch {
                shared = nil
                logger.error("snapshot bundle=\(bundleRole, privacy: .public) decode=failure errorType=\(String(describing: type(of: error)), privacy: .public)")
            }
        } catch {
            shared = nil
            logger.error("snapshot bundle=\(bundleRole, privacy: .public) read=failure errorType=\(String(describing: type(of: error)), privacy: .public)")
        }
        // Reachable container is authoritative: compact tiles must not keep an
        // older process-local audiobook after the shared file has moved on.
        let snapshot = ContinueWidgetCurrentSnapshot.select(
            shared: shared,
            localFallback: fallback,
            sharedContainerReachable: true,
        )
        logger.notice("snapshot bundle=\(bundleRole, privacy: .public) selectedHasItem=\(snapshot.hasItem, privacy: .public)")
        if snapshot.hasItem {
            rememberLastSnapshot(snapshot)
        }
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

    public static func resetLocalFallbackAfterExternalRestore() {
        UserDefaults.standard.removeObject(forKey: lastTitleDefaultsKey)
        UserDefaults.standard.removeObject(forKey: lastSnapshotDefaultsKey)
        publishLock.lock()
        lastReloadDate = .distantPast
        publishLock.unlock()
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

    /// Audio / session-end mirror used by ContinueWidgetPublisher and live-session
    /// republish. Pass streak only when this call carries Home-authoritative values;
    /// nil lets the locked publish preserve whatever is currently stored.
    public static func publishLiveMirror(
        title: String?,
        subtitle: String?,
        isPlaying: Bool,
        kind: ContinueWidgetKindTag?,
        coverData: Data?,
        deepLink: String = InkAmpContinueLink.continueURL.absoluteString,
        progress: Double? = nil,
        elapsedSeconds: Double? = nil,
        durationSeconds: Double? = nil,
        hasLiveSession: Bool,
        rate: Double? = nil,
        upNext: [ContinueWidgetUpNextDraft]? = nil,
        itemID: String? = nil,
        authoritativeStreakDays: Int? = nil,
        authoritativeStreakActivityDayKey: String? = nil,
        authoritativeTodayActiveSeconds: Double? = nil,
        authoritativeDailyGoalMinutes: Int? = nil,
        authoritativeTodayGoalDayKey: String? = nil,
        authoritativeLongestStreakDays: Int? = nil,
        fileStore: (any ContinueWidgetSnapshotFileStoring)? = nil,
    ) {
        publish(
            title: title,
            subtitle: subtitle,
            isPlaying: isPlaying,
            kind: kind,
            coverData: coverData,
            deepLink: deepLink,
            progress: progress,
            elapsedSeconds: elapsedSeconds,
            durationSeconds: durationSeconds,
            hasLiveSession: hasLiveSession,
            rate: rate,
            upNext: upNext,
            itemID: itemID,
            streakDays: authoritativeStreakDays,
            streakActivityDayKey: authoritativeStreakActivityDayKey,
            todayActiveSeconds: authoritativeTodayActiveSeconds,
            dailyGoalMinutes: authoritativeDailyGoalMinutes,
            todayGoalDayKey: authoritativeTodayGoalDayKey,
            longestStreakDays: authoritativeLongestStreakDays,
            fileStore: fileStore
        )
    }

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
        upNext: [ContinueWidgetUpNextDraft]? = nil,
        itemID: String? = nil,
        streakDays: Int? = nil,
        streakActivityDayKey: String? = nil,
        todayActiveSeconds: Double? = nil,
        dailyGoalMinutes: Int? = nil,
        todayGoalDayKey: String? = nil,
        longestStreakDays: Int? = nil,
        fileStore: (any ContinueWidgetSnapshotFileStoring)? = nil,
    ) {
        SilveranWidgetSnapshotStore.logAppGroupAvailability(source: "publish")
        let store = fileStore ?? AppGroupContinueWidgetSnapshotFileStore()
        guard let container = store.resolveContainer() else {
            logger.notice("publish outcome=skipped reason=containerUnavailable")
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
            let covers = coversDirectory(in: container)

            // Read once under the lock so injectable race hooks see the same path.
            let previousSnapshot = store.readSnapshot(in: container)
            var coverFilename: String?
            if let coverData, !coverData.isEmpty {
                coverFilename = try store.writeCoverData(coverData, to: container)
            } else if let previousSnapshot,
                ContinueWidgetSnapshot.shouldKeepPreviousCover(
                    previous: previousSnapshot,
                    nextItemID: itemID,
                    nextTitle: title,
                    nextKind: kind,
                    nextDeepLink: title == nil ? nil : deepLink,
                ),
                let existing = previousSnapshot.coverFilename
            {
                coverFilename = existing
            }
            let resolvedUpNext = try resolveUpNext(
                drafts: upNext,
                previous: previousSnapshot?.upNext,
                coversDirectory: covers,
            )
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
                upNext: resolvedUpNext,
                itemID: itemID,
                streakDays: streakDays ?? previousSnapshot?.streakDays,
                // Preserve the activity anchor across audio-only publishes; never
                // re-date it from generatedAt or progress ticks.
                streakActivityDayKey: streakActivityDayKey ?? previousSnapshot?.streakActivityDayKey,
                todayActiveSeconds: todayActiveSeconds ?? previousSnapshot?.todayActiveSeconds,
                dailyGoalMinutes: dailyGoalMinutes ?? previousSnapshot?.dailyGoalMinutes,
                todayGoalDayKey: todayGoalDayKey ?? previousSnapshot?.todayGoalDayKey,
                longestStreakDays: longestStreakDays ?? previousSnapshot?.longestStreakDays,
            )

            let previousReload = lastReloadDate
            let now = Date()
            // Write whenever content differs ignoring generatedAt (streak anchor
            // can change without repainting today's streak text).
            let contentChanged = previousSnapshot.map { prior in
                var comparable = prior
                comparable.generatedAt = snapshot.generatedAt
                return comparable != snapshot
            } ?? true
            guard contentChanged else {
                publishLock.unlock()
                logger.notice("publish outcome=skipped reason=unchanged")
                return
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            try store.writeSnapshotData(data, to: container)
            // UserDefaults only — must not re-enter publishLock.
            rememberLastSnapshot(snapshot)
            debugLogPublish(snapshot)

            shouldReload = ContinueWidgetReloadPolicy.shouldReload(
                previous: previousSnapshot,
                next: snapshot,
                lastReload: previousReload,
                now: now,
            )
            if shouldReload { lastReloadDate = now }
            publishLock.unlock()
            logger.notice(
                "publish outcome=success hasItem=\(snapshot.hasItem, privacy: .public) reloaded=\(shouldReload, privacy: .public)"
            )
        } catch {
            publishLock.unlock()
            logger.error("publish outcome=failure errorType=\(String(describing: type(of: error)), privacy: .public)")
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
        publishLiveMirror(
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
            itemID: ContinueWidgetItemID.from(sessionKind: session.kind),
        )
    }

    /// Session ended (or the app relaunched cold with nothing playing): keep the
    /// last item for tap-to-continue, but stop claiming it is playing.
    public static func markSessionInactive() {
        let last = loadSnapshot()
        guard last.hasItem else { return }
        publishLiveMirror(
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
            itemID: last.itemID,
        )
    }

    public static func reloadTimelines() {
        #if canImport(WidgetKit) && (os(iOS) || os(macOS))
        for kind in timelineKindsToReload {
            debugLog("[ContinueWidget] reload kind=\(kind)")
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: SilveranWidgetConstants.streakWidgetKind)
        debugLog("[ContinueWidget] reload kind=\(SilveranWidgetConstants.streakWidgetKind)")
        // ofKind: bursts can be coalesced to a single kind, which left compact
        // tiles on an old timeline while the large kind refreshed. Follow with
        // reloadAll so every registered family reads the shared snapshot.
        WidgetCenter.shared.reloadAllTimelines()
        debugLog("[ContinueWidget] reload all timelines")
        #endif
    }

    /// Kind identifiers `reloadTimelines()` asks WidgetKit to refresh.
    /// Compact (medium) kinds are included — family must not skip a reload.
    public static var timelineKindsToReload: [String] {
        SilveranWidgetConstants.continueWidgetKinds
    }

    public static var compactTimelineKinds: [String] {
        SilveranWidgetConstants.continueWidgetKinds.filter { $0.contains(".medium.") }
    }

    private static func debugLogPublish(_ snapshot: ContinueWidgetSnapshot) {
        let title = snapshot.title ?? "nil"
            let progress = snapshot.clampedProgress.map { String(format: "%.2f", $0) } ?? "nil"
        debugLog(
            "[ContinueWidget] publish item=\(snapshot.mediaIdentity) title=\"\(title)\" progress=\(progress) source=\(ContinueWidgetCurrentSnapshot.storageKey)"
        )
    }

    private static func debugLog(_ line: String) {
        #if DEBUG
        print(line)
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
        SilveranWidgetSnapshotStore.transientStateDirectory(in: container)
            .appendingPathComponent(snapshotFilename, isDirectory: false)
    }

    static func coversDirectory(in container: URL) -> URL {
        SilveranWidgetSnapshotStore.transientStateDirectory(in: container)
            .appendingPathComponent(coversDirectoryName, isDirectory: true)
    }

    /// `nil` drafts keep the rows already on disk (live-session ticks). A non-nil
    /// array, including empty, replaces them — Home is the only writer of the queue.
    private static func resolveUpNext(
        drafts: [ContinueWidgetUpNextDraft]?,
        previous: [ContinueWidgetQueueItem]?,
        coversDirectory: URL,
    ) throws -> [ContinueWidgetQueueItem] {
        guard let drafts else {
            return Array((previous ?? []).prefix(ContinueWidgetSnapshot.upNextLimit))
        }

        var items: [ContinueWidgetQueueItem] = []
        for draft in drafts.prefix(ContinueWidgetSnapshot.upNextLimit) {
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !draft.id.isEmpty else { continue }
            var filename = previous?.first(where: { $0.id == draft.id })?.coverFilename
            if let coverData = draft.coverData, !coverData.isEmpty {
                let name = upNextCoverFilename(id: draft.id)
                let url = coversDirectory.appendingPathComponent(name, isDirectory: false)
                try coverData.write(to: url, options: [.atomic])
                filename = name
            }
            let link = draft.deepLink.trimmingCharacters(in: .whitespacesAndNewlines)
            items.append(
                ContinueWidgetQueueItem(
                    id: draft.id,
                    title: title,
                    subtitle: draft.subtitle,
                    coverFilename: filename,
                    kind: draft.kind,
                    deepLink: link.isEmpty
                        ? InkAmpContinueLink.queueItemURL(id: draft.id).absoluteString
                        : link,
                    progress: draft.progress,
                )
            )
        }
        pruneUpNextCovers(
            in: coversDirectory,
            keeping: Set(items.compactMap(\.coverFilename)),
        )
        return items
    }

    /// Stable across processes — `Hasher` is not. Covers for different rows must
    /// not overwrite each other when a later row still points at the old file.
    private static func upNextCoverFilename(id: String) -> String {
        var hash: UInt64 = 5381
        for byte in id.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return "upnext_\(String(hash, radix: 16)).dat"
    }

    private static func pruneUpNextCovers(in directory: URL, keeping names: Set<String>) {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
            )
        else { return }
        for url in files {
            let name = url.lastPathComponent
            guard name.hasPrefix("upnext_"), !names.contains(name) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Atomic streak-only update under the existing publish lock. Reads the
    /// current snapshot, updates only streak/anchor/`generatedAt`, and never
    /// overwrites title/progress/transport from pre-lock values. No-ops (no
    /// write/reload) when streak data is unchanged. Must not call `publish`.
    @discardableResult
    public static func updateAuthoritativeStreak(
        streakDays: Int,
        streakActivityDayKey: String,
        todayActiveSeconds: Double? = nil,
        dailyGoalMinutes: Int? = nil,
        todayGoalDayKey: String? = nil,
        longestStreakDays: Int? = nil,
        fileStore: (any ContinueWidgetSnapshotFileStoring)? = nil,
    ) -> Bool {
        let normalizedDays = max(0, streakDays)
        let normalizedKey = streakActivityDayKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { return false }
        let normalizedTodaySeconds = todayActiveSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let normalizedGoalMinutes = dailyGoalMinutes.map { max(1, $0) }
        let normalizedGoalDayKey = todayGoalDayKey.flatMap { key in
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let normalizedLongest = longestStreakDays.map { max(0, $0) }

        SilveranWidgetSnapshotStore.logAppGroupAvailability(source: "streak")
        let store = fileStore ?? AppGroupContinueWidgetSnapshotFileStore()
        guard let container = store.resolveContainer() else { return false }

        var shouldReload = false
        publishLock.lock()
        do {
            try store.ensureDirectories(in: container)
            guard var snapshot = store.readSnapshot(in: container), snapshot.hasItem else {
                publishLock.unlock()
                return false
            }
            let nextTodaySeconds = normalizedTodaySeconds ?? snapshot.todayActiveSeconds
            let nextGoalMinutes = normalizedGoalMinutes ?? snapshot.dailyGoalMinutes
            let nextGoalDayKey = normalizedGoalDayKey ?? snapshot.todayGoalDayKey
            let nextLongest = normalizedLongest ?? snapshot.longestStreakDays
            if snapshot.streakDays == normalizedDays,
                snapshot.streakActivityDayKey == normalizedKey,
                snapshot.todayActiveSeconds == nextTodaySeconds,
                snapshot.dailyGoalMinutes == nextGoalMinutes,
                snapshot.todayGoalDayKey == nextGoalDayKey,
                snapshot.longestStreakDays == nextLongest
            {
                publishLock.unlock()
                return true
            }

            let previous = snapshot
            snapshot.streakDays = normalizedDays
            snapshot.streakActivityDayKey = normalizedKey
            snapshot.todayActiveSeconds = nextTodaySeconds
            snapshot.dailyGoalMinutes = nextGoalMinutes
            snapshot.todayGoalDayKey = nextGoalDayKey
            snapshot.longestStreakDays = nextLongest
            snapshot.generatedAt = Date()

            let previousReload = lastReloadDate
            let now = Date()

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            try store.writeSnapshotData(data, to: container)
            rememberLastSnapshot(snapshot)

            shouldReload = ContinueWidgetReloadPolicy.shouldReload(
                previous: previous,
                next: snapshot,
                lastReload: previousReload,
                now: now,
            )
            if shouldReload { lastReloadDate = now }
            publishLock.unlock()
        } catch {
            publishLock.unlock()
            print("[ContinueWidget] streak update failed: \(error)")
            return false
        }

        if shouldReload {
            reloadTimelines()
        }
        return true
    }

    /// Test hook: reset in-process publish signatures between injectable-store runs.
    public static func resetPublishSignaturesForTesting() {
        publishLock.lock()
        lastReloadDate = .distantPast
        publishLock.unlock()
    }
}

/// Home-queue / session identity written onto Continue snapshots.
public enum ContinueWidgetItemID {
    public static func from(sessionKind: AudioSessionKind) -> String {
        switch sessionKind {
            case .audiobook(let id), .readaloud(let id):
                return "book:\(id.sourceID)/\(id.uuid)"
            case .podcast(let episodeID):
                return "pod:\(episodeID)"
        }
    }
}

/// Deep links for the Continue widget (`punkrally` scheme — already registered).
public enum InkAmpContinueLink {
    public static let continueURL = URL(string: "punkrally://continue")!
    public static let toggleURL = URL(string: "punkrally://continue?action=toggle")!
    /// Opens Home / the queue view (Browse Queue).
    public static let homeURL = URL(string: "punkrally://home")!
    /// Query on `punkrally://continue` that opens one Home queue row (Up next).
    public static let queueItemQueryName = "item"
    /// Notification userInfo key carrying `HomeMixedItem.id` from a widget tap.
    public static let queueItemUserInfoKey = "continueQueueItemID"

    public static func isContinueURL(_ url: URL) -> Bool {
        guard url.scheme == "punkrally" else { return false }
        let host = url.host() ?? url.host
        return host == "continue"
    }

    public static func isHomeURL(_ url: URL) -> Bool {
        guard url.scheme == "punkrally" else { return false }
        let host = url.host() ?? url.host
        return host == "home"
    }

    public static func wantsToggle(_ url: URL) -> Bool {
        guard isContinueURL(url) else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        return items?.contains(where: { $0.name == "action" && $0.value == "toggle" }) == true
    }

    /// `punkrally://continue?item=<HomeMixedItem.id>` — same host as Continue, not a new player.
    public static func queueItemURL(id: String) -> URL {
        var components = URLComponents(url: continueURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: queueItemQueryName, value: id)]
        return components?.url ?? continueURL
    }

    public static func queueItemID(from url: URL) -> String? {
        guard isContinueURL(url), !wantsToggle(url) else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        let value = items?.first(where: { $0.name == queueItemQueryName })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// `book:<sourceID>/<uuid>`. Source ids may contain `/`; the uuid is the last segment.
    public static func bookID(fromQueueItemID id: String) -> BookID? {
        let prefix = "book:"
        guard id.hasPrefix(prefix) else { return nil }
        let rest = String(id.dropFirst(prefix.count))
        guard let slash = rest.lastIndex(of: "/") else { return nil }
        let source = String(rest[..<slash])
        let uuid = String(rest[rest.index(after: slash)...])
        guard !source.isEmpty, !uuid.isEmpty else { return nil }
        return BookID(sourceID: source, uuid: uuid)
    }

    public static func podcastEpisodeID(fromQueueItemID id: String) -> String? {
        let prefix = "pod:"
        guard id.hasPrefix(prefix) else { return nil }
        let episodeID = String(id.dropFirst(prefix.count))
        guard !episodeID.isEmpty else { return nil }
        return episodeID
    }
}
