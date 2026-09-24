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
@MainActor
public final class SettingsTabRequest: ObservableObject {
    public static let shared = SettingsTabRequest()
    @Published public var requestedTab: Int? = nil
    private init() {}

    public func requestReaderSettings() {
        requestedTab = 1
    }

    public func requestBookSources() {
        requestedTab = 3
    }
}
#endif

@MainActor
private class SettingsReloader: ObservableObject {
    @Published var trigger = 0
    private var observerID: UUID?

    init() {
        Task {
            observerID = await SettingsActor.shared.request_notify { @MainActor [weak self] in
                self?.trigger += 1
            }
        }
    }

    deinit {
        if let id = observerID {
            Task {
                await SettingsActor.shared.removeObserver(id: id)
            }
        }
    }
}

public struct SettingsView: View {
    @State private var config = SilveranGlobalConfig()
    @State private var isLoaded = false
    @State private var saveError: String?
    @State private var showResetConfirmation = false
    @State private var persistTask: Task<Void, Never>?
    @State private var isReloadingFromActor = false
    @State private var lastPersistTime: Date = .distantPast
    @StateObject private var reloader = SettingsReloader()
    enum ShelfarrConnectionStatus: Equatable {
        case success
        case failed(errorMessage: String?)

        var errorMessage: String? {
            switch self {
                case .success: return nil
                case .failed(let msg): return msg
            }
        }
    }
    @State private var shelfarrConnectionStatus: ShelfarrConnectionStatus?
    #if os(macOS)
        @State private var selectedTab: SettingsTab = .readerSettings
        #endif

    public init() {}

    public var body: some View {
        ZStack {
            settingsContent
                .opacity(isLoaded ? 1 : 0.5)

            if !isLoaded {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .task(loadConfig)
        .onAppear {
            Task { await SettingsSyncCoordinator.shared.syncNow(reason: "settings") }
        }
        .onReceive(NotificationCenter.default.publisher(for: .inkampSettingsSyncStatusDidChange)) { _ in
            Task { await reloadConfig(force: true) }
        }
        .onChange(of: config) { _, newValue in persistConfig(newValue: newValue) }
        .onChange(of: reloader.trigger) { _, _ in
            Task { await reloadConfig() }
        }
        #if os(macOS)
        .onReceive(SettingsTabRequest.shared.$requestedTab) { newValue in
            if let tab = newValue {
                switch tab {
                    case 1:
                        selectedTab = .readerSettings
                    case 3:
                        selectedTab = .bookSources
                    default:
                        break
                }
                DispatchQueue.main.async {
                    SettingsTabRequest.shared.requestedTab = nil
                }
            }
        }
        #endif
        .alert(
            "Unable to Save Settings",
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } },
            ),
        ) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        .alert(
            "Reset All Settings to Default?",
            isPresented: $showResetConfirmation,
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Reset All", role: .destructive) {
                resetAllSettings()
            }
        } message: {
            Text(
                "This will reset all settings across all tabs to their default values. This action cannot be undone."
            )
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        #if os(macOS)
        macOSContent
        #else
        iosContent
        #endif
    }

    private func loadConfig() async {
        guard !isLoaded else { return }
        let loaded = await SettingsActor.shared.config
        await MainActor.run {
            isReloadingFromActor = true
            config = loaded
            isLoaded = true
            isReloadingFromActor = false
        }
    }

    private func reloadConfig(force: Bool = false) async {
        guard persistTask == nil else { return }
        if !force {
            let timeSinceLastPersist = Date().timeIntervalSince(lastPersistTime)
            guard timeSinceLastPersist > 1.0 else { return }
        }
        let loaded = await SettingsActor.shared.config
        await MainActor.run {
            isReloadingFromActor = true
            config = loaded
            isReloadingFromActor = false
        }
    }

    private func persistConfig(newValue: SilveranGlobalConfig) {
            guard isLoaded, !isReloadingFromActor else { return }

            lastPersistTime = Date()
            persistTask?.cancel()
            persistTask = Task {
                defer { persistTask = nil }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }

                do {
                    try await SettingsActor.shared.updateConfig(
                        fontSize: newValue.reading.fontSize,
                        fontFamily: newValue.reading.fontFamily,
                        lineSpacing: newValue.reading.lineSpacing,
                        marginLeftRight: newValue.reading.marginLeftRight,
                        marginTopBottom: newValue.reading.marginTopBottom,
                        wordSpacing: newValue.reading.wordSpacing,
                        letterSpacing: newValue.reading.letterSpacing,
                        textAlignment: newValue.reading.textAlignment,
                        highlightColor: .some(newValue.reading.highlightColor),
                        highlightThickness: newValue.reading.highlightThickness,
                        backgroundColor: .some(newValue.reading.backgroundColor),
                        foregroundColor: .some(newValue.reading.foregroundColor),
                        customCSS: .some(newValue.reading.customCSS),
                        enableMarginClickNavigation: newValue.reading.enableMarginClickNavigation,
                        singleColumnMode: newValue.reading.singleColumnMode,
                        scrollingMode: newValue.reading.scrollingMode,
                        defaultPlaybackSpeed: newValue.playback.defaultPlaybackSpeed,
                        enableReadingBar: newValue.readingBar.enabled,
                        showPlayerControls: newValue.readingBar.showPlayerControls,
                        showProgressBar: newValue.readingBar.showProgressBar,
                        showProgress: newValue.readingBar.showProgress,
                        showTimeRemainingInBook: newValue.readingBar.showTimeRemainingInBook,
                        showTimeRemainingInChapter: newValue.readingBar.showTimeRemainingInChapter,
                        showPageNumber: newValue.readingBar.showPageNumber,
                        overlayTransparency: newValue.readingBar.overlayTransparency,
                        alwaysShowMiniPlayer: newValue.readingBar.alwaysShowMiniPlayer,
                        progressSyncIntervalSeconds: newValue.sync.progressSyncIntervalSeconds,
                        metadataRefreshIntervalSeconds: newValue.sync.metadataRefreshIntervalSeconds,
                        autoSyncToNewerServerPosition: newValue.sync.autoSyncToNewerServerPosition,
                        showAudioIndicator: newValue.library.showAudioIndicator,
                        tapToPlayPreferredPlayer: newValue.library.tapToPlayPreferredPlayer,
                        preferAudioOverEbook: newValue.library.preferAudioOverEbook,
                        accentColorHex: newValue.library.accentColorHex,
                        userHighlightColor1: newValue.reading.userHighlightColor1,
                        userHighlightColor2: newValue.reading.userHighlightColor2,
                        userHighlightColor3: newValue.reading.userHighlightColor3,
                        userHighlightColor4: newValue.reading.userHighlightColor4,
                        userHighlightColor5: newValue.reading.userHighlightColor5,
                        userHighlightColor6: newValue.reading.userHighlightColor6,
                        userHighlightLabel1: newValue.reading.userHighlightLabel1,
                        userHighlightLabel2: newValue.reading.userHighlightLabel2,
                        userHighlightLabel3: newValue.reading.userHighlightLabel3,
                        userHighlightLabel4: newValue.reading.userHighlightLabel4,
                        userHighlightLabel5: newValue.reading.userHighlightLabel5,
                        userHighlightLabel6: newValue.reading.userHighlightLabel6,
                        userHighlightMode: newValue.reading.userHighlightMode,
                        readaloudHighlightMode: newValue.reading.readaloudHighlightMode,
                        tabBarSlot1: newValue.library.tabBarSlot1,
                        tabBarSlot2: newValue.library.tabBarSlot2,
                        tvSubtitleFontSize: newValue.reading.tvSubtitleFontSize,
                        tvBackgroundStyle: newValue.reading.tvReaderAppearance.backgroundStyle,
                        selectedLightThemeId: newValue.themes.selectedLightThemeId,
                        selectedDarkThemeId: newValue.themes.selectedDarkThemeId,
                        customThemes: newValue.themes.customThemes,
                        builtInThemeOverrides: newValue.themes.builtInThemeOverrides,
                        shelfarrBaseURL: newValue.shelfarrBaseURL,
                        shelfarrAPIToken: newValue.shelfarrAPIToken,
                        lazyLibrarianEnabled: newValue.lazyLibrarianEnabled,
                        lazyLibrarianBaseURL: newValue.lazyLibrarianBaseURL,
                        bookRequestProvider: newValue.bookRequestProvider,
                        bookSearchLANEnabled: newValue.bookSearchLANEnabled,
                        bookSearchLANBaseURL: newValue.bookSearchLANBaseURL,
                        prowlarrEnabled: newValue.prowlarrEnabled,
                        prowlarrBaseURL: newValue.prowlarrBaseURL,
                        jackettEnabled: newValue.jackettEnabled,
                        jackettBaseURL: newValue.jackettBaseURL,
                        delugeEnabled: newValue.delugeEnabled,
                        delugeBaseURL: newValue.delugeBaseURL
                    )
                } catch {
                    await MainActor.run {
                        saveError = error.localizedDescription
                    }
                }
            }
        }

    private func resetAllSettings() {
            config = SilveranGlobalConfig()
        }

    private func testShelfarrConnection() {
        let base = config.shelfarrBaseURL
        let token = config.shelfarrAPIToken
        shelfarrConnectionStatus = nil
        Task { @MainActor in
            let client = ShelfarrClient(baseURL: base, token: token)
            switch await client.testConnection() {
                case .success:
                    shelfarrConnectionStatus = .success
                case .failure(let error):
                    shelfarrConnectionStatus = .failed(errorMessage: error.userMessage)
            }
        }
    }
}

#if os(macOS)
extension SettingsView {
    fileprivate var macOSContent: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                MacGeneralSettingsView(sync: $config.sync, library: $config.library)
                    .tabItem {
                        Label("General", systemImage: "gear")
                    }
                    .tag(SettingsTab.general)

                MacReaderSettingsView(
                    reading: $config.reading,
                    playback: $config.playback,
                    themes: $config.themes,
                )
                .tabItem {
                    Label("Reader Settings", systemImage: "textformat")
                }
                .tag(SettingsTab.readerSettings)

                MacReadingBarSettingsView(readingBar: $config.readingBar)
                    .tabItem {
                        Label("Overlay Stats", systemImage: "chart.bar")
                    }
                    .tag(SettingsTab.readingBar)

                MacBookSourcesSettingsView(
                    lazyLibrarianEnabled: $config.lazyLibrarianEnabled,
                    lazyLibrarianBaseURL: $config.lazyLibrarianBaseURL,
                    shelfarrBaseURL: $config.shelfarrBaseURL,
                    shelfarrAPIToken: $config.shelfarrAPIToken,
                    bookRequestProvider: $config.bookRequestProvider,
                    bookSearchLANEnabled: $config.bookSearchLANEnabled,
                    bookSearchLANBaseURL: $config.bookSearchLANBaseURL,
                    prowlarrEnabled: $config.prowlarrEnabled,
                    prowlarrBaseURL: $config.prowlarrBaseURL,
                    jackettEnabled: $config.jackettEnabled,
                    jackettBaseURL: $config.jackettBaseURL,
                    delugeEnabled: $config.delugeEnabled,
                    delugeBaseURL: $config.delugeBaseURL,
                    shelfarrConnectionStatus: shelfarrConnectionStatus,
                    onTestShelfarr: testShelfarrConnection,
                )
                .tabItem {
                    Label("Book Sources", systemImage: "externaldrive")
                }
                .tag(SettingsTab.bookSources)
            }

            Divider()

            HStack {
                if selectedTab == .readerSettings {
                    Button {
                        resetReaderSettings()
                    } label: {
                        Label("Reset Reader Settings", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Spacer()
                Button {
                    showResetConfirmation = true
                } label: {
                    Label("Reset All to Default", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(12)
        }
        .frame(width: 960, height: 600)
    }

    private func resetReaderSettings() {
        config.reading.fontSize = kDefaultFontSize
        config.reading.fontFamily = kDefaultFontFamily
        config.reading.lineSpacing = kDefaultLineSpacing
        config.reading.marginLeftRight = kDefaultMarginLeftRightMac
        config.reading.marginTopBottom = kDefaultMarginTopBottom
        config.reading.wordSpacing = kDefaultWordSpacing
        config.reading.letterSpacing = kDefaultLetterSpacing
        config.reading.textAlignment = kDefaultTextAlignment
        config.reading.highlightColor = nil
        config.reading.highlightThickness = kDefaultHighlightThickness
        config.reading.userHighlightMode = kDefaultUserHighlightMode
        config.reading.readaloudHighlightMode = kDefaultReadaloudHighlightMode
        config.reading.userHighlightColor1 = kDefaultUserHighlightColor1
        config.reading.userHighlightColor2 = kDefaultUserHighlightColor2
        config.reading.userHighlightColor3 = kDefaultUserHighlightColor3
        config.reading.userHighlightColor4 = kDefaultUserHighlightColor4
        config.reading.userHighlightColor5 = kDefaultUserHighlightColor5
        config.reading.userHighlightColor6 = kDefaultUserHighlightColor6
        config.reading.userHighlightLabel1 = kDefaultUserHighlightLabel1
        config.reading.userHighlightLabel2 = kDefaultUserHighlightLabel2
        config.reading.userHighlightLabel3 = kDefaultUserHighlightLabel3
        config.reading.userHighlightLabel4 = kDefaultUserHighlightLabel4
        config.reading.userHighlightLabel5 = kDefaultUserHighlightLabel5
        config.reading.userHighlightLabel6 = kDefaultUserHighlightLabel6
        config.reading.backgroundColor = nil
        config.reading.foregroundColor = nil
        config.reading.enableMarginClickNavigation = kDefaultEnableMarginClickNavigation
        config.reading.singleColumnMode = false
        config.reading.scrollingMode = kDefaultScrollingMode
        config.reading.customCSS = nil
        config.playback.defaultPlaybackSpeed = kDefaultPlaybackSpeed
    }
}
#else
extension SettingsView {
    fileprivate var iosContent: some View {
        NavigationStack {
            Form {
                Section("General") {
                    GeneralSettingsFields(sync: $config.sync)
                }

                GeneralSettingsFields(sync: $config.sync).autoNavigateSection

                Section {
                    BedtimeSettingsRow()
                } header: {
                    Text("Bedtime")
                } footer: {
                    Text(
                        "Used for Finish tonight on Home. Stored on this device only."
                    )
                }

                Section("Tab Bar") {
                    Picker("First Tab", selection: $config.library.tabBarSlot1) {
                        ForEach(ConfigurableTab.allCases) { tab in
                            Text(tab.label).tag(tab.rawValue)
                        }
                    }
                    Picker("Second Tab", selection: $config.library.tabBarSlot2) {
                        ForEach(ConfigurableTab.allCases) { tab in
                            Text(tab.label).tag(tab.rawValue)
                        }
                    }
                }

                Section {
                    Toggle("Tap Cover to Play", isOn: $config.library.tapToPlayPreferredPlayer)
                    if config.library.tapToPlayPreferredPlayer {
                        Picker(
                            "When Both Available",
                            selection: $config.library.preferAudioOverEbook,
                        ) {
                            Text("Prefer Ebook").tag(false)
                            Text("Prefer Audiobook").tag(true)
                        }
                    }
                } header: {
                    Text("Library")
                } footer: {
                    if config.library.tapToPlayPreferredPlayer {
                        Text(
                            "Tapping a book cover opens the preferred player if media is downloaded. Readaloud always takes priority. Long press to access book details via context menu."
                        )
                    } else {
                        Text(
                            "When enabled, tapping a book cover opens the preferred player instead of book details."
                        )
                    }
                }

                Section("Book Sources") {
                    NavigationLink {
                        StorytellerServerSettingsView()
                    } label: {
                        Label("Book Sources", systemImage: "externaldrive")
                    }
                    NavigationLink {
                        ServicesHealthView()
                    } label: {
                        Label("Services & Health", systemImage: "heart.text.square")
                    }
                    NavigationLink {
                        RequestActivityView()
                    } label: {
                        Label("Request Activity", systemImage: "tray.full")
                    }
                }

                Section("Podcasts") {
                    NavigationLink {
                        PodcastDownloadsSettingsView()
                    } label: {
                        Label("Downloads", systemImage: "arrow.down.circle")
                    }
                }

                Section {
                    StatsLastSyncSettingsRow()
                } header: {
                    Text("Stats")
                } footer: {
                    Text(
                        "Minutes sync across your devices when Storyteller is signed in (same account as progress sync). Tap the row to retry sync."
                    )
                }

                Section {
                    YouTubePlayheadLastSyncSettingsRow()
                } header: {
                    Text("YouTube playheads")
                } footer: {
                    Text(
                        "Matched YouTube resume points sync across your devices when Storyteller is signed in (same account as Stats). Offline resume still uses the local playhead. Tap the row to retry sync."
                    )
                }

                Section {
                    PodcastSyncLastSyncSettingsRow()
                } header: {
                    Text("Podcast sync")
                } footer: {
                    Text(
                        "Subscriptions and episode playheads sync across your devices when Storyteller is signed in (same account as Stats). Downloads stay on each device. Tap the row to retry sync."
                    )
                }

                LazyLibrarianSettingsSection(
                    enabled: $config.lazyLibrarianEnabled,
                    baseURL: $config.lazyLibrarianBaseURL,
                )

                DelugeSettingsSection(
                    enabled: $config.delugeEnabled,
                    baseURL: $config.delugeBaseURL,
                )

                Section("Shelfarr") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField(
                            "Base URL",
                            text: $config.shelfarrBaseURL,
                            prompt: Text("http://192.168.1.2:5057"),
                        )
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        SecureField(
                            "API Token",
                            text: $config.shelfarrAPIToken,
                            prompt: Text("Token"),
                        )
                        .textContentType(.password)
                        Button(action: testShelfarrConnection) {
                            Label("Test Connection", systemImage: "network")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        if let connectionStatus = shelfarrConnectionStatus {
                            HStack {
                                Image(
                                    systemName: connectionStatus == .success
                                        ? "checkmark.circle.fill" : "xmark.circle.fill"
                                )
                                .foregroundStyle(connectionStatus == .success ? .green : .red)
                                Text(
                                    connectionStatus == .success
                                        ? "Connected"
                                        : "Failed: \(connectionStatus.errorMessage ?? "Unknown error")"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                IndexerServiceSettingsSection(
                    title: "Prowlarr",
                    urlPrompt: "http://192.168.1.2:9696",
                    footer:
                        "Optional. The API key is stored in the keychain. Diagnostics only — nothing here searches or changes Prowlarr.",
                    enabled: $config.prowlarrEnabled,
                    baseURL: $config.prowlarrBaseURL,
                    hasKey: { await AuthenticationActor.shared.hasProwlarrAPIKey() },
                    saveKey: { try await AuthenticationActor.shared.saveProwlarrAPIKey($0) },
                    deleteKey: { try await AuthenticationActor.shared.deleteProwlarrAPIKey() },
                )
                IndexerServiceSettingsSection(
                    title: "Jackett",
                    urlPrompt: "http://192.168.1.2:9117",
                    footer:
                        "Optional. The API key is stored in the keychain. Diagnostics only — nothing here searches or changes Jackett.",
                    enabled: $config.jackettEnabled,
                    baseURL: $config.jackettBaseURL,
                    hasKey: { await AuthenticationActor.shared.hasJackettAPIKey() },
                    saveKey: { try await AuthenticationActor.shared.saveJackettAPIKey($0) },
                    deleteKey: { try await AuthenticationActor.shared.deleteJackettAPIKey() },
                )

                Section {
                    Picker("Provider", selection: $config.bookRequestProvider) {
                        Text(BookRequestProviderKind.automatic.displayName)
                            .tag(BookRequestProviderKind.automatic.rawValue)
                        Text(BookRequestProviderKind.lazyLibrarian.displayName)
                            .tag(BookRequestProviderKind.lazyLibrarian.rawValue)
                        Text(BookRequestProviderKind.shelfarr.displayName)
                            .tag(BookRequestProviderKind.shelfarr.rawValue)
                    }
                } header: {
                    Text("Book requests")
                } footer: {
                    Text(
                        "Automatic prefers LazyLibrarian when it is set up, otherwise Shelfarr. Explicit choices never silently switch providers."
                    )
                }

                RequestNotificationsSettingsSection()

                RequestAutomaticFallbackSettingsSection()

                Section {
                    Toggle("Enabled", isOn: $config.bookSearchLANEnabled)
                    TextField(
                        "Base URL",
                        text: $config.bookSearchLANBaseURL,
                        prompt: Text("http://192.168.1.2:3010"),
                    )
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                } header: {
                    Text("Book Search (LAN-only)")
                } footer: {
                    Text(
                        "Optional helper on your home network only. It has no authentication and is never exposed publicly. Off-network unavailability is informational, not an error."
                    )
                }

                ManualSearchSettingsSection()

                NASDownloadsSettingsSection()

                Section {
                    NavigationLink {
                        InkAmpBackupView()
                    } label: {
                        Label("Local Backup & Restore", systemImage: "externaldrive.badge.timemachine")
                    }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Creates a password-encrypted file with accounts, credentials, API keys, and durable settings. Widget caches and downloads are rebuilt instead of restored.")
                }

                Section {
                    NavigationLink {
                        IOSDebugLogView()
                    } label: {
                        Label("Debug Log", systemImage: "doc.text")
                    }
                    LabeledContent("Build", value: PunkRallyBuildIdentity.stamp)
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("AltStore identity stamp (America/New_York MMDDYY.HHmm).")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

#endif

#endif
