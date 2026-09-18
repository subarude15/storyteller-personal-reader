import Foundation

/// Author credited on an Explore catalog entry.
public struct ExploreBookAuthor: Hashable, Codable, Sendable {
    public let name: String
    public let uri: URL?

    public init(name: String, uri: URL? = nil) {
        self.name = name
        self.uri = uri
    }
}

/// One discoverable ebook or audiobook from a catalog source (not a Storyteller library book).
public struct ExploreBook: Identifiable, Hashable, Codable, Sendable {
    /// Stable item id within its catalog source.
    public let itemID: String
    public let sourceID: String
    public let sourceName: String
    public let title: String
    public let authors: [ExploreBookAuthor]
    public let summary: String?
    public let coverURL: URL?
    public let epubURL: URL?
    /// Audiobook acquisition URL (m4b / mp3). Mutually exclusive with `epubURL`
    /// in practice — a row is one media kind.
    public let audioURL: URL?
    /// Torrent magnet link for audiobook acquisition (AudiobookBay-style sources
    /// with no direct file URL). Resolved through TorBox before import.
    public let audioMagnet: String?
    public let language: String?
    public let subjects: [String]
    public let publishedAt: Date?
    public let updatedAt: Date?
    public let rights: String?
    public let webpageURL: URL?

    public var id: String { ExploreBookIdentity.stableID(sourceID: sourceID, itemID: itemID) }

    /// True when this row is an audiobook acquisition (audio or magnet, no ebook).
    public var isAudiobook: Bool { (audioURL != nil || audioMagnet != nil) && epubURL == nil }

    public init(
        itemID: String,
        sourceID: String,
        sourceName: String,
        title: String,
        authors: [ExploreBookAuthor] = [],
        summary: String? = nil,
        coverURL: URL? = nil,
        epubURL: URL? = nil,
        audioURL: URL? = nil,
        audioMagnet: String? = nil,
        language: String? = nil,
        subjects: [String] = [],
        publishedAt: Date? = nil,
        updatedAt: Date? = nil,
        rights: String? = nil,
        webpageURL: URL? = nil
    ) {
        self.itemID = itemID
        self.sourceID = sourceID
        self.sourceName = sourceName
        self.title = title
        self.authors = authors
        self.summary = summary
        self.coverURL = coverURL
        self.epubURL = epubURL
        self.audioURL = audioURL
        self.audioMagnet = audioMagnet
        self.language = language
        self.subjects = subjects
        self.publishedAt = publishedAt
        self.updatedAt = updatedAt
        self.rights = rights
        self.webpageURL = webpageURL
    }

    public var authorDisplay: String {
        let names = authors.map(\.name).filter { !$0.isEmpty }
        return names.isEmpty ? "Unknown author" : names.joined(separator: ", ")
    }
}

/// One page of catalog results plus optional pagination links.
public struct ExploreCatalogPage: Hashable, Codable, Sendable {
    public let books: [ExploreBook]
    public let selfURL: URL?
    public let startURL: URL?
    public let nextURL: URL?
    public let fetchedAt: Date
    public let isStaleCache: Bool

    public init(
        books: [ExploreBook],
        selfURL: URL? = nil,
        startURL: URL? = nil,
        nextURL: URL? = nil,
        fetchedAt: Date = Date(),
        isStaleCache: Bool = false
    ) {
        self.books = books
        self.selfURL = selfURL
        self.startURL = startURL
        self.nextURL = nextURL
        self.fetchedAt = fetchedAt
        self.isStaleCache = isStaleCache
    }
}

public enum ExploreCatalogSourceKind: String, Codable, Sendable, Hashable {
    case standardEbooks
    case userOPDS
    case directEPUB
    case playtorio
}

/// Persisted catalog source configuration (built-in or user-added).
public struct ExploreCatalogSource: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var name: String
    public var feedURL: URL
    public let kind: ExploreCatalogSourceKind
    public let isBuiltIn: Bool

    public init(
        id: String,
        name: String,
        feedURL: URL,
        kind: ExploreCatalogSourceKind,
        isBuiltIn: Bool
    ) {
        self.id = id
        self.name = name
        self.feedURL = feedURL
        self.kind = kind
        self.isBuiltIn = isBuiltIn
    }

    public static let standardEbooks = ExploreCatalogSource(
        id: ExploreBookIdentity.standardEbooksSourceID,
        name: "Standard Ebooks",
        feedURL: URL(string: "https://standardebooks.org/opds")!,
        kind: .standardEbooks,
        isBuiltIn: true
    )

    public static let playtorio = ExploreCatalogSource(
        id: ExploreBookIdentity.playtorioSourceID,
        name: "Playtorio",
        feedURL: URL(string: "playtorio://library")!,
        kind: .playtorio,
        isBuiltIn: true
    )
}

public enum ExploreCatalogError: Error, LocalizedError, Sendable, Equatable {
    case invalidURL
    case httpsRequired
    case httpStatus(Int)
    case notOPDS
    case emptyCatalog
    case network(String)
    case cancelled
    case validationFailed(String)
    case noAcquisitionLink
    case downloadTooLarge
    case importFailed(String)
    case alreadyImported

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "That URL isn’t valid."
        case .httpsRequired:
            return "Only HTTPS catalog and EPUB links are supported."
        case .httpStatus(let code):
            return "Catalog request failed (HTTP \(code))."
        case .notOPDS:
            return "That URL didn’t return a recognizable Atom/OPDS catalog."
        case .emptyCatalog:
            return "No books found in this catalog."
        case .network(let message):
            return message
        case .cancelled:
            return "Cancelled."
        case .validationFailed(let message):
            return message
        case .noAcquisitionLink:
            return "No EPUB download link is available for this title."
        case .downloadTooLarge:
            return "That EPUB is larger than the allowed download size."
        case .importFailed(let message):
            return message
        case .alreadyImported:
            return "This title is already in your library."
        }
    }
}
