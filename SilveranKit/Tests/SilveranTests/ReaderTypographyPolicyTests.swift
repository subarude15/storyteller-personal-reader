import Foundation
import Testing

@testable import SilveranKit

@Suite("ReaderTypographyPolicy & Built-in Themes")
struct ReaderTypographyPolicyTests {
    @Test("All 6 curated built-in themes resolve in their respective appearance modes")
    func builtInThemesAppearance() {
        #expect(ReaderTheme.allBuiltIn.count == 6)

        let lightIDs = ReaderTheme.themesForLightMode(customThemes: []).map(\.id)
        #expect(lightIDs == ["builtin-light", "builtin-sepia", "builtin-quiet"])

        let darkIDs = ReaderTheme.themesForDarkMode(customThemes: []).map(\.id)
        #expect(darkIDs == ["builtin-dark", "builtin-oled", "builtin-dusk"])

        for theme in ReaderTheme.allBuiltIn {
            #expect(ReaderTheme.resolve(id: theme.id, customThemes: []) == theme)
        }
    }

    @Test("CSS font-family formatting quotes multi-word font names and maps System Default")
    func cssFontFamilyFormatting() {
        #expect(ReaderTypographyPolicy.cssFontFamily(for: "System Default") == "serif")
        #expect(ReaderTypographyPolicy.cssFontFamily(for: "Georgia") == "Georgia")
        #expect(ReaderTypographyPolicy.cssFontFamily(for: "sans-serif") == "sans-serif")
        #expect(
            ReaderTypographyPolicy.cssFontFamily(for: "Iowan Old Style")
                == "\"Iowan Old Style\", serif"
        )
        #expect(
            ReaderTypographyPolicy.cssFontFamily(for: "Avenir Next")
                == "\"Avenir Next\", serif"
        )
    }

    @Test("Layout presets match within tolerance and distinguish customized values")
    func layoutPresetMatching() {
        for preset in ReaderTypographyPolicy.layoutPresets {
            let matched = ReaderTypographyPolicy.activePreset(
                lineSpacing: preset.lineSpacing,
                marginLeftRight: preset.marginLeftRight,
                marginTopBottom: preset.marginTopBottom,
                wordSpacing: preset.wordSpacing,
                letterSpacing: preset.letterSpacing
            )
            #expect(matched == preset)
        }

        let custom = ReaderTypographyPolicy.activePreset(
            lineSpacing: 2.1,
            marginLeftRight: 18,
            marginTopBottom: 5,
            wordSpacing: 0.4,
            letterSpacing: 0.1
        )
        #expect(custom == nil)
    }
}
