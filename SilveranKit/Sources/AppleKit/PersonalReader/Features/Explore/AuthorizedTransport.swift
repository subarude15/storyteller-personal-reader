import Foundation

// MARK: - Lawful Explore — Authorized Transport Boundary
//
// Board policy: Explore may ONLY acquire books/audiobooks via transports
// the user lawfully controls. This file is the canonical allow-list.
// Any addition must be a public OPDS/Atom feed, a user-supplied OPDS URL,
// a direct HTTPS link the user pasted, or a single BYO debrid/torrent link
// the user supplied after authenticating to their own provider.
// No bundled pirate indexes, no Audible login scrape, no DRM strip.

// No imports of DRM libraries. If you are tempted to add `libation`, `DeDRM`,
// `activation_bytes`, or an Audible session-cookie flow, stop — it is banned.

/// The four lawful ways Explore may acquire content. Every download path
/// must be tagged with one of these so UI and logs can prove the source
/// was authorized/user-controlled.
public enum AuthorizedTransport: String, Sendable, CaseIterable, Identifiable, Codable {
    /// A curated public OPDS/Atom catalog shipped with the app (e.g. Gutenberg,
    /// Standard Ebooks, Internet Archive). HTTPS, public-domain or publisher-authorized.
    case publicOPDS = "publicOPDS"
    /// An OPDS/Atom URL the user typed in Settings → Explore → Add Catalog
    /// (their library, publisher store, self-hosted Komga/Kavita/Calibre-Web OPDS).
    case userOPDS = "userOPDS"
    /// A direct https:// link to an .epub/.cbz/.m4b/.mp3/.zip the user pasted.
    /// Validated with HEAD before GET; no scraping.
    case directHTTPS = "directHTTPS"
    /// A single magnet/http link the user pasted and asked to resolve via
    /// *their own* debrid provider after they explicitly authenticated.
    /// No bundled search, no default tracker list.
    case byoDebridLink = "byoDebridLink"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .publicOPDS: return "Public Catalog"
        case .userOPDS: return "Your Catalog"
        case .directHTTPS: return "Direct Link"
        case .byoDebridLink: return "Your Debrid Link"
        }
    }

    public var systemImage: String {
        switch self {
        case .publicOPDS: return "books.vertical"
        case .userOPDS: return "link.badge.plus"
        case .directHTTPS: return "link"
        case .byoDebridLink: return "personalhotspot" // user-owned resolver
        }
    }
}

/// Errors surfaced when a user action does not map to an AuthorizedTransport.
/// DRM-related cases intentionally do not exist — DRM removal is not a transport.
public enum ExploreAcquisitionError: LocalizedError, Sendable, Equatable {
    case notHTTPS
    case unsupportedExtension(String)
    case disallowedHost(String)
    case notAuthorizedTransport
    case catalogUnreachable(String)
    case invalidOPDSURL(String)
    case byoNotAuthenticated
    case byoLinkRejected(String)
    case contentTypeMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .notHTTPS:
            return "Only https:// links are allowed."
        case .unsupportedExtension(let ext):
            return "Unsupported file type “\(ext)”. Use .epub, .cbz, .m4b, .m4a, .mp3, or .zip."
        case .disallowedHost(let host):
            return "Host “\(host)” is not an authorized catalog. Add it as Your Catalog if you control it."
        case .notAuthorizedTransport:
            return "This acquisition must use a lawful transport (public OPDS, your OPDS, direct link, or your debrid link)."
        case .catalogUnreachable(let detail):
            return "Catalog unreachable: \(detail)"
        case .invalidOPDSURL(let detail):
            return "Invalid catalog URL: \(detail)"
        case .byoNotAuthenticated:
            return "Connect your debrid provider in Settings → Explore first, then paste a link you own."
        case .byoLinkRejected(let detail):
            return "Link rejected: \(detail)"
        case .contentTypeMismatch(let expected, let actual):
            return "Unexpected content type. Expected \(expected), got \(actual)."
        }
    }
}

/// Human-readable policy tag shown next to every Add to Library button so
/// the user (and review) can see which lawful path a download uses.
public struct AcquisitionProvenance: Sendable, Hashable {
    public let transport: AuthorizedTransport
    public let sourceName: String
    public let sourceURL: URL?

    public init(transport: AuthorizedTransport, sourceName: String, sourceURL: URL? = nil) {
        self.transport = transport
        self.sourceName = sourceName
        self.sourceURL = sourceURL
    }

    public var badgeText: String {
        "via \(sourceName) · \(transport.displayName)"
    }
}
