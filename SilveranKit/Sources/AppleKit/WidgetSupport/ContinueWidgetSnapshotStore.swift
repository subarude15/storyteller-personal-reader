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
    /// True while the app holds a live audio session, i.e. transport buttons can
    /// actually do something. False for the "Home Continue" fallback card.
    public var hasLiveSession: Bool?
    public var rate: Double?
    /// Following Home mixed-queue rows (not a second queue). Nil on snapshots
    /// written before Up next existed.
    public var upNext: [ContinueWidgetQueueItem]?

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
    ) {
        self.generatedAt = generatedAt
        self.title = title
        self.subtitle = subtitle
        self.coverFilename = coverFilename
        self.isPlaying = isPlaying
        self.kind = kind
        self.deepLink = deepLink
        self.progress = progress
        self.elapsedSeconds = elapsedSeconds
        self.durationSeconds = durationSeconds
        self.hasLiveSession = hasLiveSession
        self.rate = rate
        self.upNext = upNext
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
        progress.map { min(max($0, 0), 1) }
    }

    public var percentComplete: Int? {
        clampedProgress.map { Int(($0 * 100).rounded()) }
    }

    /// "12m left" / "1h 5m left" when a duration is known.
    public var remainingText: String? {
        guard let durationSeconds, durationSeconds > 0 else { return nil }
        let elapsed = elapsedSeconds ?? ((clampedProgress ?? 0) * durationSeconds)
        let remaining = max(0, durationSeconds - elapsed)
        guard remaining > 0 else { return nil }
        return Self.durationText(remaining) + " left"
    }

    public var elapsedText: String? {
        guard let durationSeconds, durationSeconds > 0 else { return nil }
        let elapsed = max(0, elapsedSeconds ?? ((clampedProgress ?? 0) * durationSeconds))
        return Self.durationText(elapsed)
    }

    /// Compact "31% · 12m left" style caption for the tile.
    public var progressCaption: String? {
        var parts: [String] = []
        if let percentComplete { parts.append("\(percentComplete)%") }
        if let remainingText { parts.append(remainingText) }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    public static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
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

    /// Which item is Now Listening. Progress ticks must not change this.
    public var mediaIdentity: String {
        [
            kind?.rawValue ?? "",
            title ?? "",
            deepLink ?? "",
        ].joined(separator: "|")
    }

    /// Identity for "did anything the widget paints change?" comparisons —
    /// deliberately excludes `generatedAt`.
    var paintSignature: String {
        [
            mediaIdentity,
            subtitle ?? "",
            coverFilename ?? "",
            isPlaying ? "1" : "0",
            (hasLiveSession ?? false) ? "1" : "0",
            percentComplete.map(String.init) ?? "",
            queueSignature,
        ].joined(separator: "|")
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
}

public enum ContinueWidgetSnapshotStore {
    private static let snapshotFilename = ContinueWidgetCurrentSnapshot.storageKey
    private static let coversDirectoryName = "ContinueCovers"
    private static let lastTitleDefaultsKey = "inkamp.continueWidget.lastTitle"
    private static let lastSnapshotDefaultsKey = "inkamp.continueWidget.lastSnapshot"

    private static let publishLock = NSLock()
    nonisolated(unsafe) private static var lastReloadDate: Date = .distantPast

    public static func loadSnapshot(bundle: Bundle = .main) -> ContinueWidgetSnapshot {
        let fallback = localFallbackSnapshot()
        guard let container = SilveranWidgetSnapshotStore.sharedContainerURL(bundle: bundle)
        else {
            return ContinueWidgetCurrentSnapshot.select(
                shared: nil,
                localFallback: fallback,
                sharedContainerReachable: false,
            )
        }
        let url = snapshotURL(in: container)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let shared: ContinueWidgetSnapshot?
        if let data = try? Data(contentsOf: url) {
            shared = try? decoder.decode(ContinueWidgetSnapshot.self, from: data)
        } else {
            shared = nil
        }
        // Reachable container is authoritative: compact tiles must not keep an
        // older process-local audiobook after the shared file has moved on.
        let snapshot = ContinueWidgetCurrentSnapshot.select(
            shared: shared,
            localFallback: fallback,
            sharedContainerReachable: true,
        )
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
    ) {
        SilveranWidgetSnapshotStore.logAppGroupAvailability(source: "publish")
        guard let container = SilveranWidgetSnapshotStore.sharedContainerURL() else {
            print("[ContinueWidget] publish skipped — App group container unavailable")
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: container,
                withIntermediateDirectories: true,
            )
            try SilveranWidgetSnapshotStore.prepareTransientState(in: container)
            let covers = coversDirectory(in: container)
            try FileManager.default.createDirectory(
                at: covers,
                withIntermediateDirectories: true,
            )

            let previousSnapshot = readSnapshotFile(in: container)
            var coverFilename: String?
            if let coverData, !coverData.isEmpty {
                let name = "continue_cover.dat"
                let url = covers.appendingPathComponent(name, isDirectory: false)
                try coverData.write(to: url, options: [.atomic])
                coverFilename = name
            } else if let previousSnapshot, let existing = previousSnapshot.coverFilename,
                title != nil
            {
                let nextIdentity = [
                    kind?.rawValue ?? "",
                    title ?? "",
                    deepLink,
                ].joined(separator: "|")
                // Same item, no new bytes: keep art. A new item must not inherit
                // the previous audiobook cover while the snapshot title has moved on.
                if previousSnapshot.mediaIdentity == nextIdentity {
                    coverFilename = existing
                }
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
            )

            publishLock.lock()
            let previousReload = lastReloadDate
            publishLock.unlock()

            let now = Date()
            guard ContinueWidgetReloadPolicy.shouldWrite(
                previous: previousSnapshot,
                next: snapshot,
            ) else { return }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: snapshotURL(in: container), options: [.atomic])
            rememberLastSnapshot(snapshot)
            debugLogPublish(snapshot)

            let reloadNow = ContinueWidgetReloadPolicy.shouldReload(
                previous: previousSnapshot,
                next: snapshot,
                lastReload: previousReload,
                now: now,
            )

            publishLock.lock()
            if reloadNow { lastReloadDate = now }
            publishLock.unlock()

            guard reloadNow else { return }
            reloadTimelines()
        } catch {
            print("[ContinueWidget] publish failed: \(error)")
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
        )
    }

    public static func reloadTimelines() {
        #if canImport(WidgetKit) && (os(iOS) || os(macOS))
        for kind in timelineKindsToReload {
            debugLog("[ContinueWidget] reload kind=\(kind)")
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
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

    private static func readSnapshotFile(in container: URL) -> ContinueWidgetSnapshot? {
        let url = snapshotURL(in: container)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ContinueWidgetSnapshot.self, from: data)
    }

    private static func snapshotURL(in container: URL) -> URL {
        SilveranWidgetSnapshotStore.transientStateDirectory(in: container)
            .appendingPathComponent(snapshotFilename, isDirectory: false)
    }

    private static func coversDirectory(in container: URL) -> URL {
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
