import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Bring-Your-Own Debrid / Torrent Link (BYO Only — No Bundled Pirate Index)
//
// The user has already authenticated to *their own* debrid provider (Real-Debrid,
// AllDebrid, Premiumize, etc.) and pastes a single magnet / http link *they*
// supply. The app resolves ONLY that one link via the provider they authorized.
// No search, no index, no default tracker list, no bundled host.
//
// If you are about to add a torrent-index search (e.g. “search 1337x / RARBG /
// magnet index and show results”), stop — that is the banned PlayTorrio path.

public enum BYOProvider: String, Sendable, CaseIterable, Identifiable, Codable {
    case realDebrid = "realDebrid"
    case allDebrid = "allDebrid"
    case premiumize = "premiumize"
    case genericHTTP = "genericHTTP" // user pastes a direct https link they call a “torrent”

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .realDebrid: return "Real-Debrid"
        case .allDebrid: return "AllDebrid"
        case .premiumize: return "Premiumize"
        case .genericHTTP: return "Direct Link (BYO)"
        }
    }
}

/// Stores the user's debrid token (Keychain-backed in the app; here via UserDefaults
/// for the Kit target so it stays cross-platform — the app shell should override with
/// KeychainStoring when available). Token is per-provider and never bundled.
public actor BYOTransportService {
    public static let shared = BYOTransportService()

    private let urlSession: URLSession
    private var tokens: [BYOProvider: String] = [:]

    // Keychain would be preferred; UserDefaults keeps this target portable.
    private let tokenKeyPrefix = "explore.byo.token."

    public init(session: URLSession = .shared) {
        // Keep session narrow — no pirate hosts whitelisted.
        self.urlSession = session
        // Tokens hydrate lazily from UserDefaults in hasToken / resolve methods.
    }

    // MARK: - Auth

    public func setToken(_ token: String?, for provider: BYOProvider) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let t = trimmed, !t.isEmpty {
            tokens[provider] = t
            UserDefaults.standard.set(t, forKey: tokenKeyPrefix + provider.rawValue)
        } else {
            tokens.removeValue(forKey: provider)
            UserDefaults.standard.removeObject(forKey: tokenKeyPrefix + provider.rawValue)
        }
    }

    public func hasToken(for provider: BYOProvider) -> Bool {
        if tokens[provider] != nil { return true }
        // Lazy hydrate from storage
        if let stored = UserDefaults.standard.string(forKey: tokenKeyPrefix + provider.rawValue),
           !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tokens[provider] = stored
            return true
        }
        return false
    }

    public var hasAnyToken: Bool {
        BYOProvider.allCases.contains { hasToken(for: $0) }
    }

    // MARK: - Resolve a single user-supplied link

    /// The ONLY public entry point for BYO. `userSuppliedURLString` is a magnet: or https://
    /// string the user pasted. We do NOT search an index to find it.
    /// Returns a direct https URL that DirectLinkIngestService can then download, or throws.
    public func resolveUserLink(_ userSuppliedURLString: String, using provider: BYOProvider) async throws -> URL {
        guard hasToken(for: provider) else {
            throw ExploreAcquisitionError.byoNotAuthenticated
        }

        let trimmed = userSuppliedURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ExploreAcquisitionError.byoLinkRejected("Empty link")
        }

        // Reject bundled-host traps even in BYO links
        if let url = URL(string: trimmed), let host = url.host, OPDSCatalogs.isBannedHost(host) {
            throw ExploreAcquisitionError.disallowedHost(host)
        }

        // For magnet links, we require a debrid provider that can unrestrict them.
        let isMagnet = trimmed.lowercased().hasPrefix("magnet:")
        if isMagnet {
            return try await unrestrictMagnet(trimmed, provider: provider)
        }

        // For https links, validate https and then (if provider is debrid) unrestrict via that provider.
        // If genericHTTP, just validate as a DirectLink-equivalent.
        if let url = URL(string: trimmed), url.scheme?.lowercased() == "https" {
            if provider == .genericHTTP {
                return url
            }
            return try await unrestrictHTTPLink(trimmed, provider: provider)
        }

        throw ExploreAcquisitionError.byoLinkRejected("Link must be magnet: or https:// — got “\(trimmed.prefix(80))”")
    }

    // MARK: - Provider-specific unrestrict (single-link only)

    private func unrestrictMagnet(_ magnet: String, provider: BYOProvider) async throws -> URL {
        guard let token = tokens[provider] ?? UserDefaults.standard.string(forKey: tokenKeyPrefix + provider.rawValue) else {
            throw ExploreAcquisitionError.byoNotAuthenticated
        }

        // Each provider has its own unrestrict endpoint. We implement the minimal
        // single-link call; no search, no listing.
        switch provider {
        case .realDebrid:
            // POST https://api.real-debrid.com/rest/1.0/unrestrict/link with magnet
            return try await realDebridUnrestrict(link: magnet, token: token)
        case .allDebrid:
            return try await allDebridUnrestrict(link: magnet, token: token)
        case .premiumize:
            return try await premiumizeUnrestrict(link: magnet, token: token)
        case .genericHTTP:
            throw ExploreAcquisitionError.byoLinkRejected("Magnet links require a debrid provider (Real-Debrid, AllDebrid, or Premiumize).")
        }
    }

    private func unrestrictHTTPLink(_ httpLink: String, provider: BYOProvider) async throws -> URL {
        guard let token = tokens[provider] ?? UserDefaults.standard.string(forKey: tokenKeyPrefix + provider.rawValue) else {
            throw ExploreAcquisitionError.byoNotAuthenticated
        }
        switch provider {
        case .realDebrid: return try await realDebridUnrestrict(link: httpLink, token: token)
        case .allDebrid: return try await allDebridUnrestrict(link: httpLink, token: token)
        case .premiumize: return try await premiumizeUnrestrict(link: httpLink, token: token)
        case .genericHTTP: return URL(string: httpLink)! // already validated https
        }
    }

    // Each unrestrict call below is a single-link resolve. No pagination, no search.

    private func realDebridUnrestrict(link: String, token: String) async throws -> URL {
        var req = URLRequest(url: URL(string: "https://api.real-debrid.com/rest/1.0/unrestrict/link")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "link=\(link.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? link)"
        req.httpBody = body.data(using: .utf8)
        let (data, resp) = try await urlSession.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ExploreAcquisitionError.byoLinkRejected("Real-Debrid unrestrict failed (\( (resp as? HTTPURLResponse)?.statusCode ?? -1))")
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dl = json["download"] as? String, let url = URL(string: dl), url.scheme?.lowercased() == "https" {
            return url
        }
        throw ExploreAcquisitionError.byoLinkRejected("Real-Debrid response missing download link")
    }

    private func allDebridUnrestrict(link: String, token: String) async throws -> URL {
        var comps = URLComponents(string: "https://api.alldebrid.com/v4/link/unlock")!
        comps.queryItems = [
            URLQueryItem(name: "agent", value: "SilveranPersonalReader"),
            URLQueryItem(name: "apikey", value: token),
            URLQueryItem(name: "link", value: link),
        ]
        let req = URLRequest(url: comps.url!)
        let (data, resp) = try await urlSession.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ExploreAcquisitionError.byoLinkRejected("AllDebrid unlock failed (\( (resp as? HTTPURLResponse)?.statusCode ?? -1))")
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataObj = json["data"] as? [String: Any],
           let dl = dataObj["link"] as? String, let url = URL(string: dl), url.scheme?.lowercased() == "https" {
            return url
        }
        throw ExploreAcquisitionError.byoLinkRejected("AllDebrid response missing link")
    }

    private func premiumizeUnrestrict(link: String, token: String) async throws -> URL {
        var req = URLRequest(url: URL(string: "https://www.premiumize.me/api/transfer/directdl")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "apikey=\(token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token)&src=\(link.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? link)"
        req.httpBody = body.data(using: .utf8)
        let (data, resp) = try await urlSession.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ExploreAcquisitionError.byoLinkRejected("Premiumize directdl failed (\( (resp as? HTTPURLResponse)?.statusCode ?? -1))")
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let content = json["content"] as? [[String: Any]],
           let first = content.first, let dl = first["link"] as? String, let url = URL(string: dl), url.scheme?.lowercased() == "https" {
            return url
        }
        // Premiumize also returns { location } for some links
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dl = json["location"] as? String, let url = URL(string: dl), url.scheme?.lowercased() == "https" {
            return url
        }
        throw ExploreAcquisitionError.byoLinkRejected("Premiumize response missing direct link")
    }
}
