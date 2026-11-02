import Foundation
import Testing

@testable import SilveranKit

#if canImport(SwiftUI)
@testable import SilveranAppleKit
#endif

private func solidPixels(_ red: UInt8, _ green: UInt8, _ blue: UInt8, alpha: UInt8 = 255) -> [UInt8] {
    let side = CoverTintMath.sampleSide
    return Array(repeating: [red, green, blue, alpha], count: side * side).flatMap { $0 }
}

/// Every color the player gradient (surface → dominant base, drawn at 18% / 28% over the
/// theme background) and the 12% mini-player gradient can render: each 1% step between
/// the gradient endpoints, computed with plain channel math rather than `CoverTintMath`.
private func renderedSurfaces(_ colors: CoverTintSchemeColors, base: CoverRGB8, dark: Bool) -> [CoverRGB8] {
    let backgrounds = dark ? CoverTintMath.darkBackgrounds : CoverTintMath.lightBackgrounds
    func channel(_ top: UInt8, _ bottom: UInt8, _ background: UInt8, t: Double, alpha: Double) -> UInt8 {
        let gradient = Double(top) * (1 - t) + Double(bottom) * t
        return UInt8((gradient * alpha + Double(background) * (1 - alpha)).rounded())
    }
    return backgrounds.flatMap { background in
        [dark ? 0.28 : 0.18, 0.12].flatMap { alpha in
            (0...100).map { step in
                let t = Double(step) / 100
                return CoverRGB8(
                    red: channel(colors.surface.red, base.red, background.red, t: t, alpha: alpha),
                    green: channel(colors.surface.green, base.green, background.green, t: t, alpha: alpha),
                    blue: channel(colors.surface.blue, base.blue, background.blue, t: t, alpha: alpha),
                )
            }
        }
    }
}

private func expectAccessible(_ palette: CoverTintPalette) {
    #expect(CoverTintMath.relativeLuminance(palette.light.surface) >= 0.80)
    #expect(CoverTintMath.relativeLuminance(palette.dark.surface) <= 0.06)
    for (colors, isDark) in [(palette.light, false), (palette.dark, true)] {
        for surface in renderedSurfaces(colors, base: palette.base, dark: isDark) {
            #expect(CoverTintMath.contrast(colors.control, surface) >= 3)
        }
        // Raw surface: the Lock Screen Live Activity paints dark.surface opaque.
        #expect(CoverTintMath.contrast(colors.control, colors.surface) >= 3)
        #expect(CoverTintMath.contrast(colors.onControl, colors.control) >= 4.5)
        #expect([CoverTintMath.onControlLight, CoverTintMath.onControlDark].contains(colors.onControl))
    }
    #expect(palette.isValid())
}

@Test func coverTintFallsBackToAccentForWhiteBlackAndGrayCovers() {
    #expect(CoverTintMath.palette(rgbaPixels: solidPixels(255, 255, 255)) == nil)
    #expect(CoverTintMath.palette(rgbaPixels: solidPixels(0, 0, 0)) == nil)
    #expect(CoverTintMath.palette(rgbaPixels: solidPixels(128, 128, 128)) == nil)
    #expect(CoverTintMath.palette(rgbaPixels: solidPixels(0, 0, 0, alpha: 0)) == nil)
}

@Test func coverTintPureYellowCoverMeetsSurfaceAndContrastTargets() throws {
    let palette = try #require(CoverTintMath.palette(rgbaPixels: solidPixels(255, 255, 0)))
    expectAccessible(palette)
    #expect(palette.base == CoverRGB8(red: 255, green: 255, blue: 0))
    // Yellow can't reach 3:1 on white, so the light control must be a darkened yellow.
    #expect(CoverTintMath.relativeLuminance(palette.light.control) < 0.3)
    #expect(palette.light.onControl == CoverTintMath.onControlDark)
}

@Test func coverTintSaturatedCoversMeetContrastInBothSchemes() throws {
    for rgb in [(255, 214, 0), (255, 0, 0), (20, 40, 200), (10, 20, 60), (40, 160, 70), (150, 40, 180)] {
        let pixels = solidPixels(UInt8(rgb.0), UInt8(rgb.1), UInt8(rgb.2))
        expectAccessible(try #require(CoverTintMath.palette(rgbaPixels: pixels)))
    }
}

@Test func coverTintDarkSaturatedCoversClearRawSurfaceAndGradient() throws {
    for rgb in [(90, 0, 20), (0, 30, 90), (60, 0, 90), (0, 70, 40), (110, 50, 0)] {
        let palette = try #require(
            CoverTintMath.palette(rgbaPixels: solidPixels(UInt8(rgb.0), UInt8(rgb.1), UInt8(rgb.2)))
        )
        expectAccessible(palette)
    }

    // A control drawn in the raw dark surface color must be rejected.
    let palette = try #require(CoverTintMath.palette(rgbaPixels: solidPixels(0, 30, 90)))
    let surface = palette.dark.surface
    let tampered = CoverTintPalette(
        base: palette.base,
        light: palette.light,
        dark: CoverTintSchemeColors(surface: surface, control: surface, onControl: palette.dark.onControl),
    )
    #expect(!tampered.isValid())
}

@Test func coverTintIgnoresNeutralPixelsAndSmallColorSpecks() throws {
    var mostlyGray = solidPixels(120, 120, 120)
    mostlyGray.replaceSubrange(0..<8, with: [255, 0, 0, 255, 255, 0, 0, 255])
    #expect(CoverTintMath.palette(rgbaPixels: mostlyGray) == nil)

    var halfBlue = solidPixels(250, 250, 250)
    for offset in stride(from: 0, to: halfBlue.count / 2, by: 4) {
        halfBlue.replaceSubrange(offset..<(offset + 4), with: [20, 40, 200, 255])
    }
    let seed = try #require(CoverTintMath.dominantHSB(rgbaPixels: halfBlue))
    #expect(abs(seed.hue - 0.648) < 0.02)
}

@Test func coverTintPaletteRoundTripsAndRejectsInvalidDecodedValues() throws {
    let palette = try #require(CoverTintMath.palette(rgbaPixels: solidPixels(255, 255, 0)))
    let data = try JSONEncoder().encode(palette)
    #expect(try JSONDecoder().decode(CoverTintPalette.self, from: data) == palette)

    let bad = Data(#"{"red":300,"green":0,"blue":0}"#.utf8)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(CoverRGB8.self, from: bad) }

    // Tampered cache: light control swapped for white fails the contrast invariant.
    let white = CoverTintMath.onControlLight
    let tampered = CoverTintPalette(
        base: palette.base,
        light: CoverTintSchemeColors(surface: palette.light.surface, control: white, onControl: white),
        dark: palette.dark,
    )
    #expect(!tampered.isValid())

    // The dominant base is a rendered gradient stop: a black base darkens the light
    // gradient bottom below 3:1 against the darkened yellow control.
    let baseClash = CoverTintPalette(
        base: CoverRGB8(red: 0, green: 0, blue: 0),
        light: palette.light,
        dark: palette.dark,
    )
    #expect(!baseClash.isValid())
}

@Test func coverTintGradientEndsAtDominantBase() throws {
    let palette = try #require(CoverTintMath.palette(rgbaPixels: solidPixels(20, 40, 200)))
    let white = CoverTintMath.lightBackgrounds[0]
    let rendered = CoverTintMath.renderedGradient(
        surface: palette.light.surface,
        base: palette.base,
        dark: false,
        backgrounds: [white],
    )
    #expect(rendered.first == CoverTintMath.composite(palette.light.surface, over: white, opacity: 0.18))
    #expect(rendered.contains(CoverTintMath.composite(palette.base, over: white, opacity: 0.18)))
    #expect(rendered.contains(CoverTintMath.composite(palette.base, over: white, opacity: 0.12)))
}

@Test func coverRGB8ParsesReaderThemeHex() {
    #expect(CoverRGB8(hex: "#F5F7F6") == CoverRGB8(red: 0xF5, green: 0xF7, blue: 0xF6))
    #expect(CoverRGB8(hex: "2E2E2EFF") == CoverRGB8(red: 0x2E, green: 0x2E, blue: 0x2E))
    #expect(CoverRGB8(hex: "#XYZ") == nil)
}

@Test func coverTintFingerprintChangesWithCoverOrThemeBackgrounds() {
    let red = solidPixels(255, 0, 0)
    let base = CoverTintMath.fingerprint(rgbaPixels: red, backgrounds: CoverTintMath.lightBackgrounds)
    #expect(base == CoverTintMath.fingerprint(rgbaPixels: red, backgrounds: CoverTintMath.lightBackgrounds))
    #expect(base != CoverTintMath.fingerprint(rgbaPixels: solidPixels(254, 0, 0), backgrounds: CoverTintMath.lightBackgrounds))
    #expect(base != CoverTintMath.fingerprint(rgbaPixels: red, backgrounds: CoverTintMath.darkBackgrounds))
}

@Test func coverTintCacheEvictsLeastRecentAndPersists() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("palettes.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    let palette = CoverTintMath.palette(rgbaPixels: solidPixels(255, 0, 0))
    let cache = CoverTintCache(fileURL: url, capacity: 2)
    await cache.store(.init(fingerprint: "a", palette: palette), for: "book:a")
    await cache.store(.init(fingerprint: "b", palette: nil), for: "pod:b")
    _ = await cache.entry(for: "book:a")
    await cache.store(.init(fingerprint: "c", palette: palette), for: "book:c")

    #expect(await cache.entry(for: "pod:b") == nil)
    #expect(await cache.entry(for: "book:a")?.palette == palette)

    let reloaded = CoverTintCache(fileURL: url, capacity: 2)
    #expect(await reloaded.entry(for: "book:c")?.fingerprint == "c")
    #expect(await reloaded.entry(for: "book:a")?.palette == palette)
    #expect(await reloaded.entry(for: "pod:b") == nil)
}

@Test func coverTintCacheDropsEntriesFromOlderAlgorithmVersions() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("palettes.json")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true,
    )
    let stale = #"{"order":["book:x"],"entries":{"book:x":{"fingerprint":"f","version":0}}}"#
    try Data(stale.utf8).write(to: url)

    #expect(await CoverTintCache(fileURL: url).entry(for: "book:x") == nil)
}

#if canImport(SwiftUI)
@Test func coverTintBackgroundsMatchInkAmpPalette() {
    #expect(CoverTintThemeBackgrounds.rgb(dark: false) == CoverTintMath.lightBackgrounds)
    #expect(CoverTintThemeBackgrounds.rgb(dark: true) == CoverTintMath.darkBackgrounds)
}

/// One-shot latch usable from the detached sampler thread and from async test code.
private final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func open() { semaphore.signal() }
    func waitBlocking() { semaphore.wait() }
    func wait() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.semaphore.wait()
                continuation.resume()
            }
        }
    }
}

@MainActor
@Test func coverTintModelIgnoresStaleExtractionAfterItemSwitch() async throws {
    let model = CoverTintModel(cache: CoverTintCache(fileURL: nil))
    let red = solidPixels(255, 0, 0)
    let blue = solidPixels(20, 40, 200)
    let redStarted = Gate()
    let releaseRed = Gate()

    let staleRed = Task { @MainActor in
        await model.update(itemID: "book:red", samplePixels: {
            redStarted.open()
            releaseRed.waitBlocking()
            return red
        })
    }
    await redStarted.wait()
    await model.update(itemID: "pod:blue", samplePixels: { blue })
    releaseRed.open()
    await staleRed.value

    #expect(model.itemID == "pod:blue")
    #expect(model.palette == CoverTintMath.palette(rgbaPixels: blue))
}

@MainActor
@Test func coverTintModelUsesCachedPaletteWithoutResampling() async throws {
    let cache = CoverTintCache(fileURL: nil)
    let model = CoverTintModel(cache: cache)
    let red = solidPixels(255, 0, 0)
    await model.update(itemID: "book:red", samplePixels: { red })
    let derived = try #require(model.palette)

    await model.update(itemID: "pod:other", samplePixels: nil)
    #expect(model.palette == nil)
    // Switching back restores the cached palette before any cover image arrives.
    await model.update(itemID: "book:red", samplePixels: nil)
    #expect(model.palette == derived)
}

@MainActor
@Test func coverTintModelClearsPaletteWhenPlaybackEndsOrCoverIsNeutral() async {
    let model = CoverTintModel(cache: CoverTintCache(fileURL: nil))
    await model.update(itemID: "book:red", samplePixels: { solidPixels(255, 0, 0) })
    #expect(model.palette != nil)

    await model.update(itemID: "book:gray", samplePixels: { solidPixels(128, 128, 128) })
    #expect(model.palette == nil)

    await model.update(itemID: nil, samplePixels: nil)
    #expect(model.palette == nil)
    #expect(model.itemID == nil)
}
#endif
