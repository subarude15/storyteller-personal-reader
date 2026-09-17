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
        let epub = book.formats.first { $0.format.lowercased() == "epub" }?.url
        return ExploreBook(
            itemID: itemID,
            sourceID: source.id,
            sourceName: source.name,
            title: book.title.isEmpty ? "Untitled" : book.title,
            authors: book.author.isEmpty ? [] : [ExploreBookAuthor(name: book.author)],
            summary: book.narrator.isEmpty ? nil : "Narrated by \(book.narrator)",
            coverURL: URL(string: book.cover_url),
            epubURL: epub.flatMap(URL.init(string:)),
            language: nil,
            subjects: book.metadata_sources,
            publishedAt: nil,
            updatedAt: nil,
            rights: nil,
            webpageURL: URL(string: book.sample_audio_url)
        )
    }
}
