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
