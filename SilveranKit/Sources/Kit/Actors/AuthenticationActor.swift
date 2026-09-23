import Foundation

@globalActor
public actor AuthenticationActor {
    public static let shared = AuthenticationActor()

    private let serverURLKey = "serverURL"
    private let lanURLKey = "lanURL"
    private let usernameKey = "username"
    private let passwordKey = "password"
    private let hardcoverTokenKey = "hardcoverToken"
    private let lazyLibrarianAPIKey = "lazyLibrarianAPIKey"
    private let prowlarrAPIKey = "prowlarrAPIKey"
    private let jackettAPIKey = "jackettAPIKey"
    private let delugePassword = "delugePassword"
    private let qbittorrentPassword = "qbittorrentPassword"
    private let synologyPassword = "synologyPassword"
    private let torboxAPIKey = "torboxAPIKey"
    private let torboxarrPassword = "torboxarrPassword"

    private init() {}

    private var keychain: any KeychainStoring {
        get throws {
            guard let keychain = SilveranPlatform.keychain else {
                throw KeychainError.unsupportedPlatform
            }
            return keychain
        }
    }

    public func saveCredentials(
        url: String,
        lanURL: String? = nil,
        username: String,
        password: String,
        sourceID: BookSourceID,
    ) async throws {
        try await deleteCredentials(sourceID: sourceID)

        try await saveString(url, for: accountKey(serverURLKey, sourceID: sourceID))
        try await saveString(username, for: accountKey(usernameKey, sourceID: sourceID))
        try await saveString(password, for: accountKey(passwordKey, sourceID: sourceID))
        // Persist LAN even when empty so "cleared" stays disabled (≠ missing → default).
        try await saveString(lanURL ?? "", for: accountKey(lanURLKey, sourceID: sourceID))
    }

    public func loadCredentials() async throws -> (url: String, username: String, password: String)?
    {
        guard let url = try await loadString(for: serverURLKey),
            let username = try await loadString(for: usernameKey),
            let password = try await loadString(for: passwordKey)
        else {
            return nil
        }

        return (url, username, password)
    }

    public func loadCredentials(sourceID: BookSourceID) async throws -> StorytellerSourceCredentials?
    {
        guard let url = try await loadString(for: accountKey(serverURLKey, sourceID: sourceID)),
            let username = try await loadString(for: accountKey(usernameKey, sourceID: sourceID)),
            let password = try await loadString(for: accountKey(passwordKey, sourceID: sourceID))
        else {
            return nil
        }

        // Missing key → nil (routing uses default). Present empty string → disabled.
        let lanURL: String?
        if try await keychain.item(account: accountKey(lanURLKey, sourceID: sourceID)) == nil {
            lanURL = nil
        } else {
            lanURL = try await loadString(for: accountKey(lanURLKey, sourceID: sourceID)) ?? ""
        }

        return StorytellerSourceCredentials(
            url: url,
            lanURL: lanURL,
            username: username,
            password: password,
        )
    }

    public func deleteCredentials() async throws {
        for key in [serverURLKey, usernameKey, passwordKey] {
            try await keychain.removeItem(account: key)
        }
    }

    public func deleteCredentials(sourceID: BookSourceID) async throws {
        for key in [serverURLKey, lanURLKey, usernameKey, passwordKey] {
            try await keychain.removeItem(account: accountKey(key, sourceID: sourceID))
        }
    }

    public func hasCredentials(sourceID: BookSourceID) async -> Bool {
        do {
            let creds = try await loadCredentials(sourceID: sourceID)
            return creds != nil
        } catch {
            return false
        }
    }

    public func saveHardcoverToken(_ token: String) async throws {
        try await saveString(token, for: hardcoverTokenKey)
    }

    public func loadHardcoverToken() async throws -> String? {
        try await loadString(for: hardcoverTokenKey)
    }

    public func deleteHardcoverToken() async throws {
        try await keychain.removeItem(account: hardcoverTokenKey)
    }

    public func saveLazyLibrarianAPIKey(_ key: String) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try await deleteLazyLibrarianAPIKey()
            return
        }
        try await saveString(trimmed, for: lazyLibrarianAPIKey)
    }

    public func loadLazyLibrarianAPIKey() async throws -> String? {
        try await loadString(for: lazyLibrarianAPIKey)
    }

    public func deleteLazyLibrarianAPIKey() async throws {
        try await keychain.removeItem(account: lazyLibrarianAPIKey)
    }

    public func hasLazyLibrarianAPIKey() async -> Bool {
        guard let key = try? await loadLazyLibrarianAPIKey() else { return false }
        return !key.isEmpty
    }

    public func saveProwlarrAPIKey(_ key: String) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try await deleteProwlarrAPIKey()
            return
        }
        try await saveString(trimmed, for: prowlarrAPIKey)
    }

    public func loadProwlarrAPIKey() async throws -> String? {
        try await loadString(for: prowlarrAPIKey)
    }

    public func deleteProwlarrAPIKey() async throws {
        try await keychain.removeItem(account: prowlarrAPIKey)
    }

    public func hasProwlarrAPIKey() async -> Bool {
        guard let key = try? await loadProwlarrAPIKey() else { return false }
        return !key.isEmpty
    }

    public func saveJackettAPIKey(_ key: String) async throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try await deleteJackettAPIKey()
            return
        }
        try await saveString(trimmed, for: jackettAPIKey)
    }

    public func loadJackettAPIKey() async throws -> String? {
        try await loadString(for: jackettAPIKey)
    }

    public func deleteJackettAPIKey() async throws {
        try await keychain.removeItem(account: jackettAPIKey)
    }

    public func hasJackettAPIKey() async -> Bool {
        guard let key = try? await loadJackettAPIKey() else { return false }
        return !key.isEmpty
    }

    public func saveDelugePassword(_ password: String) async throws {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try await deleteDelugePassword()
            return
        }
        try await saveString(trimmed, for: delugePassword)
    }

    public func loadDelugePassword() async throws -> String? {
        try await loadString(for: delugePassword)
    }

    public func deleteDelugePassword() async throws {
        try await keychain.removeItem(account: delugePassword)
    }

    public func hasDelugePassword() async -> Bool {
        guard let password = try? await loadDelugePassword() else { return false }
        return !password.isEmpty
    }

    public func saveQBittorrentPassword(_ password: String) async throws {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try await deleteQBittorrentPassword()
            return
        }
        try await saveString(trimmed, for: qbittorrentPassword)
    }

    public func loadQBittorrentPassword() async throws -> String? {
        try await loadString(for: qbittorrentPassword)
    }

    public func deleteQBittorrentPassword() async throws {
        try await keychain.removeItem(account: qbittorrentPassword)
    }

    public func hasQBittorrentPassword() async -> Bool {
        guard let password = try? await loadQBittorrentPassword() else { return false }
        return !password.isEmpty
    }

    public func saveSynologyPassword(_ password: String) async throws {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try await deleteSynologyPassword()
            return
        }
        try await saveString(trimmed, for: synologyPassword)
    }

    public func loadSynologyPassword() async throws -> String? {
        try await loadString(for: synologyPassword)
    }

    public func deleteSynologyPassword() async throws {
        try await keychain.removeItem(account: synologyPassword)
    }

    public func hasSynologyPassword() async -> Bool {
        guard let password = try? await loadSynologyPassword() else { return false }
        return !password.isEmpty
    }

    public func saveTorBoxAPIKey(_ apiKey: String) async throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try await deleteTorBoxAPIKey()
            return
        }
        try await saveString(trimmed, for: torboxAPIKey)
    }

    public func loadTorBoxAPIKey() async throws -> String? {
        try await loadString(for: torboxAPIKey)
    }

    public func deleteTorBoxAPIKey() async throws {
        try await keychain.removeItem(account: torboxAPIKey)
    }

    public func hasTorBoxAPIKey() async -> Bool {
        guard let key = try? await loadTorBoxAPIKey() else { return false }
        return !key.isEmpty
    }

    public func saveTorBoxarrPassword(_ password: String) async throws {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try await deleteTorBoxarrPassword()
            return
        }
        try await saveString(trimmed, for: torboxarrPassword)
    }

    public func loadTorBoxarrPassword() async throws -> String? {
        try await loadString(for: torboxarrPassword)
    }

    public func deleteTorBoxarrPassword() async throws {
        try await keychain.removeItem(account: torboxarrPassword)
    }

    public func hasTorBoxarrPassword() async -> Bool {
        guard let password = try? await loadTorBoxarrPassword() else { return false }
        return !password.isEmpty
    }

    public struct StorytellerCredentialBackup: Codable, Equatable, Sendable {
        public var sourceID: BookSourceID
        public var url: String
        public var lanURL: String?
        public var username: String
        public var password: String

        public init(
            sourceID: BookSourceID,
            url: String,
            lanURL: String?,
            username: String,
            password: String
        ) {
            self.sourceID = sourceID
            self.url = url
            self.lanURL = lanURL
            self.username = username
            self.password = password
        }
    }

    public struct LegacyStorytellerCredentialBackup: Codable, Equatable, Sendable {
        public var url: String
        public var username: String
        public var password: String
    }

    /// Explicit credential allowlist for an encrypted ink+amp backup.
    ///
    /// This intentionally exports values through the actor's typed accessors instead
    /// of dumping the Keychain database, which may contain unrelated app or signing
    /// records.
    public struct PortableBackup: Codable, Equatable, Sendable {
        public var storyteller: [StorytellerCredentialBackup]
        public var legacyStoryteller: LegacyStorytellerCredentialBackup?
        public var hardcoverToken: String?
        public var lazyLibrarianAPIKey: String?
        public var prowlarrAPIKey: String?
        public var jackettAPIKey: String?
        public var delugePassword: String?
        public var qbittorrentPassword: String?
        public var synologyPassword: String?
        public var torboxAPIKey: String?
        public var torboxarrPassword: String?

        public init(
            storyteller: [StorytellerCredentialBackup] = [],
            legacyStoryteller: LegacyStorytellerCredentialBackup? = nil,
            hardcoverToken: String? = nil,
            lazyLibrarianAPIKey: String? = nil,
            prowlarrAPIKey: String? = nil,
            jackettAPIKey: String? = nil,
            delugePassword: String? = nil,
            qbittorrentPassword: String? = nil,
            synologyPassword: String? = nil,
            torboxAPIKey: String? = nil,
            torboxarrPassword: String? = nil
        ) {
            self.storyteller = storyteller
            self.legacyStoryteller = legacyStoryteller
            self.hardcoverToken = hardcoverToken
            self.lazyLibrarianAPIKey = lazyLibrarianAPIKey
            self.prowlarrAPIKey = prowlarrAPIKey
            self.jackettAPIKey = jackettAPIKey
            self.delugePassword = delugePassword
            self.qbittorrentPassword = qbittorrentPassword
            self.synologyPassword = synologyPassword
            self.torboxAPIKey = torboxAPIKey
            self.torboxarrPassword = torboxarrPassword
        }
    }

    public func makePortableBackup(sourceIDs: [BookSourceID]) async throws -> PortableBackup {
        var storyteller: [StorytellerCredentialBackup] = []
        for sourceID in sourceIDs {
            guard let credentials = try await loadCredentials(sourceID: sourceID) else { continue }
            storyteller.append(
                StorytellerCredentialBackup(
                    sourceID: sourceID,
                    url: credentials.url,
                    lanURL: credentials.lanURL,
                    username: credentials.username,
                    password: credentials.password
                )
            )
        }

        let legacyStoryteller: LegacyStorytellerCredentialBackup?
        if let credentials = try await loadCredentials() {
            legacyStoryteller = LegacyStorytellerCredentialBackup(
                url: credentials.url,
                username: credentials.username,
                password: credentials.password
            )
        } else {
            legacyStoryteller = nil
        }

        return PortableBackup(
            storyteller: storyteller.sorted { $0.sourceID < $1.sourceID },
            legacyStoryteller: legacyStoryteller,
            hardcoverToken: try await loadHardcoverToken(),
            lazyLibrarianAPIKey: try await loadLazyLibrarianAPIKey(),
            prowlarrAPIKey: try await loadProwlarrAPIKey(),
            jackettAPIKey: try await loadJackettAPIKey(),
            delugePassword: try await loadDelugePassword(),
            qbittorrentPassword: try await loadQBittorrentPassword(),
            synologyPassword: try await loadSynologyPassword(),
            torboxAPIKey: try await loadTorBoxAPIKey(),
            torboxarrPassword: try await loadTorBoxarrPassword()
        )
    }

    /// Restores only values present in the backup. Existing credentials that are
    /// absent from the file are left untouched.
    public func restorePortableBackup(_ backup: PortableBackup) async throws {
        for credentials in backup.storyteller {
            try await saveCredentials(
                url: credentials.url,
                lanURL: credentials.lanURL,
                username: credentials.username,
                password: credentials.password,
                sourceID: credentials.sourceID
            )
        }

        if let legacy = backup.legacyStoryteller {
            try await saveString(legacy.url, for: serverURLKey)
            try await saveString(legacy.username, for: usernameKey)
            try await saveString(legacy.password, for: passwordKey)
        }
        if let value = backup.hardcoverToken { try await saveHardcoverToken(value) }
        if let value = backup.lazyLibrarianAPIKey { try await saveLazyLibrarianAPIKey(value) }
        if let value = backup.prowlarrAPIKey { try await saveProwlarrAPIKey(value) }
        if let value = backup.jackettAPIKey { try await saveJackettAPIKey(value) }
        if let value = backup.delugePassword { try await saveDelugePassword(value) }
        if let value = backup.qbittorrentPassword { try await saveQBittorrentPassword(value) }
        if let value = backup.synologyPassword { try await saveSynologyPassword(value) }
        if let value = backup.torboxAPIKey { try await saveTorBoxAPIKey(value) }
        if let value = backup.torboxarrPassword { try await saveTorBoxarrPassword(value) }
    }

    private func saveString(_ value: String, for account: String) async throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.invalidData
        }

        try await keychain.setItem(data, account: account)
    }

    private func loadString(for account: String) async throws -> String? {
        guard
            let data = try await keychain.item(account: account)
        else {
            return nil
        }

        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }

        return string
    }

    private func accountKey(_ key: String, sourceID: BookSourceID) -> String {
        return "bookSource.\(sourceID).\(key)"
    }

}

public enum KeychainError: Error, LocalizedError {
    #if canImport(Security)
    case unableToSave(status: OSStatus)
    case unableToLoad(status: OSStatus)
    case unableToDelete(status: OSStatus)
    #endif
    case invalidData
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
            #if canImport(Security)
                case .unableToSave(let status):
                    return "Unable to save to keychain (status: \(status))"
                case .unableToLoad(let status):
                    return "Unable to load from keychain (status: \(status))"
                case .unableToDelete(let status):
                    return "Unable to delete from keychain (status: \(status))"
            #endif
            case .invalidData:
                return "Invalid data in keychain"
            case .unsupportedPlatform:
                return "Keychain is not available on this platform"
        }
    }
}
