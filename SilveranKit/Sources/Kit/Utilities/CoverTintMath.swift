import Foundation

/// Colors for one color scheme. `surface` and the palette `base` are only ever drawn as a
/// translucent gradient over the theme background; `control` must stay legible on it.
public struct CoverTintSchemeColors: Codable, Equatable, Hashable, Sendable {
    public let surface: CoverRGB8
    public let control: CoverRGB8
    public let onControl: CoverRGB8

    public init(surface: CoverRGB8, control: CoverRGB8, onControl: CoverRGB8) {
        self.surface = surface
        self.control = control
        self.onControl = onControl
    }
}

public struct CoverTintPalette: Codable, Equatable, Hashable, Sendable {
    /// Bump whenever extraction or contrast rules change so cached palettes are re-derived.
    public static let algorithmVersion = 3

    public let version: Int
    /// Dominant cover color the scheme colors were derived from.
    public let base: CoverRGB8
    public let light: CoverTintSchemeColors
    public let dark: CoverTintSchemeColors

    public init(base: CoverRGB8, light: CoverTintSchemeColors, dark: CoverTintSchemeColors) {
        self.version = Self.algorithmVersion
        self.base = base
        self.light = light
        self.dark = dark
    }

    public func colors(dark isDark: Bool) -> CoverTintSchemeColors {
        isDark ? dark : light
    }

    /// Re-checks invariants on decoded (cached) palettes before they reach the UI.
    public func isValid(
        lightBackgrounds: [CoverRGB8] = CoverTintMath.lightBackgrounds,
        darkBackgrounds: [CoverRGB8] = CoverTintMath.darkBackgrounds,
    ) -> Bool {
        version == Self.algorithmVersion
            && CoverTintMath.relativeLuminance(light.surface) >= CoverTintMath.lightSurfaceMinimumLuminance
            && CoverTintMath.relativeLuminance(dark.surface) <= CoverTintMath.darkSurfaceMaximumLuminance
            && CoverTintMath.meetsContrast(light, base: base, dark: false, backgrounds: lightBackgrounds)
            && CoverTintMath.meetsContrast(dark, base: base, dark: true, backgrounds: darkBackgrounds)
    }
}

/// Pure, platform-free cover tint derivation. The Apple adapter samples the cover to
/// 24x24 straight-alpha RGBA and passes the bytes here off the main actor.
public enum CoverTintMath {
    public static let sampleSide = 24
    public static let lightWashOpacity = 0.18
    public static let darkWashOpacity = 0.28
    public static let miniPlayerWashOpacity = 0.12
    public static let minimumSaturation = 0.15
    public static let lightSurfaceMinimumLuminance = 0.80
    public static let darkSurfaceMaximumLuminance = 0.06
    public static let controlMinimumContrast = 3.0
    public static let onControlMinimumContrast = 4.5
    public static let onControlLight = CoverRGB8(red: 255, green: 255, blue: 255)
    public static let onControlDark = CoverRGB8(red: 0x11, green: 0x11, blue: 0x11)

    /// Theme backgrounds a tinted control can sit on: InkAmpAppPalette background and
    /// surfaceElevated (mini-player card) for each scheme.
    public static let lightBackgrounds = [
        CoverRGB8(red: 0xFF, green: 0xFF, blue: 0xFF),
        CoverRGB8(red: 0xF5, green: 0xF7, blue: 0xF6),
    ]
    public static let darkBackgrounds = [
        CoverRGB8(red: 0x2E, green: 0x2E, blue: 0x2E),
        CoverRGB8(red: 0x45, green: 0x45, blue: 0x45),
    ]

    private static let hueBucketCount = 12
    /// Fraction of opaque pixels that must be colorful before a cover gets a tint.
    private static let minimumColorfulCoverage = 0.04

    public static func palette(
        rgbaPixels: [UInt8],
        lightBackgrounds: [CoverRGB8] = lightBackgrounds,
        darkBackgrounds: [CoverRGB8] = darkBackgrounds,
    ) -> CoverTintPalette? {
        guard let seed = dominantHSB(rgbaPixels: rgbaPixels),
            let light = schemeColors(seed: seed, dark: false, backgrounds: lightBackgrounds),
            let dark = schemeColors(seed: seed, dark: true, backgrounds: darkBackgrounds)
        else { return nil }
        return CoverTintPalette(base: CoverColorAverager.rgb(seed), light: light, dark: dark)
    }

    /// Saturation-weighted hue histogram; skips grays, near-black and near-white pixels.
    public static func dominantHSB(rgbaPixels: [UInt8]) -> CoverHSB? {
        guard !rgbaPixels.isEmpty, rgbaPixels.count.isMultiple(of: 4) else { return nil }

        var weights = [Double](repeating: 0, count: hueBucketCount)
        var sinSums = [Double](repeating: 0, count: hueBucketCount)
        var cosSums = [Double](repeating: 0, count: hueBucketCount)
        var saturationSums = [Double](repeating: 0, count: hueBucketCount)
        var brightnessSums = [Double](repeating: 0, count: hueBucketCount)
        var opaqueCount = 0.0
        var colorfulCount = 0.0

        for offset in stride(from: 0, to: rgbaPixels.count, by: 4) {
            let alpha = Double(rgbaPixels[offset + 3]) / 255
            guard alpha > 0.05 else { continue }
            opaqueCount += alpha
            let hsb = CoverColorAverager.hsb(
                red: Double(rgbaPixels[offset]) / 255,
                green: Double(rgbaPixels[offset + 1]) / 255,
                blue: Double(rgbaPixels[offset + 2]) / 255,
            )
            guard hsb.saturation >= minimumSaturation,
                hsb.brightness >= 0.12,
                !(hsb.brightness > 0.96 && hsb.saturation < 0.22)
            else { continue }

            colorfulCount += alpha
            let weight = hsb.saturation * alpha
            let bucket = min(Int(hsb.hue * Double(hueBucketCount)), hueBucketCount - 1)
            let angle = hsb.hue * 2 * .pi
            weights[bucket] += weight
            sinSums[bucket] += sin(angle) * weight
            cosSums[bucket] += cos(angle) * weight
            saturationSums[bucket] += hsb.saturation * weight
            brightnessSums[bucket] += hsb.brightness * weight
        }

        guard opaqueCount > 0,
            let best = weights.indices.max(by: { weights[$0] < weights[$1] }),
            weights[best] > 0,
            colorfulCount / opaqueCount >= minimumColorfulCoverage
        else { return nil }

        var hue = atan2(sinSums[best], cosSums[best]) / (2 * .pi)
        if hue < 0 { hue += 1 }
        return CoverHSB(
            hue: clamp01(hue),
            saturation: clamp01(saturationSums[best] / weights[best]),
            brightness: clamp01(brightnessSums[best] / weights[best]),
        )
    }

    static func schemeColors(
        seed: CoverHSB,
        dark: Bool,
        backgrounds: [CoverRGB8],
    ) -> CoverTintSchemeColors? {
        guard !backgrounds.isEmpty else { return nil }
        let surface = dark ? darkSurface(seed: seed) : lightSurface(seed: seed)
        let rendered = contrastCandidates(
            surface: surface,
            base: CoverColorAverager.rgb(seed),
            dark: dark,
            backgrounds: backgrounds,
        )

        let saturation = min(max(seed.saturation, 0.45), 0.90)
        // Light scheme walks darker from the cover's brightness; dark walks lighter.
        let brightnessSteps = dark
            ? Array(stride(from: max(seed.brightness, 0.55), through: 1.0, by: 0.01))
            : Array(stride(from: min(seed.brightness, 0.95), through: 0.05, by: -0.01))
        for currentSaturation in [saturation, saturation * 0.7, saturation * 0.4] {
            for brightness in brightnessSteps {
                let control = CoverColorAverager.rgb(
                    CoverHSB(hue: seed.hue, saturation: currentSaturation, brightness: brightness)
                )
                guard rendered.allSatisfy({ contrast(control, $0) >= controlMinimumContrast }),
                    let onControl = onControl(for: control)
                else { continue }
                return CoverTintSchemeColors(surface: surface, control: control, onControl: onControl)
            }
        }
        return nil
    }

    /// Every color a tinted wash renders on each theme background: the player gradient
    /// runs `surface` → dominant `base` at 18% (light) / 28% (dark), and the mini-player
    /// draws the same surface → base gradient at 12%.
    public static func renderedGradient(
        surface: CoverRGB8,
        base: CoverRGB8,
        dark: Bool,
        backgrounds: [CoverRGB8],
    ) -> [CoverRGB8] {
        let washOpacity = dark ? darkWashOpacity : lightWashOpacity
        return backgrounds.flatMap { background in
            // 0 = the bare theme background (Live Activity controls sit on surfaceDark).
            [washOpacity, miniPlayerWashOpacity, 0].flatMap { opacity in
                (0...100).map {
                    gradientColor(surface: surface, base: base, at: Double($0) / 100, opacity: opacity, over: background)
                }
            }
        }
    }

    /// Everything `control` must clear 3:1 against: the rendered washes plus the raw
    /// `surface`, which the Lock Screen Live Activity draws as its opaque background.
    public static func contrastCandidates(
        surface: CoverRGB8,
        base: CoverRGB8,
        dark: Bool,
        backgrounds: [CoverRGB8],
    ) -> [CoverRGB8] {
        renderedGradient(surface: surface, base: base, dark: dark, backgrounds: backgrounds) + [surface]
    }

    /// Opaque color of the surface → base gradient at position `t`, drawn at `opacity`
    /// over `background`.
    public static func gradientColor(
        surface: CoverRGB8,
        base: CoverRGB8,
        at t: Double,
        opacity: Double,
        over background: CoverRGB8,
    ) -> CoverRGB8 {
        let t = clamp01(t)
        let alpha = clamp01(opacity)
        func mix(_ top: UInt8, _ bottom: UInt8, _ back: UInt8) -> UInt8 {
            let gradient = Double(top) * (1 - t) + Double(bottom) * t
            return UInt8(clamping: Int((gradient * alpha + Double(back) * (1 - alpha)).rounded()))
        }
        return CoverRGB8(
            red: mix(surface.red, base.red, background.red),
            green: mix(surface.green, base.green, background.green),
            blue: mix(surface.blue, base.blue, background.blue),
        )
    }

    static func meetsContrast(
        _ colors: CoverTintSchemeColors,
        base: CoverRGB8,
        dark: Bool,
        backgrounds: [CoverRGB8],
    ) -> Bool {
        !backgrounds.isEmpty
            && contrastCandidates(surface: colors.surface, base: base, dark: dark, backgrounds: backgrounds)
                .allSatisfy { contrast(colors.control, $0) >= controlMinimumContrast }
            && contrast(colors.onControl, colors.control) >= onControlMinimumContrast
    }

    static func lightSurface(seed: CoverHSB) -> CoverRGB8 {
        var saturation = min(max(seed.saturation * 0.5, 0.12), 0.30)
        while saturation > 0 {
            let color = CoverColorAverager.rgb(
                CoverHSB(hue: seed.hue, saturation: saturation, brightness: 1)
            )
            if relativeLuminance(color) >= lightSurfaceMinimumLuminance { return color }
            saturation -= 0.02
        }
        return CoverRGB8(red: 255, green: 255, blue: 255)
    }

    static func darkSurface(seed: CoverHSB) -> CoverRGB8 {
        let saturation = min(max(seed.saturation * 0.8, 0.30), 0.70)
        var brightness = 0.35
        while brightness > 0 {
            let color = CoverColorAverager.rgb(
                CoverHSB(hue: seed.hue, saturation: saturation, brightness: brightness)
            )
            if relativeLuminance(color) <= darkSurfaceMaximumLuminance { return color }
            brightness -= 0.01
        }
        return CoverRGB8(red: 0, green: 0, blue: 0)
    }

    public static func onControl(for control: CoverRGB8) -> CoverRGB8? {
        let white = contrast(onControlLight, control)
        let ink = contrast(onControlDark, control)
        guard max(white, ink) >= onControlMinimumContrast else { return nil }
        return white >= ink ? onControlLight : onControlDark
    }

    /// WCAG 2.x relative luminance.
    public static func relativeLuminance(_ color: CoverRGB8) -> Double {
        func linear(_ channel: UInt8) -> Double {
            let value = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red) + 0.7152 * linear(color.green)
            + 0.0722 * linear(color.blue)
    }

    public static func contrast(_ first: CoverRGB8, _ second: CoverRGB8) -> Double {
        let a = relativeLuminance(first)
        let b = relativeLuminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Source-over compositing of an opaque color at `opacity` onto an opaque base.
    public static func composite(_ top: CoverRGB8, over base: CoverRGB8, opacity: Double) -> CoverRGB8 {
        let t = clamp01(opacity)
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8(clamping: Int((Double(a) * t + Double(b) * (1 - t)).rounded()))
        }
        return CoverRGB8(
            red: mix(top.red, base.red),
            green: mix(top.green, base.green),
            blue: mix(top.blue, base.blue),
        )
    }

    /// FNV-1a over sampled pixels plus the theme backgrounds the palette was checked
    /// against; detects a replaced cover (or changed theme) for the same item id.
    public static func fingerprint(rgbaPixels: [UInt8], backgrounds: [CoverRGB8] = []) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in rgbaPixels + backgrounds.flatMap({ [$0.red, $0.green, $0.blue] }) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }

    private static func clamp01(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }
}

extension CoverRGB8 {
    /// Parses `#RRGGBB` / `RRGGBB` (reader theme colors); alpha suffixes are ignored.
    public init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6 || digits.count == 8,
            let value = UInt32(digits.prefix(6), radix: 16)
        else { return nil }
        self.init(
            red: UInt8((value >> 16) & 0xFF),
            green: UInt8((value >> 8) & 0xFF),
            blue: UInt8(value & 0xFF),
        )
    }
}

/// Per-item palette cache: bounded LRU in memory, mirrored to one JSON file (App Group).
/// A `nil` palette is cached too, so gray covers are not re-sampled on every play.
public actor CoverTintCache {
    public struct Entry: Codable, Equatable, Sendable {
        public let fingerprint: String
        public let palette: CoverTintPalette?
        public let version: Int

        public init(fingerprint: String, palette: CoverTintPalette?) {
            self.fingerprint = fingerprint
            self.palette = palette
            self.version = CoverTintPalette.algorithmVersion
        }
    }

    private struct Stored: Codable {
        var order: [String]
        var entries: [String: Entry]
    }

    public static let defaultCapacity = 64

    private let fileURL: URL?
    private let capacity: Int
    private var order: [String] = []
    private var entries: [String: Entry] = [:]
    private var loaded = false

    public init(fileURL: URL?, capacity: Int = CoverTintCache.defaultCapacity) {
        self.fileURL = fileURL
        self.capacity = max(1, capacity)
    }

    public func entry(for itemID: String) -> Entry? {
        loadIfNeeded()
        guard let entry = entries[itemID] else { return nil }
        touch(itemID)
        return entry
    }

    public func store(_ entry: Entry, for itemID: String) {
        loadIfNeeded()
        guard entries[itemID] != entry else {
            touch(itemID)
            return
        }
        entries[itemID] = entry
        touch(itemID)
        while order.count > capacity {
            entries.removeValue(forKey: order.removeFirst())
        }
        persist()
    }

    public func removeAll() {
        order = []
        entries = [:]
        loaded = true
        persist()
    }

    private func touch(_ itemID: String) {
        order.removeAll { $0 == itemID }
        order.append(itemID)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL,
            let data = try? Data(contentsOf: fileURL),
            let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }
        let valid = stored.entries.filter { $0.value.version == CoverTintPalette.algorithmVersion }
        order = Array(stored.order.filter { valid[$0] != nil }.suffix(capacity))
        entries = valid.filter { order.contains($0.key) }
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            let data = try JSONEncoder().encode(Stored(order: order, entries: entries))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Cache is best-effort; colors are re-derived from the cover next time.
        }
    }
}
