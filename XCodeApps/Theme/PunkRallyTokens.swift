import SwiftUI
import SilveranAppleKit

/// ink+amp Design System Tokens.
///
/// Phase 1 chrome colors come from `InkAmpAppTheme` (Blanc/Carmin/Aqua light,
/// Sea Grey/Tangerine/Leaf Green dark). Reader page themes remain separate
/// (`ReaderTheme` in SilveranKit) and must not be overloaded for app chrome.
public enum PunkRallyTheme {
    /// App brand display name
    public static let appName = "ink+amp"
    public static let libraryOpdsTitle = "ink+amp books"
    /// Default Storyteller server — this is the private cellar server
    /// (storyteller.banditoburrito.xyz), pre-filled into the connect/auth flow
    /// from a fresh book source via SilveranKit's kDefaultStorytellerServerURL.
    public static let defaultStorytellerURL = "https://storyteller.banditoburrito.xyz"

    /// Shared brand accents for chips / status.
    public enum Accent {
        /// Default light-scheme primary (Carmin). Prefer `primary(for:)` when
        /// the active color scheme is known.
        public static let primary = InkAmpAppTheme.resolve(for: .light).accent

        public static func primary(for scheme: ColorScheme) -> Color {
            InkAmpAppTheme.resolve(for: scheme).accent
        }

        /// Success / synced
        public static let success = Color(red: 0.239, green: 0.863, blue: 0.592)
        /// Gold — badges, sync indicators (kept subtle; not a brand primary)
        public static let gold = Color(red: 0.882, green: 0.706, blue: 0.431)
        /// Danger / error — Carmin family
        public static let danger = InkAmpAppTheme.resolve(for: .light).destructive
    }

    /// Chrome palette adaptors for system light and dark modes (InkAmpAppTheme).
    public struct Chrome {
        public let scheme: ColorScheme
        private let theme: InkAmpAppTheme

        public init(scheme: ColorScheme) {
            self.scheme = scheme
            self.theme = InkAmpAppTheme.resolve(for: scheme)
        }

        public var bg: Color { theme.background }
        public var surface: Color { theme.surface }
        public var surface2: Color { theme.surfaceElevated }
        public var border: Color { theme.border }
        public var text: Color { theme.primaryText }
        public var textMuted: Color { theme.secondaryText }
        public var textFaint: Color { theme.tertiaryText }
        public var tabActive: Color { theme.accent }
        public var miniBarBg: Color { theme.surfaceElevated }
        public var accent: Color { theme.accent }
        public var secondaryAccent: Color { theme.secondaryAccent }
        public var progress: Color { theme.progress }
    }

    /// Kind badge styling definitions
    public enum KindBadgeType: String, CaseIterable {
        case ebook = "READ"
        case audiobook = "LISTEN"
        case readaloud = "SYNC"
        case podcast = "POD"

        public func backgroundColor(scheme: ColorScheme) -> Color {
            let theme = InkAmpAppTheme.resolve(for: scheme)
            switch self {
            case .ebook:
                return theme.surface
            case .audiobook:
                return scheme == .dark
                    ? theme.accent.opacity(0.18)
                    : theme.accent.opacity(0.10)
            case .readaloud:
                return scheme == .dark
                    ? theme.secondaryAccent.opacity(0.28)
                    : theme.secondaryAccent.opacity(0.22)
            case .podcast:
                return scheme == .dark
                    ? Color.white.opacity(0.08)
                    : theme.secondaryAccent.opacity(0.16)
            }
        }

        public func foregroundColor(scheme: ColorScheme) -> Color {
            let theme = InkAmpAppTheme.resolve(for: scheme)
            switch self {
            case .ebook:
                return theme.primaryText
            case .audiobook:
                return theme.accent
            case .readaloud:
                return scheme == .dark ? theme.secondaryAccent : theme.accent
            case .podcast:
                return theme.secondaryText
            }
        }
    }

    /// Spacing metrics — aligned with InkAmpMetrics for Phase 1.
    public enum Metric {
        public static let gridBase: CGFloat = 8
        public static let screenInset: CGFloat = InkAmpMetrics.screenInset
        public static let cardPadding: CGFloat = InkAmpMetrics.cardPadding
        public static let gridGutter: CGFloat = 12
        public static let miniBarHeight: CGFloat = 56
        public static let coverCornerRadius: CGFloat = 10
        public static let buttonCornerRadius: CGFloat = InkAmpMetrics.cardRadius
        public static let featureCornerRadius: CGFloat = InkAmpMetrics.featureCardRadius
        public static let minHitTarget: CGFloat = InkAmpMetrics.minHitTarget
    }
}

/// SwiftUI View extension to quickly access ink+amp tokens
extension View {
    public func punkRallyTheme(_ scheme: ColorScheme) -> PunkRallyTheme.Chrome {
        PunkRallyTheme.Chrome(scheme: scheme)
    }
}
