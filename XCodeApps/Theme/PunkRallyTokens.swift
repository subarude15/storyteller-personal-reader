import SwiftUI

/// punk+rally Design System Tokens (per UX-SHELL.md and DESIGN.md)
public enum PunkRallyTheme {
    /// App brand display name
    public static let appName = "punk+rally"
    public static let libraryOpdsTitle = "punk+rally books"
    public static let defaultStorytellerURL = "https://storyteller.banditoburrito.xyz"

    /// Shared brand accent colors (identical across Light and Dark chrome)
    public enum Accent {
        /// Burnt orange (#E85D04) — primary CTA and active tab
        public static let primary = Color(red: 0.910, green: 0.365, blue: 0.016)
        /// Pressed CTA (#C44E03)
        public static let primaryPressed = Color(red: 0.769, green: 0.306, blue: 0.012)
        /// Gold (#E1B46E) — badges, sync indicators, kind chips
        public static let gold = Color(red: 0.882, green: 0.706, blue: 0.431)
        /// Danger / error (#FF4D6D)
        public static let danger = Color(red: 1.000, green: 0.302, blue: 0.427)
        /// Success / synced (#3DDC97)
        public static let success = Color(red: 0.239, green: 0.863, blue: 0.592)
    }

    /// Chrome palette adaptors for system light and dark modes
    public struct Chrome {
        public let scheme: ColorScheme

        public init(scheme: ColorScheme) {
            self.scheme = scheme
        }

        /// App background
        public var bg: Color {
            scheme == .dark
                ? Color(red: 0.043, green: 0.043, blue: 0.047) // #0B0B0C
                : Color(red: 0.969, green: 0.961, blue: 0.949) // #F7F5F2 (warm paper)
        }

        /// Surface (cards, sheets)
        public var surface: Color {
            scheme == .dark
                ? Color(red: 0.086, green: 0.086, blue: 0.094) // #161618
                : Color.white
        }

        /// Surface 2 (elevated / pressed / chip wells)
        public var surface2: Color {
            scheme == .dark
                ? Color(red: 0.118, green: 0.118, blue: 0.133) // #1E1E22
                : Color(red: 0.937, green: 0.918, blue: 0.894) // #EFEAE4
        }

        /// Borders and hairlines
        public var border: Color {
            scheme == .dark
                ? Color(red: 0.165, green: 0.165, blue: 0.180) // #2A2A2E
                : Color(red: 0.878, green: 0.855, blue: 0.824) // #E0DAD2
        }

        /// Primary text
        public var text: Color {
            scheme == .dark
                ? Color(red: 0.957, green: 0.945, blue: 0.918) // #F4F1EA
                : Color(red: 0.102, green: 0.094, blue: 0.078) // #1A1814
        }

        /// Secondary muted text
        public var textMuted: Color {
            scheme == .dark
                ? Color(red: 0.604, green: 0.584, blue: 0.549) // #9A958C
                : Color(red: 0.420, green: 0.396, blue: 0.376) // #6B6560
        }

        /// Faint / tertiary text
        public var textFaint: Color {
            scheme == .dark
                ? Color(red: 0.420, green: 0.404, blue: 0.376) // #6B6760
                : Color(red: 0.604, green: 0.580, blue: 0.549) // #9A948C
        }

        /// Tab bar selection tint
        public var tabActive: Color {
            Accent.primary
        }

        /// Mini-player bar background
        public var miniBarBg: Color {
            surface
        }
    }

    /// Kind badge styling definitions
    public enum KindBadgeType: String, CaseIterable {
        case ebook = "READ"
        case audiobook = "LISTEN"
        case readaloud = "SYNC"
        case podcast = "POD"

        public func backgroundColor(scheme: ColorScheme) -> Color {
            switch self {
            case .ebook:
                return scheme == .dark
                    ? Color(red: 0.165, green: 0.165, blue: 0.180)
                    : Color(red: 0.937, green: 0.918, blue: 0.894)
            case .audiobook:
                return scheme == .dark
                    ? Color(red: 0.165, green: 0.141, blue: 0.094)
                    : Color(red: 0.961, green: 0.929, blue: 0.847)
            case .readaloud:
                return scheme == .dark
                    ? Color(red: 0.165, green: 0.094, blue: 0.063)
                    : Color(red: 0.988, green: 0.910, blue: 0.847)
            case .podcast:
                return scheme == .dark
                    ? Color(red: 0.094, green: 0.125, blue: 0.165)
                    : Color(red: 0.894, green: 0.933, blue: 0.973)
            }
        }

        public func foregroundColor(scheme: ColorScheme) -> Color {
            switch self {
            case .ebook:
                return scheme == .dark
                    ? Color(red: 0.957, green: 0.945, blue: 0.918)
                    : Color(red: 0.102, green: 0.094, blue: 0.078)
            case .audiobook:
                return scheme == .dark
                    ? Accent.gold
                    : Color(red: 0.541, green: 0.416, blue: 0.165)
            case .readaloud:
                return scheme == .dark
                    ? Accent.primary
                    : Accent.primaryPressed
            case .podcast:
                return scheme == .dark
                    ? Color(red: 0.541, green: 0.706, blue: 1.000)
                    : Color(red: 0.184, green: 0.373, blue: 0.604)
            }
        }
    }

    /// Spacing metrics per DESIGN.md
    public enum Metric {
        public static let gridBase: CGFloat = 8
        public static let screenInset: CGFloat = 16
        public static let cardPadding: CGFloat = 12
        public static let gridGutter: CGFloat = 12
        public static let miniBarHeight: CGFloat = 56
        public static let coverCornerRadius: CGFloat = 8
        public static let buttonCornerRadius: CGFloat = 12
        public static let minHitTarget: CGFloat = 44
    }
}

/// SwiftUI View extension to quickly access punk+rally tokens
extension View {
    public func punkRallyTheme(_ scheme: ColorScheme) -> PunkRallyTheme.Chrome {
        PunkRallyTheme.Chrome(scheme: scheme)
    }
}
