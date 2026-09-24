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
enum SettingsTab: Hashable {
    case general
    case readerSettings
    case readingBar
    case bookSources
}

struct MacSettingsContainer<Content: View>: View {
    let tab: SettingsTab
    let content: Content

    init(tab: SettingsTab, @ViewBuilder content: () -> Content) {
        self.tab = tab
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }
}

struct MacGeneralSettingsView: View {
    @Binding var sync: SilveranGlobalConfig.Sync
    @Binding var library: SilveranGlobalConfig.Library
    @State private var showClearConfirmation = false
    private let labelWidth: CGFloat = 180

    private let syncIntervals: [Double] = [10, 30, 60, 120, 300, 600, 1800, 3600, 7200, 14400, -1]

    var body: some View {
        MacSettingsContainer(tab: .general) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Storyteller Server Sync")
                    .font(.headline)

                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 18) {
                    GridRow {
                        label("Progress Sync Interval")
                        HStack(spacing: 12) {
                            Slider(
                                value: Binding(
                                    get: {
                                        let index = indexForInterval(
                                            sync.progressSyncIntervalSeconds
                                        )
                                        //debugLog(.settingsView, "Progress Sync GET - current value: \(sync.progressSyncIntervalSeconds)s, index: \(index)")
                                        return index
                                    },
                                    set: { newIndex in
                                        let newValue = syncIntervals[Int(newIndex)]
                                        debugLog(
                                            "[SettingsView] Progress Sync SET - index: \(newIndex) -> value: \(newValue)s"
                                        )
                                        sync.progressSyncIntervalSeconds = newValue
                                    },
                                ),
                                in: 0...Double(syncIntervals.count - 1),
                                step: 1,
                            )
                            .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
                            Text(formatInterval(sync.progressSyncIntervalSeconds))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .trailing)
                        }
                    }

                    GridRow {
                        label("Metadata Refresh Interval")
                        HStack(spacing: 12) {
                            Slider(
                                value: Binding(
                                    get: {
                                        let index = indexForInterval(
                                            sync.metadataRefreshIntervalSeconds
                                        )
                                        //debugLog(.settingsView, "Metadata Refresh GET - current value: \(sync.metadataRefreshIntervalSeconds)s, index: \(index)")
                                        return index
                                    },
                                    set: { newIndex in
                                        let newValue = syncIntervals[Int(newIndex)]
                                        debugLog(
                                            "[SettingsView] Metadata Refresh SET - index: \(newIndex) -> value: \(newValue)s"
                                        )
                                        sync.metadataRefreshIntervalSeconds = newValue
                                    },
                                ),
                                in: 0...Double(syncIntervals.count - 1),
                                step: 1,
                            )
                            .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
                            Text(formatInterval(sync.metadataRefreshIntervalSeconds))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 60, alignment: .trailing)
                        }
                    }
                }

                Divider()
                    .padding(.vertical, 8)

                Toggle(
                    "Auto-navigate to server position",
                    isOn: $sync.autoSyncToNewerServerPosition,
                )
                .help(
                    "When the server has a newer reading position (from another device), automatically jump to that position."
                )

            }

        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .frame(width: labelWidth, alignment: .trailing)
            .foregroundStyle(.secondary)
    }

    private func indexForInterval(_ seconds: Double) -> Double {
        if let index = syncIntervals.firstIndex(of: seconds) {
            return Double(index)
        }
        if seconds < 0 {
            return Double(syncIntervals.count - 1)
        }
        let closest = syncIntervals.enumerated().min(by: {
            abs($0.element - seconds) < abs($1.element - seconds)
        })
        return Double(closest?.offset ?? 0)
    }

    private func formatInterval(_ seconds: Double) -> String {
        if seconds < 0 {
            return "Never"
        }
        let s = Int(seconds)
        if s < 60 {
            return "\(s)s"
        } else if s < 3600 {
            return "\(s / 60)m"
        } else {
            return "\(s / 3600)h"
        }
    }
}

struct MacBookSourcesSettingsView: View {
    @Binding var lazyLibrarianEnabled: Bool
    @Binding var lazyLibrarianBaseURL: String
    @Binding var shelfarrBaseURL: String
    @Binding var shelfarrAPIToken: String
    @Binding var bookRequestProvider: String
    @Binding var bookSearchLANEnabled: Bool
    @Binding var bookSearchLANBaseURL: String
    @Binding var prowlarrEnabled: Bool
    @Binding var prowlarrBaseURL: String
    @Binding var jackettEnabled: Bool
    @Binding var jackettBaseURL: String
    @Binding var delugeEnabled: Bool
    @Binding var delugeBaseURL: String
    var shelfarrConnectionStatus: SettingsView.ShelfarrConnectionStatus?
    var onTestShelfarr: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            StorytellerServerSettingsView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            NavigationStack {
                Form {
                    Section {
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
                    LazyLibrarianSettingsSection(
                        enabled: $lazyLibrarianEnabled,
                        baseURL: $lazyLibrarianBaseURL,
                    )
                    DelugeSettingsSection(
                        enabled: $delugeEnabled,
                        baseURL: $delugeBaseURL,
                    )
                Section("Shelfarr") {
                    TextField(
                        "Base URL",
                        text: $shelfarrBaseURL,
                        prompt: Text("https://host:5057"),
                    )
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    SecureField(
                        "API Token",
                        text: $shelfarrAPIToken,
                        prompt: Text("Token"),
                    )
                    .textContentType(.password)
                    Button(action: onTestShelfarr) {
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
                IndexerServiceSettingsSection(
                    title: "Prowlarr",
                    urlPrompt: "http://192.168.1.2:9696",
                    footer:
                        "Optional. The API key is stored in the keychain. Diagnostics only — nothing here searches or changes Prowlarr.",
                    enabled: $prowlarrEnabled,
                    baseURL: $prowlarrBaseURL,
                    hasKey: { await AuthenticationActor.shared.hasProwlarrAPIKey() },
                    saveKey: { try await AuthenticationActor.shared.saveProwlarrAPIKey($0) },
                    deleteKey: { try await AuthenticationActor.shared.deleteProwlarrAPIKey() },
                )
                IndexerServiceSettingsSection(
                    title: "Jackett",
                    urlPrompt: "http://192.168.1.2:9117",
                    footer:
                        "Optional. The API key is stored in the keychain. Diagnostics only — nothing here searches or changes Jackett.",
                    enabled: $jackettEnabled,
                    baseURL: $jackettBaseURL,
                    hasKey: { await AuthenticationActor.shared.hasJackettAPIKey() },
                    saveKey: { try await AuthenticationActor.shared.saveJackettAPIKey($0) },
                    deleteKey: { try await AuthenticationActor.shared.deleteJackettAPIKey() },
                )
                Section {
                    Picker("Provider", selection: $bookRequestProvider) {
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
                    Toggle("Enabled", isOn: $bookSearchLANEnabled)
                    TextField(
                        "Base URL",
                        text: $bookSearchLANBaseURL,
                        prompt: Text("http://192.168.1.2:3010"),
                    )
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                } header: {
                    Text("Book Search (LAN-only)")
                } footer: {
                    Text(
                        "Optional helper on your home network only. Off-network unavailability is informational, not an error."
                    )
                }
                ManualSearchSettingsSection()

                NASDownloadsSettingsSection()
            }
            .formStyle(.grouped)
            .frame(maxHeight: 420)
            }
        }
    }
}

#endif

#endif
