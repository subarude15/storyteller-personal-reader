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

#if os(iOS)
struct InkAmpPortableBackupPayload: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var createdAt: Date
    var appVersion: String
    var settings: SilveranGlobalConfig
    var storytellerSources: [BookSourceRecord]
    var credentials: AuthenticationActor.PortableBackup
    var syncedSettings: SyncedAppSettings?
    var bookFormatLinkCache: [String: Data]
}

struct InkAmpEncryptedBackupEnvelope: Codable {
    var format: String
    var schemaVersion: Int
    var kdf: String
    var iterations: Int
    var salt: Data
    var sealedPayload: Data
}

private enum InkAmpPortableBackupError: LocalizedError {
    case passwordTooShort
    case passwordMismatch
    case invalidFile
    case unsupportedSchema(Int)
    case decryptionFailed

    var errorDescription: String? {
        switch self {
            case .passwordTooShort:
                return "Use a backup password with at least 8 characters."
            case .passwordMismatch:
                return "The two backup passwords do not match."
            case .invalidFile:
                return "This is not a valid ink+amp backup file."
            case .unsupportedSchema(let version):
                return "This backup uses unsupported format version \(version)."
            case .decryptionFailed:
                return "The password is incorrect, or the backup file is damaged."
        }
    }
}

private enum InkAmpPortableBackupCrypto {
    static let format = "inkamp-encrypted-backup"
    static let iterations = 120_000

    static func seal(_ plaintext: Data, passphrase: String) throws -> Data {
        var generator = SystemRandomNumberGenerator()
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else {
            throw InkAmpPortableBackupError.invalidFile
        }
        let envelope = InkAmpEncryptedBackupEnvelope(
            format: format,
            schemaVersion: 1,
            kdf: "PBKDF2-HMAC-SHA256",
            iterations: iterations,
            salt: salt,
            sealedPayload: combined
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    static func open(_ encrypted: Data, passphrase: String) throws -> Data {
        let envelope: InkAmpEncryptedBackupEnvelope
        do {
            envelope = try JSONDecoder().decode(InkAmpEncryptedBackupEnvelope.self, from: encrypted)
        } catch {
            throw InkAmpPortableBackupError.invalidFile
        }
        guard envelope.format == format,
            envelope.schemaVersion == 1,
            envelope.kdf == "PBKDF2-HMAC-SHA256",
            envelope.iterations >= 10_000,
            envelope.iterations <= 1_000_000,
            envelope.salt.count >= 16
        else {
            throw InkAmpPortableBackupError.invalidFile
        }

        do {
            let key = try deriveKey(
                passphrase: passphrase,
                salt: envelope.salt,
                iterations: envelope.iterations
            )
            return try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealedPayload), using: key)
        } catch {
            throw InkAmpPortableBackupError.decryptionFailed
        }
    }

    private static func deriveKey(
        passphrase: String,
        salt: Data,
        iterations: Int
    ) throws -> SymmetricKey {
        guard !passphrase.isEmpty, iterations > 0 else {
            throw InkAmpPortableBackupError.invalidFile
        }
        let normalized = passphrase.precomposedStringWithCanonicalMapping
        let passwordKey = SymmetricKey(data: Data(normalized.utf8))
        var firstBlock = Data(salt)
        firstBlock.append(contentsOf: [0, 0, 0, 1])

        var previous = Array(
            HMAC<SHA256>.authenticationCode(for: firstBlock, using: passwordKey)
        )
        var derived = previous
        if iterations > 1 {
            for _ in 2...iterations {
                previous = Array(
                    HMAC<SHA256>.authenticationCode(
                        for: Data(previous),
                        using: passwordKey
                    )
                )
                for index in derived.indices {
                    derived[index] ^= previous[index]
                }
            }
        }
        return SymmetricKey(data: Data(derived))
    }
}

private enum InkAmpPortableBackupCoordinator {
    static func create(passphrase: String) async throws -> Data {
        guard passphrase.count >= 8 else {
            throw InkAmpPortableBackupError.passwordTooShort
        }

        let allSources = await BookServiceActor.shared.bookSources
        let storytellerSources = allSources.filter { $0.kind == .storyteller }
        let credentials = try await AuthenticationActor.shared.makePortableBackup(
            sourceIDs: storytellerSources.map(\.id)
        )
        let settings = await SettingsActor.shared.config
        let syncedSettings = SettingsSyncJournal.live().load()

        var bookFormatLinkCache: [String: Data] = [:]
        for source in storytellerSources {
            let key = "punkRally.bookFormatLinks.v1.\(source.id)"
            if let value = UserDefaults.standard.data(forKey: key) {
                bookFormatLinkCache[source.id] = value
            }
        }

        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
        let payload = InkAmpPortableBackupPayload(
            schemaVersion: InkAmpPortableBackupPayload.currentSchemaVersion,
            createdAt: Date(),
            appVersion: version,
            settings: settings,
            storytellerSources: storytellerSources,
            credentials: credentials,
            syncedSettings: syncedSettings,
            bookFormatLinkCache: bookFormatLinkCache
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(payload)

        return try await Task.detached(priority: .userInitiated) {
            try InkAmpPortableBackupCrypto.seal(plaintext, passphrase: passphrase)
        }.value
    }

    static func restore(_ encrypted: Data, passphrase: String) async throws -> Int {
        guard !passphrase.isEmpty else {
            throw InkAmpPortableBackupError.passwordTooShort
        }
        let plaintext = try await Task.detached(priority: .userInitiated) {
            try InkAmpPortableBackupCrypto.open(encrypted, passphrase: passphrase)
        }.value

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload: InkAmpPortableBackupPayload
        do {
            payload = try decoder.decode(InkAmpPortableBackupPayload.self, from: plaintext)
        } catch {
            throw InkAmpPortableBackupError.invalidFile
        }
        guard payload.schemaVersion == InkAmpPortableBackupPayload.currentSchemaVersion else {
            throw InkAmpPortableBackupError.unsupportedSchema(payload.schemaVersion)
        }

        // Restore credentials before rebuilding source actors so each Storyteller
        // source can configure itself from the restored Keychain values.
        try await AuthenticationActor.shared.restorePortableBackup(payload.credentials)
        try await SettingsActor.shared.restorePortableBackupConfig(payload.settings)

        if let syncedSettings = payload.syncedSettings {
            let journal = SettingsSyncJournal.live()
            try journal.save(syncedSettings)
            journal.migrationCompleted = true
            journal.needsSync = true
            await MainActor.run {
                ManualSearchSettingsStore.shared.applySynced(
                    SettingsSyncApply.manualSearch(document: syncedSettings)
                )
                NASDownloadSettingsStore.shared.applySynced(
                    SettingsSyncApply.nasDownloads(document: syncedSettings)
                )
            }
        }

        for (sourceID, value) in payload.bookFormatLinkCache {
            UserDefaults.standard.set(value, forKey: "punkRally.bookFormatLinks.v1.\(sourceID)")
        }

        try await BookServiceActor.shared.restorePortableBackupSources(
            payload.storytellerSources
        )

        // No widget snapshot is present in the portable backup. Clear anything
        // an external container restore may have injected, then let the normal
        // library refresh publish a fresh snapshot.
        SilveranWidgetSnapshotStore.resetTransientStateAfterExternalRestore()
        ContinueWidgetSnapshotStore.resetLocalFallbackAfterExternalRestore()
        await ContinueWidgetSnapshotStore.publishFromLiveSession()
        return payload.credentials.storyteller.count
    }
}

struct InkAmpBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    static var writableContentTypes: [UTType] { [.data] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw InkAmpPortableBackupError.invalidFile
        }
        self.data = data
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct InkAmpBackupView: View {
    @State private var password = ""
    @State private var confirmation = ""
    @State private var isWorking = false
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var exportDocument: InkAmpBackupDocument?
    @State private var statusMessage: String?
    @State private var statusIsError = false

    var body: some View {
        Form {
            Section {
                SecureField("Backup password", text: $password)
                    .textContentType(.newPassword)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                SecureField("Confirm for export", text: $confirmation)
                    .textContentType(.newPassword)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Encryption")
            } footer: {
                Text("You will need this password to restore on this or another device. It is never written into the backup file.")
            }

            Section("Backup") {
                Button {
                    createBackup()
                } label: {
                    Label("Create Encrypted Backup", systemImage: "square.and.arrow.up")
                }
                .disabled(isWorking)

                Button {
                    isImporting = true
                } label: {
                    Label("Restore Encrypted Backup", systemImage: "square.and.arrow.down")
                }
                .disabled(isWorking || password.isEmpty)
            }

            Section {
                Label("Storyteller accounts and passwords", systemImage: "person.crop.circle.badge.checkmark")
                Label("API keys and service logins", systemImage: "key")
                Label("Reader, playback, sync, search, and NAS settings", systemImage: "gearshape.2")
                Label("Book-format link cache", systemImage: "link")
            } header: {
                Text("Included")
            }

            Section {
                Label("Widget snapshots and cover thumbnails", systemImage: "rectangle.slash")
                Label("Downloaded books, podcasts, and staged torrents", systemImage: "arrow.down.circle")
                Label("Temporary caches and App Group handoff queues", systemImage: "trash")
            } header: {
                Text("Rebuilt, not restored")
            } footer: {
                Text("Excluding generated widget state prevents an AltStore data restore from putting the broken snapshot back.")
            }

            if isWorking {
                Section {
                    HStack {
                        ProgressView()
                        Text("Encrypting or restoring…")
                    }
                }
            }

            if let statusMessage {
                Section {
                    Label(
                        statusMessage,
                        systemImage: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                    )
                    .foregroundStyle(statusIsError ? .red : .green)
                }
            }
        }
        .navigationTitle("Local Backup")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .data,
            defaultFilename: defaultFilename
        ) { result in
            switch result {
                case .success:
                    setStatus("Encrypted backup saved.", isError: false)
                case .failure(let error):
                    setStatus(error.localizedDescription, isError: true)
            }
            exportDocument = nil
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    restoreBackup(from: url)
                case .failure(let error):
                    setStatus(error.localizedDescription, isError: true)
            }
        }
    }

    private var defaultFilename: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "inkamp-backup-\(formatter.string(from: Date())).inkampbackup"
    }

    private func createBackup() {
        guard password.count >= 8 else {
            setStatus(InkAmpPortableBackupError.passwordTooShort.localizedDescription, isError: true)
            return
        }
        guard password == confirmation else {
            setStatus(InkAmpPortableBackupError.passwordMismatch.localizedDescription, isError: true)
            return
        }

        isWorking = true
        statusMessage = nil
        Task {
            defer { isWorking = false }
            do {
                let data = try await InkAmpPortableBackupCoordinator.create(passphrase: password)
                exportDocument = InkAmpBackupDocument(data: data)
                isExporting = true
            } catch {
                setStatus(error.localizedDescription, isError: true)
            }
        }
    }

    private func restoreBackup(from url: URL) {
        isWorking = true
        statusMessage = nil
        Task {
            defer { isWorking = false }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                let loginCount = try await InkAmpPortableBackupCoordinator.restore(
                    data,
                    passphrase: password
                )
                setStatus(
                    "Restore complete. Restored \(loginCount) Storyteller login\(loginCount == 1 ? "" : "s"); widget data will rebuild fresh.",
                    isError: false
                )
            } catch {
                setStatus(error.localizedDescription, isError: true)
            }
        }
    }

    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }
}
#endif

#endif
