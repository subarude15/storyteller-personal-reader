import Foundation

// Storyteller can associate an e-book and audiobook only by `POST /api/v2/books/merge`.
// That call moves format rows onto the first book, deletes the other book records, and
// relocates files. `DELETE /api/v2/books/{id}/replace-asset` removes a format and deletes
// library-owned files. Neither is a reversible link that keeps both records.
//
// This file stores the association in the app's existing private-collection blob
// (`.inkamp.bookFormatLinks.v1`), the same server-synced metadata used for stats and
// podcasts. Storyteller stays authoritative for records, files, and progress. The blob
// syncs across devices signed into that server. It is not a second copy of the books.
//
// Readaloud creation still uses `POST /api/v2/books/{id}/process`, and only when one
// record already has both an e-book and an audiobook. Split records are not sent through
// merge, and the UI must not call them ready until a record's readaloud status is ALIGNED.

public enum BookFormatKind: String, Codable, Sendable, CaseIterable {
    case ebook
    case audiobook
    case readaloud
}

public enum BookFormatPlaybackKind: String, Codable, Sendable {
    case read
    case listen
    case readAndListen

    public var title: String {
        switch self {
            case .read: "Read"
            case .listen: "Listen"
            case .readAndListen: "Read & Listen"
        }
    }
}

public struct BookFormatPlayback: Equatable, Sendable, Identifiable {
    public var id: String { "\(bookID.description)|\(kind.rawValue)" }
    public var bookID: BookID
    public var kind: BookFormatPlaybackKind

    public init(bookID: BookID, kind: BookFormatPlaybackKind) {
        self.bookID = bookID
        self.kind = kind
    }
}

public struct BookFormatLink: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var members: [BookID]
    public var primary: BookID
    public var updatedAt: Date
    /// Tombstone so an unlink syncs. Active links are `removed == false`.
    public var removed: Bool

    public init(
        id: String,
        members: [BookID],
        primary: BookID,
        updatedAt: Date,
        removed: Bool,
    ) {
        self.id = id
        self.members = members
        self.primary = primary
        self.updatedAt = updatedAt
        self.removed = removed
    }

    public static func identifier(for members: [BookID]) -> String {
        members.map(\.description).sorted().joined(separator: "|")
    }
}

public struct BookFormatLinkDocument: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let collectionName = ".inkamp.bookFormatLinks.v1"

    public var schemaVersion: Int
    public var updatedAt: Date
    public var links: [BookFormatLink]

    public init(
        schemaVersion: Int = BookFormatLinkDocument.schemaVersion,
        updatedAt: Date = .distantPast,
        links: [BookFormatLink] = [],
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.links = links
    }

    public static var empty: BookFormatLinkDocument { BookFormatLinkDocument() }

    public var activeLinks: [BookFormatLink] {
        links.filter { !$0.removed }
    }
}

public struct BookFormatCandidate: Equatable, Sendable, Identifiable {
    public var id: BookID { book.id }
    public var book: BookMetadata
    public var score: Int
    public var editionSummary: String
    public var badges: [String]

    public init(book: BookMetadata, score: Int, editionSummary: String, badges: [String]) {
        self.book = book
        self.score = score
        self.editionSummary = editionSummary
        self.badges = badges
    }
}

public enum BookFormatLinkAction: Sendable {
    case link
    case unlink
    case retry
}

public enum BookFormatLinkFailure: Equatable, Sendable {
    case offline
    case authenticationExpired
    case sourceMissing
    case incompatible
    case alreadyLinked
    case serverRejected
    case timeout
    case duplicateSubmission
    case notLinked

    public func message(action: BookFormatLinkAction) -> String {
        let unchanged: String =
            switch action {
                case .link: "Nothing was linked."
                case .unlink: "The formats are still linked."
                case .retry: "Readaloud was not started."
            }
        switch self {
            case .offline:
                return "You're offline. Connect to Storyteller, then try again. \(unchanged)"
            case .authenticationExpired:
                return
                    "Storyteller refused the request. Sign in again, or ask for permission to update collections. \(unchanged)"
            case .sourceMissing:
                return
                    "One of these books is no longer in the library. Refresh and choose it again. \(unchanged)"
            case .incompatible:
                return
                    "These books can't be linked. Choose an e-book, audiobook, or Readaloud that doesn't already share a format. \(unchanged)"
            case .alreadyLinked:
                return "That book is already linked to another edition. Unlink it there first. \(unchanged)"
            case .serverRejected:
                return
                    "Storyteller didn't accept the change. It may have timed out or rejected it. \(unchanged)"
            case .timeout:
                return "Storyteller didn't respond in time. \(unchanged)"
            case .duplicateSubmission:
                return "That change is already being saved."
            case .notLinked:
                return "These formats aren't linked, so there was nothing to unlink."
        }
    }
}

public enum ReadaloudPhase: Equatable, Sendable {
    case unavailable
    case queued
    case processing
    case ready
    case failed
}

public struct ReadaloudAlignment: Equatable, Sendable {
    public var phase: ReadaloudPhase
    public var bookID: BookID?
    public var canRetry: Bool
    public var canStart: Bool
    public var message: String

    public init(
        phase: ReadaloudPhase,
        bookID: BookID?,
        canRetry: Bool,
        canStart: Bool,
        message: String,
    ) {
        self.phase = phase
        self.bookID = bookID
        self.canRetry = canRetry
        self.canStart = canStart
        self.message = message
    }
}

public struct BookFormatLinkConfirmation: Equatable, Sendable {
    public var title: String
    public var body: String
    public var alignment: ReadaloudAlignment

    public init(title: String, body: String, alignment: ReadaloudAlignment) {
        self.title = title
        self.body = body
        self.alignment = alignment
    }
}

public enum BookFormatLinkFetchResult: Equatable, Sendable {
    case unavailable(reason: String)
    case empty
    case document(BookFormatLinkDocument)
}

public enum BookFormatLinkPushResult: Equatable, Sendable {
    case success
    case failure(reason: String)
}

public enum BookFormatLinkOutcome: Equatable, Sendable {
    case linked(BookFormatLinkDocument, ReadaloudAlignment)
    case unlinked(BookFormatLinkDocument)
    case alignment(ReadaloudAlignment)
    case failed(BookFormatLinkFailure)
}

public enum BookFormatLinkMerge {
    public static func merge(
        local: BookFormatLinkDocument,
        remote: BookFormatLinkDocument,
    ) -> BookFormatLinkDocument {
        var byID: [String: BookFormatLink] = [:]
        for link in local.links {
            byID[link.id] = link
        }
        for link in remote.links {
            if let existing = byID[link.id] {
                if link.updatedAt >= existing.updatedAt {
                    byID[link.id] = link
                }
            } else {
                byID[link.id] = link
            }
        }
        let links = byID.values.sorted { $0.id < $1.id }
        return BookFormatLinkDocument(
            updatedAt: max(local.updatedAt, remote.updatedAt),
            links: links,
        )
    }

    public static func encodeDescription(_ document: BookFormatLinkDocument) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        guard let string = String(data: data, encoding: .utf8) else {
            throw BookFormatLinkCodecError.utf8
        }
        return string
    }

    public static func decodeDescription(_ string: String) throws -> BookFormatLinkDocument {
        guard let data = string.data(using: .utf8) else {
            throw BookFormatLinkCodecError.utf8
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BookFormatLinkDocument.self, from: data)
    }

    public static func failure(forTransportReason reason: String) -> BookFormatLinkFailure {
        let lower = reason.lowercased()
        if lower.contains("auth") || lower.contains("credential") || lower.contains("unauthorized")
        {
            return .authenticationExpired
        }
        if lower.contains("timeout") || lower.contains("timed out") {
            return .timeout
        }
        if lower.contains("offline") || lower.contains("connection") {
            return .offline
        }
        if lower.contains("not found") || lower.contains("missing") {
            return .sourceMissing
        }
        return .serverRejected
    }
}

public enum BookFormatLinkCodecError: Error, Sendable {
    case utf8
}

public enum BookFormatTexts {
    public static func fold(_ raw: String) -> String {
        let lowered = raw.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX"),
        )
        let filtered = lowered.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " "
        }
        let collapsed = String(String.UnicodeScalarView(filtered))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return collapsed
    }

    public static func titleKey(_ title: String, subtitle: String?) -> String {
        var core = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let subtitle {
            let trimmed = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, core.lowercased().hasSuffix(trimmed.lowercased()), core.count > trimmed.count
            {
                core = String(core.dropLast(trimmed.count))
                core = core.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
            }
        }
        for separator in [":", " — ", " – ", " - "] {
            if let range = core.range(of: separator) {
                let head = core[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                if head.count >= 3 {
                    core = String(head)
                    break
                }
            }
        }
        var folded = fold(core)
        for article in ["the ", "a ", "an "] where folded.hasPrefix(article) {
            folded = String(folded.dropFirst(article.count))
            break
        }
        return folded
    }

    public static func isbnTokens(in fields: [String?]) -> Set<String> {
        var tokens: Set<String> = []
        for field in fields {
            guard let field else { continue }
            var digits = ""
            func flush() {
                if digits.count == 10 || digits.count == 13 {
                    tokens.insert(digits.uppercased())
                }
                digits = ""
            }
            for character in field {
                if character.isNumber {
                    digits.append(character)
                } else if character == "-" {
                    continue
                } else if character == "X" || character == "x", digits.count == 9 {
                    digits.append("X")
                } else {
                    flush()
                }
            }
            flush()
        }
        return tokens
    }

    public static func badges(for book: BookMetadata) -> [String] {
        var badges: [String] = []
        let formats = BookFormatMatcher.presentFormats(book)
        if formats.contains(.ebook) { badges.append("E-book") }
        if formats.contains(.audiobook) { badges.append("Audiobook") }
        if formats.contains(.readaloud) {
            switch book.readaloud?.status?.uppercased() {
                case "ALIGNED": badges.append("Readaloud")
                case "QUEUED": badges.append("Readaloud · Queued")
                case "PROCESSING": badges.append("Readaloud · Processing")
                case "ERROR", "STOPPED": badges.append("Readaloud · Failed")
                default: badges.append("Readaloud")
            }
        }
        return badges
    }

    public static func editionSummary(for book: BookMetadata) -> String {
        var parts: [String] = []
        if let subtitle = book.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !subtitle.isEmpty {
            parts.append(subtitle)
        }
        if let year = BookMetadata.publicationYear(from: book.publicationDate) {
            parts.append(year)
        }
        if let series = book.series?.first {
            if let position = series.formattedPosition {
                parts.append("\(series.name) #\(position)")
            } else if !series.name.isEmpty {
                parts.append(series.name)
            }
        }
        if let narrator = book.narrators?.compactMap(\.name).first, !narrator.isEmpty {
            parts.append("Narrated by \(narrator)")
        }
        if let language = book.language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty {
            parts.append(language.uppercased())
        }
        return parts.isEmpty ? "No extra edition details" : parts.joined(separator: " · ")
    }

    public static func authorLine(for book: BookMetadata) -> String {
        let names = book.authors?.compactMap(\.name).filter { !$0.isEmpty } ?? []
        return names.isEmpty ? "Unknown author" : names.joined(separator: ", ")
    }
}

public enum BookFormatMatcher {
    public static func presentFormats(_ book: BookMetadata) -> Set<BookFormatKind> {
        var formats: Set<BookFormatKind> = []
        if let ebook = book.ebook, !ebook.isMissing { formats.insert(.ebook) }
        if let audiobook = book.audiobook, !audiobook.isMissing { formats.insert(.audiobook) }
        if let readaloud = book.readaloud, !readaloud.isMissing { formats.insert(.readaloud) }
        return formats
    }

    public static func isPodcastLike(_ book: BookMetadata) -> Bool {
        if book.source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "podcast" {
            return true
        }
        return book.tagNames.contains { $0.compare("podcast", options: .caseInsensitive) == .orderedSame }
    }

    public static func isCompatible(_ candidate: BookMetadata, with current: BookMetadata) -> Bool {
        guard candidate.id != current.id else { return false }
        guard candidate.sourceID == current.sourceID else { return false }
        guard !isPodcastLike(candidate), !isPodcastLike(current) else { return false }
        let left = presentFormats(current)
        let right = presentFormats(candidate)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left.isDisjoint(with: right)
    }

    public static func isLinked(_ bookID: BookID, links: [BookFormatLink]) -> Bool {
        links.contains { !$0.removed && $0.members.contains(bookID) }
    }

    public static func score(_ candidate: BookMetadata, against current: BookMetadata) -> Int {
        var score = 0
        let currentISBN = BookFormatTexts.isbnTokens(in: [current.title, current.subtitle, current.description])
        let candidateISBN = BookFormatTexts.isbnTokens(in: [
            candidate.title, candidate.subtitle, candidate.description,
        ])
        if !currentISBN.isEmpty, !currentISBN.isDisjoint(with: candidateISBN) {
            score += 1_000
        }
        let currentTitle = BookFormatTexts.titleKey(current.title, subtitle: current.subtitle)
        let candidateTitle = BookFormatTexts.titleKey(candidate.title, subtitle: candidate.subtitle)
        if !currentTitle.isEmpty, currentTitle == candidateTitle {
            score += 400
        } else if !currentTitle.isEmpty, !candidateTitle.isEmpty,
            min(currentTitle.count, candidateTitle.count) >= 4,
            currentTitle.contains(candidateTitle) || candidateTitle.contains(currentTitle)
        {
            score += 180
        }
        let currentAuthors = Set((current.authors ?? []).compactMap(\.name).map(BookFormatTexts.fold))
        let candidateAuthors = Set((candidate.authors ?? []).compactMap(\.name).map(BookFormatTexts.fold))
        if !currentAuthors.isEmpty, !currentAuthors.isDisjoint(with: candidateAuthors) {
            score += 250
        }
        let currentSeries = BookFormatTexts.fold(current.series?.first?.name ?? "")
        let candidateSeries = BookFormatTexts.fold(candidate.series?.first?.name ?? "")
        if !currentSeries.isEmpty, currentSeries == candidateSeries {
            score += 120
            if let left = current.series?.first?.position, let right = candidate.series?.first?.position, left == right
            {
                score += 40
            }
        }
        let currentYear = BookMetadata.publicationYear(from: current.publicationDate) ?? ""
        let candidateYear = BookMetadata.publicationYear(from: candidate.publicationDate) ?? ""
        if !currentYear.isEmpty, currentYear == candidateYear {
            score += 30
        }
        return score
    }

    public static func candidates(
        for current: BookMetadata,
        in library: [BookMetadata],
        links: [BookFormatLink],
        query: String = "",
    ) -> [BookFormatCandidate] {
        let needle = BookFormatTexts.fold(query)
        return library.compactMap { book -> BookFormatCandidate? in
            guard isCompatible(book, with: current) else { return nil }
            guard !isLinked(book.id, links: links) else { return nil }
            guard !isLinked(current.id, links: links) else { return nil }
            guard matches(book, needle: needle) else { return nil }
            return BookFormatCandidate(
                book: book,
                score: score(book, against: current),
                editionSummary: BookFormatTexts.editionSummary(for: book),
                badges: BookFormatTexts.badges(for: book),
            )
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let titleOrder = lhs.book.title.localizedStandardCompare(rhs.book.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return lhs.book.uuid < rhs.book.uuid
        }
    }

    private static func matches(_ book: BookMetadata, needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        var fields = [book.title, book.subtitle, book.language]
        fields.append(contentsOf: book.authors?.compactMap(\.name) ?? [])
        fields.append(contentsOf: book.narrators?.compactMap(\.name) ?? [])
        fields.append(contentsOf: book.series?.map(\.name) ?? [])
        if let year = BookMetadata.publicationYear(from: book.publicationDate) {
            fields.append(year)
        }
        let isbn = BookFormatTexts.isbnTokens(in: [book.title, book.subtitle, book.description]).joined(
            separator: " "
        )
        fields.append(isbn)
        return fields.contains { field in
            guard let field else { return false }
            return BookFormatTexts.fold(field).contains(needle)
        }
    }
}

public enum BookFormatGrouping {
    public static func visibleBooks(
        _ books: [BookMetadata],
        links: [BookFormatLink],
    ) -> [BookMetadata] {
        let ids = Set(books.map(\.id))
        var hidden: Set<BookID> = []
        for link in links where !link.removed {
            let present = link.members.filter { ids.contains($0) }
            guard present.count >= 2 else { continue }
            let primary = present.contains(link.primary) ? link.primary : present[0]
            for id in present where id != primary {
                hidden.insert(id)
            }
        }
        return books.filter { !hidden.contains($0.id) }
    }

    public static func members(
        of bookID: BookID,
        in books: [BookMetadata],
        links: [BookFormatLink],
    ) -> [BookMetadata] {
        let byID = Dictionary(books.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let link = links.first(where: { !$0.removed && $0.members.contains(bookID) }) else {
            return byID[bookID].map { [$0] } ?? []
        }
        var ordered: [BookMetadata] = []
        if let primary = byID[link.primary] {
            ordered.append(primary)
        }
        for id in link.members where id != link.primary {
            if let book = byID[id] {
                ordered.append(book)
            }
        }
        if ordered.isEmpty, let book = byID[bookID] {
            return [book]
        }
        return ordered
    }

    /// Playable formats across the group. Read & Listen is included only when Storyteller
    /// reports the readaloud status as ALIGNED.
    public static func playbackActions(for members: [BookMetadata]) -> [BookFormatPlayback] {
        var actions: [BookFormatPlayback] = []
        for book in members {
            let formats = BookFormatMatcher.presentFormats(book)
            if formats.contains(.ebook) {
                actions.append(BookFormatPlayback(bookID: book.id, kind: .read))
            }
            if formats.contains(.audiobook) {
                actions.append(BookFormatPlayback(bookID: book.id, kind: .listen))
            }
            if book.hasAvailableReadaloud {
                actions.append(BookFormatPlayback(bookID: book.id, kind: .readAndListen))
            }
        }
        return actions
    }
}

public enum BookFormatAlignment {
    public static func assess(_ members: [BookMetadata]) -> ReadaloudAlignment {
        let ranked = members.compactMap { member -> (BookMetadata, ReadaloudPhase)? in
            guard let phase = phase(for: member.readaloud?.status) else { return nil }
            return (member, phase)
        }
        .sorted { rank($0.1) > rank($1.1) }

        if let best = ranked.first {
            let bothFormats = hasBothSourceFormats(best.0)
            switch best.1 {
                case .ready:
                    return ReadaloudAlignment(
                        phase: .ready,
                        bookID: best.0.id,
                        canRetry: false,
                        canStart: false,
                        message:
                            "Storyteller already has a Readaloud for this book. That edition will be used. A new one will not be created.",
                    )
                case .queued:
                    return ReadaloudAlignment(
                        phase: .queued,
                        bookID: best.0.id,
                        canRetry: false,
                        canStart: false,
                        message: "Readaloud is queued on Storyteller. It is not ready for Read & Listen yet.",
                    )
                case .processing:
                    return ReadaloudAlignment(
                        phase: .processing,
                        bookID: best.0.id,
                        canRetry: false,
                        canStart: false,
                        message: "Readaloud is processing on Storyteller. It is not ready for Read & Listen yet.",
                    )
                case .failed:
                    return ReadaloudAlignment(
                        phase: .failed,
                        bookID: best.0.id,
                        canRetry: bothFormats,
                        canStart: false,
                        message: bothFormats
                            ? "Readaloud failed on Storyteller. You can retry. It is not ready for Read & Listen."
                            : "Readaloud failed. Storyteller can only retry alignment when that record already has both an e-book and an audiobook.",
                    )
                case .unavailable:
                    break
            }
        }

        if let readyHost = members.first(where: hasBothSourceFormats) {
            return ReadaloudAlignment(
                phase: .unavailable,
                bookID: readyHost.id,
                canRetry: false,
                canStart: true,
                message:
                    "Storyteller can align this record because it already has an e-book and an audiobook. Alignment is not started unless you ask. Read & Listen stays unavailable until Storyteller reports it ready.",
            )
        }

        return ReadaloudAlignment(
            phase: .unavailable,
            bookID: nil,
            canRetry: false,
            canStart: false,
            message:
                "Read & Listen is not available. Storyteller can only align an e-book and audiobook that already share one record. Linking these keeps both records and does not create a Readaloud.",
        )
    }

    public static func confirmation(current: BookMetadata, other: BookMetadata) -> BookFormatLinkConfirmation {
        let alignment = assess([current, other])
        let currentLine = recordLine(current)
        let otherLine = recordLine(other)
        let body = """
            \(currentLine)

            \(otherLine)

            Both records, files, downloads, bookmarks, and progress stay as they are. Nothing is deleted or rewritten.

            The link is saved in your private Storyteller library data and syncs to other devices signed into this server. This is not Storyteller's Merge Books action, which would delete one record.

            \(alignment.message)
            """
        return BookFormatLinkConfirmation(
            title: "Link these formats?",
            body: body,
            alignment: alignment,
        )
    }

    private static func recordLine(_ book: BookMetadata) -> String {
        let badges = BookFormatTexts.badges(for: book).joined(separator: ", ")
        let edition = BookFormatTexts.editionSummary(for: book)
        return """
            \(badges.isEmpty ? "Book" : badges): \(book.title)
            \(BookFormatTexts.authorLine(for: book))
            \(edition)
            """
    }

    private static func hasBothSourceFormats(_ book: BookMetadata) -> Bool {
        let formats = BookFormatMatcher.presentFormats(book)
        return formats.contains(.ebook) && formats.contains(.audiobook)
    }

    private static func phase(for status: String?) -> ReadaloudPhase? {
        switch status?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
            case "QUEUED": .queued
            case "PROCESSING": .processing
            case "ALIGNED": .ready
            case "ERROR", "STOPPED": .failed
            case nil, "": nil
            default: nil
        }
    }

    private static func rank(_ phase: ReadaloudPhase) -> Int {
        switch phase {
            case .ready: 5
            case .processing: 4
            case .queued: 3
            case .failed: 2
            case .unavailable: 1
        }
    }
}
