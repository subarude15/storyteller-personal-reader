#if os(iOS) || os(macOS)
import SwiftUI

#if os(iOS)
import UIKit

struct EbookPlayerTopToolbar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @AppStorage(CoverTintSettings.enabledKey) private var coverTintEnabled = CoverTintSettings.defaultEnabled
    private var coverTintModel: CoverTintModel { .shared }
    private var audioMonitor: AudioSessionMonitor { .shared }

    let hasAudioNarration: Bool
    let playbackSpeed: Double
    let chapters: [ChapterItem]
    let selectedChapterId: String?
    let isSynced: Bool
    let sleepTimerActive: Bool
    let sleepTimerRemaining: TimeInterval?
    let sleepTimerType: SleepTimerType?

    @Binding var showCustomizePopover: Bool
    @Binding var showSearchSheet: Bool
    @Binding var showBookmarksPanel: Bool
    @Binding var showAudioSidebar: Bool

    let searchManager: EbookSearchManager?

    let onDismiss: () -> Void
    let onChapterSelected: (ChapterItem) -> Void
    let onSyncToggle: (Bool) async throws -> Void
    let onSearchResultSelected: (SearchResult) -> Void
    let onSleepTimerStart: (TimeInterval?, SleepTimerType) -> Void
    let onSleepTimerCancel: () -> Void

    let settingsVM: SettingsViewModel

    /// Other downloaded formats for this title (excludes the current category).
    var switchableFormats: [(label: String, category: LocalMediaCategory)] = []
    var onSwitchFormat: ((LocalMediaCategory) -> Void)?
    var isCurrentPageBookmarked: Bool = false
    var onTogglePageBookmark: (() -> Void)? = nil
    /// Immersive mode only: whether Select Text is active (`nil` hides the control).
    var isSelectTextMode: Bool? = nil
    var onToggleSelectText: (() -> Void)? = nil
    var onHideControls: (() -> Void)? = nil
    /// Taps on chrome that do not open a sheet restart the immersive idle window.
    var onActivity: () -> Void = {}

    @State private var showSleepTimerSheet = false
    @State private var showOptionsSheet = false

    private var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    private var backgroundHex: String {
        settingsVM.backgroundColor
            ?? (colorScheme == .dark ? kDefaultBackgroundColorDark : kDefaultBackgroundColorLight)
    }

    private var toolbarForegroundColor: Color {
        isLightColor(hex: backgroundHex) ? .black : .white
    }

    /// Chrome icons pick up the cover tint only while readaloud narration is the active
    /// session, and only when the tint keeps 3:1 against this reader page background.
    private var iconColor: Color {
        guard coverTintEnabled,
            colorSchemeContrast != .increased,
            case .readaloud? = audioMonitor.snapshot?.kind,
            let palette = coverTintModel.palette,
            let background = CoverRGB8(hex: backgroundHex)
        else { return toolbarForegroundColor }
        let control = palette.colors(dark: CoverTintMath.relativeLuminance(background) < 0.18).control
        guard CoverTintMath.contrast(control, background) >= CoverTintMath.controlMinimumContrast
        else { return toolbarForegroundColor }
        return Color(coverRGB: control)
    }

    private var toolbarBackgroundColor: Color {
        if let bgColor = settingsVM.backgroundColor, let color = Color(hex: bgColor) {
            return color
        }
        return colorScheme == .dark
            ? Color(hex: kDefaultBackgroundColorDark) ?? .black
            : Color(hex: kDefaultBackgroundColorLight) ?? .white
    }

    private func isLightColor(hex: String) -> Bool {
        guard let color = Color(hex: hex),
            let components = UIColor(color).cgColor.components,
            components.count >= 3
        else {
            return colorScheme == .light
        }
        let brightness = (components[0] * 299 + components[1] * 587 + components[2] * 114) / 1000
        return brightness > 0.5
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(iconColor)
                        .contentShape(Rectangle())
                }
                .frame(width: 44, height: 44)

                Spacer(minLength: 0)

                HStack(spacing: 2) {
                    if hasAudioNarration {
                        sleepTimerButton
                    }

                    ChaptersButton(
                        chapters: chapters,
                        selectedChapterId: selectedChapterId,
                        onChapterSelected: onChapterSelected,
                        backgroundColor: iconColor,
                        foregroundColor: iconColor,
                        transparency: 1.0,
                        showLabel: false,
                        buttonSize: 42,
                        showBackground: false,
                    )

                    Button {
                        showBookmarksPanel = true
                    } label: {
                        Image(systemName: "highlighter")
                            .font(.system(size: 19, weight: .regular))
                            .foregroundStyle(iconColor)
                            .contentShape(Rectangle())
                    }
                    .frame(width: 42, height: 44)
                    .accessibilityLabel("Bookmarks and Highlights")

                    Button {
                        showSearchSheet = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 19, weight: .regular))
                            .foregroundStyle(iconColor)
                            .contentShape(Rectangle())
                    }
                    .frame(width: 42, height: 44)
                    .sheet(isPresented: $showSearchSheet) {
                        NavigationStack {
                            if let manager = searchManager {
                                EbookSearchPanel(
                                    searchManager: manager,
                                    onDismiss: { showSearchSheet = false },
                                    onResultSelected: { result in
                                        onSearchResultSelected(result)
                                        showSearchSheet = false
                                    },
                                )
                                .navigationTitle("Search")
                                .navigationBarTitleDisplayMode(.inline)
                                .toolbar {
                                    ToolbarItem(placement: .topBarTrailing) {
                                        Button("Done") {
                                            showSearchSheet = false
                                        }
                                    }
                                }
                            }
                        }
                        .presentationDetents([.medium, .large])
                    }

                    Button {
                        showCustomizePopover = true
                    } label: {
                        Image(systemName: "textformat.size")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(iconColor)
                            .contentShape(Rectangle())
                    }
                    .frame(width: 44, height: 44)
                    .sheet(isPresented: $showCustomizePopover) {
                        NavigationStack {
                            ScrollView {
                                EbookPlayerSettings(
                                    settingsVM: settingsVM,
                                    hasAudioNarration: hasAudioNarration,
                                    onDismiss: nil,
                                )
                                .padding()
                            }
                            .navigationTitle("Customize Reader")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("Done") {
                                        showCustomizePopover = false
                                    }
                                }
                            }
                        }
                        .presentationDetents([.fraction(0.7)])
                    }

                    if isPad {
                        Button {
                            onActivity()
                            withAnimation(.easeInOut) { showAudioSidebar.toggle() }
                        } label: {
                            Image(systemName: "sidebar.trailing")
                                .font(.system(size: 20, weight: .regular))
                                .symbolVariant(showAudioSidebar ? .fill : .none)
                                .foregroundStyle(iconColor)
                                .contentShape(Rectangle())
                        }
                        .frame(width: 44, height: 44)
                    }

                    Button {
                        showOptionsSheet = true
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 19, weight: .regular))
                            .foregroundStyle(iconColor)
                            .contentShape(Rectangle())
                    }
                    .frame(width: 42, height: 44)
                    .accessibilityLabel("Display Options")
                    .sheet(isPresented: $showOptionsSheet) {
                        optionsSheet
                    }
                    .reportsReaderChromeSheet(showOptionsSheet)

                    Button {
                        if let onTogglePageBookmark {
                            onTogglePageBookmark()
                        } else {
                            showBookmarksPanel = true
                        }
                    } label: {
                        Image(systemName: isCurrentPageBookmarked ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundStyle(
                                isCurrentPageBookmarked
                                    ? BookmarkPageRibbonView.ribbonColor
                                    : iconColor
                            )
                            .scaleEffect(isCurrentPageBookmarked ? 1.08 : 1.0)
                            .animation(
                                .spring(response: 0.28, dampingFraction: 0.7),
                                value: isCurrentPageBookmarked
                            )
                            .contentShape(Rectangle())
                    }
                    .frame(width: 42, height: 44)
                    .accessibilityLabel(
                        isCurrentPageBookmarked ? "Remove Page Bookmark" : "Bookmark Page"
                    )
                    .contextMenu {
                        Button {
                            onTogglePageBookmark?()
                        } label: {
                            Label(
                                isCurrentPageBookmarked ? "Remove Bookmark" : "Bookmark This Page",
                                systemImage: isCurrentPageBookmarked
                                    ? "bookmark.slash" : "bookmark.fill"
                            )
                        }
                        Button {
                            showBookmarksPanel = true
                        } label: {
                            Label("All Bookmarks & Highlights", systemImage: "list.bullet")
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            .background(toolbarBackgroundColor.ignoresSafeArea(edges: .top))

            if let isSelectTextMode {
                selectTextControl(active: isSelectTextMode)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 8)
                    .padding(.trailing, 12)
            }

            Spacer()
        }
        .sheet(isPresented: $showSleepTimerSheet) {
            sleepTimerSheet
        }
        .reportsReaderChromeSheet(showSleepTimerSheet)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Hide reader controls") {
            onHideControls?()
        }
    }

    private func selectTextControl(active: Bool) -> some View {
        Button {
            onToggleSelectText?()
        } label: {
            if active {
                Label("Done Selecting", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(Color.accentColor))
            } else {
                Label("Select Text", systemImage: "character.cursor.ibeam")
                    .font(.subheadline)
                    .foregroundStyle(iconColor)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(toolbarBackgroundColor.opacity(0.92)))
                    .overlay(Capsule().stroke(iconColor.opacity(0.18), lineWidth: 1))
            }
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .accessibilityLabel(active ? "Done selecting text" : "Select Text")
        .accessibilityHint(
            active
                ? "Returns to immersive reading."
                : "Lets you touch and hold text to select and highlight it."
        )
    }

    private var sleepTimerButton: some View {
        Button(action: {
            if sleepTimerActive {
                onActivity()
                onSleepTimerCancel()
            } else {
                showSleepTimerSheet = true
            }
        }) {
            Image(systemName: sleepTimerActive ? "moon.zzz.fill" : "moon.zzz")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(sleepTimerActive ? .accentColor : iconColor)
                .contentShape(Rectangle())
        }
        .frame(width: 44, height: 44)
        .overlay(alignment: .bottom) {
            if sleepTimerActive {
                Group {
                    if sleepTimerType == .endOfChapter {
                        Text("End Ch.")
                    } else if let remaining = sleepTimerRemaining {
                        Text(formatSleepTimerRemaining(remaining))
                    }
                }
                .font(.caption2)
                .foregroundStyle(toolbarForegroundColor.opacity(0.7))
                .offset(y: 10)
            }
        }
    }

    private func formatSleepTimerRemaining(_ time: TimeInterval) -> String {
        let totalSeconds = max(Int(time.rounded()), 0)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var optionsSheet: some View {
        NavigationStack {
            List {
                if !switchableFormats.isEmpty {
                    Section("Switch Format") {
                        ForEach(switchableFormats, id: \.category) { format in
                            Button {
                                showOptionsSheet = false
                                onSwitchFormat?(format.category)
                            } label: {
                                Label(
                                    format.label,
                                    systemImage: FormatSwitchLabels.systemImage(for: format.category),
                                )
                            }
                            .accessibilityLabel("Switch to \(format.label)")
                        }
                    }
                }

                if hasAudioNarration {
                    Section("Playback") {
                        Toggle(
                            isOn: Binding(
                                get: { !isSynced },
                                set: { newValue in
                                    Task { try? await onSyncToggle(!newValue) }
                                },
                            )
                        ) {
                            Label("Free Browse When Paused", systemImage: "lock.open")
                        }
                    }

                    Section {
                        Toggle(
                            isOn: Binding(
                                get: { settingsVM.alwaysShowMiniPlayer },
                                set: { newValue in
                                    settingsVM.alwaysShowMiniPlayer = newValue
                                    Task { try? await settingsVM.save() }
                                },
                            )
                        ) {
                            Label("Always Show", systemImage: "rectangle.bottomhalf.inset.filled")
                        }

                        Toggle(
                            isOn: Binding(
                                get: { settingsVM.showMiniPlayerStats },
                                set: { newValue in
                                    settingsVM.showMiniPlayerStats = newValue
                                    Task { try? await settingsVM.save() }
                                },
                            )
                        ) {
                            Label("Show Stats Below", systemImage: "clock")
                        }
                    } header: {
                        Text("Mini Player")
                    } footer: {
                        Text(
                            settingsVM.readerControlsMode == .immersive
                                ? "With Immersive controls, Always Show keeps only the compact narration player on screen; the toolbar and scrubber still hide."
                                : "Keeps the mini player on screen when you tap to hide controls."
                        )
                    }
                }

                Section("Overlay Info") {
                    Toggle(
                        isOn: Binding(
                            get: { settingsVM.showProgress },
                            set: { newValue in
                                settingsVM.showProgress = newValue
                                Task { try? await settingsVM.save() }
                            },
                        )
                    ) {
                        Label("Book Progress", systemImage: "percent")
                    }

                    Toggle(
                        isOn: Binding(
                            get: { settingsVM.showPageNumber },
                            set: { newValue in
                                settingsVM.showPageNumber = newValue
                                Task { try? await settingsVM.save() }
                            },
                        )
                    ) {
                        Label("Page Number", systemImage: "book.pages")
                    }

                    if hasAudioNarration {
                        Toggle(
                            isOn: Binding(
                                get: { settingsVM.showTimeRemainingInBook },
                                set: { newValue in
                                    settingsVM.showTimeRemainingInBook = newValue
                                    Task { try? await settingsVM.save() }
                                },
                            )
                        ) {
                            Label("Time in Book", systemImage: "clock")
                        }

                        Toggle(
                            isOn: Binding(
                                get: { settingsVM.showTimeRemainingInChapter },
                                set: { newValue in
                                    settingsVM.showTimeRemainingInChapter = newValue
                                    Task { try? await settingsVM.save() }
                                },
                            )
                        ) {
                            Label("Time in Chapter", systemImage: "clock.badge")
                        }
                    }
                }

                if hasAudioNarration {
                    Section("Overlay Controls") {
                        Toggle(
                            isOn: Binding(
                                get: { settingsVM.showOverlaySkipBackward },
                                set: { newValue in
                                    settingsVM.showOverlaySkipBackward = newValue
                                    Task { try? await settingsVM.save() }
                                },
                            )
                        ) {
                            Label("Skip Back", systemImage: "arrow.counterclockwise")
                        }

                        Toggle(
                            isOn: Binding(
                                get: { settingsVM.showOverlayPlayPause },
                                set: { newValue in
                                    settingsVM.showOverlayPlayPause = newValue
                                    Task { try? await settingsVM.save() }
                                },
                            )
                        ) {
                            Label("Play/Pause", systemImage: "play")
                        }

                        Toggle(
                            isOn: Binding(
                                get: { settingsVM.showOverlaySkipForward },
                                set: { newValue in
                                    settingsVM.showOverlaySkipForward = newValue
                                    Task { try? await settingsVM.save() }
                                },
                            )
                        ) {
                            Label("Skip Forward", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
            .navigationTitle("Display Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showOptionsSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var sleepTimerSheet: some View {
        NavigationStack {
            List {
                Section {
                    sleepTimerOption(title: "10 minutes", duration: 10 * 60)
                    sleepTimerOption(title: "15 minutes", duration: 15 * 60)
                    sleepTimerOption(title: "30 minutes", duration: 30 * 60)
                    sleepTimerOption(title: "1 hour", duration: 60 * 60)
                }

                Section {
                    sleepTimerOption(
                        title: "At End of Chapter",
                        duration: nil,
                        type: .endOfChapter,
                    )
                }
            }
            .navigationTitle("Sleep Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        showSleepTimerSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func sleepTimerOption(
        title: String,
        duration: TimeInterval?,
        type: SleepTimerType = .duration,
    ) -> some View {
        Button(action: {
            onSleepTimerStart(duration, type)
            showSleepTimerSheet = false
        }) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                if sleepTimerActive && sleepTimerType == type {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}
#endif

#endif
