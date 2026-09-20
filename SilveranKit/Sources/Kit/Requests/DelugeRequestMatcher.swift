import Foundation

/// Detectable format hints in a Deluge torrent name/path.
public enum DelugeTorrentFormatEvidence: Equatable, Sendable {
    case audiobook
    case ebook
    case mixed
    case none
}

/// Pure request ↔ Deluge torrent matching. Never guesses.
public enum DelugeRequestMatcher {
    public static func match(
        item: RequestActivityItem,
        format: BookRequestFormat,
        index: DelugeTorrentIndex,
        excludingTorrentIDs: Set<String> = [],
    ) -> DelugeMatchResult {
        if let existing = item.downloadState(for: format)?.torrentID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !existing.isEmpty
        {
            if let hit = index.torrent(id: existing) {
                return .matched(hit)
            }
            // Persisted id missing from Deluge — fall through to name matching.
        }

        let candidates = index.torrents.filter { torrent in
            guard !excludingTorrentIDs.contains(torrent.id) else { return false }
            guard scores(item: item, format: format, torrent: torrent) != nil else { return false }
            return isFormatCompatible(
                format: format,
                torrent: torrent,
                requestedFormats: item.requestedFormats,
            )
        }
        if candidates.isEmpty { return .noMatch }
        if candidates.count > 1 { return .ambiguous }
        return .matched(candidates[0])
    }

    /// Returns a confidence tag when the torrent is an acceptable book-identity match.
    static func scores(
        item: RequestActivityItem,
        format: BookRequestFormat,
        torrent: DelugeTorrentSnapshot,
    ) -> String? {
        let haystack = normalize("\(torrent.name) \(torrent.savePath ?? "")")
        guard !haystack.isEmpty else { return nil }

        if let isbn = normalizedISBN(item.isbn), !isbn.isEmpty {
            if haystack.contains(isbn) { return "isbn" }
        }

        let title = normalize(item.title)
        guard title.count >= 4 else { return nil }

        // Strong exact title token presence: normalized torrent name equals title,
        // or contains title as a contiguous phrase bounded by separators.
        if haystack == title { return "exact-title" }
        if containsPhrase(haystack, phrase: title) {
            let author = normalize(item.author)
            if author.isEmpty { return "strong-title" }
            let authorUnits = authorTokens(from: item.author)
            if authorUnits.contains(where: { containsPhrase(haystack, phrase: $0) }) {
                return "title-author"
            }
            // Title match alone is only accepted when the title is long / distinctive.
            if title.count >= 12 { return "strong-title" }
            return nil
        }
        return nil
    }

    /// Format-aware eligibility after book identity has already matched.
    public static func isFormatCompatible(
        format: BookRequestFormat,
        torrent: DelugeTorrentSnapshot,
        requestedFormats: [BookRequestFormat],
    ) -> Bool {
        switch formatEvidence(name: torrent.name, savePath: torrent.savePath) {
            case .audiobook:
                return format == .audiobook
            case .ebook:
                return format == .ebook
            case .mixed:
                // Explicit dual signals: eligible for either; claim tracking prevents double-attach.
                return true
            case .none:
                let unique = Set(requestedFormats)
                // Single-format requests may attach a format-unknown torrent.
                // Both-format requests must not guess.
                return unique.count <= 1 && unique.contains(format)
        }
    }

    /// Conservative format signals from torrent name/path. Tokenized — no loose substrings.
    public static func formatEvidence(name: String, savePath: String?) -> DelugeTorrentFormatEvidence {
        let haystack = normalize("\(name) \(savePath ?? "")")
        guard !haystack.isEmpty else { return .none }
        let tokens = Set(haystack.split(separator: " ").map(String.init))

        let hasAudiobook =
            tokens.contains("audiobook")
            || tokens.contains("m4b")
            || tokens.contains("mp3")
            || tokens.contains("m4a")
            || tokens.contains("opus")
            || tokens.contains("flac")
            || containsPhrase(haystack, phrase: "audio book")

        let hasEbook =
            tokens.contains("ebook")
            || tokens.contains("epub")
            || tokens.contains("azw")
            || tokens.contains("azw3")
            || tokens.contains("mobi")
            || tokens.contains("pdf")
            || containsPhrase(haystack, phrase: "e book")

        switch (hasAudiobook, hasEbook) {
            case (true, true): return .mixed
            case (true, false): return .audiobook
            case (false, true): return .ebook
            case (false, false): return .none
        }
    }

    // MARK: - Normalization

    public static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }
        let collapsed = String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed
    }

    public static func normalizedISBN(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let digits = raw.filter(\.isNumber)
        guard digits.count == 10 || digits.count == 13 else { return nil }
        return digits
    }

    private static func authorTokens(from author: String) -> [String] {
        let units = RequestLibraryMatcher.authorUnits(from: author)
        let normalized = units.map(normalize).filter { $0.count >= 3 }
        if !normalized.isEmpty { return normalized }
        let whole = normalize(author)
        return whole.isEmpty ? [] : [whole]
    }

    private static func containsPhrase(_ haystack: String, phrase: String) -> Bool {
        guard !phrase.isEmpty else { return false }
        if haystack == phrase { return true }
        let padded = " \(haystack) "
        let needle = " \(phrase) "
        return padded.contains(needle)
    }
}
