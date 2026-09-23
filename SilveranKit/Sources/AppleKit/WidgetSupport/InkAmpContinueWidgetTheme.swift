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

/// Approved hex palette for the four Continue + Next Up widgets.
///
/// Light: Aqua / Blanc / Carmin. Dark: Tangerine / Leaf Green / Sea Grey.
public enum InkAmpContinueWidgetPalette {
    public enum Light {
        public static let aqua = "#95D9C0"
        public static let blanc = "#FFFFFF"
        public static let carmin = "#D41F26"
        /// Very dark neutral for primary copy on Blanc.
        public static let primaryText = "#1A1A1A"
        /// Muted dark gray for secondary copy.
        public static let secondaryText = "#5C5C5C"
    }

    public enum Dark {
        public static let tangerine = "#F58F20"
        public static let leafGreen = "#467434"
        public static let seaGrey = "#363636"
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
