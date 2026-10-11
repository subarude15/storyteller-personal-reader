#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI

struct RaveBSDSettingsSection: View {
    @Binding var enabled: Bool
    @Binding var localURL: String
    @Binding var remoteURL: String
    @Binding var defaultProvider: String

    @State private var apiKeyDraft = ""
    @State private var keySaved = false
    @State private var keyError: String?
    @State private var testing = false
    @State private var connectionStatus: RaveBSDConnectionStatus?

    var body: some View {
        Section {
            Toggle("Enabled", isOn: $enabled)
            TextField(
                "Local URL",
                text: $localURL,
                prompt: Text(RaveBSDURL.defaultLocal),
            )
            .textContentType(.URL)
            #if os(iOS)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()

            TextField(
                "Remote URL",
                text: $remoteURL,
                prompt: Text(RaveBSDURL.defaultRemote),
            )
            .textContentType(.URL)
            #if os(iOS)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()

            SecureField(
                "API key (optional)",
                text: $apiKeyDraft,
                prompt: Text(keySaved ? "Saved — enter a new key to replace" : "X-API-Key if set on server"),
            )
            .textContentType(.password)
            if keySaved {
                Text("API key saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let keyError {
                Text(keyError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Save key") { Task { await saveKey() } }
                    .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if keySaved {
                    Button("Remove key", role: .destructive) { Task { await removeKey() } }
                }
            }

            Picker("Default search", selection: $defaultProvider) {
                ForEach(BookSearchProviderKind.allCases, id: \.rawValue) { kind in
                    Text(kind.displayName).tag(kind.rawValue)
                }
            }

            Button {
                Task { await testConnection() }
            } label: {
                if testing {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Label("Test Connection", systemImage: "network")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(testing || !enabled)

            if let connectionStatus {
                HStack(alignment: .top, spacing: 8) {
                    Image(
                        systemName: connectionStatus.isSuccess
                            ? "checkmark.circle.fill" : "xmark.circle.fill"
                    )
                    .foregroundStyle(connectionStatus.isSuccess ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connectionStatus.title)
                        Text(connectionStatus.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("RaveBSD")
        } footer: {
            Text(
                "Self-hosted book search. Local is preferred on home Wi‑Fi; remote is used when local is unreachable. RaveBSD has no login of its own — optional API key is only for /api/v1/search. Cloudflare Access challenges cannot be solved in-app."
            )
        }
        .task { await refreshKeyState() }
    }

    private func refreshKeyState() async {
        keySaved = await AuthenticationActor.shared.hasRaveBSDAPIKey()
    }

    private func saveKey() async {
        do {
            try await AuthenticationActor.shared.saveRaveBSDAPIKey(apiKeyDraft)
            apiKeyDraft = ""
            keyError = nil
            await refreshKeyState()
        } catch {
            keyError = "Could not save the API key."
        }
    }

    private func removeKey() async {
        do {
            try await AuthenticationActor.shared.deleteRaveBSDAPIKey()
            keyError = nil
            await refreshKeyState()
        } catch {
            keyError = "Could not remove the API key."
        }
    }

    private func testConnection() async {
        testing = true
        defer { testing = false }
        let apiKey = (try? await AuthenticationActor.shared.loadRaveBSDAPIKey()) ?? ""
        let client = RaveBSDClient()
        let selection = await RaveBSDEndpointRouting.resolveLive(
            localURL: localURL,
            remoteURL: remoteURL,
        )
        guard let selection else {
            connectionStatus = .invalidEndpoint(detail: "Enter a valid local or remote URL")
            return
        }
        var status = await client.testConnection(baseURL: selection.baseURL, apiKey: apiKey)
        // If preferred endpoint failed with CF and the other exists, try it once for the test UI.
        if !status.isSuccess {
            let others = RaveBSDEndpointRouting.orderedBases(localURL: localURL, remoteURL: remoteURL)
                .filter { $0.baseURL != selection.baseURL }
            for other in others {
                let next = await client.testConnection(baseURL: other.baseURL, apiKey: apiKey)
                if next.isSuccess {
                    status = next
                    break
                }
                status = next
            }
        }
        connectionStatus = status
    }
}
#endif
