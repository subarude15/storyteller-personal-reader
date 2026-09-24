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

struct LazyLibrarianSettingsSection: View {
    @Binding var enabled: Bool
    @Binding var baseURL: String
    @State private var keyDraft = ""
    @State private var keySaved = false
    @State private var status: LazyLibrarianConnection?
    @State private var keyError: String?
    @State private var checking = false
    @State private var syncStatus: SettingsSyncStatus = .offlineWillSyncLater
    @State private var automaticMatching = LazyLibrarianMatchingSettings.preference

    private var integrationConfigured: Bool {
        enabled || !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var credentialNote: String {
        if syncStatus == .synced {
            return "Integration settings synced. API credential is stored securely on this device."
        }
        return "API credential is stored securely on this device."
    }

    var body: some View {
        Section {
            Toggle("Enabled", isOn: $enabled)
            Picker(
                "Automatic matching",
                selection: Binding(
                    get: { automaticMatching },
                    set: { value in
                        automaticMatching = value
                        LazyLibrarianMatchingSettings.preference = value
                    },
                ),
            ) {
                ForEach(LazyLibrarianAutomaticMatching.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            Text(
                "Exact title and author matches can still proceed when you ask to confirm uncertain ones. Automatic mode takes a uniquely stronger match and leaves a tie for review. Title-only results are never chosen automatically."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            TextField(
                "Server URL",
                text: $baseURL,
                prompt: Text("https://host:5299"),
            )
            .textContentType(.URL)
            .autocorrectionDisabled()
            #if os(iOS)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            #endif
            SecureField(
                "API Key",
                text: $keyDraft,
                prompt: Text(keySaved ? "Saved — enter a new key to replace" : "API key"),
            )
            .textContentType(.password)
            .onSubmit { Task { await saveDraft() } }
            if keySaved, keyDraft.isEmpty {
                Text("API key saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Remove API Key", role: .destructive) {
                    Task { await removeKey() }
                }
            }
            Button {
                Task { await test() }
            } label: {
                Label(checking ? "Testing…" : "Test Connection", systemImage: "network")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(checking)
            if let keyError {
                Text(keyError)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let status {
                HStack {
                    Image(systemName: status == .ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(status == .ok ? .green : .red)
                    Text(status == .ok ? "Connected" : status.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                guard syncStatus != .syncing else { return }
                Task { await SettingsSyncCoordinator.shared.syncNow(reason: "settingsRetry") }
            } label: {
                Text(syncStatus.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(syncStatus == .syncing)
            .accessibilityHint("Retries settings sync")
        } header: {
            Text("LazyLibrarian")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    "The API key is stored in the keychain and is not shown again after it is saved. Test Connection does not change the LazyLibrarian library."
                )
                if integrationConfigured {
                    Text(credentialNote)
                }
            }
        }
        .task {
            keySaved = await AuthenticationActor.shared.hasLazyLibrarianAPIKey()
            let current = await MainActor.run { SettingsSyncCoordinator.shared.status }
            syncStatus = current
        }
        .onReceive(NotificationCenter.default.publisher(for: .inkampSettingsSyncStatusDidChange)) { _ in
            Task { @MainActor in
                syncStatus = SettingsSyncCoordinator.shared.status
            }
        }
        .onDisappear {
            let draft = keyDraft
            guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Task {
                try? await AuthenticationActor.shared.saveLazyLibrarianAPIKey(draft)
            }
        }
    }

    private func saveDraft() async {
        let draft = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        do {
            try await AuthenticationActor.shared.saveLazyLibrarianAPIKey(draft)
            keyDraft = ""
            keySaved = true
            keyError = nil
        } catch {
            keyError = "Could not save the API key."
        }
    }

    private func removeKey() async {
        do {
            try await AuthenticationActor.shared.deleteLazyLibrarianAPIKey()
            keyDraft = ""
            keySaved = false
            keyError = nil
            status = nil
        } catch {
            keyError = "Could not remove the API key."
        }
    }

    private func test() async {
        checking = true
        keyError = nil
        status = nil
        defer { checking = false }
        await saveDraft()
        if keyError != nil { return }
        let key = (try? await AuthenticationActor.shared.loadLazyLibrarianAPIKey()) ?? ""
        status = await LazyLibrarianClient().testConnection(baseURL: baseURL, apiKey: key)
    }
}

struct DelugeSettingsSection: View {
    @Binding var enabled: Bool
    @Binding var baseURL: String
    @State private var passwordDraft = ""
    @State private var passwordSaved = false
    @State private var status: DelugeConnection?
    @State private var passwordError: String?
    @State private var checking = false

    var body: some View {
        Section {
            Toggle("Enabled", isOn: $enabled)
            TextField(
                "Server URL",
                text: $baseURL,
                prompt: Text("http://host:8112"),
            )
            .textContentType(.URL)
            .autocorrectionDisabled()
            #if os(iOS)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            #endif
            SecureField(
                "Password",
                text: $passwordDraft,
                prompt: Text(passwordSaved ? "Saved — enter a new password to replace" : "WebUI password"),
            )
            .textContentType(.password)
            .onSubmit { Task { await saveDraft() } }
            if passwordSaved, passwordDraft.isEmpty {
                Text("Password saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Remove Password", role: .destructive) {
                    Task { await removePassword() }
                }
            }
            Button {
                Task { await test() }
            } label: {
                Label(checking ? "Testing…" : "Test Connection", systemImage: "network")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(checking)
            if let passwordError {
                Text(passwordError)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let status {
                HStack {
                    Image(systemName: status == .ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(status == .ok ? .green : .red)
                    Text(status.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Deluge")
        } footer: {
            Text(
                "Read-only download observability for LazyLibrarian. The WebUI password is stored in the keychain. Test Connection never adds, pauses, or removes torrents."
            )
        }
        .onChange(of: baseURL) { _, newValue in
            NASDownloadSettingsStore.shared.setDelugeBaseURL(newValue)
        }
        .task {
            passwordSaved = await AuthenticationActor.shared.hasDelugePassword()
        }
        .onDisappear {
            let draft = passwordDraft
            guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Task {
                try? await AuthenticationActor.shared.saveDelugePassword(draft)
            }
        }
    }

    private func saveDraft() async {
        let draft = passwordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        do {
            try await AuthenticationActor.shared.saveDelugePassword(draft)
            passwordDraft = ""
            passwordSaved = true
            passwordError = nil
        } catch {
            passwordError = "Could not save the password."
        }
    }

    private func removePassword() async {
        do {
            try await AuthenticationActor.shared.deleteDelugePassword()
            passwordDraft = ""
            passwordSaved = false
            passwordError = nil
            status = nil
        } catch {
            passwordError = "Could not remove the password."
        }
    }

    private func test() async {
        checking = true
        passwordError = nil
        status = nil
        defer { checking = false }
        await saveDraft()
        if passwordError != nil { return }
        let password = (try? await AuthenticationActor.shared.loadDelugePassword()) ?? ""
        status = await DelugeWebClient().testConnection(baseURL: baseURL, password: password)
    }
}

/// Optional indexer service. URL stays in config; the API key stays in the keychain.
struct IndexerServiceSettingsSection: View {
    var title: String
    var urlPrompt: String
    var footer: String
    @Binding var enabled: Bool
    @Binding var baseURL: String
    var hasKey: () async -> Bool
    var saveKey: (String) async throws -> Void
    var deleteKey: () async throws -> Void

    @State private var keyDraft = ""
    @State private var keySaved = false
    @State private var keyError: String?

    var body: some View {
        Section {
            Toggle("Enabled", isOn: $enabled)
            TextField("Server URL", text: $baseURL, prompt: Text(urlPrompt))
                .textContentType(.URL)
                .autocorrectionDisabled()
            #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
            #endif
            SecureField(
                "API Key",
                text: $keyDraft,
                prompt: Text(keySaved ? "Saved — enter a new key to replace" : "API key"),
            )
            .textContentType(.password)
            .onSubmit { Task { await saveDraft() } }
            if keySaved, keyDraft.isEmpty {
                Text("API key saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Remove API Key", role: .destructive) {
                    Task { await removeKey() }
                }
            }
            if let keyError {
                Text(keyError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
        .task { keySaved = await hasKey() }
        .onDisappear {
            let draft = keyDraft
            guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Task { try? await saveKey(draft) }
        }
    }

    private func saveDraft() async {
        let draft = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else { return }
        do {
            try await saveKey(draft)
            keyDraft = ""
            keySaved = true
            keyError = nil
        } catch {
            keyError = "Could not save the API key."
        }
    }

    private func removeKey() async {
        do {
            try await deleteKey()
            keyDraft = ""
            keySaved = false
            keyError = nil
        } catch {
            keyError = "Could not remove the API key."
        }
    }
}

#endif
