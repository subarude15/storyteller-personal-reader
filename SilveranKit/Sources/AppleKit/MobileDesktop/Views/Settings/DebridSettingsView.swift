#if os(iOS) || os(macOS)
import PlaytorioFetcher
import SilveranKit
import SwiftUI

/// Settings → Debrid Settings: TorBox API key in Keychain.
public struct DebridSettingsView: View {
    @State private var apiKey: String = ""
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var hasStoredKey = false

    public init() {}

    public var body: some View {
        Form {
            Section {
                SecureField("TorBox API Key", text: $apiKey)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                #endif

                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Save API Key")
                    }
                }
                .disabled(isSaving)

                Button {
                    Task { await testKey() }
                } label: {
                    if isTesting {
                        ProgressView()
                    } else {
                        Text("Test connection")
                    }
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTesting)

                if hasStoredKey {
                    Button("Clear stored key", role: .destructive) {
                        Task { await clear() }
                    }
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                }
            } header: {
                Text("TorBox")
            } footer: {
                Text("API key is stored in the device Keychain. Create one at torbox.app → Settings → API. Used to resolve magnet links into direct downloads for Storyteller ingest.")
            }
        }
        .navigationTitle("Debrid Settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await reload() }
    }

    private func reload() async {
        do {
            let stored = try await AuthenticationActor.shared.loadTorBoxAPIKey()
            hasStoredKey = !(stored ?? "").isEmpty
            if apiKey.isEmpty, let stored, !stored.isEmpty {
                apiKey = stored
            }
        } catch {
            statusIsError = true
            statusMessage = "Couldn't read Keychain."
        }
    }

    private func save() async {
        isSaving = true
        statusIsError = false
        defer { isSaving = false }
        do {
            try await AuthenticationActor.shared.saveTorBoxAPIKey(apiKey)
            hasStoredKey = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            statusMessage = hasStoredKey ? "TorBox API key saved." : "TorBox API key cleared."
        } catch {
            statusIsError = true
            statusMessage = "Couldn't save to Keychain."
        }
    }

    private func clear() async {
        do {
            try await AuthenticationActor.shared.deleteTorBoxAPIKey()
            apiKey = ""
            hasStoredKey = false
            statusIsError = false
            statusMessage = "TorBox API key cleared."
        } catch {
            statusIsError = true
            statusMessage = "Couldn't clear Keychain."
        }
    }

    private func testKey() async {
        isTesting = true
        statusIsError = false
        defer { isTesting = false }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            statusIsError = true
            statusMessage = TorBoxError.missingAPIKey.localizedDescription
            return
        }
        do {
            try await TorBoxClient(apiKey: key).validateAPIKey()
            statusMessage = "TorBox authentication OK."
        } catch {
            statusIsError = true
            statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Ingest menu: paste magnet → TorBox resolve → Storyteller upload (background-capable).
public struct TorBoxMagnetImportView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var magnet: String = ""
    @State private var status: String?
    @State private var statusIsError = false
    @State private var isRunning = false
    @State private var phaseLabel: String?

    public init() {}

    public var body: some View {
        Form {
            Section {
                TextField("magnet:?xt=urn:btih:…", text: $magnet, axis: .vertical)
                    .lineLimit(3 ... 8)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                #endif

                Button {
                    Task { await startImport(leaveWhenQueued: false) }
                } label: {
                    if isRunning {
                        ProgressView()
                    } else {
                        Text("Resolve & Import")
                    }
                }
                .disabled(isRunning || magnet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    Task { await startImport(leaveWhenQueued: true) }
                } label: {
                    Text("Import in background")
                }
                .disabled(isRunning || magnet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let phaseLabel {
                    Text(phaseLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let status {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                }
            } header: {
                Text("Magnet link")
            } footer: {
                Text("Resolves via TorBox, then uploads the preferred file to your Storyteller source. You can leave after “Import in background”; progress continues and posts a toast when done.")
            }
        }
        .navigationTitle("Import via TorBox")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func startImport(leaveWhenQueued: Bool) async {
        let trimmed = magnet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TorBoxClient.isValidMagnet(trimmed) else {
            statusIsError = true
            status = TorBoxError.malformedMagnet.localizedDescription
            NotificationCenter.default.post(
                name: .punkRallyTorBoxIngestFailed,
                object: nil,
                userInfo: ["message": TorBoxError.malformedMagnet.localizedDescription]
            )
            return
        }

        let apiKey: String
        do {
            guard let key = try await AuthenticationActor.shared.loadTorBoxAPIKey(), !key.isEmpty else {
                statusIsError = true
                status = TorBoxError.missingAPIKey.localizedDescription
                NotificationCenter.default.post(
                    name: .punkRallyTorBoxIngestFailed,
                    object: nil,
                    userInfo: ["message": TorBoxError.missingAPIKey.localizedDescription]
                )
                return
            }
            apiKey = key
        } catch {
            statusIsError = true
            status = "Couldn't read TorBox API key."
            return
        }

        isRunning = true
        statusIsError = false
        status = nil
        phaseLabel = "Resolving via TorBox…"

        let jobMagnet = trimmed
        let jobKey = apiKey

        if leaveWhenQueued {
            TorBoxIngestCoordinator.shared.enqueue(magnet: jobMagnet, apiKey: jobKey)
            statusIsError = false
            status = "Queued — you can leave. TorBox → Server → Library runs in the background."
            isRunning = false
            dismiss()
            return
        }

        do {
            let result = try await TorBoxIngestCoordinator.shared.runForeground(
                magnet: jobMagnet,
                apiKey: jobKey,
                onPhase: { phase in
                    Task { @MainActor in
                        phaseLabel = Self.label(for: phase)
                    }
                }
            )
            statusIsError = false
            status = "Imported “\(result.file.name)” to Library."
            phaseLabel = nil
            await BookServiceActor.shared.fetchLibraryInformation()
        } catch {
            statusIsError = true
            status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phaseLabel = nil
            NotificationCenter.default.post(
                name: .punkRallyTorBoxIngestFailed,
                object: nil,
                userInfo: ["message": status ?? "TorBox import failed"]
            )
        }
        isRunning = false
    }

    private static func label(for phase: TorBoxIngestCoordinator.Phase) -> String {
        switch phase {
        case .resolving: return "Resolving via TorBox…"
        case .waitingForCache: return "Resolving via TorBox… (downloading on TorBox)"
        case .downloadingFromTorBox: return "Downloading from TorBox…"
        case .sendingToServer: return "Sending to Server…"
        case .done: return "Done"
        }
    }
}

/// Background-capable magnet → TorBox → Storyteller upload jobs.
@MainActor
public final class TorBoxIngestCoordinator {
    public static let shared = TorBoxIngestCoordinator()

    public enum Phase: Equatable, Sendable {
        case resolving
        case waitingForCache
        case downloadingFromTorBox
        case sendingToServer
        case done
    }

    public struct Result: Sendable {
        public var file: TorBoxTorrentFile
        public var downloadURL: URL
        public var bookID: BookID
    }

    private var runningTasks: [UUID: Task<Void, Never>] = [:]

    private init() {}

    public func enqueue(magnet: String, apiKey: String) {
        let id = UUID()
        let task = Task { [weak self] in
            do {
                _ = try await self?.runForeground(magnet: magnet, apiKey: apiKey, onPhase: nil)
                NotificationCenter.default.post(
                    name: .punkRallyTorBoxIngestSucceeded,
                    object: nil,
                    userInfo: ["message": "TorBox import finished — check Library."]
                )
                await BookServiceActor.shared.fetchLibraryInformation()
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                NotificationCenter.default.post(
                    name: .punkRallyTorBoxIngestFailed,
                    object: nil,
                    userInfo: ["message": message]
                )
            }
            await MainActor.run {
                self?.runningTasks[id] = nil
            }
        }
        runningTasks[id] = task
    }

    public func runForeground(
        magnet: String,
        apiKey: String,
        onPhase: (@Sendable (Phase) -> Void)?
    ) async throws -> Result {
        let resolved = try await TorBoxMagnetResolver.resolve(
            magnet: magnet,
            apiKey: apiKey,
            onPhase: { resolverPhase in
                switch resolverPhase {
                case .resolving: onPhase?(.resolving)
                case .waitingForCache: onPhase?(.waitingForCache)
                case .ready: break
                }
            }
        )

        onPhase?(.downloadingFromTorBox)
        let data = try await TorBoxMagnetResolver.downloadFile(from: resolved.downloadURL)

        onPhase?(.sendingToServer)
        let sourceID = try await resolveUploadSourceID()
        let filename = sanitizedFilename(resolved.file.name)
        let isEbook = TorBoxMagnetResolver.isEbookFilename(filename)
        let isAudio = TorBoxMagnetResolver.isAudiobookFilename(filename)
        let format: StorytellerBookFormat = isAudio && !isEbook ? .audiobook : .ebook
        let asset = StorytellerUploadAsset(
            format: format,
            filename: filename,
            data: data,
            contentType: TorBoxMagnetResolver.contentType(for: filename),
            relativePath: nil
        )

        let bookID = BookID(sourceID: sourceID, uuid: UUID().uuidString)
        let ebook: StorytellerUploadAsset? = format == .ebook ? asset : nil
        let audiobooks: [StorytellerUploadAsset] = format == .audiobook ? [asset] : []
        let success = await BookServiceActor.shared.uploadBookAssets(
            bookID: bookID,
            ebook: ebook,
            audiobooks: audiobooks,
            readaloud: nil,
            onProgress: nil
        )
        guard success else {
            throw TorBoxError.api(message: "Couldn't upload to Storyteller. Check Wi‑Fi / LAN and try again.")
        }
        onPhase?(.done)
        return Result(file: resolved.file, downloadURL: resolved.downloadURL, bookID: bookID)
    }

    private func resolveUploadSourceID() async throws -> BookSourceID {
        let sources = await BookServiceActor.shared.bookSources
            .filter { $0.capabilities.canUploadBooks }
            .sorted { lhs, rhs in
                if lhs.kind == .storyteller && rhs.kind != .storyteller { return true }
                if lhs.kind != .storyteller && rhs.kind == .storyteller { return false }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        if let preferred = sources.first(where: { $0.kind == .storyteller }) {
            return preferred.id
        }
        if let first = sources.first {
            return first.id
        }
        throw TorBoxError.api(message: "Add a Storyteller source in Settings before importing.")
    }

    private func sanitizedFilename(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "torbox-import.bin" : String(cleaned.prefix(120))
    }
}
#endif
