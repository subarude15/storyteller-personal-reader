import Foundation

/// A metadata-only suggestion. Never a download, catalog import, or file URL.
public struct ReadingIdea: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let title: String
    public let author: String
    public let coverURL: URL?
    public let blurb: String?
    /// Why this title was suggested from the local library.
    public let reason: String
    public let score: Double
    /// ISBN-13 when Open Library sent one. Used only to drop owned/finished matches.
    public let isbn: String?
    /// Subject headings (Open Library), capped at a handful for display.
    public let subjects: [String]
    /// First publication year (Open Library), when known.
    public let year: Int?

    public init(
        id: String,
        title: String,
        author: String,
        coverURL: URL?,
        blurb: String?,
        reason: String,
        score: Double,
        isbn: String? = nil,
        subjects: [String] = [],
        year: Int? = nil,
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.coverURL = coverURL
        self.blurb = blurb
        self.reason = reason
        self.score = score
        self.isbn = isbn
        self.subjects = subjects
        self.year = year
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, author, coverURL, blurb, reason, score, isbn, subjects, year
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        author = try c.decode(String.self, forKey: .author)
        coverURL = try c.decodeIfPresent(URL.self, forKey: .coverURL)
        blurb = try c.decodeIfPresent(String.self, forKey: .blurb)
        reason = try c.decode(String.self, forKey: .reason)
        score = try c.decode(Double.self, forKey: .score)
        isbn = try c.decodeIfPresent(String.self, forKey: .isbn)
        subjects = try c.decodeIfPresent([String].self, forKey: .subjects) ?? []
        year = try c.decodeIfPresent(Int.self, forKey: .year)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(author, forKey: .author)
        try c.encodeIfPresent(coverURL, forKey: .coverURL)
        try c.encodeIfPresent(blurb, forKey: .blurb)
        try c.encode(reason, forKey: .reason)
        try c.encode(score, forKey: .score)
        try c.encodeIfPresent(isbn, forKey: .isbn)
        try c.encode(subjects, forKey: .subjects)
        try c.encodeIfPresent(year, forKey: .year)
    }
}

public struct OpenLibraryWork: Equatable, Sendable {
    public let key: String
    public let title: String
    public let author: String
    public let coverURL: URL?
    public let blurb: String?
    public let isbn: String?
    public let subjects: [String]
    public let year: Int?

    public init(
        key: String,
        title: String,
        author: String,
        coverURL: URL?,
        blurb: String?,
        isbn: String? = nil,
        subjects: [String] = [],
        year: Int? = nil,
    ) {
        self.key = key
        self.title = title
        self.author = author
        self.coverURL = coverURL
        self.blurb = blurb
        self.isbn = isbn
        self.subjects = subjects
        self.year = year
    }
}

public struct ReadingIdeaQuery: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case seriesGap
        case author
        case tag
    }

    public let kind: Kind
    public let term: String
    public let weight: Double
    public let missingPosition: Int?
    public let authorHint: String?
    public let reason: String

    public init(
        kind: Kind,
        term: String,
        weight: Double,
        missingPosition: Int?,
        authorHint: String?,
        reason: String,
    ) {
        self.kind = kind
        self.term = term
        self.weight = weight
        self.missingPosition = missingPosition
        self.authorHint = authorHint
        self.reason = reason
    }
}

/// Ranks unowned “ideas for later” from books already in the Storyteller library.
/// Series next-unread first, then same authors, then shared tags. Owned and finished
/// rows drop out by title+author, or by ISBN when one is present.
public enum ReadingHabitIdeas {
    public static func queries(
        from library: [BookMetadata],
        now: Date = Date(),
        limit: Int = 28,
    ) -> [ReadingIdeaQuery] {
        let habits = library.compactMap { book -> (BookMetadata, Habit)? in
            guard let habit = habit(for: book, now: now) else { return nil }
            return (book, habit)
        }
        guard !habits.isEmpty, limit > 0 else { return [] }

        var queries = seriesQueries(habits)
        queries.append(contentsOf: authorQueries(habits))
        queries.append(contentsOf: tagQueries(habits))
        return Array(
            queries.sorted { lhs, rhs in
                if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
                return kindRank(lhs.kind) < kindRank(rhs.kind)
            }.prefix(limit)
        )
    }

    public static func ideas(
        queries: [ReadingIdeaQuery],
        worksByQuery: [[OpenLibraryWork]],
        owned: [BookMetadata],
        limit: Int = 48,
    ) -> [ReadingIdea] {
        guard limit > 0 else { return [] }
        let identity = LibraryIdentity(books: owned)
        let ordered = queries.enumerated().sorted { lhs, rhs in
            if lhs.element.weight != rhs.element.weight { return lhs.element.weight > rhs.element.weight }
            return kindRank(lhs.element.kind) < kindRank(rhs.element.kind)
        }

        var ideas: [ReadingIdea] = []
        var seen: Set<String> = []
        for (index, query) in ordered {
            let reason = query.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reason.isEmpty else { continue }
            let works = index < worksByQuery.count ? worksByQuery[index] : []
            let fresh = works.filter { work in
                !identity.contains(title: work.title, author: work.author, isbn: work.isbn)
            }
            if fresh.isEmpty {
                guard query.kind == .seriesGap, let position = query.missingPosition else { continue }
                let idea = seriesPlaceholder(query, position: position, reason: reason)
                guard !identity.contains(title: idea.title, author: idea.author, isbn: nil) else {
                    continue
                }
                let key = normalize(idea.title)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                ideas.append(idea)
                continue
            }
            let ranked: [OpenLibraryWork]
            if query.kind == .seriesGap, let position = query.missingPosition {
                ranked = fresh.sorted { lhs, rhs in
                    let left = matchesSeriesPosition(lhs.title, position)
                    let right = matchesSeriesPosition(rhs.title, position)
                    if left != right { return left && !right }
                    return false
                }
            } else {
                ranked = fresh
            }
            let take = query.kind == .author ? 4 : 3
            for work in ranked.prefix(take) {
                // Dedupe by ISBN when present, else title+author.
                let key: String
                if let isbn = work.isbn {
                    key = "isbn:\(isbn)"
                } else {
                    key = "\(normalize(work.title))|\(LibraryIdentity.authorKey(work.author))"
                }
                guard seen.insert(key).inserted else { continue }
                let id = work.key.isEmpty
                    ? "title:\(key)"
                    : "ol:\(work.key)"
                ideas.append(
                    ReadingIdea(
                        id: id,
                        title: work.title,
                        author: work.author,
                        coverURL: work.coverURL,
                        blurb: work.blurb,
                        reason: reason,
                        score: query.weight,
                        isbn: work.isbn,
                        subjects: work.subjects,
                        year: work.year,
                    )
                )
            }
        }

        return Array(
            ideas.sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                let title = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                if title != .orderedSame { return title == .orderedAscending }
                return lhs.id < rhs.id
            }.prefix(limit)
        )
    }

    /// Offline / failed lookup keeps the last good list. Never substitutes owned library titles.
    public static func present(
        fresh: [ReadingIdea],
        lookupFailed: Bool,
        cached: [ReadingIdea],
        owned: [BookMetadata],
    ) -> [ReadingIdea] {
        excludingOwned(lookupFailed ? cached : fresh, library: owned)
    }

    public static func excludingOwned(_ ideas: [ReadingIdea], library: [BookMetadata]) -> [ReadingIdea] {
        let identity = LibraryIdentity(books: library)
        return ideas.filter {
            !identity.contains(title: $0.title, author: $0.author, isbn: $0.isbn)
        }
    }

    /// Stable key for "Not interested": Open Library work key first, then ISBN,
    /// then normalized title+author.
    public static func dismissKey(for idea: ReadingIdea) -> String {
        if idea.id.hasPrefix("ol:") { return idea.id }
        if let isbn = idea.isbn, !isbn.isEmpty { return "isbn:\(isbn)" }
        return "title:\(normalize(idea.title))|\(LibraryIdentity.authorKey(idea.author))"
    }

    public static func excludingDismissed(_ ideas: [ReadingIdea], dismissed: Set<String>) -> [ReadingIdea] {
        ideas.filter { !dismissed.contains(dismissKey(for: $0)) }
    }

    public static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX"),
            )
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private enum Habit {
        case finished(Double)
        case inProgress(Double)

        var weight: Double {
            switch self {
            case .finished(let weight), .inProgress(let weight):
                return weight
            }
        }

        var isFinished: Bool {
            if case .finished = self { return true }
            return false
        }
    }

    private static func habit(for book: BookMetadata, now: Date) -> Habit? {
        let status = normalize(book.status?.name ?? "")
        if status == "abandoned" || status == "did not finish" { return nil }
        let finished = status == "read" || status == "finished" || status == "complete"
            || status == "completed" || book.progress >= 0.98
        let started = finished || book.progress > 0.01 || status.contains("reading")
            || status.contains("progress") || status == "started"
        guard started else { return nil }
        let recency = recencyMultiplier(for: book, now: now)
        if finished { return .finished(1.0 * recency) }
        return .inProgress(0.75 * recency)
    }

    private static func recencyMultiplier(for book: BookMetadata, now: Date) -> Double {
        guard let date = activityDate(book) else { return 0.55 }
        let days = now.timeIntervalSince(date) / 86_400
        if days <= 14 { return 1.4 }
        if days <= 90 { return 1.0 }
        return 0.55
    }

    private static func activityDate(_ book: BookMetadata) -> Date? {
        let updated = parseDate(book.updatedAt)
        let position: Date? = book.position?.timestamp.map { Date(timeIntervalSince1970: $0 / 1000) }
        switch (updated, position) {
        case let (updated?, position?):
            return max(updated, position)
        case let (updated?, nil):
            return updated
        case let (nil, position?):
            return position
        case (nil, nil):
            return nil
        }
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: trimmed) { return date }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(secondsFromGMT: 0)
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: trimmed)
    }

    private struct SeriesBucket {
        var display: String
        var weight: Double
        var positions: Set<Int>
        var finishedPositions: Set<Int>
        var authors: [String: Double]
    }

    private static func seriesQueries(_ habits: [(BookMetadata, Habit)]) -> [ReadingIdeaQuery] {
        var buckets: [String: SeriesBucket] = [:]
        for (book, habit) in habits {
            for series in book.series ?? [] {
                let display = series.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = normalize(display)
                guard !key.isEmpty else { continue }
                var bucket = buckets[key] ?? SeriesBucket(
                    display: display,
                    weight: 0,
                    positions: [],
                    finishedPositions: [],
                    authors: [:],
                )
                bucket.weight += habit.weight
                if let position = integerPosition(series.position) {
                    bucket.positions.insert(position)
                    if habit.isFinished { bucket.finishedPositions.insert(position) }
                }
                for name in authorNames(book) {
                    bucket.authors[name, default: 0] += habit.weight
                }
                buckets[key] = bucket
            }
        }

        var queries: [ReadingIdeaQuery] = []
        for bucket in buckets.values {
            let positions = bucket.positions.sorted()
            guard let min = positions.first, let max = positions.last else { continue }
            var missing: [(Int, Bool)] = []
            if max > min {
                for number in (min + 1) ..< max where !bucket.positions.contains(number) {
                    missing.append((number, false))
                }
            }
            if missing.isEmpty, bucket.finishedPositions.contains(max) {
                missing.append((max + 1, true))
            }
            let author = bucket.authors.max { $0.value < $1.value }?.key
            // Denser: list up to three missing slots per series.
            for (number, isNext) in missing.prefix(3) {
                let reason = becauseYouLike([bucket.display, author].compactMap { $0 })
                queries.append(
                    ReadingIdeaQuery(
                        kind: .seriesGap,
                        term: bucket.display,
                        weight: bucket.weight * (isNext ? 1.3 : 1.8),
                        missingPosition: number,
                        authorHint: author,
                        reason: reason,
                    )
                )
            }
        }
        return queries
    }

    private struct AuthorAccum {
        var display: String
        var weight: Double
        var topTitle: String?
        var topTitleWeight: Double = 0
    }

    private static func authorQueries(_ habits: [(BookMetadata, Habit)]) -> [ReadingIdeaQuery] {
        var weights: [String: AuthorAccum] = [:]
        for (book, habit) in habits {
            for name in authorNames(book) {
                let key = normalize(name)
                var entry = weights[key] ?? AuthorAccum(display: name, weight: 0)
                entry.weight += habit.weight
                let title = book.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty, habit.weight > entry.topTitleWeight {
                    entry.topTitle = title
                    entry.topTitleWeight = habit.weight
                }
                weights[key] = entry
            }
        }
        return weights.values
            .sorted { $0.weight > $1.weight }
            .prefix(8)
            .map { entry in
                ReadingIdeaQuery(
                    kind: .author,
                    term: entry.display,
                    weight: entry.weight,
                    missingPosition: nil,
                    authorHint: entry.display,
                    reason: becauseYouLike([entry.topTitle, entry.display].compactMap { $0 }),
                )
            }
    }

    private struct TagAccum {
        var display: String
        var weight: Double
        var books: Int
        var authors: [String: Double] = [:]
    }

    private static func tagQueries(_ habits: [(BookMetadata, Habit)]) -> [ReadingIdeaQuery] {
        var weights: [String: TagAccum] = [:]
        for (book, habit) in habits {
            var seen: Set<String> = []
            for raw in book.tagNames {
                let display = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = normalize(display)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                var entry = weights[key] ?? TagAccum(display: display, weight: 0, books: 0)
                entry.weight += habit.weight
                entry.books += 1
                for name in authorNames(book) {
                    entry.authors[name, default: 0] += habit.weight
                }
                weights[key] = entry
            }
        }
        return weights.values
            .filter { $0.books >= 2 }
            .sorted { $0.weight > $1.weight }
            .prefix(8)
            .map { entry in
                let topAuthor = entry.authors.max { $0.value < $1.value }?.key
                ReadingIdeaQuery(
                    kind: .tag,
                    term: entry.display,
                    weight: entry.weight * (1 + 0.2 * Double(entry.books - 1)),
                    missingPosition: nil,
                    authorHint: nil,
                    reason: becauseYouLike([entry.display, topAuthor].compactMap { $0 }),
                )
            }
    }

    /// Builds an explicit "Because you like X, Y" callout (2 anchors max). Never
    /// a vague one-word reason.
    private static func becauseYouLike(_ anchors: [String]) -> String {
        let cleaned = anchors.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !cleaned.isEmpty else { return "Recommended for you" }
        return "Because you like " + cleaned.joined(separator: ", ")
    }

    private static func seriesPlaceholder(_ query: ReadingIdeaQuery, position: Int, reason: String) -> ReadingIdea {
        let title = "\(query.term) #\(position)"
        return ReadingIdea(
            id: "series:\(normalize(query.term)):\(position)",
            title: title,
            author: query.authorHint ?? "",
            coverURL: nil,
            blurb: nil,
            reason: reason,
            score: query.weight,
        )
    }

    private static func authorNames(_ book: BookMetadata) -> [String] {
        (book.authors ?? []).compactMap { creator in
            let name = (creator.name ?? creator.fileAs)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let name, !name.isEmpty else { return nil }
            return name
        }
    }

    private static func integerPosition(_ value: Float?) -> Int? {
        guard let value, value >= 1, value < 500 else { return nil }
        let rounded = value.rounded()
        guard abs(value - rounded) < 0.01 else { return nil }
        return Int(rounded)
    }

    private static func kindRank(_ kind: ReadingIdeaQuery.Kind) -> Int {
        switch kind {
        case .seriesGap: return 0
        case .author: return 1
        case .tag: return 2
        }
    }

    private static func matchesSeriesPosition(_ title: String, _ position: Int) -> Bool {
        let name = normalize(title)
        if name.contains("#\(position)") || name.hasSuffix(" \(position)") { return true }
        if name.contains("book \(position)") || name.contains("volume \(position)") { return true }
        return name.contains("vol \(position)")
    }
}

/// Owned and finished library rows. Match title+author when both exist, title alone
/// when an author is missing, and ISBN-13 when either side has one.
private struct LibraryIdentity {
    var pairs: Set<String>
    var titles: Set<String>
    var titleOnly: Set<String>
    var isbns: Set<String>

    init(books: [BookMetadata]) {
        pairs = []
        titles = []
        titleOnly = []
        isbns = []
        for book in books {
            let title = ReadingHabitIdeas.normalize(book.title)
            guard !title.isEmpty else { continue }
            titles.insert(title)
            let authors = Self.authorKeys(book)
            if authors.isEmpty {
                titleOnly.insert(title)
            } else {
                for author in authors {
                    pairs.insert("\(title)|\(author)")
                }
            }
            for isbn in Self.isbn13s(in: book.description) {
                isbns.insert(isbn)
            }
        }
    }

    func contains(title: String, author: String, isbn: String?) -> Bool {
        if let isbn, let normalized = Self.isbn13(isbn), isbns.contains(normalized) {
            return true
        }
        let titleKey = ReadingHabitIdeas.normalize(title)
        guard !titleKey.isEmpty else { return false }
        if titleOnly.contains(titleKey) { return true }
        let authorKey = Self.authorKey(author)
        if authorKey.isEmpty { return titles.contains(titleKey) }
        return pairs.contains("\(titleKey)|\(authorKey)")
    }

    static func authorKey(_ name: String) -> String {
        ReadingHabitIdeas.normalize(name)
            .split { $0 == "," || $0.isWhitespace }
            .map(String.init)
            .filter { !$0.isEmpty }
            .sorted()
            .joined(separator: " ")
    }

    static func authorKeys(_ book: BookMetadata) -> [String] {
        var seen: Set<String> = []
        return (book.authors ?? []).compactMap { creator in
            let raw = (creator.name ?? creator.fileAs)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let key = authorKey(raw)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return key
        }
    }

    static func isbn13s(in text: String?) -> [String] {
        guard let text else { return [] }
        var found: [String] = []
        var buffer = ""
        func flush() {
            if let isbn = isbn13(buffer) { found.append(isbn) }
            buffer.removeAll(keepingCapacity: true)
        }
        for character in text {
            if character.isNumber || character == "-" || character == " " || character == "X"
                || character == "x"
            {
                buffer.append(character)
            } else {
                flush()
            }
        }
        flush()
        return found
    }

    /// ponytail: ISBN-10 → 13 without checksum verify. Upgrade by rejecting bad check digits.
    static func isbn13(_ raw: String) -> String? {
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
}

/// Open Library search for titles the library does not already own.
/// ponytail: search.json only — no Hardcover, no series-index match. Upgrade by
/// preferring a Hardcover works lookup when a token is already stored.
public enum OpenLibraryIdeaLookup {
    public static func works(for queries: [ReadingIdeaQuery]) async -> [[OpenLibraryWork]] {
        var results = Array(repeating: [OpenLibraryWork](), count: queries.count)
        await withTaskGroup(of: (Int, [OpenLibraryWork]).self) { group in
            for (index, query) in queries.enumerated() {
                group.addTask {
                    (index, await search(query))
                }
            }
            for await (index, works) in group {
                results[index] = works
            }
        }
        return results
    }

    public static func parse(_ data: Data) -> [OpenLibraryWork] {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let docs = object["docs"] as? [[String: Any]]
        else { return [] }

        return docs.compactMap { doc in
            let title = (doc["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { return nil }
            let author = (doc["author_name"] as? [String])?.first ?? ""
            let key = doc["key"] as? String ?? ""
            let cover: URL? = {
                guard let id = intValue(doc["cover_i"]) else { return nil }
                return URL(string: "https://covers.openlibrary.org/b/id/\(id)-M.jpg")
            }()
            let isbn = (doc["isbn"] as? [String])?.compactMap(LibraryIdentity.isbn13).first
            let subjects = stringArray(doc["subject"], cap: 4)
            let year = intValue(doc["first_publish_year"])
            return OpenLibraryWork(
                key: key,
                title: title,
                author: author,
                coverURL: cover,
                blurb: blurb(doc["first_sentence"]),
                isbn: isbn,
                subjects: subjects,
                year: year,
            )
        }
    }

    static func url(for query: ReadingIdeaQuery) -> URL? {
        var components = URLComponents(string: "https://openlibrary.org/search.json")
        let limit: String
        switch query.kind {
        case .author: limit = "15"
        case .seriesGap, .tag: limit = "15"
        }
        var items = [
            URLQueryItem(name: "limit", value: limit),
            URLQueryItem(
                name: "fields",
                value: "key,title,author_name,cover_i,first_sentence,isbn,first_publish_year,subject",
            ),
        ]
        switch query.kind {
        case .seriesGap:
            let position = query.missingPosition.map { " \($0)" } ?? ""
            items.append(URLQueryItem(name: "q", value: query.term + position))
            if let author = query.authorHint, !author.isEmpty {
                items.append(URLQueryItem(name: "author", value: author))
            }
        case .author:
            items.append(URLQueryItem(name: "author", value: query.term))
        case .tag:
            items.append(URLQueryItem(name: "subject", value: query.term))
        }
        components?.queryItems = items
        return components?.url
    }

    private static func search(_ query: ReadingIdeaQuery) async -> [OpenLibraryWork] {
        guard let url = url(for: query) else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                return []
            }
            return parse(data)
        } catch {
            return []
        }
    }

    /// Fetches a single work's description/subjects/year from `/works/{key}.json`,
    /// used to backfill a detail blurb when `first_sentence` was missing on search.json.
    public static func fetchDetail(forKey key: String) async -> OpenLibraryWorkDetail? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let path = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        let work = await fetchAndParseDetail(urlString: "https://openlibrary.org\(path).json")

        // Prefer the work description. When a work carries no synopsis, fall back
        // to the first edition's description (many works only have one there).
        if (work?.description ?? "").isEmpty {
            if let editionKey = await fetchFirstEditionKey(workKey: trimmed) {
                let editionPath = editionKey.hasPrefix("/") ? editionKey : "/" + editionKey
                if let edition = await fetchAndParseDetail(urlString: "https://openlibrary.org\(editionPath).json") {
                    let desc = (edition.description?.isEmpty ?? true) ? work?.description : edition.description
                    let subjects = edition.subjects.isEmpty ? (work?.subjects ?? []) : edition.subjects
                    let year = edition.year ?? work?.year
                    return OpenLibraryWorkDetail(description: desc, subjects: subjects, year: year)
                }
            }
        }
        return work
    }

    private static func fetchFirstEditionKey(workKey: String) async -> String? {
        let trimmed = workKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let path = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        guard let url = URL(string: "https://openlibrary.org\(path)/editions.json?limit=1") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let entries = object["entries"] as? [[String: Any]]
            else { return nil }
            return entries.first?["key"] as? String
        } catch {
            return nil
        }
    }

    private static func fetchAndParseDetail(urlString: String) async -> OpenLibraryWorkDetail? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                return nil
            }
            return parseWorkDetail(data)
        } catch {
            return nil
        }
    }

    /// Parses a `/works/{key}.json` body: description (string or `{value}` object),
    /// subjects, and first publication year.
    public static func parseWorkDetail(_ data: Data) -> OpenLibraryWorkDetail? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let description: String? = {
            let raw = object["description"]
            if let text = raw as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            if let wrapper = raw as? [String: Any], let value = wrapper["value"] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return nil
        }()
        let subjects = stringArray(object["subjects"], cap: 6)
        let year = intValue(object["first_publish_year"])
        return OpenLibraryWorkDetail(description: description, subjects: subjects, year: year)
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func stringArray(_ value: Any?, cap: Int) -> [String] {
        guard let raw = value as? [String] else { return [] }
        return raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(cap)
            .map { $0 }
    }

    private static func blurb(_ value: Any?) -> String? {
        if let lines = value as? [String] {
            let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return first.isEmpty ? nil : first
        }
        if let line = value as? String {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }
}

/// Work-level metadata fetched from `/works/{key}.json` (description, subjects, year).
public struct OpenLibraryWorkDetail: Equatable, Sendable {
    public let description: String?
    public let subjects: [String]
    public let year: Int?

    public init(description: String?, subjects: [String] = [], year: Int? = nil) {
        self.description = description
        self.subjects = subjects
        self.year = year
    }
}

public enum SavedReadingIdeas {
    private static let key = "inkamp.savedReadingIdeas.v1"

    public static func load(defaults: UserDefaults = .standard) -> [ReadingIdea] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ReadingIdea].self, from: data)) ?? []
    }

    public static func save(_ idea: ReadingIdea, defaults: UserDefaults = .standard) {
        var all = load(defaults: defaults)
        all.removeAll { $0.id == idea.id }
        all.insert(idea, at: 0)
        persist(all, defaults: defaults)
    }

    public static func remove(_ id: String, defaults: UserDefaults = .standard) {
        var all = load(defaults: defaults)
        all.removeAll { $0.id == id }
        persist(all, defaults: defaults)
    }

    public static func contains(_ id: String, defaults: UserDefaults = .standard) -> Bool {
        load(defaults: defaults).contains { $0.id == id }
    }

    private static func persist(_ ideas: [ReadingIdea], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(ideas) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Last Open Library-backed Ideas list. Shown when lookup fails so we don't invent owned titles.
public enum CachedReadingIdeas {
    private static let key = "inkamp.readingIdeas.cache.v1"

    public static func load(defaults: UserDefaults = .standard) -> [ReadingIdea] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ReadingIdea].self, from: data)) ?? []
    }

    public static func save(_ ideas: [ReadingIdea], defaults: UserDefaults = .standard) {
        guard ideas.contains(where: { $0.id.hasPrefix("ol:") }),
            let data = try? JSONEncoder().encode(ideas)
        else { return }
        defaults.set(data, forKey: key)
    }
}

/// "Not interested" dismissals, keyed by a stable id (work key / ISBN / title+author).
public enum DismissedReadingIdeas {
    private static let key = "inkamp.dismissedReadingIdeas.v1"

    public static func load(defaults: UserDefaults = .standard) -> Set<String> {
        guard let data = defaults.data(forKey: key),
            let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(ids)
    }

    public static func dismiss(_ id: String, defaults: UserDefaults = .standard) {
        var all = load(defaults: defaults)
        all.insert(id)
        persist(all, defaults: defaults)
    }

    public static func remove(_ id: String, defaults: UserDefaults = .standard) {
        var all = load(defaults: defaults)
        all.remove(id)
        persist(all, defaults: defaults)
    }

    private static func persist(_ ids: Set<String>, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(Array(ids)) else { return }
        defaults.set(data, forKey: key)
    }
}
