import Foundation

/// Per-format presence in the loaded Storyteller / local library.
public struct RequestLibraryFormatAvailability: Equatable, Sendable {
    public var hasEbook: Bool
    public var hasAudiobook: Bool

    public init(hasEbook: Bool = false, hasAudiobook: Bool = false) {
        self.hasEbook = hasEbook
        self.hasAudiobook = hasAudiobook
    }

    public var isEmpty: Bool { !hasEbook && !hasAudiobook }

    public func has(_ format: BookRequestFormat) -> Bool {
        switch format {
            case .ebook: hasEbook
            case .audiobook: hasAudiobook
        }
    }

    public static func merging(_ lhs: Self, _ rhs: Self) -> Self {
        RequestLibraryFormatAvailability(
            hasEbook: lhs.hasEbook || rhs.hasEbook,
            hasAudiobook: lhs.hasAudiobook || rhs.hasAudiobook,
        )
    }

    public static func from(book: BookMetadata) -> Self {
        // Match BookRequestLibrary.ownedFormats — readaloud is not an audiobook stand-in.
        RequestLibraryFormatAvailability(
            hasEbook: book.ebook.map { !$0.isMissing } ?? false,
            hasAudiobook: book.audiobook.map { !$0.isMissing } ?? false,
        )
    }
}

/// Pure matcher: Request Activity row → Storyteller library formats.
///
/// Priority (first hit wins; indexes merge formats across matching books):
/// 1. Canonical work / book ID
/// 2. Open Library work / edition ID
/// 3. Normalized ISBN
/// 4. Exact normalized title + compatible author
public struct RequestLibraryMatcher: Sendable {
    private var byCanonicalID: [String: RequestLibraryFormatAvailability] = [:]
    private var byOpenLibraryID: [String: RequestLibraryFormatAvailability] = [:]
    private var byISBN: [String: RequestLibraryFormatAvailability] = [:]
    private var byTitleAuthor: [String: RequestLibraryFormatAvailability] = [:]

    public init(books: [BookMetadata]) {
        for book in books {
            let availability = RequestLibraryFormatAvailability.from(book: book)
            guard !availability.isEmpty else { continue }

            merge(&byCanonicalID, key: book.id.description, availability)

            for isbn in Self.isbns(in: book) {
                merge(&byISBN, key: isbn, availability)
            }

            // Index each listed author separately so any one can match.
            let authorNames = book.authors?.compactMap(\.name) ?? []
            for author in authorNames {
                if let pair = Self.titleAuthorKey(title: book.title, authorNames: [author]) {
                    merge(&byTitleAuthor, key: pair, availability)
                }
            }
        }
    }

    public func availability(for item: RequestActivityItem) -> RequestLibraryFormatAvailability? {
        if let hit = byCanonicalID[item.canonicalWorkID] { return hit }

        for candidate in [
            item.openLibraryWorkID,
            item.openLibraryEditionID,
            item.canonicalWorkID,
        ] {
            if let key = Self.normalizeOpenLibraryID(candidate), let hit = byOpenLibraryID[key] {
                return hit
            }
        }

        if let isbn = Self.normalizeISBN(item.isbn), let hit = byISBN[isbn] {
            return hit
        }

        // Try whole author string first, then carefully parsed multi-author units.
        // Never blindly split on commas — "Le Guin, Ursula K." is one author.
        for author in Self.authorCandidates(from: item.author) {
            if let pair = Self.titleAuthorKey(title: item.title, authorNames: [author]),
                let hit = byTitleAuthor[pair]
            {
                return hit
            }
        }

        return nil
    }

    public func hasFormat(_ format: BookRequestFormat, for item: RequestActivityItem) -> Bool {
        availability(for: item)?.has(format) ?? false
    }

    // MARK: - Index helpers

    private func merge(
        _ table: inout [String: RequestLibraryFormatAvailability],
        key: String,
        _ availability: RequestLibraryFormatAvailability,
    ) {
        guard !key.isEmpty else { return }
        if let existing = table[key] {
            table[key] = .merging(existing, availability)
        } else {
            table[key] = availability
        }
    }

    public static func normalizeOpenLibraryID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var value = trimmed
        if value.hasPrefix("ol:") {
            value = String(value.dropFirst(3))
        }
        if let range = value.range(of: "/works/") {
            value = String(value[range.lowerBound...])
        } else if let range = value.range(of: "/books/") {
            value = String(value[range.lowerBound...])
        }
        if !value.hasPrefix("/"), value.hasPrefix("OL") {
            // Bare OL id — leave as-is for exact map keys we may store later.
        }
        return value
    }

    public static func normalizeISBN(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let compact = raw.uppercased().filter { $0.isNumber || $0 == "X" }
        if compact.count == 13, compact.hasPrefix("978") || compact.hasPrefix("979") {
            return String(compact.filter(\.isNumber))
        }
        guard compact.count == 10, compact.dropLast().allSatisfy(\.isNumber) else { return nil }
        let core = "978" + compact.prefix(9)
        var sum = 0
        for (index, character) in core.enumerated() {
            let digit = Int(String(character)) ?? 0
            sum += index.isMultiple(of: 2) ? digit : digit * 3
        }
        let check = (10 - (sum % 10)) % 10
        return core + String(check)
    }

    public static func normalizeTitle(_ title: String) -> String {
        BookFormatTexts.titleKey(title, subtitle: nil)
    }

    public static func normalizeAuthor(_ name: String) -> String {
        BookFormatTexts.fold(name)
            .split { $0 == "," || $0.isWhitespace }
            .map(String.init)
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: " ")
    }

    /// Author strings to try for title+author fallback.
    /// Always includes the full stored string first so "Le Guin, Ursula K." stays intact.
    public static func authorCandidates(from stored: String) -> [String] {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var candidates: [String] = [trimmed]
        let units = authorUnits(from: trimmed)
        if units.count > 1 {
            for unit in units where !candidates.contains(unit) {
                candidates.append(unit)
            }
        }
        return candidates
    }

    /// Split `", "`-joined authors without breaking "Last, First" names.
    /// Written as `work.authors.joined(separator: ", ")`.
    public static func authorUnits(from stored: String) -> [String] {
        let parts = stored.components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts.count >= 2 else { return parts.isEmpty ? [] : parts }

        var units: [String] = []
        var index = 0
        while index < parts.count {
            if index + 1 < parts.count,
                isSurnameGivenPair(surnameSide: parts[index], givenSide: parts[index + 1])
            {
                units.append("\(parts[index]), \(parts[index + 1])")
                index += 2
            } else {
                units.append(parts[index])
                index += 1
            }
        }
        return units
    }

    /// "Herbert"+"Frank" / "Le Guin"+"Ursula K." → true.
    /// "Frank Herbert"+"Brian Herbert" → false (two complete display names).
    public static func isSurnameGivenPair(surnameSide: String, givenSide: String) -> Bool {
        if looksLikeFullDisplayName(surnameSide), looksLikeFullDisplayName(givenSide) {
            return false
        }
        return true
    }

    /// "Brian Herbert" / "Frank Herbert" — two+ non-initial tokens.
    /// "Ursula K." / "Frank" / "Le Guin" — not a complete First Last display name.
    public static func looksLikeFullDisplayName(_ raw: String) -> Bool {
        let tokens = raw
            .split(whereSeparator: \.isWhitespace)
            .map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            }
            .filter { !$0.isEmpty }
        guard tokens.count >= 2 else { return false }
        if tokens.contains(where: { $0.count == 1 }) { return false }
        return true
    }

    public static func titleAuthorKey(title: String, authorNames: [String]) -> String? {
        let titleKey = normalizeTitle(title)
        guard !titleKey.isEmpty else { return nil }
        let authors = authorNames
            .map(normalizeAuthor)
            .filter { !$0.isEmpty }
        // Require a compatible author — title-only matches are too aggressive.
        guard let author = authors.sorted().first, !author.isEmpty else { return nil }
        return "\(titleKey)|\(author)"
    }

    private static func isbns(in book: BookMetadata) -> [String] {
        BookFormatTexts.isbnTokens(in: [
            book.title, book.subtitle, book.description,
        ]).compactMap(normalizeISBN)
    }
}

/// Applies Storyteller library presence onto request rows. Never clears `availableInLibrary`.
public enum RequestLibraryPresence {
    public static func apply(
        _ item: RequestActivityItem,
        availability: RequestLibraryFormatAvailability?,
        now: Date = Date(),
    ) -> RequestActivityItem {
        guard let availability, !availability.isEmpty else { return item }
        var updated = item
        var changed = false
        for format in updated.requestedFormats {
            guard availability.has(format) else { continue }
            if let index = updated.formatStatuses.firstIndex(where: { $0.format == format }) {
                if updated.formatStatuses[index].status != .availableInLibrary {
                    updated.formatStatuses[index].status = .availableInLibrary
                    updated.formatStatuses[index].detail = "Available in Library"
                    updated.formatStatuses[index].updatedAt = now
                    updated.formatStatuses[index].consecutiveLookupFailures = 0
                    changed = true
                }
            } else {
                updated.formatStatuses.append(
                    RequestFormatStatus(
                        format: format,
                        status: .availableInLibrary,
                        detail: "Available in Library",
                        updatedAt: now,
                    )
                )
                changed = true
            }
        }
        if changed {
            updated.updatedAt = now
            if !updated.formatStatuses.contains(where: { $0.status.needsAttentionBucket }) {
                updated.attentionReason = nil
                updated.lastError = nil
            }
        }
        return updated
    }

    public static func apply(
        _ item: RequestActivityItem,
        matcher: RequestLibraryMatcher,
        now: Date = Date(),
    ) -> RequestActivityItem {
        apply(item, availability: matcher.availability(for: item), now: now)
    }
}
