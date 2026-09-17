import Foundation
import SilveranKit

// MARK: - Explore “More like this” — Library Only
//
// Must NOT call any network. Recommendations come solely from the user's own
// library (`[BookMetadata]`) until they tap Add to Library and acquire via a
// lawful transport (A–D). Keeps “discovery” from becoming an unpaid pipeline.

public enum ExploreMoreLikeThisService {

    /// Return up to `limit` books from `library` most similar to `book`.
    /// Pure local filter on author / series / tags / narrator overlap.
    /// Stable sort: higher overlap score first, then most recently added.
    public static func moreLike(_ book: BookMetadata, in library: [BookMetadata], limit: Int = 8) -> [BookMetadata] {
        // Never recommend the same book
        let candidates = library.filter { $0.id != book.id }
        guard !candidates.isEmpty else { return [] }

        let bookAuthors = normalizedAuthors(book)
        let bookSeries = normalizedSeries(book)
        let bookTags = normalizedTags(book)
        let bookNarrators = normalizedNarrators(book)

        // Score each candidate; keep only those with non-zero overlap
        let scored: [(book: BookMetadata, score: Int)] = candidates.compactMap { cand in
            var score = 0
            if !bookAuthors.isEmpty {
                let overlap = normalizedAuthors(cand).intersection(bookAuthors).count
                score += overlap * 10
            }
            if !bookSeries.isEmpty {
                let overlap = normalizedSeries(cand).intersection(bookSeries).count
                score += overlap * 12 // series is strongest signal
            }
            if !bookTags.isEmpty {
                let overlap = normalizedTags(cand).intersection(bookTags).count
                score += overlap * 3
            }
            if !bookNarrators.isEmpty {
                let overlap = normalizedNarrators(cand).intersection(bookNarrators).count
                score += overlap * 6
            }
            // Bonus for same publication decade
            if let by = bookYear(book), let cy = bookYear(cand), abs(by - cy) <= 5 {
                score += 2
            }
            guard score > 0 else { return nil }
            return (cand, score)
        }

        let sorted = scored.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            // Tie-breaker: more recent first (updatedAt / createdAt)
            let ad = a.book.updatedAt ?? a.book.createdAt ?? ""
            let bd = b.book.updatedAt ?? b.book.createdAt ?? ""
            return ad > bd
        }

        return sorted.prefix(limit).map { $0.book }
    }

    // MARK: - Normalization

    private static func normalizedAuthors(_ b: BookMetadata) -> Set<String> {
        var set = Set<String>()
        (b.authors ?? []).forEach { c in
            if let name = c.name?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                set.insert(name)
            }
        }
        (b.creators ?? []).forEach { c in
            if let name = c.name?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                set.insert(name)
            }
        }
        return set
    }

    private static func normalizedSeries(_ b: BookMetadata) -> Set<String> {
        var set = Set<String>()
        (b.series ?? []).forEach { s in
            let n = s.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty { set.insert(n) }
        }
        return set
    }

    private static func normalizedTags(_ b: BookMetadata) -> Set<String> {
        var set = Set<String>()
        (b.tags ?? []).forEach { t in
            let n = t.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty { set.insert(n) }
        }
        return set
    }

    private static func normalizedNarrators(_ b: BookMetadata) -> Set<String> {
        var set = Set<String>()
        (b.narrators ?? []).forEach { c in
            if let name = c.name?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                set.insert(name)
            }
        }
        return set
    }

    private static func bookYear(_ b: BookMetadata) -> Int? {
        if let s = b.publicationDate, let y = Int(s.prefix(4)) { return y }
        return nil
    }
}
