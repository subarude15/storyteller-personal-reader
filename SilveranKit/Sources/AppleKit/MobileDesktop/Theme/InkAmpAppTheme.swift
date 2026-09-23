#if os(iOS) || os(macOS)
import SilveranAppleWidgets
import SwiftUI

/// App-shell visual theme for ink+amp (tabs, Home, Library chrome, mini-player).
///
/// Intentionally separate from `ReaderTheme`, which only styles ebook pages and
/// readaloud highlights. Do not overload ReaderTheme for application chrome.
public struct InkAmpAppTheme: Equatable {
    public let colorScheme: ColorScheme
    public let palette: InkAmpAppPalette

    public init(colorScheme: ColorScheme) {
        self.colorScheme = colorScheme
        self.palette = InkAmpAppPalette(colorScheme: colorScheme)
    }

    public static func resolve(for colorScheme: ColorScheme) -> InkAmpAppTheme {
        InkAmpAppTheme(colorScheme: colorScheme)
    }

    public var isDark: Bool { colorScheme == .dark }

    public var background: Color { palette.background }
    public var surface: Color { palette.surface }
    public var surfaceElevated: Color { palette.surfaceElevated }
    public var primaryText: Color { palette.primaryText }
    public var secondaryText: Color { palette.secondaryText }
    public var tertiaryText: Color { palette.tertiaryText }
    public var accent: Color { palette.accent }
    public var secondaryAccent: Color { palette.secondaryAccent }
    public var progress: Color { palette.progress }
    public var divider: Color { palette.divider }
    public var border: Color { palette.border }
    public var destructive: Color { palette.destructive }
}

/// Semantic color roles for app chrome. Hex brand values come from
/// `InkAmpBrandPalette` / `InkAmpContinueWidgetPalette`.
public struct InkAmpAppPalette: Equatable {
    public let background: Color
    public let surface: Color
    public let surfaceElevated: Color
    public let primaryText: Color
    public let secondaryText: Color
    public let tertiaryText: Color
    public let accent: Color
    public let secondaryAccent: Color
    public let progress: Color
    public let divider: Color
    public let border: Color
    public let destructive: Color

    public init(colorScheme: ColorScheme) {
        switch colorScheme {
            case .dark:
                // Slightly deeper than Sea Grey for the page behind cards.
                background = Self.color("#2E2E2E")
                surface = Self.color(InkAmpBrandPalette.seaGrey)
                surfaceElevated = Self.color("#454545")
                primaryText = Self.color(InkAmpContinueWidgetPalette.Dark.primaryText)
                secondaryText = Self.color(InkAmpContinueWidgetPalette.Dark.secondaryText)
                tertiaryText = Self.color("#8A8A8A")
                accent = Self.color(InkAmpBrandPalette.tangerine)
                secondaryAccent = Self.color(InkAmpBrandPalette.leafGreen)
                progress = Self.color(InkAmpBrandPalette.tangerine)
                divider = Self.color("#4A4A4A")
                border = Self.color("#525252")
                destructive = Self.color("#E85A5A")
            case .light:
                background = Self.color(InkAmpBrandPalette.blanc)
                // Blanc-family off-white — related to Blanc, not a warm paper cream.
                surface = Self.color("#F5F7F6")
                surfaceElevated = Self.color(InkAmpBrandPalette.blanc)
                primaryText = Self.color(InkAmpContinueWidgetPalette.Light.primaryText)
                secondaryText = Self.color(InkAmpContinueWidgetPalette.Light.secondaryText)
                tertiaryText = Self.color("#8A8A8A")
                accent = Self.color(InkAmpBrandPalette.carmin)
                secondaryAccent = Self.color(InkAmpBrandPalette.aqua)
                progress = Self.color(InkAmpBrandPalette.carmin)
                divider = Self.color("#E6E8E7")
                border = Self.color("#D8DCDA")
                destructive = Self.color(InkAmpBrandPalette.carmin)
            @unknown default:
                background = Self.color(InkAmpBrandPalette.blanc)
                surface = Self.color("#F5F7F6")
                surfaceElevated = Self.color(InkAmpBrandPalette.blanc)
                primaryText = Self.color(InkAmpContinueWidgetPalette.Light.primaryText)
                secondaryText = Self.color(InkAmpContinueWidgetPalette.Light.secondaryText)
                tertiaryText = Self.color("#8A8A8A")
                accent = Self.color(InkAmpBrandPalette.carmin)
                secondaryAccent = Self.color(InkAmpBrandPalette.aqua)
                progress = Self.color(InkAmpBrandPalette.carmin)
                divider = Self.color("#E6E8E7")
                border = Self.color("#D8DCDA")
                destructive = Self.color(InkAmpBrandPalette.carmin)
        }
    }

    /// Hex strings used by tests / alignment checks (no Color bridging).
    public struct Hex: Equatable, Sendable {
        public let background: String
        public let surface: String
        public let surfaceElevated: String
        public let primaryText: String
        public let secondaryText: String
        public let tertiaryText: String
        public let accent: String
        public let secondaryAccent: String
        public let progress: String
        public let divider: String
        public let border: String
        public let destructive: String

        public static func resolve(for colorScheme: ColorScheme) -> Hex {
            switch colorScheme {
                case .dark:
                    return Hex(
                        background: "#2E2E2E",
                        surface: InkAmpBrandPalette.seaGrey,
                        surfaceElevated: "#454545",
                        primaryText: InkAmpContinueWidgetPalette.Dark.primaryText,
                        secondaryText: InkAmpContinueWidgetPalette.Dark.secondaryText,
                        tertiaryText: "#8A8A8A",
                        accent: InkAmpBrandPalette.tangerine,
                        secondaryAccent: InkAmpBrandPalette.leafGreen,
                        progress: InkAmpBrandPalette.tangerine,
                        divider: "#4A4A4A",
                        border: "#525252",
                        destructive: "#E85A5A",
                    )
                case .light:
                    return Hex(
                        background: InkAmpBrandPalette.blanc,
                        surface: "#F5F7F6",
                        surfaceElevated: InkAmpBrandPalette.blanc,
                        primaryText: InkAmpContinueWidgetPalette.Light.primaryText,
                        secondaryText: InkAmpContinueWidgetPalette.Light.secondaryText,
                        tertiaryText: "#8A8A8A",
                        accent: InkAmpBrandPalette.carmin,
                        secondaryAccent: InkAmpBrandPalette.aqua,
                        progress: InkAmpBrandPalette.carmin,
                        divider: "#E6E8E7",
                        border: "#D8DCDA",
                        destructive: InkAmpBrandPalette.carmin,
                    )
                @unknown default:
                    return resolve(for: .light)
            }
        }
    }

    private static func color(_ hex: String) -> Color {
        Color(hex: hex) ?? .primary
    }
}

/// Radii / spacing for Phase 1 ink+amp chrome. Continuous rounded rects preferred.
public enum InkAmpMetrics {
    public static let controlRadius: CGFloat = 10
    public static let chipRadius: CGFloat = 12
    public static let cardRadius: CGFloat = 18
    public static let featureCardRadius: CGFloat = 22
    public static let screenInset: CGFloat = 16
    public static let sectionSpacing: CGFloat = 28
    public static let cardPadding: CGFloat = 14
    public static let minHitTarget: CGFloat = 44
}

private struct InkAmpAppThemeKey: EnvironmentKey {
    static let defaultValue = InkAmpAppTheme(colorScheme: .light)
}

extension EnvironmentValues {
    public var inkAmpTheme: InkAmpAppTheme {
        get { self[InkAmpAppThemeKey.self] }
        set { self[InkAmpAppThemeKey.self] = newValue }
    }
}

extension View {
    /// Injects `\.inkAmpTheme` from the current system color scheme.
    public func inkAmpAppThemed() -> some View {
        modifier(InkAmpAppThemeEnvironmentModifier())
    }
}

private struct InkAmpAppThemeEnvironmentModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let theme = InkAmpAppTheme.resolve(for: colorScheme)
        content
            .environment(\.inkAmpTheme, theme)
            .tint(theme.accent)
    }
}
#endif
