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
                "Configure torrent clients, Synology upload, and destination folders. Active jobs live in Downloads."
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
    @State private var qbStatus: QBittorrentConnection?
    @State private var synologyStatus: SynologyConnection?
    @State private var delugeStatus: DelugeConnection?
    @State private var checking: String?
    @State private var secretError: String?

    var body: some View {
        List {
            Section {
                Picker("Torrent client", selection: torrentClientBinding) {
                    ForEach(NASTorrentClient.allCases, id: \.self) { client in
                        Text(client.label).tag(client)
                    }
                }
                Toggle("Start downloads automatically", isOn: startAutomaticallyBinding)
                Toggle("Create title/author subfolders", isOn: subfoldersBinding)
            } header: {
                Text("Routing")
            } footer: {
                Text(
                    "Torrents and magnets go to the selected torrent client. Direct HTTP files download locally, then upload to Synology. Subfolders stay under the configured folder."
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
                Text("The app picks the folder from the book type. You do not choose it each time.")
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
                    "Reuses the existing Deluge WebUI password from Settings. Used for magnet links and .torrent URLs when Deluge is selected."
                )
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
                    "Direct files upload through the DSM File Station API. Volume paths such as /volume1/media/… are converted to share paths automatically."
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
            let qbDraft = qbPasswordDraft
            let synologyDraft = synologyPasswordDraft
            Task {
                if !qbDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try? await AuthenticationActor.shared.saveQBittorrentPassword(qbDraft)
                }
                if !synologyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try? await AuthenticationActor.shared.saveSynologyPassword(synologyDraft)
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

    private var synologyURLBinding: Binding<String> {
        Binding(get: { snapshot.synologyBaseURL }, set: { snapshot.synologyBaseURL = $0 })
    }

    private var synologyUserBinding: Binding<String> {
        Binding(get: { snapshot.synologyUsername }, set: { snapshot.synologyUsername = $0 })
    }

    private func persist() {
        NASDownloadSettingsStore.shared.replace(snapshot)
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
