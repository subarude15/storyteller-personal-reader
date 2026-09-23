import SilveranAppleKit
import SilveranAppleWidgets
import SwiftUI
import Testing

@Suite("InkAmpAppTheme")
struct InkAmpAppThemeTests {
    @Test func brandPaletteConstantsMatchApprovedHex() {
        #expect(InkAmpBrandPalette.aqua == "#95D9C0")
        #expect(InkAmpBrandPalette.blanc == "#FFFFFF")
        #expect(InkAmpBrandPalette.carmin == "#D41F26")
        #expect(InkAmpBrandPalette.tangerine == "#F58F20")
        #expect(InkAmpBrandPalette.leafGreen == "#467434")
        #expect(InkAmpBrandPalette.seaGrey == "#363636")
    }

    @Test func widgetPaletteAliasesStayAlignedWithBrandPalette() {
        #expect(InkAmpContinueWidgetPalette.Light.aqua == InkAmpBrandPalette.aqua)
        #expect(InkAmpContinueWidgetPalette.Light.blanc == InkAmpBrandPalette.blanc)
        #expect(InkAmpContinueWidgetPalette.Light.carmin == InkAmpBrandPalette.carmin)
        #expect(InkAmpContinueWidgetPalette.Dark.tangerine == InkAmpBrandPalette.tangerine)
        #expect(InkAmpContinueWidgetPalette.Dark.leafGreen == InkAmpBrandPalette.leafGreen)
        #expect(InkAmpContinueWidgetPalette.Dark.seaGrey == InkAmpBrandPalette.seaGrey)
    }

    @Test func lightSemanticAccentsUseCarminAndAqua() {
        let hex = InkAmpAppPalette.Hex.resolve(for: .light)
        #expect(hex.background == InkAmpBrandPalette.blanc)
        #expect(hex.surfaceElevated == InkAmpBrandPalette.blanc)
        #expect(hex.accent == InkAmpBrandPalette.carmin)
        #expect(hex.secondaryAccent == InkAmpBrandPalette.aqua)
        #expect(hex.progress == InkAmpBrandPalette.carmin)
        #expect(hex.primaryText == InkAmpContinueWidgetPalette.Light.primaryText)
        #expect(hex.secondaryText == InkAmpContinueWidgetPalette.Light.secondaryText)
        #expect(!hex.destructive.isEmpty)
        #expect(!hex.divider.isEmpty)
        #expect(!hex.border.isEmpty)
        #expect(!hex.surface.isEmpty)
        #expect(!hex.tertiaryText.isEmpty)
    }

    @Test func darkSemanticAccentsUseTangerineAndLeafGreen() {
        let hex = InkAmpAppPalette.Hex.resolve(for: .dark)
        #expect(hex.surface == InkAmpBrandPalette.seaGrey)
        #expect(hex.accent == InkAmpBrandPalette.tangerine)
        #expect(hex.secondaryAccent == InkAmpBrandPalette.leafGreen)
        #expect(hex.progress == InkAmpBrandPalette.tangerine)
        #expect(hex.primaryText == InkAmpContinueWidgetPalette.Dark.primaryText)
        #expect(hex.secondaryText == InkAmpContinueWidgetPalette.Dark.secondaryText)
    }

    @Test func themeSelectionFollowsColorScheme() {
        let light = InkAmpAppTheme.resolve(for: .light)
        let dark = InkAmpAppTheme.resolve(for: .dark)
        #expect(light.colorScheme == .light)
        #expect(dark.colorScheme == .dark)
        #expect(light.isDark == false)
        #expect(dark.isDark == true)

        let lightHex = InkAmpAppPalette.Hex.resolve(for: .light)
        let darkHex = InkAmpAppPalette.Hex.resolve(for: .dark)
        #expect(lightHex.accent != darkHex.accent)
        #expect(lightHex.accent == InkAmpBrandPalette.carmin)
        #expect(darkHex.accent == InkAmpBrandPalette.tangerine)
    }

    @Test func requiredSemanticRolesExist() {
        let roles = [
            "background",
            "surface",
            "surfaceElevated",
            "primaryText",
            "secondaryText",
            "tertiaryText",
            "accent",
            "secondaryAccent",
            "progress",
            "divider",
            "border",
            "destructive",
        ]
        let light = InkAmpAppPalette.Hex.resolve(for: .light)
        let mirror = Mirror(reflecting: light)
        let names = Set(mirror.children.compactMap(\.label))
        for role in roles {
            #expect(names.contains(role), "Missing semantic role \(role)")
        }
    }
}
