import Foundation
import PlaytorioFetcher

/// Explore catalog backed by the durable Playtorio library ingest store.
public struct PlaytorioCatalogProvider: ExploreCatalogProvider {
    public let source: ExploreCatalogSource
    private let library: PlaytorioLibraryStore

    public init(
        source: ExploreCatalogSource = .playtorio,
        library: PlaytorioLibraryStore = PlaytorioCatalogProvider.defaultLibrary()
    ) {
        self.source = source
        self.library = library
    }

    public static func defaultLibrary() -> PlaytorioLibraryStore {
        #if os(iOS) || os(macOS) || os(tvOS)
        return PlaytorioLibraryStore(databasePath: PlaytorioLibraryStore.applicationSupportPath())
        #else
        return PlaytorioLibraryStore()
        #endif
    }

    public func loadPage(at url: URL?) async throws -> ExploreCatalogPage {
        let books = library.allBooks().map { Self.mapBook($0, source: source) }
        return ExploreCatalogPage(books: books, fetchedAt: Date(), isStaleCache: false)
    }

    public static func mapBook(_ book: NormalizedBook, source: ExploreCatalogSource) -> ExploreBook {
        let itemID = PlaytorioLibraryStore.bookKey(for: book)
        // Prefer EPUB for Storyteller ingest; fall back to any http(s) format URL.
        let acquisition = preferredAcquisitionURL(from: book.formats)
        let summaryParts: [String] = {
            var parts: [String] = []
            if !book.narrator.isEmpty { parts.append("Narrated by \(book.narrator)") }
            let formatSummary = book.formats
                .map(\.format)
                .filter { !$0.isEmpty }
            if !formatSummary.isEmpty {
                let unique = Array(Set(formatSummary.map { $0.uppercased() })).sorted()
                parts.append("Formats: \(unique.joined(separator: ", "))")
            }
            return parts
        }()
        return ExploreBook(
            itemID: itemID,
            sourceID: source.id,
            sourceName: source.name,
            title: book.title.isEmpty ? "Untitled" : book.title,
            authors: book.author.isEmpty ? [] : [ExploreBookAuthor(name: book.author)],
            summary: summaryParts.isEmpty ? nil : summaryParts.joined(separator: " · "),
            coverURL: URL(string: book.cover_url),
            epubURL: acquisition,
            language: nil,
            subjects: book.metadata_sources,
            publishedAt: nil,
            updatedAt: nil,
            rights: nil,
            webpageURL: URL(string: book.sample_audio_url)
        )
    }

    /// Picks the best download URL from adapter `formats` for Explore Read / Import.
    public static func preferredAcquisitionURL(from formats: [BookFormat]) -> URL? {
        let ranked = formats.sorted { lhs, rhs in
            Self.formatRank(lhs.format) < Self.formatRank(rhs.format)
        }
        for format in ranked {
            if let url = URL(string: format.url),
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https"
            {
                return url
            }
        }
        return nil
    }

    private static func formatRank(_ format: String) -> Int {
        switch format.lowercased() {
        case "epub": return 0
        case "pdf": return 1
        case "mobi", "azw3": return 2
        default: return 10
        }
    }
}
