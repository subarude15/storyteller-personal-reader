#if os(iOS) || os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import SilveranKit
import SilveranAppleWidgets

#if os(macOS)
import AppKit
#else
import UIKit
import CryptoKit
#endif

#if os(macOS)
struct MacReaderSettingsView: View {
    @Binding var reading: SilveranGlobalConfig.Reading
    @Binding var playback: SilveranGlobalConfig.Playback
    @Binding var themes: SilveranGlobalConfig.Themes
    private let labelWidth: CGFloat = 150
    @State private var customFamilies: [CustomFontFamily] = []
    @State private var showFontManager = false
    @State private var showManageThemes = false
    @Environment(\.colorScheme) private var colorScheme

    private func isCustomFont(_ fontFamily: String) -> Bool {
        !["System Default", "serif", "sans-serif", "monospace"].contains(fontFamily)
    }

    private var builtInFonts: [String] {
        ["System Default", "serif", "sans-serif", "monospace"]
    }

    var body: some View {
        MacSettingsContainer(tab: .readerSettings) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 18) {
                GridRow {
                    label("Font Size")
                    Stepper(value: $reading.fontSize, in: 8...60, step: 1) {
                        Text("\(Int(reading.fontSize)) pt")
                    }
                    .frame(width: 200, alignment: .leading)
                }

                GridRow {
                    label("")
                    HStack(spacing: 48) {
                        Toggle("Single Column", isOn: singleColumnBinding)
                            .frame(width: 180, alignment: .leading)
                            .disabled(reading.scrollingMode)

                        Toggle("Scrolling Mode", isOn: $reading.scrollingMode)
                            .frame(width: 240, alignment: .leading)
                    }
                }

                GridRow {
                    label("Text Alignment")
                    Picker("", selection: $reading.textAlignment) {
                        Image(systemName: "text.alignleft").tag("left")
                        Image(systemName: "text.justify").tag("justify")
                        Image(systemName: "text.alignright").tag("right")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200, alignment: .leading)
                }

                GridRow {
                    label("Font")
                    HStack(spacing: 12) {
                        Picker("", selection: $reading.fontFamily) {
                            Text("System Default").tag("System Default")
                            Text("Serif").tag("serif")
                            Text("Sans-Serif").tag("sans-serif")
                            Text("Monospace").tag("monospace")

                            if !customFamilies.isEmpty {
                                Divider()
                                ForEach(customFamilies) { family in
                                    Text(family.name).tag(family.name)
                                }
                            }

                            if isCustomFont(reading.fontFamily)
                                && !customFamilies.contains(where: { $0.name == reading.fontFamily }
                                )
                            {
                                Divider()
                                Text(reading.fontFamily).tag(reading.fontFamily)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)

                        Button("Import...") {
                            importFont()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)

                        if !customFamilies.isEmpty {
                            Button("Manage...") {
                                showFontManager = true
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                            .popover(isPresented: $showFontManager) {
                                CustomFontManagerView(
                                    customFamilies: $customFamilies,
                                    selectedFont: $reading.fontFamily,
                                )
                            }
                        }
                    }
                }

                GridRow {
                    label("Margin (Left/Right)")
                    MacSliderControl(
                        value: $reading.marginLeftRight,
                        range: 0...30,
                        step: 1,
                        formatter: { String(format: "%.0f%%", $0) },
                    )
                }

                GridRow {
                    label("Margin (Top/Bottom)")
                    MacSliderControl(
                        value: $reading.marginTopBottom,
                        range: 0...30,
                        step: 1,
                        formatter: { String(format: "%.0f%%", $0) },
                    )
                }

                GridRow {
                    label("Line Spacing")
                    MacSliderControl(
                        value: $reading.lineSpacing,
                        range: 1.0...2.5,
                        step: 0.1,
                        formatter: { String(format: "%.1f", $0) },
                    )
                }

                GridRow {
                    label("Word Spacing")
                    MacSliderControl(
                        value: $reading.wordSpacing,
                        range: -0.5...2.0,
                        step: 0.1,
                        formatter: { String(format: "%.1fem", $0) },
                    )
                }

                GridRow {
                    label("Letter Spacing")
                    MacSliderControl(
                        value: $reading.letterSpacing,
                        range: -0.1...0.5,
                        step: 0.01,
                        formatter: { String(format: "%.2fem", $0) },
                    )
                }

                GridRow {
                    label("Playback Speed")
                    MacSliderControl(
                        value: $playback.defaultPlaybackSpeed,
                        range: 0.5...3.0,
                        step: 0.05,
                        formatter: { String(format: "%.2fx", $0) },
                    )
                }
            }

            Divider()
                .padding(.vertical, 8)

            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Themes")
                        .font(.headline)

                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 18) {
                        GridRow {
                            label("Light Mode Theme")
                            themePickerView(
                                selection: $themes.selectedLightThemeId,
                                themes: ReaderTheme.themesForLightMode(
                                    customThemes: themes.customThemes,
                                    builtInOverrides: themes.builtInThemeOverrides,
                                ),
                            )
                            .onChange(of: themes.selectedLightThemeId) { _, _ in
                                applyActiveThemeToReading()
                            }
                        }

                        GridRow {
                            label("Dark Mode Theme")
                            themePickerView(
                                selection: $themes.selectedDarkThemeId,
                                themes: ReaderTheme.themesForDarkMode(
                                    customThemes: themes.customThemes,
                                    builtInOverrides: themes.builtInThemeOverrides,
                                ),
                            )
                            .onChange(of: themes.selectedDarkThemeId) { _, _ in
                                applyActiveThemeToReading()
                            }
                        }
                    }

                    Button {
                        showManageThemes = true
                    } label: {
                        Label("Manage Themes...", systemImage: "paintpalette")
                    }
                    .buttonStyle(.bordered)
                }
                .sheet(isPresented: $showManageThemes) {
                    macManageThemesSheet
                }

                Divider()
                    .padding(.horizontal, 24)

                VStack(alignment: .leading, spacing: 18) {
                    Text("Navigation")
                        .font(.headline)

                    Toggle(
                        "Enable margin click to turn pages",
                        isOn: $reading.enableMarginClickNavigation,
                    )
                    .help(
                        "Click on the left or right margins of the page to navigate between pages"
                    )
                }
            }
        }
        .task {
            await loadCustomFonts()
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .frame(width: labelWidth, alignment: .trailing)
            .foregroundStyle(.secondary)
    }

    private var singleColumnBinding: Binding<Bool> {
        Binding(
            get: { reading.singleColumnMode || reading.scrollingMode },
            set: { reading.singleColumnMode = $0 },
        )
    }

    @ViewBuilder
    private func themePickerView(
        selection: Binding<String>,
        themes: [ReaderTheme],
    ) -> some View {
        Picker("", selection: selection) {
            ForEach(themes) { theme in
                Text(theme.name).tag(theme.id)
            }
        }
        .labelsHidden()
        .frame(width: 260)
    }

    private func applyActiveThemeToReading() {
        let activeId =
            colorScheme == .dark
            ? themes.selectedDarkThemeId
            : themes.selectedLightThemeId
        guard
            let theme = ReaderTheme.resolve(
                id: activeId,
                customThemes: themes.customThemes,
                builtInOverrides: themes.builtInThemeOverrides,
            )
        else {
            return
        }
        reading.apply(theme: theme)
    }

    private var macManageThemesSheet: some View {
        MacManageThemesView(themes: $themes, reading: $reading)
    }

    private func loadCustomFonts() async {
        await CustomFontsActor.shared.refreshFonts()
        customFamilies = await CustomFontsActor.shared.availableFamilies
    }

    private func importFont() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.font]

        if panel.runModal() == .OK {
            Task {
                for url in panel.urls {
                    try? await CustomFontsActor.shared.importFont(from: url)
                }
                await loadCustomFonts()
            }
        }
    }
}

struct MacManageThemesView: View {
    @Binding var themes: SilveranGlobalConfig.Themes
    @Binding var reading: SilveranGlobalConfig.Reading
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var editingTheme: ReaderTheme? = nil
    @State private var renamingThemeId: String? = nil
    @State private var renameText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(ReaderTheme.effectiveBuiltIn(overrides: themes.builtInThemeOverrides)) {
                        theme in
                        themeRow(theme)
                    }
                    if !themes.customThemes.isEmpty {
                        Divider()
                        ForEach(themes.customThemes) { theme in
                            themeRow(theme)
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minWidth: 500, minHeight: 500)

            Divider()
            HStack {
                newThemeMenu
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .sheet(item: $editingTheme) { theme in
            MacThemeEditorSheet(theme: theme, themes: $themes, reading: $reading)
        }
    }

    private var newThemeMenu: some View {
        let allThemes =
            ReaderTheme.effectiveBuiltIn(overrides: themes.builtInThemeOverrides)
            + themes.customThemes
        return Menu {
            ForEach(allThemes) { theme in
                Button("From \"\(theme.name)\"") {
                    let newTheme = duplicateTheme(theme)
                    editingTheme = newTheme
                }
            }
        } label: {
            Label("New Theme", systemImage: "plus")
        }
    }

    @ViewBuilder
    private func themeRow(_ theme: ReaderTheme) -> some View {
        HStack(spacing: 12) {
            Button {
                editingTheme = theme
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(hex: theme.backgroundColor) ?? .white)
                            .frame(width: 32, height: 32)
                        Text("Aa")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color(hex: theme.foregroundColor) ?? .black)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        if renamingThemeId == theme.id {
                            TextField("Theme Name", text: $renameText)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { commitRename(theme) }
                        } else {
                            Text(theme.name).fontWeight(.medium)
                        }
                        HStack(spacing: 4) {
                            Text(theme.readaloudHighlightMode.capitalized + " highlight")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !theme.isBuiltIn {
                                Text(appearanceLabel(theme.appearance))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.15))
                                    .cornerRadius(3)
                            }
                            if theme.isBuiltIn, isBuiltInEdited(theme.id) {
                                Text("Edited")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.15))
                                    .cornerRadius(3)
                            }
                        }
                    }

                    Spacer()

                    if themes.selectedLightThemeId == theme.id {
                        Image(systemName: "sun.max.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if themes.selectedDarkThemeId == theme.id {
                        Image(systemName: "moon.fill")
                            .font(.caption).foregroundStyle(.indigo)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                if theme.availableFor(colorScheme: "light") {
                    Button {
                        themes.selectedLightThemeId = theme.id
                    } label: {
                        Label("Use for Light Mode", systemImage: "sun.max")
                    }
                }
                if theme.availableFor(colorScheme: "dark") {
                    Button {
                        themes.selectedDarkThemeId = theme.id
                    } label: {
                        Label("Use for Dark Mode", systemImage: "moon")
                    }
                }
                Divider()
                Button {
                    let dup = duplicateTheme(theme)
                    editingTheme = dup
                } label: {
                    Label("Duplicate", systemImage: "doc.on.doc")
                }
                if theme.isBuiltIn, isBuiltInEdited(theme.id) {
                    Button {
                        resetBuiltInTheme(theme.id)
                    } label: {
                        Label("Reset to Stock", systemImage: "arrow.counterclockwise")
                    }
                }
                if !theme.isBuiltIn {
                    Button {
                        renamingThemeId = theme.id
                        renameText = theme.name
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive) {
                        deleteTheme(id: theme.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 2)
    }

    private func duplicateTheme(_ source: ReaderTheme) -> ReaderTheme {
        let allNames = (ReaderTheme.allBuiltIn + themes.customThemes).map(\.name)
        let newTheme = ReaderTheme(
            name: uniqueCopyName(for: source.name, existing: allNames),
            isBuiltIn: false,
            appearance: source.appearance,
            backgroundColor: source.backgroundColor,
            foregroundColor: source.foregroundColor,
            highlightColor: source.highlightColor,
            highlightThickness: source.highlightThickness,
            readaloudHighlightMode: source.readaloudHighlightMode,
            userHighlightColor1: source.userHighlightColor1,
            userHighlightColor2: source.userHighlightColor2,
            userHighlightColor3: source.userHighlightColor3,
            userHighlightColor4: source.userHighlightColor4,
            userHighlightColor5: source.userHighlightColor5,
            userHighlightColor6: source.userHighlightColor6,
            userHighlightLabel1: source.userHighlightLabel1,
            userHighlightLabel2: source.userHighlightLabel2,
            userHighlightLabel3: source.userHighlightLabel3,
            userHighlightLabel4: source.userHighlightLabel4,
            userHighlightLabel5: source.userHighlightLabel5,
            userHighlightLabel6: source.userHighlightLabel6,
            userHighlightMode: source.userHighlightMode,
            customCSS: source.customCSS,
        )
        themes.customThemes.append(newTheme)
        return newTheme
    }

    private func uniqueCopyName(for baseName: String, existing: [String]) -> String {
        let candidate = "\(baseName) Copy"
        if !existing.contains(candidate) { return candidate }
        var n = 2
        while existing.contains("\(baseName) Copy \(n)") { n += 1 }
        return "\(baseName) Copy \(n)"
    }

    private func deleteTheme(id: String) {
        themes.customThemes.removeAll { $0.id == id }
        if themes.selectedLightThemeId == id {
            themes.selectedLightThemeId = "builtin-light"
        }
        if themes.selectedDarkThemeId == id {
            themes.selectedDarkThemeId = "builtin-dark"
        }
    }

    private func isBuiltInEdited(_ id: String) -> Bool {
        themes.builtInThemeOverrides.contains { $0.id == id }
    }

    private func resetBuiltInTheme(_ id: String) {
        themes.builtInThemeOverrides.removeAll { $0.id == id }
        let activeId =
            colorScheme == .dark
            ? themes.selectedDarkThemeId
            : themes.selectedLightThemeId
        if activeId == id, let stock = ReaderTheme.allBuiltIn.first(where: { $0.id == id }) {
            reading.apply(theme: stock)
        }
    }

    private func appearanceLabel(_ appearance: ThemeAppearance) -> String {
        switch appearance {
            case .light: return "Light only"
            case .dark: return "Dark only"
            case .any: return "Both"
        }
    }

    private func commitRename(_ theme: ReaderTheme) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !theme.isBuiltIn else {
            renamingThemeId = nil
            return
        }
        if let idx = themes.customThemes.firstIndex(where: { $0.id == theme.id }) {
            themes.customThemes[idx].name = trimmed
        }
        renamingThemeId = nil
    }
}

struct MacThemeEditorSheet: View {
    let theme: ReaderTheme
    @Binding var themes: SilveranGlobalConfig.Themes
    @Binding var reading: SilveranGlobalConfig.Reading
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var draft: ReaderTheme
    @State private var tab: ThemeEditorTab = .theme
    @State private var previewUserIndex = 0

    init(
        theme: ReaderTheme,
        themes: Binding<SilveranGlobalConfig.Themes>,
        reading: Binding<SilveranGlobalConfig.Reading>,
    ) {
        self.theme = theme
        self._themes = themes
        self._reading = reading
        self._draft = State(initialValue: theme)
    }

    private var isBuiltInEdit: Bool { theme.isBuiltIn }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                ThemePreviewCard(theme: draft, previewUserColor: previewUserColor)
                    .padding(.horizontal)
                    .padding(.top, 12)

                Picker("Section", selection: $tab) {
                    ForEach(ThemeEditorTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal)

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch tab {
                            case .theme: themeTab
                            case .readaloud: readaloudTab
                            case .highlights: highlightsTab
                            case .advanced: advancedTab
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
            }
            .frame(minWidth: 550, minHeight: 560)

            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { saveTheme() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var themeTab: some View {
        if isBuiltInEdit {
            Text(
                "This built-in theme stays available in its appearance mode. "
                    + "Restore the stock look anytime with Reset to Stock in Manage Themes."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Theme Name").font(.headline)
                TextField("Theme Name", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Show In").font(.headline)
                Picker("Show In", selection: $draft.appearance) {
                    Text("Light & Dark").tag(ThemeAppearance.any)
                    Text("Light Only").tag(ThemeAppearance.light)
                    Text("Dark Only").tag(ThemeAppearance.dark)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                .labelsHidden()
            }
        }

        VStack(alignment: .leading, spacing: 12) {
            Text("Reader Colors").font(.headline)
            macColorRow(label: "Background", hex: $draft.backgroundColor)
            macColorRow(label: "Text", hex: $draft.foregroundColor)
        }
    }

    private var readaloudTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Readaloud Highlight").font(.headline)
            Picker("Style", selection: $draft.readaloudHighlightMode) {
                Text("Background").tag("background")
                Text("Text").tag("text")
                Text("Underline").tag("underline")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)
            .labelsHidden()

            macColorRow(label: "Highlight Color", hex: $draft.highlightColor)

            if draft.readaloudHighlightMode == "background" {
                HStack(spacing: 8) {
                    Text("Highlight Height")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $draft.highlightThickness, in: 0.6...4.0)
                        .frame(width: 120)
                    Text(String(format: "%.1fx", draft.highlightThickness))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var highlightsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("User Highlight Colors").font(.headline)
            Picker("Style", selection: $draft.userHighlightMode) {
                Text("Background").tag("background")
                Text("Text").tag("text")
                Text("Underline").tag("underline")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)
            .labelsHidden()

            macLabeledColorRow(
                label: $draft.userHighlightLabel1,
                hex: $draft.userHighlightColor1,
            )
            macLabeledColorRow(
                label: $draft.userHighlightLabel2,
                hex: $draft.userHighlightColor2,
            )
            macLabeledColorRow(
                label: $draft.userHighlightLabel3,
                hex: $draft.userHighlightColor3,
            )
            macLabeledColorRow(
                label: $draft.userHighlightLabel4,
                hex: $draft.userHighlightColor4,
            )
            macLabeledColorRow(
                label: $draft.userHighlightLabel5,
                hex: $draft.userHighlightColor5,
            )
            macLabeledColorRow(
                label: $draft.userHighlightLabel6,
                hex: $draft.userHighlightColor6,
            )
        }
        .onChange(of: draft.userHighlightColor1) { _, _ in previewUserIndex = 0 }
        .onChange(of: draft.userHighlightColor2) { _, _ in previewUserIndex = 1 }
        .onChange(of: draft.userHighlightColor3) { _, _ in previewUserIndex = 2 }
        .onChange(of: draft.userHighlightColor4) { _, _ in previewUserIndex = 3 }
        .onChange(of: draft.userHighlightColor5) { _, _ in previewUserIndex = 4 }
        .onChange(of: draft.userHighlightColor6) { _, _ in previewUserIndex = 5 }
    }

    private var advancedTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom CSS").font(.headline)
            TextEditor(
                text: Binding(
                    get: { draft.customCSS ?? "" },
                    set: { draft.customCSS = $0.isEmpty ? nil : $0 },
                )
            )
            .font(.system(.body, design: .monospaced))
            .frame(height: 100)
            .border(Color.secondary.opacity(0.3), width: 1)
        }
    }

    private var previewUserColor: String {
        switch previewUserIndex {
            case 1: return draft.userHighlightColor2
            case 2: return draft.userHighlightColor3
            case 3: return draft.userHighlightColor4
            case 4: return draft.userHighlightColor5
            case 5: return draft.userHighlightColor6
            default: return draft.userHighlightColor1
        }
    }

    @ViewBuilder
    private func macColorRow(label: String, hex: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)

            ColorPicker(
                "",
                selection: Binding(
                    get: { Color(hex: hex.wrappedValue) ?? .gray },
                    set: { newColor in
                        if let newHex = newColor.hexString() {
                            hex.wrappedValue = newHex
                        }
                    },
                ),
                supportsOpacity: false,
            )
            .labelsHidden()
            .frame(width: 48, height: 28)

            TextField("#RRGGBB", text: hex)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: 100)
        }
    }

    @ViewBuilder
    private func macLabeledColorRow(label: Binding<String>, hex: Binding<String>) -> some View {
        HStack(spacing: 12) {
            TextField("Label", text: label)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)

            ColorPicker(
                "",
                selection: Binding(
                    get: { Color(hex: hex.wrappedValue) ?? .gray },
                    set: { newColor in
                        if let newHex = newColor.hexString() {
                            hex.wrappedValue = newHex
                        }
                    },
                ),
                supportsOpacity: false,
            )
            .labelsHidden()
            .frame(width: 48, height: 28)

            TextField("#RRGGBB", text: hex)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: 100)
        }
    }

    private func saveTheme() {
        if isBuiltInEdit {
            // Overrides keep the stock name and appearance so Reset to Stock
            // can always restore the theme without identity changes.
            if let stock = ReaderTheme.allBuiltIn.first(where: { $0.id == draft.id }) {
                draft.name = stock.name
                draft.appearance = stock.appearance
                if let idx = themes.builtInThemeOverrides.firstIndex(where: { $0.id == draft.id }
                ) {
                    themes.builtInThemeOverrides[idx] = draft
                } else {
                    themes.builtInThemeOverrides.append(draft)
                }
            }
        } else {
            if let idx = themes.customThemes.firstIndex(where: { $0.id == draft.id }) {
                themes.customThemes[idx] = draft
            }
            if !draft.availableFor(colorScheme: "light")
                && themes.selectedLightThemeId == draft.id
            {
                themes.selectedLightThemeId = "builtin-light"
            }
            if !draft.availableFor(colorScheme: "dark") && themes.selectedDarkThemeId == draft.id {
                themes.selectedDarkThemeId = "builtin-dark"
            }
        }
        let activeId =
            colorScheme == .dark
            ? themes.selectedDarkThemeId
            : themes.selectedLightThemeId
        if activeId == draft.id {
            reading.apply(theme: draft)
        }
        dismiss()
    }

}

extension SilveranGlobalConfig.Reading {
    fileprivate mutating func apply(theme: ReaderTheme) {
        backgroundColor = theme.backgroundColor
        foregroundColor = theme.foregroundColor
        highlightColor = theme.highlightColor
        highlightThickness = theme.highlightThickness
        readaloudHighlightMode = theme.readaloudHighlightMode
        userHighlightColor1 = theme.userHighlightColor1
        userHighlightColor2 = theme.userHighlightColor2
        userHighlightColor3 = theme.userHighlightColor3
        userHighlightColor4 = theme.userHighlightColor4
        userHighlightColor5 = theme.userHighlightColor5
        userHighlightColor6 = theme.userHighlightColor6
        userHighlightLabel1 = theme.userHighlightLabel1
        userHighlightLabel2 = theme.userHighlightLabel2
        userHighlightLabel3 = theme.userHighlightLabel3
        userHighlightLabel4 = theme.userHighlightLabel4
        userHighlightLabel5 = theme.userHighlightLabel5
        userHighlightLabel6 = theme.userHighlightLabel6
        userHighlightMode = theme.userHighlightMode
        customCSS = theme.customCSS
    }
}

struct CustomFontManagerView: View {
    @Binding var customFamilies: [CustomFontFamily]
    @Binding var selectedFont: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom Fonts")
                .font(.headline)

            if customFamilies.isEmpty {
                Text("No custom fonts imported")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(customFamilies) { family in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(family.name)
                                .fontWeight(.medium)
                            Text(
                                "(\(family.variants.count) variant\(family.variants.count == 1 ? "" : "s"))"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                deleteFamily(family)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Delete all variants of \(family.name)")
                        }

                        ForEach(family.variants) { variant in
                            HStack {
                                Text(variant.styleDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 16)
                                Spacer()
                                Button {
                                    deleteVariant(variant, from: family)
                                } label: {
                                    Image(systemName: "xmark.circle")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Delete \(variant.styleDescription)")
                            }
                        }
                    }

                    if family.id != customFamilies.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 300)
    }

    private func deleteFamily(_ family: CustomFontFamily) {
        Task {
            if selectedFont == family.name {
                selectedFont = "System Default"
            }
            try? await CustomFontsActor.shared.deleteFamily(family)
            await MainActor.run {
                customFamilies.removeAll { $0.id == family.id }
            }
        }
    }

    private func deleteVariant(_ variant: CustomFontVariant, from family: CustomFontFamily) {
        Task {
            try? await CustomFontsActor.shared.deleteVariant(variant)
            await MainActor.run {
                if let familyIndex = customFamilies.firstIndex(where: { $0.id == family.id }) {
                    customFamilies[familyIndex].variants.removeAll { $0.id == variant.id }
                    if customFamilies[familyIndex].variants.isEmpty {
                        if selectedFont == family.name {
                            selectedFont = "System Default"
                        }
                        customFamilies.remove(at: familyIndex)
                    }
                }
            }
        }
    }
}

struct MacReadingBarSettingsView: View {
    @Binding var readingBar: SilveranGlobalConfig.ReadingBar

    var body: some View {
        MacSettingsContainer(tab: .readingBar) {
            VStack(alignment: .leading, spacing: 18) {
                Toggle("Enable Overlay Stats", isOn: $readingBar.enabled)
                    .font(.headline)

                Divider()

                Group {
                    DebouncedOpacitySlider(value: $readingBar.overlayTransparency)

                    Toggle("Show Player Controls", isOn: $readingBar.showPlayerControls)
                    Toggle("Show Progress Bar", isOn: $readingBar.showProgressBar)
                    Toggle("Show Page Number in Chapter", isOn: $readingBar.showPageNumber)
                    Toggle("Show Book Progress (%)", isOn: $readingBar.showProgress)
                    Toggle(
                        "Show Time Remaining in Chapter",
                        isOn: $readingBar.showTimeRemainingInChapter,
                    )
                    Toggle(
                        "Show Time Remaining in Book",
                        isOn: $readingBar.showTimeRemainingInBook,
                    )
                }
                .disabled(!readingBar.enabled)
                .opacity(readingBar.enabled ? 1.0 : 0.5)
            }
        }
    }
}

struct MacSliderControl: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let formatter: (Double) -> String
    @State private var localValue: Double = 0
    @State private var debounceTask: Task<Void, Never>?
    @State private var isUpdatingFromSlider = false

    var body: some View {
        HStack(spacing: 12) {
            Slider(value: $localValue, in: range, step: step)
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
                .onAppear {
                    localValue = value
                }
                .onChange(of: localValue) { _, newValue in
                    debounceTask?.cancel()
                    debounceTask = Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            isUpdatingFromSlider = true
                            value = newValue
                            isUpdatingFromSlider = false
                        }
                    }
                }
                .onChange(of: value) { _, newValue in
                    guard !isUpdatingFromSlider else { return }
                    localValue = newValue
                }
            Text(formatter(localValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
    }
}

#endif

#endif
