import Foundation

/// Deterministic recommendations drawn only from metadata already present in a library snapshot.
public enum LocalBookRecommendations {
    public static func recommendations(
        for currentBook: BookMetadata,
        in library: [BookMetadata],
        limit: Int = 15,
    ) -> [BookMetadata] {
        guard limit > 0 else { return [] }

        let candidates = library.filter {
            $0.id != currentBook.id && $0.sourceID == currentBook.sourceID
        }
        var recommendations: [BookMetadata] = []
        var includedIDs: Set<BookID> = []

        let currentSeries = orderedSeriesNames(currentBook.series ?? [])
        let seriesMatches = candidates.compactMap { book -> SeriesMatch? in
            bestSeriesMatch(for: book, currentSeries: currentSeries)
        }.sorted(by: seriesMatchComesFirst)
        append(seriesMatches.map(\.book), to: &recommendations, includedIDs: &includedIDs)

        let currentAuthors = creatorKeys(currentBook.authors ?? [])
        if !currentAuthors.isEmpty {
            let authorMatches = candidates.filter { book in
                includedIDs.contains(book.id) == false
                    && creatorKeys(book.authors ?? []).isDisjoint(with: currentAuthors) == false
            }.sorted(by: titleComesFirst)
            append(authorMatches, to: &recommendations, includedIDs: &includedIDs)
        }

        let currentTags = normalizedNames(currentBook.tagNames)
        if !currentTags.isEmpty {
            let tagMatches = candidates.compactMap { book -> TagMatch? in
                guard includedIDs.contains(book.id) == false else { return nil }
                let overlap = normalizedNames(book.tagNames).intersection(currentTags).count
                return overlap > 0 ? TagMatch(book: book, overlap: overlap) : nil
            }.sorted { lhs, rhs in
                if lhs.overlap != rhs.overlap { return lhs.overlap > rhs.overlap }
                return titleComesFirst(lhs.book, rhs.book)
            }
            append(tagMatches.map(\.book), to: &recommendations, includedIDs: &includedIDs)
        }

        return Array(recommendations.prefix(limit))
    }

    private struct SeriesMatch {
        let book: BookMetadata
        let currentSeriesIndex: Int
        let position: Float?
    }

    private struct TagMatch {
        let book: BookMetadata
        let overlap: Int
    }

    private static func orderedSeriesNames(_ series: [BookSeries]) -> [String: Int] {
        var result: [String: Int] = [:]
        for value in series {
            let name = normalized(value.name)
            guard !name.isEmpty, result[name] == nil else { continue }
            result[name] = result.count
        }
        return result
    }

    private static func bestSeriesMatch(
        for book: BookMetadata,
        currentSeries: [String: Int],
    ) -> SeriesMatch? {
        guard !currentSeries.isEmpty else { return nil }

        return (book.series ?? []).compactMap { series -> SeriesMatch? in
            guard let index = currentSeries[normalized(series.name)] else { return nil }
            return SeriesMatch(book: book, currentSeriesIndex: index, position: series.position)
        }.min { lhs, rhs in
            if lhs.currentSeriesIndex != rhs.currentSeriesIndex {
                return lhs.currentSeriesIndex < rhs.currentSeriesIndex
            }
            return optionalPosition(lhs.position, comesBefore: rhs.position)
        }
    }

    private static func seriesMatchComesFirst(_ lhs: SeriesMatch, _ rhs: SeriesMatch) -> Bool {
        if lhs.currentSeriesIndex != rhs.currentSeriesIndex {
            return lhs.currentSeriesIndex < rhs.currentSeriesIndex
        }
        if lhs.position != rhs.position {
            return optionalPosition(lhs.position, comesBefore: rhs.position)
        }
        return titleComesFirst(lhs.book, rhs.book)
    }

    private static func optionalPosition(_ lhs: Float?, comesBefore rhs: Float?) -> Bool {
        switch (lhs, rhs) {
            case (.some(let lhs), .some(let rhs)): return lhs < rhs
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return false
        }
    }

    private static func creatorKeys(_ creators: [BookCreator]) -> Set<String> {
        var keys: Set<String> = []
        for creator in creators {
            if let uuid = creator.uuid {
                let value = normalized(uuid)
                if !value.isEmpty { keys.insert("id:\(value)") }
            }
            if let name = creator.name {
                let value = normalized(name)
                if !value.isEmpty { keys.insert("name:\(value)") }
            }
        }
        return keys
    }

    private static func normalizedNames(_ names: [String]) -> Set<String> {
        Set(names.map(normalized).filter { !$0.isEmpty })
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX"),
            )
            .lowercased()
    }

    private static func titleComesFirst(_ lhs: BookMetadata, _ rhs: BookMetadata) -> Bool {
        let comparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.id < rhs.id
    }

    private static func append(
        _ books: [BookMetadata],
        to recommendations: inout [BookMetadata],
        includedIDs: inout Set<BookID>,
    ) {
        for book in books where includedIDs.insert(book.id).inserted {
            recommendations.append(book)
        }
    }
}
