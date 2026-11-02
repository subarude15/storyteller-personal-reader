#if os(iOS) || os(macOS)
import SilveranAppleWidgets
import SilveranKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

public enum CoverTintSettings {
    public static let enabledKey = "inkamp.coverTint.enabled"
    public static let defaultEnabled = true

    public static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }
}

/// Cover-derived player colors for the current color scheme. `nil` in the environment
/// means "use the InkAmpAppTheme accent" (tint off, Increase Contrast, or no usable hue).
public struct CoverTint: Equatable, Sendable {
    /// Gradient top stop (scheme surface).
    public let surface: Color
    /// Gradient bottom stop (dominant cover color).
    public let base: Color
    public let control: Color
    public let onControl: Color
    /// Opacity of the surface → base gradient over the player's theme background.
    public let washOpacity: Double

    init(_ colors: CoverTintSchemeColors, base: CoverRGB8, dark: Bool) {
        surface = Color(coverRGB: colors.surface)
        self.base = Color(coverRGB: base)
        control = Color(coverRGB: colors.control)
        onControl = Color(coverRGB: colors.onControl)
        washOpacity = dark ? CoverTintMath.darkWashOpacity : CoverTintMath.lightWashOpacity
    }

    /// The surface → base gradient; callers draw it at `washOpacity` (player) or
    /// `CoverTintMath.miniPlayerWashOpacity` (mini-player) over an opaque theme color.
    public func gradient(startPoint: UnitPoint = .top, endPoint: UnitPoint = .bottom) -> LinearGradient {
        LinearGradient(colors: [surface, base], startPoint: startPoint, endPoint: endPoint)
    }
}

/// InkAmpAppTheme backgrounds a tinted control sits on: page background plus the card
/// surface (light) / elevated mini-player card (dark).
enum CoverTintThemeBackgrounds {
    static func rgb(dark: Bool) -> [CoverRGB8] {
        let hex = InkAmpAppPalette.Hex.resolve(for: dark ? .dark : .light)
        return [hex.background, dark ? hex.surfaceElevated : hex.surface]
            .compactMap { CoverRGB8(hex: $0) }
    }
}

extension Color {
    public init(coverRGB rgb: CoverRGB8) {
        self.init(
            .sRGB,
            red: Double(rgb.red) / 255,
            green: Double(rgb.green) / 255,
            blue: Double(rgb.blue) / 255,
        )
    }
}

private struct CoverTintKey: EnvironmentKey {
    static let defaultValue: CoverTint? = nil
}

extension EnvironmentValues {
    public var coverTint: CoverTint? {
        get { self[CoverTintKey.self] }
        set { self[CoverTintKey.self] = newValue }
    }
}

extension View {
    /// Opaque `themeBackground`, plus the surface → dominant-base gradient at the scheme
    /// wash opacity when tinted.
    public func coverTintBackground(themeBackground: Color) -> some View {
        modifier(CoverTintWashModifier(themeBackground: themeBackground))
    }
}

private struct CoverTintWashModifier: ViewModifier {
    @Environment(\.coverTint) private var tint
    let themeBackground: Color

    func body(content: Content) -> some View {
        content.background {
            themeBackground
                .overlay {
                    if let tint {
                        tint.gradient().opacity(tint.washOpacity)
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }
}

/// Palette for whatever is currently playing (audiobook, readaloud or podcast).
@MainActor
@Observable
public final class CoverTintModel {
    public static let shared = CoverTintModel(
        cache: CoverTintCache(
            fileURL: AppGroupContainer.sharedContainerURL()?
                .appendingPathComponent("CoverTint", isDirectory: true)
                .appendingPathComponent("palettes.json")
        )
    )

    public private(set) var itemID: String?
    public private(set) var palette: CoverTintPalette?

    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let cache: CoverTintCache
    @ObservationIgnored private let lightBackgrounds: [CoverRGB8]
    @ObservationIgnored private let darkBackgrounds: [CoverRGB8]

    init(
        cache: CoverTintCache,
        lightBackgrounds: [CoverRGB8] = CoverTintThemeBackgrounds.rgb(dark: false),
        darkBackgrounds: [CoverRGB8] = CoverTintThemeBackgrounds.rgb(dark: true),
    ) {
        self.cache = cache
        self.lightBackgrounds = lightBackgrounds
        self.darkBackgrounds = darkBackgrounds
    }

    /// Called whenever the playing item or its cover image changes. `samplePixels` runs
    /// off the main actor and returns 24x24 straight RGBA. Callers run this from
    /// `.task(id:)`, so a newer item cancels this one; after every suspension the
    /// generation guard drops results that a newer call has superseded.
    func update(itemID: String?, samplePixels: (@Sendable () -> [UInt8]?)?) async {
        generation += 1
        let token = generation
        let light = lightBackgrounds
        let dark = darkBackgrounds
        func isCurrent() -> Bool { token == generation && !Task.isCancelled }

        guard let itemID else {
            self.itemID = nil
            palette = nil
            return
        }
        if itemID != self.itemID {
            self.itemID = itemID
            palette = nil
            let cached = await cache.entry(for: itemID)
            guard isCurrent() else { return }
            palette = cached?.palette.flatMap {
                $0.isValid(lightBackgrounds: light, darkBackgrounds: dark) ? $0 : nil
            }
        }
        guard let samplePixels else { return }

        let sample = await Task.detached(priority: .utility) { () -> (pixels: [UInt8], fingerprint: String)? in
            guard let pixels = samplePixels() else { return nil }
            return (pixels, CoverTintMath.fingerprint(rgbaPixels: pixels, backgrounds: light + dark))
        }.value
        guard isCurrent(), let sample else { return }

        let cached = await cache.entry(for: itemID)
        guard isCurrent() else { return }
        if let cached, cached.fingerprint == sample.fingerprint,
            cached.palette?.isValid(lightBackgrounds: light, darkBackgrounds: dark) ?? true
        {
            palette = cached.palette
            return
        }

        let derived = await Task.detached(priority: .utility) {
            CoverTintMath.palette(rgbaPixels: sample.pixels, lightBackgrounds: light, darkBackgrounds: dark)
        }.value
        guard isCurrent() else { return }
        palette = derived
        await cache.store(.init(fingerprint: sample.fingerprint, palette: derived), for: itemID)
    }

    /// Tint for a scheme after user/accessibility overrides; `nil` means accent.
    public func resolvedTint(dark: Bool, increaseContrast: Bool) -> CoverTint? {
        guard CoverTintSettings.isEnabled, !increaseContrast, let palette else { return nil }
        return CoverTint(palette.colors(dark: dark), base: palette.base, dark: dark)
    }
}
#endif

#if os(iOS)
extension View {
    /// Publishes `\.coverTint` for the currently playing item to the whole subtree,
    /// including full-screen player covers presented from it.
    public func coverTintEnvironment() -> some View {
        modifier(CoverTintEnvironmentModifier())
    }
}

private struct CoverTintTaskID: Hashable {
    let itemID: String?
    let image: ObjectIdentifier?
}

private struct CoverTintEnvironmentModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(CoverTintSettings.enabledKey) private var enabled = CoverTintSettings.defaultEnabled

    private var model = CoverTintModel.shared
    private var monitor = AudioSessionMonitor.shared

    func body(content: Content) -> some View {
        // Reading `enabled` keeps this view subscribed to the toggle.
        let tint = enabled
            ? model.resolvedTint(dark: colorScheme == .dark, increaseContrast: contrast == .increased)
            : nil
        content
            .environment(\.coverTint, tint)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: tint)
            .task(id: CoverTintTaskID(
                itemID: monitor.snapshot.map { ContinueWidgetItemID.from(sessionKind: $0.kind) },
                image: monitor.coverImage.map(ObjectIdentifier.init),
            )) {
                let sampler: (@Sendable () -> [UInt8]?)? = monitor.coverImage.map { image in
                    { @Sendable () -> [UInt8]? in
                        image.cgImage.flatMap {
                            CoverDerivedPalette.sampledRGBA(of: $0, side: CoverTintMath.sampleSide)
                        }
                    }
                }
                await model.update(
                    itemID: monitor.snapshot.map { ContinueWidgetItemID.from(sessionKind: $0.kind) },
                    samplePixels: sampler,
                )
            }
            .onAppear { monitor.start() }
    }
}
#endif
