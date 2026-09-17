import Foundation

// MARK: - Lawful OPDS / Atom Catalogs
//
// Explore ships a small allow-list of public, publisher-authorized OPDS/Atom feeds.
// Users may add their own (library, publisher store, self-hosted) via Settings.
// No bundled pirate indexes. All URLs must be https.

/// A single OPDS/Atom catalog Explore can browse.
public struct OPDSCatalog: Sendable, Hashable, Identifiable, Codable {
    public let id: String
    public let name: String
    public let url: URL
    public let requiresAuth: Bool
    public let isUserAdded: Bool
    /// Human-readable provenance, e.g. "Public domain — Project Gutenberg"
    public let provenance: String

    public init(
        id: String,
        name: String,
        url: URL,
        requiresAuth: Bool = false,
        isUserAdded: Bool = false,
        provenance: String
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.requiresAuth = requiresAuth
        self.isUserAdded = isUserAdded
        self.provenance = provenance
    }
}

/// Built-in allow-list. Keep it to public-domain or publisher-authorized feeds.
/// All URLs are https. Do not add LibGen / Z-Lib / Anna’s Archive here.
public enum OPDSCatalogs {
    public static let builtIn: [OPDSCatalog] = [
        OPDSCatalog(
            id: "gutenberg",
            name: "Project Gutenberg",
            url: URL(string: "https://www.gutenberg.org/ebooks.opds/?format=opds")!,
            provenance: "Public domain — Project Gutenberg OPDS"
        ),
        OPDSCatalog(
            id: "standard-ebooks",
            name: "Standard Ebooks",
            url: URL(string: "https://standardebooks.org/opds")!,
            provenance: "Public domain — Standard Ebooks OPDS"
        ),
        OPDSCatalog(
            id: "internet-archive",
            name: "Internet Archive",
            url: URL(string: "https://archive.org/services/opds/search.php?query=mediatype:texts")!,
            provenance: "Public / controlled digital lending — Internet Archive OPDS"
        ),
        OPDSCatalog(
            id: "feedbooks-publicdomain",
            name: "Feedbooks Public Domain",
            url: URL(string: "https://catalog.feedbooks.com/publicdomain.atom")!,
            provenance: "Public domain — Feedbooks OPDS"
        ),
        OPDSCatalog(
            id: "open-library-opds",
            name: "Open Library",
            url: URL(string: "https://openlibrary.org/search.atom?q=public+domain")!,
            provenance: "Metadata + public-domain loans — Open Library Atom"
        ),
        // User-added examples are NOT defaults; they document the “your catalog” path.
    ]

    /// OPDSCatalogs whose host is banned (pirate indexes, Audible scrape). Used to
    /// reject user-added URLs that attempt to smuggle a banned host through the
    /// “Your Catalog” field.
    public static let bannedHosts: Set<String> = [
        "libgen.is", "libgen.rs", "libgen.st", "libgen.li",
        "z-lib.io", "z-lib.do", "zlibrary.to",
        "annas-archive.org", "annas-archive.li", "annas-archive.se",
        "audible.com", "audible.co.uk", "audible.de", "audible.fr", "audible.ca",
        "audible.com.au", "audible.in", "api.audible.com", "api.audible.co.uk",
    ]

    public static func isBannedHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        return bannedHosts.contains(lower) || bannedHosts.contains { lower.hasSuffix(".\($0)") }
    }
}

// MARK: - OPDS Entry (feed item)

/// One book/audiobook entry parsed from an OPDS/Atom feed.
public struct OPDSEntry: Sendable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let author: String?
    public let summary: String?
    public let coverURL: URL?
    public let acquisitionLinks: [OPDSAcquisitionLink]
    /// The catalog this entry came from (for provenance badge)
    public let provenance: AcquisitionProvenance

    public init(
        id: String,
        title: String,
        author: String? = nil,
        summary: String? = nil,
        coverURL: URL? = nil,
        acquisitionLinks: [OPDSAcquisitionLink] = [],
        provenance: AcquisitionProvenance
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.summary = summary
        self.coverURL = coverURL
        self.acquisitionLinks = acquisitionLinks
        self.provenance = provenance
    }
}

/// A single acquisition href from an OPDS entry. Only https + allow-listed types.
public struct OPDSAcquisitionLink: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable {
        case epub
        case audiobook // m4b/m4a/mp3/zip (Readium)
        case readaloud
    }

    public let id: String
    public let kind: Kind
    public let href: URL
    public let mimeType: String?

    public init(kind: Kind, href: URL, mimeType: String? = nil) {
        self.id = href.absoluteString
        self.kind = kind
        self.href = href
        self.mimeType = mimeType
    }

    public var transport: AuthorizedTransport { .publicOPDS }
}

// MARK: - Persistence for user-added catalogs

public enum OPDSCatalogStore {
    private static let userCatalogsKey = "explore.userOPDSCatalogs"

    public static func loadUserCatalogs() -> [OPDSCatalog] {
        guard let data = UserDefaults.standard.data(forKey: userCatalogsKey),
              let decoded = try? JSONDecoder().decode([OPDSCatalog].self, from: data) else {
            return []
        }
        return decoded
    }

    public static func saveUserCatalogs(_ catalogs: [OPDSCatalog]) {
        if let data = try? JSONEncoder().encode(catalogs) {
            UserDefaults.standard.set(data, forKey: userCatalogsKey)
        }
    }

    /// Validate a user-pasted OPDS URL before persisting. Must be https and not a banned host.
    public static func validateUserURLString(_ urlString: String) throws -> URL {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https", let host = url.host, !host.isEmpty else {
            throw ExploreAcquisitionError.notHTTPS
        }
        if OPDSCatalogs.isBannedHost(host) {
            throw ExploreAcquisitionError.disallowedHost(host)
        }
        return url
    }
}
