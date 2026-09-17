import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Preferred Storyteller API host when optional LAN URL is configured.
public enum StorytellerNetworkRoute: String, Sendable, Equatable {
    case `public`
    case lan

    public var settingsStatusLabel: String {
        switch self {
            case .lan:
                return "Using LAN"
            case .public:
                return "Using public"
        }
    }
}

/// Resolve optional LAN URL for Storyteller home-Wi‑Fi failover.
///
/// - `nil` stored (never saved): use the ink+amp default NAS URL.
/// - empty / whitespace: LAN disabled.
/// - non-empty: use that URL.
public enum StorytellerLANRouting {
    public static let probeTimeout: TimeInterval = 2

    /// Effective LAN base URL string for probing/routing, or nil when disabled.
    public static func effectiveLANURL(stored: String?) -> String? {
        guard let stored else {
            return kDefaultStorytellerLANURL
        }
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func preferLAN(probeSucceeded: Bool, effectiveLANURL: String?) -> Bool {
        effectiveLANURL != nil && probeSucceeded
    }

    /// Cheap reachability: any HTTP response (including 401/404/405) means the host is up.
    /// Connection errors / timeouts mean LAN is unavailable.
    public static func probeReachability(
        serverURL: URL,
        timeout: TimeInterval = probeTimeout,
        session: URLSession? = nil,
    ) async -> Bool {
        let apiBase = resolveAPIBaseURL(from: serverURL)
        // Hit a known API path; unauthorized still proves the NAS answered.
        let probeURL = apiBase.appendingPathComponent("books")

        let ownedSession: URLSession?
        let activeSession: URLSession
        if let session {
            ownedSession = nil
            activeSession = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = timeout
            configuration.timeoutIntervalForResource = timeout
            configuration.waitsForConnectivity = false
            let created = URLSession(configuration: configuration)
            ownedSession = created
            activeSession = created
        }
        defer { ownedSession?.invalidateAndCancel() }

        var request = URLRequest(url: probeURL, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (_, response) = try await activeSession.data(for: request)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }

    /// Same path rules as StorytellerActor.resolveAPIBaseURL (kept free of actor state for tests).
    public static func resolveAPIBaseURL(from serverURL: URL) -> URL {
        let trimmedPath = serverURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmedPath.hasSuffix("api/v2") {
            return serverURL
        }
        if trimmedPath.hasSuffix("api") {
            return serverURL.appendingPathComponent("v2")
        }
        return
            serverURL
            .appendingPathComponent("api")
            .appendingPathComponent("v2")
    }
}
