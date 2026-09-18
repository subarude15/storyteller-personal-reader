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
        // Split acquisitions: ebook formats → epubURL, audio formats → audioURL/magnet.
        let ebookURL = preferredAcquisitionURL(from: book.formats, kind: .ebook)
        let audioURL = preferredAcquisitionURL(from: book.formats, kind: .audiobook)
        let audioMagnet = book.formats
            .first { Self.formatKind($0.format) == .audiobook && !($0.magnet ?? "").isEmpty }?
            .magnet
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
            epubURL: ebookURL,
            audioURL: audioURL,
            audioMagnet: audioMagnet,
            language: nil,
            subjects: book.metadata_sources,
            publishedAt: nil,
            updatedAt: nil,
            rights: nil,
            webpageURL: URL(string: book.sample_audio_url)
        )
    }

    /// Acquisition media kind: ebook (epub/pdf/mobi/azw3) or audiobook (m4b/mp3/m4a).
    public enum AcquisitionKind {
        case ebook
        case audiobook
    }

    /// Picks the best download URL of `kind` from adapter `formats` for Explore Read / Import.
    public static func preferredAcquisitionURL(from formats: [BookFormat], kind: AcquisitionKind) -> URL? {
        let ranked = formats
            .filter { Self.formatKind($0.format) == kind }
            .sorted { lhs, rhs in
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

    /// Classifies a format string as ebook or audiobook (or nil if neither).
    public static func formatKind(_ format: String) -> AcquisitionKind? {
        switch format.lowercased() {
        case "epub", "pdf", "mobi", "azw3", "azw", "cbz", "cbr", "fb2", "txt", "html":
            return .ebook
        case "m4b", "mp3", "m4a", "aac", "ogg", "opus", "wav", "flac", "mp4", "mka":
            return .audiobook
        default:
            return nil
        }
    }

    private static func formatRank(_ format: String) -> Int {
        switch format.lowercased() {
        case "epub": return 0
        case "m4b": return 0
        case "mp3": return 1
        case "m4a": return 2
        case "pdf": return 3
        case "mobi", "azw3": return 4
        default: return 10
        }
    }
}
