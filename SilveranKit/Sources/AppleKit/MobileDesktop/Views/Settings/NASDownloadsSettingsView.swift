#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI

struct NASDownloadsSettingsSection: View {
    var body: some View {
        Section {
            NavigationLink {
                NASDownloadsSettingsView()
            } label: {
                Label("NAS Downloads", systemImage: "externaldrive.badge.icloud")
            }
        } header: {
            Text("NAS Downloads")
        } footer: {
            Text(
                "Configure TorBox / Deluge / qBittorrent, Synology upload, and destination folders. Active jobs live in Downloads (More → Downloads)."
            )
        }
    }
}

struct NASDownloadsSettingsView: View {
    @State private var snapshot = NASDownloadSettingsStore.shared.snapshot
    @State private var qbPasswordDraft = ""
    @State private var qbPasswordSaved = false
    @State private var synologyPasswordDraft = ""
    @State private var synologyPasswordSaved = false
    @State private var torboxAPIKeyDraft = ""
    @State private var torboxAPIKeySaved = false
    @State private var qbStatus: QBittorrentConnection?
    @State private var synologyStatus: SynologyConnection?
    @State private var delugeStatus: DelugeConnection?
    @State private var torboxStatus: TorBoxConnection?
    @State private var torboxarrHost = ""
    @State private var torboxarrPort = ""
    @State private var torboxarrUsername = ""
    @State private var torboxarrPasswordDraft = ""
    @State private var torboxarrPasswordSaved = false
    @State private var torboxarrStatus: QBittorrentConnection?
    @State private var checking: String?
    @State private var secretError: String?

    var body: some View {
        List {
            Section {
                Picker("Default torrent provider", selection: torrentClientBinding) {
                    ForEach(NASTorrentClient.allCases, id: \.self) { client in
                        Text(client.label).tag(client)
                    }
                }
                Toggle("Start downloads automatically", isOn: startAutomaticallyBinding)
                Toggle("Create title/author subfolders", isOn: subfoldersBinding)
            } header: {
                Text("Torrent Provider")
            } footer: {
                Text(
                    "Magnets and .torrent files go to the selected provider. TorBox is recommended for new setups; Deluge and qBittorrent remain available. Direct HTTP files still download locally, then upload to Synology."
                )
            }

            Section {
                Toggle("Enabled", isOn: torboxEnabledBinding)
                Toggle(
                    "Automatically transfer Ready downloads to NAS",
                    isOn: torboxAutoTransferBinding,
                )
                .disabled(!snapshot.torboxEnabled || !snapshot.isSynologyConfigured)
                SecureField(
                    "API Key",
                    text: $torboxAPIKeyDraft,
                    prompt: Text(torboxAPIKeySaved ? "Saved — enter a new key to replace" : "TorBox API token"),
                )
                .textContentType(.password)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
                #endif
                .onSubmit { Task { await saveTorBoxAPIKey() } }
                if torboxAPIKeySaved, torboxAPIKeyDraft.isEmpty {
                    Text("••••••••••••••••")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("API key saved")
                    Button("Remove API Key", role: .destructive) {
                        Task { await removeTorBoxAPIKey() }
                    }
                }
                testButton(id: "torbox", title: "Test Connection") {
                    await testTorBox()
                }
                statusRow(ok: torboxStatus?.isOK == true, message: torboxStatus?.message)
            } header: {
                Text("TorBox API")
            } footer: {
                Text(
                    "API key is stored in the device Keychain and never shown in full after save. Create one at torbox.app → Settings → API. When Ready, the NAS pulls TorBox files via Download Station — the phone never pipes multi-GB media."
                )
            }

            Section {
                TextField(
                    "Host",
                    text: $torboxarrHost,
                    prompt: Text(TorBoxarrConnectionSettings.defaultHost),
                )
                .textContentType(.URL)
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { persistTorBoxarr() }
                TextField(
                    "Port",
                    text: $torboxarrPort,
                    prompt: Text(String(TorBoxarrConnectionSettings.defaultPort)),
                )
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
                .onSubmit { persistTorBoxarr() }
                TextField(
                    "Username",
                    text: $torboxarrUsername,
                    prompt: Text(TorBoxarrConnectionSettings.defaultUsername),
                )
                .textContentType(.username)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { persistTorBoxarr() }
                SecureField(
                    "Password",
                    text: $torboxarrPasswordDraft,
                    prompt: Text(
                        torboxarrPasswordSaved
                            ? "Saved — enter a new password to replace"
                            : "TorBoxarr password"
                    ),
                )
                .textContentType(.password)
                .onSubmit { Task { await saveTorBoxarrPassword() } }
                if torboxarrPasswordSaved, torboxarrPasswordDraft.isEmpty {
                    Text("Password saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Remove Password", role: .destructive) {
                        Task { await removeTorBoxarrPassword() }
                    }
                }
                testButton(id: "torboxarr", title: "Test TorBox connection") {
                    await testTorBoxarr()
                }
                statusRow(ok: torboxarrStatus == .ok, message: torboxarrStatus?.message)
            } header: {
                Text("TorBox")
            } footer: {
                Text(
                    "TorBox uses your TorBoxarr qBittorrent bridge. The password stays in the device Keychain."
                )
            }

            Section {
                TextField(
                    "Audiobooks",
                    text: audiobookBinding,
                    prompt: Text(NASDownloadSettingsSnapshot.defaultAudiobookFolder),
                )
                .textContentType(.none)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { persist() }
                TextField(
                    "eBooks",
                    text: ebookBinding,
                    prompt: Text(NASDownloadSettingsSnapshot.defaultEbookFolder),
                )
                .textContentType(.none)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { persist() }
            } header: {
                Text("Destination folders")
            } footer: {
                Text(
                    "Provider-independent library folders. TorBox, Deluge, qBittorrent, and Synology all route into these destinations."
                )
            }

            Section {
                TextField(
                    "Base URL",
                    text: qbURLBinding,
                    prompt: Text("http://host:8080"),
                )
                .textContentType(.URL)
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { persist() }
                TextField(
                    "Username",
                    text: qbUserBinding,
                    prompt: Text("admin"),
                )
                .textContentType(.username)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                SecureField(
                    "Password",
                    text: $qbPasswordDraft,
                    prompt: Text(qbPasswordSaved ? "Saved — enter a new password to replace" : "WebUI password"),
                )
                .textContentType(.password)
                .onSubmit { Task { await saveQBittorrentPassword() } }
                if qbPasswordSaved, qbPasswordDraft.isEmpty {
                    Text("Password saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Remove Password", role: .destructive) {
                        Task { await removeQBittorrentPassword() }
                    }
                }
                testButton(id: "qbittorrent", title: "Test Connection") {
                    await testQBittorrent()
                }
                statusRow(ok: qbStatus == .ok, message: qbStatus?.message)
            } header: {
                Text("qBittorrent")
            } footer: {
                Text("Used for magnet links and .torrent URLs when qBittorrent is the selected torrent client.")
            }

            Section {
                TextField(
                    "Base URL",
                    text: delugeURLBinding,
                    prompt: Text("http://host:8112"),
                )
                .textContentType(.URL)
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                testButton(id: "deluge", title: "Test Connection") {
                    await testDeluge()
                }
                statusRow(ok: delugeStatus == .ok, message: delugeStatus?.message)
            } header: {
                Text("Deluge")
            } footer: {
                Text(
                    "Optional fallback provider. Reuses the existing Deluge WebUI password from Settings. Magnets start in Incoming; after Deluge moves them to Completed, ink+amp routes to the eBook or Audiobook folder."
                )
            }

            if snapshot.torrentClient == .deluge {
                Section {
                    TextField(
                        "Incoming",
                        text: delugeIncomingBinding,
                        prompt: Text(NASDownloadSettingsSnapshot.defaultDelugeIncomingFolder),
                    )
                    .textContentType(.none)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit { persist() }
                    TextField(
                        "Completed",
                        text: delugeCompletedBinding,
                        prompt: Text(NASDownloadSettingsSnapshot.defaultDelugeCompletedFolder),
                    )
                    .textContentType(.none)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit { persist() }
                } header: {
                    Text("Deluge staging folders")
                } footer: {
                    Text(
                        "ink+amp waits until Deluge reports a torrent in Completed before calling move_storage to the final library folder."
                    )
                }
            }

            Section {
                TextField(
                    "DSM URL",
                    text: synologyURLBinding,
                    prompt: Text("http://diskstation.local:5000"),
                )
                .textContentType(.URL)
                .autocorrectionDisabled()
                #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit { persist() }
                TextField(
                    "Username",
                    text: synologyUserBinding,
                    prompt: Text("admin"),
                )
                .textContentType(.username)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                SecureField(
                    "Password",
                    text: $synologyPasswordDraft,
                    prompt: Text(
                        synologyPasswordSaved ? "Saved — enter a new password to replace" : "DSM password"
                    ),
                )
                .textContentType(.password)
                .onSubmit { Task { await saveSynologyPassword() } }
                if synologyPasswordSaved, synologyPasswordDraft.isEmpty {
                    Text("Password saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Remove Password", role: .destructive) {
                        Task { await removeSynologyPassword() }
                    }
                }
                testButton(id: "synology", title: "Test Connection") {
                    await testSynology()
                }
                statusRow(ok: synologyStatus == .ok, message: synologyStatus?.message)
            } header: {
                Text("Synology File Station")
            } footer: {
                Text(
                    "Used for direct file downloads after they finish downloading to this device. Uploads go through the DSM File Station API. Volume paths such as /volume1/media/… are converted to share paths automatically."
                )
            }

            if let secretError {
                Section {
                    Text(secretError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("NAS Downloads")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            snapshot = NASDownloadSettingsStore.shared.snapshot
            qbPasswordSaved = await AuthenticationActor.shared.hasQBittorrentPassword()
            synologyPasswordSaved = await AuthenticationActor.shared.hasSynologyPassword()
            torboxAPIKeySaved = await AuthenticationActor.shared.hasTorBoxAPIKey()
            torboxarrHost = ManualMagnetBackendSettings.host()
            torboxarrPort = String(ManualMagnetBackendSettings.port())
            torboxarrUsername = ManualMagnetBackendSettings.username()
            torboxarrPasswordSaved = await AuthenticationActor.shared.hasTorBoxarrPassword()
            let configURL = await SettingsActor.shared.config.delugeBaseURL
            let resolved = snapshot.resolvedDelugeBaseURL(configURL: configURL)
            if snapshot.trimmedDelugeBaseURL.isEmpty, !resolved.isEmpty {
                snapshot.delugeBaseURL = resolved
                persist()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .inkampNASDownloadSettingsDidChange)) { _ in
            snapshot = NASDownloadSettingsStore.shared.snapshot
        }
        .onDisappear {
            persist()
            persistTorBoxarr()
            let qbDraft = qbPasswordDraft
            let torboxarrDraft = torboxarrPasswordDraft
            let synologyDraft = synologyPasswordDraft
            let torboxDraft = torboxAPIKeyDraft
            Task {
                if !qbDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try? await AuthenticationActor.shared.saveQBittorrentPassword(qbDraft)
                }
                if !synologyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try? await AuthenticationActor.shared.saveSynologyPassword(synologyDraft)
                }
                if !torboxDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try? await AuthenticationActor.shared.saveTorBoxAPIKey(torboxDraft)
                }
                if !torboxarrDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try? await AuthenticationActor.shared.saveTorBoxarrPassword(torboxarrDraft)
                }
            }
        }
    }

    private var torrentClientBinding: Binding<NASTorrentClient> {
        Binding(
            get: { snapshot.torrentClient },
            set: { snapshot.torrentClient = $0; persist() },
        )
    }

    private var torboxEnabledBinding: Binding<Bool> {
        Binding(
            get: { snapshot.torboxEnabled },
            set: { snapshot.torboxEnabled = $0; persist() },
        )
    }

    private var torboxAutoTransferBinding: Binding<Bool> {
        Binding(
            get: { snapshot.torboxAutoTransferToNAS },
            set: { snapshot.torboxAutoTransferToNAS = $0; persist() },
        )
    }

    private var startAutomaticallyBinding: Binding<Bool> {
        Binding(
            get: { snapshot.startAutomatically },
            set: { snapshot.startAutomatically = $0; persist() },
        )
    }

    private var subfoldersBinding: Binding<Bool> {
        Binding(
            get: { snapshot.createTitleAuthorSubfolders },
            set: { snapshot.createTitleAuthorSubfolders = $0; persist() },
        )
    }

    private var audiobookBinding: Binding<String> {
        Binding(get: { snapshot.audiobookFolder }, set: { snapshot.audiobookFolder = $0 })
    }

    private var ebookBinding: Binding<String> {
        Binding(get: { snapshot.ebookFolder }, set: { snapshot.ebookFolder = $0 })
    }

    private var qbURLBinding: Binding<String> {
        Binding(get: { snapshot.qbittorrentBaseURL }, set: { snapshot.qbittorrentBaseURL = $0 })
    }

    private var qbUserBinding: Binding<String> {
        Binding(get: { snapshot.qbittorrentUsername }, set: { snapshot.qbittorrentUsername = $0 })
    }

    private var delugeURLBinding: Binding<String> {
        Binding(
            get: { snapshot.delugeBaseURL },
            set: { newValue in
                snapshot.delugeBaseURL = newValue
                persist()
                Task { try? await SettingsActor.shared.updateConfig(delugeBaseURL: newValue) }
            },
        )
    }

    private var delugeIncomingBinding: Binding<String> {
        Binding(get: { snapshot.delugeIncomingFolder }, set: { snapshot.delugeIncomingFolder = $0 })
    }

    private var delugeCompletedBinding: Binding<String> {
        Binding(get: { snapshot.delugeCompletedFolder }, set: { snapshot.delugeCompletedFolder = $0 })
    }

    private var synologyURLBinding: Binding<String> {
        Binding(get: { snapshot.synologyBaseURL }, set: { snapshot.synologyBaseURL = $0 })
    }

    private var synologyUserBinding: Binding<String> {
        Binding(get: { snapshot.synologyUsername }, set: { snapshot.synologyUsername = $0 })
    }

    private func persist() {
        NASDownloadSettingsStore.shared.replace(snapshot)
    }

    private func persistTorBoxarr() {
        ManualMagnetBackendSettings.setHost(torboxarrHost)
        if let port = Int(torboxarrPort.trimmingCharacters(in: .whitespacesAndNewlines)) {
            ManualMagnetBackendSettings.setPort(port)
        }
        ManualMagnetBackendSettings.setUsername(torboxarrUsername)
    }

    @ViewBuilder
    private func testButton(id: String, title: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Label(checking == id ? "Testing…" : title, systemImage: "network")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(checking != nil)
    }

    @ViewBuilder
    private func statusRow(ok: Bool, message: String?) -> some View {
        if let message {
            HStack {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(ok ? .green : .red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func saveTorBoxAPIKey() async {
        let draft = torboxAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        do {
            try await AuthenticationActor.shared.saveTorBoxAPIKey(draft)
            torboxAPIKeyDraft = ""
            torboxAPIKeySaved = true
            secretError = nil
        } catch {
            secretError = "Could not save the TorBox API key."
        }
    }

    private func removeTorBoxAPIKey() async {
        do {
            try await AuthenticationActor.shared.deleteTorBoxAPIKey()
            torboxAPIKeyDraft = ""
            torboxAPIKeySaved = false
            torboxStatus = nil
            secretError = nil
        } catch {
            secretError = "Could not remove the TorBox API key."
        }
    }

    private func saveQBittorrentPassword() async {
        let draft = qbPasswordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        do {
            try await AuthenticationActor.shared.saveQBittorrentPassword(draft)
            qbPasswordDraft = ""
            qbPasswordSaved = true
            secretError = nil
        } catch {
            secretError = "Could not save the qBittorrent password."
        }
    }

    private func removeQBittorrentPassword() async {
        do {
            try await AuthenticationActor.shared.deleteQBittorrentPassword()
            qbPasswordDraft = ""
            qbPasswordSaved = false
            qbStatus = nil
            secretError = nil
        } catch {
            secretError = "Could not remove the qBittorrent password."
        }
    }

    private func saveSynologyPassword() async {
        let draft = synologyPasswordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        do {
            try await AuthenticationActor.shared.saveSynologyPassword(draft)
            synologyPasswordDraft = ""
            synologyPasswordSaved = true
            secretError = nil
        } catch {
            secretError = "Could not save the Synology password."
        }
    }

    private func removeSynologyPassword() async {
        do {
            try await AuthenticationActor.shared.deleteSynologyPassword()
            synologyPasswordDraft = ""
            synologyPasswordSaved = false
            synologyStatus = nil
            secretError = nil
        } catch {
            secretError = "Could not remove the Synology password."
        }
    }

    private func saveTorBoxarrPassword() async {
        let draft = torboxarrPasswordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        do {
            try await AuthenticationActor.shared.saveTorBoxarrPassword(draft)
            torboxarrPasswordDraft = ""
            torboxarrPasswordSaved = true
            secretError = nil
        } catch {
            secretError = "Could not save the TorBox password."
        }
    }

    private func removeTorBoxarrPassword() async {
        do {
            try await AuthenticationActor.shared.deleteTorBoxarrPassword()
            torboxarrPasswordDraft = ""
            torboxarrPasswordSaved = false
            torboxarrStatus = nil
            secretError = nil
        } catch {
            secretError = "Could not remove the TorBox password."
        }
    }

    private func testTorBoxarr() async {
        checking = "torboxarr"
        torboxarrStatus = nil
        defer { checking = nil }
        persistTorBoxarr()
        await saveTorBoxarrPassword()
        let password = (try? await AuthenticationActor.shared.loadTorBoxarrPassword()) ?? ""
        guard !password.isEmpty else {
            secretError = NASHandoffError.backendNotConfigured(.torbox).message
            return
        }
        secretError = nil
        let settings = TorBoxarrConnectionSettings.current()
        torboxarrStatus = await TorBoxarrProbe.testConnection(settings: settings, password: password)
    }

    private func testTorBox() async {
        checking = "torbox"
        torboxStatus = nil
        defer { checking = nil }
        persist()
        await saveTorBoxAPIKey()
        let key = (try? await AuthenticationActor.shared.loadTorBoxAPIKey()) ?? ""
        torboxStatus = await TorBoxClient().testConnection(apiKey: key)
    }

    private func testQBittorrent() async {
        checking = "qbittorrent"
        qbStatus = nil
        defer { checking = nil }
        persist()
        await saveQBittorrentPassword()
        let password = (try? await AuthenticationActor.shared.loadQBittorrentPassword()) ?? ""
        qbStatus = await QBittorrentClient().testConnection(
            baseURL: snapshot.qbittorrentBaseURL,
            username: snapshot.qbittorrentUsername,
            password: password,
        )
    }

    private func testDeluge() async {
        checking = "deluge"
        delugeStatus = nil
        defer { checking = nil }
        persist()
        let password = (try? await AuthenticationActor.shared.loadDelugePassword()) ?? ""
        delugeStatus = await DelugeWebClient().testConnection(
            baseURL: snapshot.delugeBaseURL,
            password: password,
        )
    }

    private func testSynology() async {
        checking = "synology"
        synologyStatus = nil
        defer { checking = nil }
        persist()
        await saveSynologyPassword()
        let password = (try? await AuthenticationActor.shared.loadSynologyPassword()) ?? ""
        synologyStatus = await SynologyFileStationClient().testConnection(
            baseURL: snapshot.synologyBaseURL,
            username: snapshot.synologyUsername,
            password: password,
        )
    }
}

#endif
