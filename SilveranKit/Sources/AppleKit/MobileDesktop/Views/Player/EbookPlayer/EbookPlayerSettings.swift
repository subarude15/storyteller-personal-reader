#if os(iOS) || os(macOS)
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
struct EbookPlayerSettings: View {
    @Bindable var settingsVM: SettingsViewModel
    let hasAudioNarration: Bool
    @Environment(\.colorScheme) private var colorScheme

    let onDismiss: (() -> Void)?

    @State private var fontSizeInput: String = "20"
    @State private var customFamilies: [CustomFontFamily] = []
    @State private var showFontManager = false
    @State private var showFineTuning = false
    @AppStorage(CoverTintSettings.enabledKey) private var coverTintEnabled = CoverTintSettings.defaultEnabled
    @AppStorage(ReaderSpreadPolicy.settingKey) private var twoPagesInLandscape = true

    private var activeThemesForCurrentScheme: [ReaderTheme] {
        colorScheme == .dark ? settingsVM.darkThemes : settingsVM.lightThemes
    }

    private var activeThemeIdForCurrentScheme: String {
        settingsVM.activeThemeId(for: colorScheme)
    }

    private var activePreset: ReaderTypographyPolicy.LayoutPreset? {
        ReaderTypographyPolicy.activePreset(
            lineSpacing: settingsVM.lineSpacing,
            marginLeftRight: settingsVM.marginLeftRight,
            marginTopBottom: settingsVM.marginTopBottom,
            wordSpacing: settingsVM.wordSpacing,
            letterSpacing: settingsVM.letterSpacing
        )
    }

    var body: some View {
        iOSBody
    }

    private var iOSBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            themeSwatchSection

            Divider()

            typographySection

            Divider()

            layoutPresetsAndSpacingSection

            Divider()

            pageTurnAndFlowSection

            Divider()

            HStack {
                Button {
                    ReaderHaptics.selectionTick()
                    resetToDefaults()
                } label: {
                    Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()
            }
        }
        .onAppear {
            fontSizeInput = String(Int(settingsVM.fontSize))
            Task {
                await loadCustomFonts()
            }
        }
    }

    // MARK: - Visual Theme Swatch Strip

    private var themeSwatchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Themes")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                NavigationLink {
                    ManageThemesView(settingsVM: settingsVM)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "paintpalette")
                        Text("Manage")
                    }
                    .font(.caption.weight(.medium))
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(activeThemesForCurrentScheme) { theme in
                        let isSelected = activeThemeIdForCurrentScheme == theme.id
                        Button {
                            ReaderHaptics.selectionTick()
                            settingsVM.selectTheme(id: theme.id, for: colorScheme)
                        } label: {
                            VStack(spacing: 6) {
                                ZStack(alignment: .topTrailing) {
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color(hex: theme.backgroundColor) ?? .white)
                                        .frame(width: 68, height: 48)
                                        .overlay {
                                            Text("Aa")
                                                .font(.system(size: 18, weight: .semibold, design: .serif))
                                                .foregroundStyle(Color(hex: theme.foregroundColor) ?? .black)
                                        }
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .strokeBorder(
                                                    isSelected
                                                        ? Color.accentColor
                                                        : Color.secondary.opacity(0.3),
                                                    lineWidth: isSelected ? 2.5 : 1
                                                )
                                        )

                                    if isSelected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.caption2)
                                            .foregroundStyle(Color.accentColor)
                                            .background(Circle().fill(Color(uiColor: .systemBackground)))
                                            .offset(x: -4, y: 4)
                                    }
                                }

                                Text(theme.name)
                                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? .primary : .secondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 12) {
                if colorScheme == .dark {
                    HStack(spacing: 4) {
                        Image(systemName: "sun.max")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Day theme:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Light Mode Theme", selection: $settingsVM.selectedLightThemeId) {
                            ForEach(settingsVM.lightThemes) { theme in
                                Text(theme.name).tag(theme.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .onChange(of: settingsVM.selectedLightThemeId) { _, _ in
                            settingsVM.applyActiveTheme(for: colorScheme)
                        }
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "moon")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Night theme:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("Dark Mode Theme", selection: $settingsVM.selectedDarkThemeId) {
                            ForEach(settingsVM.darkThemes) { theme in
                                Text(theme.name).tag(theme.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .onChange(of: settingsVM.selectedDarkThemeId) { _, _ in
                            settingsVM.applyActiveTheme(for: colorScheme)
                        }
                    }
                }
                Spacer()
            }

            Toggle("Tint player from cover", isOn: $coverTintEnabled)
                .font(.subheadline)
        }
    }

    // MARK: - Typography (Font Size & Typeface)

    private var typographySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Typography")
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Font Size")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 6) {
                        Button {
                            let next = max(8, settingsVM.fontSize - 1)
                            guard next != settingsVM.fontSize else { return }
                            ReaderHaptics.selectionTick()
                            settingsVM.fontSize = next
                            fontSizeInput = String(Int(next))
                            settingsVM.save()
                        } label: {
                            Text("A−")
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 38, height: 28)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.secondary.opacity(0.14))
                                )
                        }
                        .buttonStyle(.plain)

                        TextField("Size", text: $fontSizeInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 48)
                            .multilineTextAlignment(.center)
                            .font(.caption.monospacedDigit())
                            .onSubmit {
                                if let val = Double(fontSizeInput), val >= 8, val <= 60 {
                                    settingsVM.fontSize = val
                                    settingsVM.save()
                                } else {
                                    fontSizeInput = String(Int(settingsVM.fontSize))
                                }
                            }

                        Button {
                            let next = min(60, settingsVM.fontSize + 1)
                            guard next != settingsVM.fontSize else { return }
                            ReaderHaptics.selectionTick()
                            settingsVM.fontSize = next
                            fontSizeInput = String(Int(next))
                            settingsVM.save()
                        } label: {
                            Text("A+")
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 38, height: 28)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.secondary.opacity(0.14))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Slider(value: $settingsVM.fontSize, in: 8...60, step: 1)
                    .onChange(of: settingsVM.fontSize) { _, newValue in
                        fontSizeInput = String(Int(newValue))
                        settingsVM.save()
                    }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Font Family")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Manage Custom Fonts...") {
                        showFontManager = true
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .font(.caption)
                    .sheet(isPresented: $showFontManager) {
                        IOSFontManagerView(
                            customFamilies: $customFamilies,
                            selectedFont: $settingsVM.fontFamily,
                            onSave: { settingsVM.save() },
                        )
                    }
                }

                Picker("Font", selection: $settingsVM.fontFamily) {
                    ForEach(ReaderTypographyPolicy.builtInFontOptions) { option in
                        Text(option.label).tag(option.id)
                    }

                    if !customFamilies.isEmpty {
                        Divider()
                        ForEach(customFamilies) { family in
                            Text(family.name).tag(family.name)
                        }
                    }

                    if isCustomFont(settingsVM.fontFamily)
                        && !customFamilies.contains(where: { $0.name == settingsVM.fontFamily })
                    {
                        Text(settingsVM.fontFamily).tag(settingsVM.fontFamily)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .onChange(of: settingsVM.fontFamily) { _, _ in
                    ReaderHaptics.selectionTick()
                    settingsVM.save()
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Text Alignment")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Text Alignment", selection: $settingsVM.textAlignment) {
                    Image(systemName: "text.alignleft").tag("left")
                    Image(systemName: "text.justify").tag("justify")
                    Image(systemName: "text.alignright").tag("right")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: settingsVM.textAlignment) { _, _ in
                    ReaderHaptics.selectionTick()
                    settingsVM.save()
                }
            }
        }
    }

    // MARK: - Layout Presets & Spacing

    private var layoutPresetsAndSpacingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Layout & Spacing")
                .font(.headline)
                .foregroundStyle(.primary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ReaderTypographyPolicy.layoutPresets) { preset in
                        let isSelected = activePreset?.id == preset.id
                        Button {
                            ReaderHaptics.selectionTick()
                            applyPreset(preset)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: preset.systemImage)
                                    .font(.caption)
                                Text(preset.title)
                                    .font(.caption.weight(.semibold))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                Capsule()
                                    .fill(
                                        isSelected
                                            ? Color.accentColor
                                            : Color.secondary.opacity(0.12)
                                    )
                            )
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            labeledSlider(
                label: "Line Spacing",
                value: $settingsVM.lineSpacing,
                range: 1.0...2.5,
                step: 0.1,
                formatter: { String(format: "%.1f", $0) },
            )

            labeledSlider(
                label: "Margins (Left/Right)",
                value: $settingsVM.marginLeftRight,
                range: 0...30,
                step: 1,
                formatter: { "\(Int($0))%" },
            )

            DisclosureGroup("Fine-Tune Margins & Character Spacing", isExpanded: $showFineTuning) {
                VStack(alignment: .leading, spacing: 10) {
                    labeledSlider(
                        label: "Margins (Top/Bottom)",
                        value: $settingsVM.marginTopBottom,
                        range: 0...30,
                        step: 1,
                        formatter: { "\(Int($0))%" },
                    )

                    labeledSlider(
                        label: "Word Spacing",
                        value: $settingsVM.wordSpacing,
                        range: -0.5...2.0,
                        step: 0.1,
                        formatter: { String(format: "%.1fem", $0) },
                    )

                    labeledSlider(
                        label: "Letter Spacing",
                        value: $settingsVM.letterSpacing,
                        range: -0.1...0.5,
                        step: 0.01,
                        formatter: { String(format: "%.2fem", $0) },
                    )
                }
                .padding(.top, 8)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Page Turn & Flow

    private var pageTurnAndFlowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Page Turn & Navigation")
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Page Turn Style")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Page Turn", selection: $settingsVM.pageTurnStyle) {
                    ForEach(PageTurnStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(settingsVM.scrollingMode)
                .onChange(of: settingsVM.pageTurnStyle) { _, _ in
                    ReaderHaptics.selectionTick()
                    settingsVM.save()
                }
                if settingsVM.scrollingMode {
                    Text("Page turn style applies in paginated mode.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Toggle("Scrolling Mode", isOn: $settingsVM.scrollingMode)
                .onChange(of: settingsVM.scrollingMode) { _, _ in
                    settingsVM.save()
                }

            Toggle("Single Column", isOn: singleColumnBinding)
                .onChange(of: settingsVM.singleColumnMode) { _, _ in
                    settingsVM.save()
                }
                .disabled(settingsVM.scrollingMode)

            if UIDevice.current.userInterfaceIdiom == .pad {
                Toggle("Two pages in landscape", isOn: $twoPagesInLandscape)
                    .disabled(settingsVM.scrollingMode)
            }

            Toggle("Margin Tap to Turn Pages", isOn: $settingsVM.enableMarginClickNavigation)
                .onChange(of: settingsVM.enableMarginClickNavigation) { _, _ in
                    settingsVM.save()
                }
        }
    }

    private func applyPreset(_ preset: ReaderTypographyPolicy.LayoutPreset) {
        settingsVM.lineSpacing = preset.lineSpacing
        settingsVM.marginLeftRight = preset.marginLeftRight
        settingsVM.marginTopBottom = preset.marginTopBottom
        settingsVM.wordSpacing = preset.wordSpacing
        settingsVM.letterSpacing = preset.letterSpacing
        settingsVM.save()
    }

    private func loadCustomFonts() async {
        await CustomFontsActor.shared.refreshFonts()
        customFamilies = await CustomFontsActor.shared.availableFamilies
    }

    @ViewBuilder
    private func labeledSlider(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        formatter: (Double) -> String,
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(label): \(formatter(value.wrappedValue))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: value, in: range, step: step)
                .onChange(of: value.wrappedValue) { _, _ in
                    settingsVM.save()
                }
        }
    }

    private func resetToDefaults() {
        settingsVM.fontSize = kDefaultFontSize
        settingsVM.fontFamily = kDefaultFontFamily
        settingsVM.lineSpacing = kDefaultLineSpacing
        settingsVM.marginLeftRight = kDefaultMarginLeftRightIOS
        settingsVM.marginTopBottom = kDefaultMarginTopBottom
        settingsVM.wordSpacing = kDefaultWordSpacing
        settingsVM.letterSpacing = kDefaultLetterSpacing
        settingsVM.textAlignment = kDefaultTextAlignment
        settingsVM.enableMarginClickNavigation = kDefaultEnableMarginClickNavigation
        settingsVM.scrollingMode = kDefaultScrollingMode
        settingsVM.pageTurnStyle = kDefaultPageTurnStyle
        settingsVM.enableReadingBar = kDefaultReadingBarEnabled
        settingsVM.showProgressBar = kDefaultShowProgressBar
        settingsVM.showProgress = kDefaultShowProgress
        settingsVM.showTimeRemainingInBook = kDefaultShowTimeRemainingInBook
        settingsVM.showTimeRemainingInChapter = kDefaultShowTimeRemainingInChapter
        settingsVM.showPageNumber = kDefaultShowPageNumber
        settingsVM.overlayTransparency = kDefaultOverlayTransparency
        settingsVM.singleColumnMode = kDefaultSingleColumnMode
        settingsVM.showPlayerControls = kDefaultShowPlayerControlsIOS
        settingsVM.showOverlaySkipBackward = kDefaultShowOverlaySkipBackward
        settingsVM.showOverlaySkipForward = kDefaultShowOverlaySkipForward
        settingsVM.showOverlayPlayPause = kDefaultShowOverlayPlayPause
        settingsVM.lockViewToAudio = kDefaultLockViewToAudio
        twoPagesInLandscape = true
        fontSizeInput = String(Int(kDefaultFontSize))

        settingsVM.save()
    }

    private func isCustomFont(_ fontFamily: String) -> Bool {
        !ReaderTypographyPolicy.isBuiltInFont(fontFamily)
    }

    private var singleColumnBinding: Binding<Bool> {
        Binding(
            get: { settingsVM.singleColumnMode || settingsVM.scrollingMode },
            set: { settingsVM.singleColumnMode = $0 },
        )
    }
}

private struct IOSFontManagerView: View {
    @Binding var customFamilies: [CustomFontFamily]
    @Binding var selectedFont: String
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showFontImporter = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showFontImporter = true
                    } label: {
                        Label("Import Font", systemImage: "plus.circle")
                    }
                    .fileImporter(
                        isPresented: $showFontImporter,
                        allowedContentTypes: [
                            UTType(filenameExtension: "ttf") ?? .data,
                            UTType(filenameExtension: "otf") ?? .data,
                            UTType.font,
                        ],
                        allowsMultipleSelection: true,
                    ) { result in
                        Task {
                            switch result {
                                case .success(let urls):
                                    for url in urls {
                                        try? await CustomFontsActor.shared.importFont(from: url)
                                    }
                                    await refreshFonts()
                                case .failure:
                                    break
                            }
                        }
                    }
                }

                Section("Custom Fonts") {
                    if customFamilies.isEmpty {
                        Text("No custom fonts imported")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(customFamilies) { family in
                            DisclosureGroup {
                                ForEach(family.variants) { variant in
                                    HStack {
                                        Text(variant.styleDescription)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            deleteVariant(variant, from: family)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(family.name)
                                        Text(
                                            "\(family.variants.count) variant\(family.variants.count == 1 ? "" : "s")"
                                        )
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if selectedFont == family.name {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.blue)
                                    }
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteFamily(family)
                                } label: {
                                    Label("Delete All", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Manage Fonts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            await refreshFonts()
        }
    }

    private func refreshFonts() async {
        await CustomFontsActor.shared.refreshFonts()
        customFamilies = await CustomFontsActor.shared.availableFamilies
    }

    private func deleteFamily(_ family: CustomFontFamily) {
        Task {
            if selectedFont == family.name {
                selectedFont = "System Default"
                onSave()
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
                            onSave()
                        }
                        customFamilies.remove(at: familyIndex)
                    }
                }
            }
        }
    }
}

#endif

#endif
