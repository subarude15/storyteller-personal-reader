import Foundation
import SilveranKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Explore Wishlist / Search (Metadata Discovery Only)
//
// Open Library and Hardcover are used to *discover* books you don't own.
// They are shown as wishlist/search results — title, author, cover, description —
// with a “Not in Library” badge. They NEVER auto-download. The user must tap
// Add to Library and pick a lawful transport (public OPDS, your OPDS, direct HTTPS,
// or your debrid link) to actually acquire a file.
//
// Keep download logic out of this file on purpose.

public struct WishlistItem: Sendable, Identifiable, Hashable {
    public enum Source: String, Sendable {
        case openLibrary = "openLibrary"
        case hardcover = "hardcover"
    }

    public let id: String // openLibrary key or hardcover id
    public let source: Source
    public let title: String
    public let subtitle: String?
    public let authors: [String]
    public let coverURL: URL?
    public let description: String?
    public let releaseYear: Int?
    public var isInLibrary: Bool // computed after fetch

    public init(
        id: String,
        source: Source,
        title: String,
        subtitle: String? = nil,
        authors: [String] = [],
        coverURL: URL? = nil,
        description: String? = nil,
        releaseYear: Int? = nil,
        isInLibrary: Bool = false
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.subtitle = subtitle
        self.authors = authors
        self.coverURL = coverURL
        self.description = description
        self.releaseYear = releaseYear
        self.isInLibrary = isInLibrary
    }
}

public actor ExploreWishlistService {
    public static let shared = ExploreWishlistService()

    private let urlSession: URLSession
    private let openLibrarySearchBase = "https://openlibrary.org/search.json"
    private let openLibraryCoverBase = "https://covers.openlibrary.org/b/id/"

    public init(session: URLSession = .shared) {
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 20
        self.urlSession = URLSession(configuration: cfg)
    }

    // MARK: - Public

    /// Search wishlist candidates across Open Library (always) and Hardcover (when token present).
    /// Results are wishlist-only; no download is triggered here.
    public func search(query: String, library: [BookMetadata]) async -> [WishlistItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        async let openLibrary = searchOpenLibrary(query: trimmed)
        async let hardcover = searchHardcover(query: trimmed)

        let ol = (try? await openLibrary) ?? []
        let hc = (try? await hardcover) ?? []

        // Merge and mark isInLibrary by title+author loose match
        let merged = (ol + hc)
        return merged.map { item in
            var copy = item
            copy.isInLibrary = isInLibrary(item, library: library)
            return copy
        }
    }

    // MARK: - Open Library

    private struct OLSearchResponse: Decodable {
        struct Doc: Decodable {
            let key: String?
            let title: String?
            let author_name: [String]?
            let first_publish_year: Int?
            let cover_i: Int?
            let subtitle: String?
        }
        let docs: [Doc]
    }

    private func searchOpenLibrary(query: String) async throws -> [WishlistItem] {
        var comps = URLComponents(string: openLibrarySearchBase)!
        comps.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "fields", value: "key,title,author_name,first_publish_year,cover_i,subtitle"),
        ]
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await urlSession.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }

        let decoded = try JSONDecoder().decode(OLSearchResponse.self, from: data)
        return decoded.docs.compactMap { doc in
            guard let title = doc.title, !title.isEmpty else { return nil }
            let coverURL: URL? = {
                guard let id = doc.cover_i else { return nil }
                return URL(string: "\(openLibraryCoverBase)\(id)-M.jpg")
            }()
            return WishlistItem(
                id: doc.key ?? "ol-\(title.hashValue)",
                source: .openLibrary,
                title: title,
                subtitle: doc.subtitle,
                authors: doc.author_name ?? [],
                coverURL: coverURL,
                releaseYear: doc.first_publish_year
            )
        }
    }

    // MARK: - Hardcover (via HardcoverActor)

    private func searchHardcover(query: String) async throws -> [WishlistItem] {
        // Only if user configured a token — HardcoverActor throws noToken otherwise.
        let results = try await HardcoverActor.shared.searchBooks(query: query)
        return results.map { r in
            WishlistItem(
                id: "hardcover-\(r.id)",
                source: .hardcover,
                title: r.title,
                subtitle: r.subtitle,
                authors: r.authors,
                coverURL: r.imageUrl.flatMap(URL.init(string:)),
                releaseYear: r.releaseYear
            )
        }
    }

    // MARK: - Helpers

    private func isInLibrary(_ item: WishlistItem, library: [BookMetadata]) -> Bool {
        let needle = item.title.lowercased()
        return library.contains { book in
            let titleMatch = book.title.lowercased().contains(needle) || needle.contains(book.title.lowercased())
            if !titleMatch { return false }
            // If we have an author, require overlap
            if let firstAuthor = item.authors.first?.lowercased(), !firstAuthor.isEmpty {
                let bookAuthors: [String] = (book.authors?.compactMap { $0.name } ?? []) + (book.creators?.compactMap { $0.name } ?? [])
                return bookAuthors.contains { $0.lowercased().contains(firstAuthor) || firstAuthor.contains($0.lowercased()) }
            }
            return true
        }
    }
}
