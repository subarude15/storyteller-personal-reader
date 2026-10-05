import CoreGraphics
import Foundation

/// Light / dark Continue + Next Up Home Screen tiles.
public enum InkAmpWidgetTheme: String, Sendable, CaseIterable {
    case light
    case dark
}

/// Medium vs large layout for the Continue + Next Up tile.
public enum InkAmpContinueWidgetLayout: String, Sendable, CaseIterable {
    case medium
    case large

    /// Medium paints at most 2 Up Next rows; large at most 3.
    public var upNextLimit: Int {
        switch self {
            case .medium: return 2
            case .large: return 3
        }
    }
}

/// Deterministic geometry for Continue + Next Up Home Screen tiles.
///
/// Medium is a compact two-column layout sized from the live widget width.
/// Large keeps its validated fractions / cover size — do not retune Medium by
/// changing Large constants.
public enum InkAmpContinueWidgetMetrics: Sendable {
    /// Share of usable Medium width for the current / Now Listening column.
    public static let mediumCurrentFraction: CGFloat = 0.58
    /// Share of usable Medium width for the Up Next column.
    public static let mediumQueueFraction: CGFloat = 0.42
    /// Gap between Medium current and Up Next columns.
    public static let mediumColumnGap: CGFloat = 11
    /// Horizontal outer padding for the Medium tile.
    public static let mediumOuterPadding: CGFloat = 12
    /// Vertical padding is tighter so systemMedium fits the 148 pt canvas on compact iPhones.
    public static let mediumOuterVerticalPadding: CGFloat = 7
    /// Current cover on Medium (compact; must stay well below Large).
    public static let mediumCoverSize: CGFloat = 54
    /// Up Next thumbnail on Medium.
    public static let mediumQueueCoverSize: CGFloat = 23
    /// Spacing between Medium current-column blocks (chip / cover row / progress / caption).
    public static let mediumNowColumnSpacing: CGFloat = 4
    /// Gap between Medium cover and title/subtitle in the cover row.
    public static let mediumCoverMetadataGap: CGFloat = 8
    /// Compact progress bar height on Medium.
    public static let mediumProgressHeight: CGFloat = 3.5
    /// Progress caption point size on Medium (kept small for height budget).
    public static let mediumCaptionFontSize: CGFloat = 8.5
    /// Representative systemMedium canvas used by constrained previews / budget checks.
    public static let mediumPreviewWidth: CGFloat = 360
    public static let mediumPreviewHeight: CGFloat = 148
    /// Compact Medium action-row vertical padding.
    public static let mediumActionVerticalPadding: CGFloat = 6.5
    /// Approximate Medium action-row height (font + vertical padding).
    public static let mediumActionRowHeight: CGFloat = 24
    /// Validated Large current cover — frozen; Medium must stay materially smaller.
    public static let largeCoverSize: CGFloat = 92
    /// Historical Medium Up Next fixed width that over-constrained systemMedium.
    /// Kept only so tests can assert the layout no longer hardcodes it.
    public static let deprecatedMediumFixedQueueWidth: CGFloat = 148

    public static func mediumCurrentWidth(usableWidth: CGFloat) -> CGFloat {
        max(0, usableWidth) * mediumCurrentFraction
    }

    public static func mediumQueueWidth(usableWidth: CGFloat) -> CGFloat {
        max(0, usableWidth) * mediumQueueFraction
    }

    /// Lower-bound height for Medium current-column content after the compact HStack redesign.
    /// Chip + cover row + progress (+ optional caption) with fixed spacing — no title-under-cover stack.
    public static func mediumNowColumnMinimumHeight(includeCaption: Bool) -> CGFloat {
        let chipHeight: CGFloat = 18
        let coverRowHeight = mediumCoverSize
        let progressBlock = mediumProgressHeight
        let captionBlock: CGFloat = includeCaption ? (mediumCaptionFontSize + 2) : 0
        let gaps = mediumNowColumnSpacing * (includeCaption ? 3 : 2)
        return chipHeight + coverRowHeight + progressBlock + captionBlock + gaps
    }

    /// Outer padding + column stack spacing + action row + current-column minimum.
    public static func mediumContentMinimumHeight(includeCaption: Bool) -> CGFloat {
        let verticalPadding = mediumOuterVerticalPadding * 2
        let bodySpacing: CGFloat = 8
        return verticalPadding
            + bodySpacing
            + mediumNowColumnMinimumHeight(includeCaption: includeCaption)
            + mediumActionRowHeight
    }
}

/// Approved hex palette for the four Continue + Next Up widgets.
///
/// Light: Aqua / Blanc / Carmin. Dark: Tangerine / Leaf Green / Sea Grey.
/// Brand primaries come from `InkAmpBrandPalette` so app chrome stays aligned.
public enum InkAmpContinueWidgetPalette {
    public enum Light {
        public static let aqua = InkAmpBrandPalette.aqua
        public static let blanc = InkAmpBrandPalette.blanc
        public static let carmin = InkAmpBrandPalette.carmin
        /// Very dark neutral for primary copy on Blanc.
        public static let primaryText = "#1A1A1A"
        /// Muted dark gray for secondary copy.
        public static let secondaryText = "#5C5C5C"
    }

    public enum Dark {
        public static let tangerine = InkAmpBrandPalette.tangerine
        public static let leafGreen = InkAmpBrandPalette.leafGreen
        public static let seaGrey = InkAmpBrandPalette.seaGrey
        /// Off-white primary on Sea Grey.
        public static let primaryText = "#F5F5F5"
        /// Muted light gray secondary.
        public static let secondaryText = "#B0B0B0"
    }
}

/// Deep-link actions for the Home Screen Continue + Next Up tiles.
///
/// These widgets intentionally do **not** surface playback transport
/// (`ContinuePlayPauseIntent` / skip intents). Transport intents may still live
/// in shared code for other surfaces.
public enum InkAmpContinueWidgetActions {
    public static let usesPlaybackTransportIntents = false

    public static func continueURL(for snapshot: ContinueWidgetSnapshot) -> URL {
        if let deepLink = snapshot.deepLink?.trimmingCharacters(in: .whitespacesAndNewlines),
            !deepLink.isEmpty,
            let url = URL(string: deepLink)
        {
            return url
        }
        return InkAmpContinueLink.continueURL
    }

    public static func upNextURL(for item: ContinueWidgetQueueItem) -> URL {
        let trimmed = item.deepLink.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let url = URL(string: trimmed) {
            return url
        }
        return InkAmpContinueLink.queueItemURL(id: item.id)
    }

    public static func browseQueueURL() -> URL {
        InkAmpContinueLink.homeURL
    }

    public static func openAppURL() -> URL {
        InkAmpContinueLink.homeURL
    }

    public static func showsEmptyState(_ snapshot: ContinueWidgetSnapshot) -> Bool {
        !snapshot.hasItem
    }

    public static func upNextItems(
        for snapshot: ContinueWidgetSnapshot,
        layout: InkAmpContinueWidgetLayout,
    ) -> [ContinueWidgetQueueItem] {
        Array(snapshot.upNextItems.prefix(layout.upNextLimit))
    }
}

/// How a Continue tile timeline was produced.
///
/// `.placeholder` is the redacted Widget Gallery sample only. Snapshot and
/// timeline phases are live reads of the shared playback snapshot.
public enum InkAmpContinueTimelinePhase: String, Sendable, Equatable {
    case placeholder
    case snapshot
    case timeline
}

/// Live snapshot/timeline phases. Placeholder is not a member, so a real
/// entry cannot be constructed as the gallery sample.
public enum InkAmpContinueLivePhase: String, Sendable, Equatable {
    case snapshot
    case timeline

    public var timelinePhase: InkAmpContinueTimelinePhase {
        switch self {
            case .snapshot: return .snapshot
            case .timeline: return .timeline
        }
    }
}

/// Playback model for one Continue tile update.
///
/// Theme is not stored. Light and dark compact tiles must carry the same
/// snapshot; appearance is applied later by the view.
public struct InkAmpContinueResolvedTimeline: Sendable, Equatable {
    public var phase: InkAmpContinueTimelinePhase
    public var snapshot: ContinueWidgetSnapshot
    public var isPlaceholder: Bool
    public var showsEmptyState: Bool

    public init(
        phase: InkAmpContinueTimelinePhase,
        snapshot: ContinueWidgetSnapshot,
        isPlaceholder: Bool,
        showsEmptyState: Bool,
    ) {
        self.phase = phase
        self.snapshot = snapshot
        self.isPlaceholder = isPlaceholder
        self.showsEmptyState = showsEmptyState
    }
}

/// Builds Continue tile timelines from the shared playback snapshot.
///
/// `theme` is accepted on the live path so every call site has to name the
/// appearance it will paint, then ignored. Adding a theme case fails the
/// exhaustive switch until it is explicitly mapped onto the same snapshot.
public enum InkAmpContinueTimelineResolver {
    public static func resolve(
        loaded: ContinueWidgetSnapshot,
        phase: InkAmpContinueLivePhase,
        theme: InkAmpWidgetTheme,
    ) -> InkAmpContinueResolvedTimeline {
        switch theme {
            case .light, .dark:
                return resolveLive(loaded: loaded, phase: phase)
        }
    }

    public static func resolveLive(
        loaded: ContinueWidgetSnapshot,
        phase: InkAmpContinueLivePhase,
    ) -> InkAmpContinueResolvedTimeline {
        InkAmpContinueResolvedTimeline(
            phase: phase.timelinePhase,
            snapshot: loaded,
            isPlaceholder: false,
            showsEmptyState: InkAmpContinueWidgetActions.showsEmptyState(loaded),
        )
    }

    /// Gallery sample. Never means "nothing in progress" — WidgetKit redacts it.
    public static func placeholder(
        sample: ContinueWidgetSnapshot,
    ) -> InkAmpContinueResolvedTimeline {
        InkAmpContinueResolvedTimeline(
            phase: .placeholder,
            snapshot: sample,
            isPlaceholder: true,
            showsEmptyState: false,
        )
    }

    /// Temporary diagnostic line. Same fields for compact and large tiles.
    public static func logLine(
        kind: String,
        family: String,
        theme: InkAmpWidgetTheme,
        phase: InkAmpContinueTimelinePhase,
        isPreview: Bool,
        snapshot: ContinueWidgetSnapshot,
        generatedAt: Date? = nil,
        storageKey: String = ContinueWidgetCurrentSnapshot.storageKey,
        entryDate: Date? = nil,
        refreshAfter: Date? = nil,
    ) -> String {
        let trimmed = snapshot.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = trimmed.isEmpty ? "nil" : trimmed
        let queue = snapshot.upNext?.count ?? 0
        let progress = snapshot.clampedProgress.map { String(format: "%.2f", $0) } ?? "nil"
        let item = snapshot.mediaIdentity.isEmpty ? "nil" : snapshot.mediaIdentity
        let generated = (generatedAt ?? snapshot.generatedAt).timeIntervalSince1970
        let call: String
        switch phase {
            case .placeholder: call = "placeholder"
            case .snapshot: call = "getSnapshot"
            case .timeline: call = "getTimeline"
        }
        var line =
            "[ContinueWidget] \(call) kind=\(kind) family=\(family) theme=\(theme.rawValue) phase=\(phase.rawValue) preview=\(isPreview) item=\(item) title=\"\(title)\" progress=\(progress) generated=\(generated) source=\(storageKey) queue=\(queue)"
        if let entryDate {
            line += " entry=\(entryDate.timeIntervalSince1970)"
        }
        if let refreshAfter {
            line += " refreshAfter=\(refreshAfter.timeIntervalSince1970)"
        } else if phase == .timeline {
            line += " refreshAfter=nil"
        }
        return line
    }
}

/// One live gallery snapshot or Home Screen timeline built from the shared file.
public struct ContinueWidgetLiveUpdate: Sendable, Equatable {
    public var resolved: InkAmpContinueResolvedTimeline
    public var entryDate: Date
    /// `getTimeline` only — next WidgetKit refresh. Nil for gallery snapshots.
    public var refreshAfter: Date?

    public var snapshot: ContinueWidgetSnapshot { resolved.snapshot }

    public init(
        resolved: InkAmpContinueResolvedTimeline,
        entryDate: Date,
        refreshAfter: Date?,
    ) {
        self.resolved = resolved
        self.entryDate = entryDate
        self.refreshAfter = refreshAfter
    }
}

/// Gallery `getSnapshot` and Home Screen `getTimeline` read the same snapshot.
public enum ContinueWidgetLiveUpdateBuilder {
    public static func refreshInterval(isPlaying: Bool) -> TimeInterval {
        isPlaying ? 5 * 60 : 15 * 60
    }

    public static func make(
        loaded: ContinueWidgetSnapshot,
        phase: InkAmpContinueLivePhase,
        theme: InkAmpWidgetTheme,
        now: Date = Date(),
    ) -> ContinueWidgetLiveUpdate {
        let resolved = InkAmpContinueTimelineResolver.resolve(
            loaded: loaded,
            phase: phase,
            theme: theme,
        )
        let refreshAfter: Date?
        switch phase {
            case .snapshot:
                refreshAfter = nil
            case .timeline:
                refreshAfter = now.addingTimeInterval(
                    refreshInterval(isPlaying: resolved.snapshot.isPlaying)
                )
        }
        return ContinueWidgetLiveUpdate(
            resolved: resolved,
            entryDate: now,
            refreshAfter: refreshAfter,
        )
    }
}

/// WidgetKit family names used when proving compact and large share one snapshot.
/// Presentation-only — never selects a different Now Listening item.
public enum ContinueWidgetTimelineFamily: String, Sendable, CaseIterable {
    case systemSmall
    case systemMedium
    case systemLarge
}

/// Authoritative Now Listening snapshot. Family is not an input to storage.
public enum ContinueWidgetCurrentSnapshot {
    public static let storageKey = "continue-now.json"

    public static func select(
        shared: ContinueWidgetSnapshot?,
        localFallback: ContinueWidgetSnapshot?,
        sharedContainerReachable: Bool,
    ) -> ContinueWidgetSnapshot {
        if sharedContainerReachable {
            // Reachable App Group is source of truth: do not resurrect an older
            // process-local audiobook when the shared file has moved on.
            guard let shared, shared.hasItem else { return .empty }
            return shared
        }
        guard let localFallback, localFallback.hasItem else { return .empty }
        return localFallback
    }

    /// Family affects layout only. Compact and large must resolve the same item.
    public static func snapshot(
        for family: ContinueWidgetTimelineFamily,
        shared: ContinueWidgetSnapshot?,
        localFallback: ContinueWidgetSnapshot?,
        sharedContainerReachable: Bool,
    ) -> ContinueWidgetSnapshot {
        switch family {
            case .systemSmall, .systemMedium, .systemLarge:
                return select(
                    shared: shared,
                    localFallback: localFallback,
                    sharedContainerReachable: sharedContainerReachable,
                )
        }
    }
}

/// When to write the shared snapshot and ask WidgetKit to reload every kind.
public enum ContinueWidgetReloadPolicy {
    public static let progressReloadInterval: TimeInterval = 20

    public static func shouldWrite(
        previous: ContinueWidgetSnapshot?,
        next: ContinueWidgetSnapshot,
    ) -> Bool {
        previous?.paintSignature != next.paintSignature
            || previous?.transportSignature != next.transportSignature
    }

    /// Identity changes reload immediately so compact tiles cannot keep The Troop
    /// after the shared file has already moved to a podcast.
    public static func shouldReload(
        previous: ContinueWidgetSnapshot?,
        next: ContinueWidgetSnapshot,
        lastReload: Date,
        now: Date,
    ) -> Bool {
        let identityChanged = previous?.mediaIdentity != next.mediaIdentity
        if identityChanged { return true }
        let transportChanged = previous?.transportSignature != next.transportSignature
        let queueChanged = previous?.queueSignature != next.queueSignature
        if transportChanged || queueChanged { return true }
        let paintChanged = previous?.paintSignature != next.paintSignature
        if paintChanged, now.timeIntervalSince(lastReload) >= progressReloadInterval {
            return true
        }
        return now.timeIntervalSince(lastReload) >= 300
    }
}
