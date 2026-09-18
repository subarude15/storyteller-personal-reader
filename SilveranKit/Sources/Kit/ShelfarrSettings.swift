import Foundation

/// Manages Shelfarr configuration (base URL and API token).
final class ShelfarrSettings: ObservableObject {
    static let shared = ShelfarrSettings()
    
    @Published var baseURL: String = "" {
        didSet {
            UserDefaults.standard.set(baseURL, forKey: "ShelfarrBaseURL")
        }
    }
    
    @Published var apiToken: String = "" {
        didSet {
            guard !apiToken.isEmpty else {
                try? SecurityKeychainStore(service: "Shelfarr", accessGroup: nil).removeItem(account: "token")
                return
            }
            let data = Data(apiToken.utf8)
            try? SecurityKeychainStore(service: "Shelfarr", accessGroup: nil).setItem(data, account: "token")
        }
    }
    
    var isConfigured: Bool {
        !baseURL.isEmpty && !apiToken.isEmpty
    }
    
    private init() {
        // Load baseURL from UserDefaults
        if let url = UserDefaults.standard.string(forKey: "ShelfarrBaseURL") {
            baseURL = url
        }
        
        // Load token from Keychain
        if let tokenData = try? SecurityKeychainStore(service: "Shelfarr", accessGroup: nil).item(account: "token"),
           let token = String(data: tokenData, encoding: .utf8) {
            apiToken = token
        }
    }
}