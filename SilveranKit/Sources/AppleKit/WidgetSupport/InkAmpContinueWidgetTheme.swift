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
    /// Outer padding for the Medium tile.
    public static let mediumOuterPadding: CGFloat = 12
    /// Current cover on Medium (compact; must stay well below Large).
    public static let mediumCoverSize: CGFloat = 54
    /// Up Next thumbnail on Medium.
    public static let mediumQueueCoverSize: CGFloat = 23
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
