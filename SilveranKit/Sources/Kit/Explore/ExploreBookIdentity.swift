import Foundation

/// Stable Explore identity helpers. Ephemeral Read Now books use a namespaced
/// form `explore.<source-id>.<item-id>` and must never enter Storyteller sync,
/// Library, Shelf, or local recommendations until explicitly imported.
public enum ExploreBookIdentity {
    public static let bookSourceID: BookSourceID = "explore"
    public static let standardEbooksSourceID = "standard-ebooks"
    public static let directLinkSourceID = "direct-epub"
    public static let playtorioSourceID = "playtorio"

    public static func stableID(sourceID: String, itemID: String) -> String {
        "explore.\(sanitize(sourceID)).\(sanitize(itemID))"
    }

    public static func bookID(sourceID: String, itemID: String) -> BookID {
        BookID(sourceID: bookSourceID, uuid: "\(sanitize(sourceID)).\(sanitize(itemID))")
    }

    public static func bookID(for book: ExploreBook) -> BookID {
        bookID(sourceID: book.sourceID, itemID: book.itemID)
    }

    public static func isExplore(_ bookID: BookID) -> Bool {
        bookID.sourceID == bookSourceID
    }

    public static func isExplore(stableID: String) -> Bool {
        stableID.hasPrefix("explore.")
    }

    public static func sanitize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unknown" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        let scalars = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(scalars)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return collapsed.isEmpty ? "unknown" : String(collapsed.prefix(180))
    }

    /// Minimal BookMetadata bridge so the existing ebook reader can present a
    /// temporary Explore EPUB without inserting it into the Storyteller library.
    public static func makeEphemeralMetadata(for book: ExploreBook) -> BookMetadata {
        let authors = book.authors.map {
            BookCreator(
                uuid: nil,
                id: nil,
                name: $0.name,
                fileAs: nil,
                role: "aut",
                createdAt: nil,
                updatedAt: nil
            )
        }
        let progress = ExploreProgressStore.shared.load(exploreID: book.id)
        let position: BookReadingPosition? = {
            guard let locator = progress?.locator else { return nil }
            return BookReadingPosition(
                uuid: nil,
                locator: locator,
                timestamp: (progress?.updatedAt.timeIntervalSince1970 ?? 0) * 1000,
                createdAt: nil,
                updatedAt: nil
            )
        }()
        return BookMetadata(
            bookID: bookID(for: book),
            title: book.title,
            subtitle: nil,
            description: book.summary,
            language: book.language,
            createdAt: nil,
            updatedAt: nil,
            publicationDate: nil,
            authors: authors.isEmpty ? nil : authors,
            narrators: nil,
            creators: nil,
            series: nil,
            tags: nil,
            collections: nil,
            ebook: BookAsset(
                uuid: book.itemID,
                filepath: book.epubURL?.lastPathComponent ?? "book.epub",
                missing: 0,
                isEpub2: nil,
                isEpub3: true,
                createdAt: nil,
                updatedAt: nil
            ),
            audiobook: nil,
            readaloud: nil,
            status: nil,
            position: position,
            rating: nil,
            source: book.sourceName
        )
    }
}
