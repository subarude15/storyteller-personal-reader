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

    public init(
        id: String,
        title: String,
        author: String,
        coverURL: URL?,
        blurb: String?,
        reason: String,
        score: Double,
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.coverURL = coverURL
        self.blurb = blurb
        self.reason = reason
        self.score = score
    }
}

public struct OpenLibraryWork: Equatable, Sendable {
    public let key: String
    public let title: String
    public let author: String
    public let coverURL: URL?
    public let blurb: String?

    public init(key: String, title: String, author: String, coverURL: URL?, blurb: String?) {
        self.key = key
        self.title = title
        self.author = author
        self.coverURL = coverURL
        self.blurb = blurb
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

/// Ranks “ideas for later” from books already in the Storyteller library.
/// Series gaps can stand alone. Author and tag ideas need metadata hits for
/// titles that are not already owned.
public enum ReadingHabitIdeas {
    public static func queries(
        from library: [BookMetadata],
        now: Date = Date(),
        limit: Int = 8,
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
        limit: Int = 12,
    ) -> [ReadingIdea] {
        guard limit > 0 else { return [] }
        let ownedTitles = Set(owned.map { normalize($0.title) }.filter { !$0.isEmpty })
        let ordered = queries.enumerated().sorted { lhs, rhs in
            if lhs.element.weight != rhs.element.weight { return lhs.element.weight > rhs.element.weight }
            return kindRank(lhs.element.kind) < kindRank(rhs.element.kind)
        }

        var ideas: [ReadingIdea] = []
        var seen: Set<String> = []
        for (index, query) in ordered {
            let works = index < worksByQuery.count ? worksByQuery[index] : []
            let fresh = works.filter { work in
                let title = normalize(work.title)
                return !title.isEmpty && !ownedTitles.contains(title)
            }
            if fresh.isEmpty {
                guard query.kind == .seriesGap, let position = query.missingPosition else { continue }
                let idea = seriesPlaceholder(query, position: position)
                let key = normalize(idea.title)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                ideas.append(idea)
                continue
            }
            let take = query.kind == .author ? 2 : 1
            for work in fresh.prefix(take) {
                let key = "\(normalize(work.title))|\(normalize(work.author))"
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
                        reason: query.reason,
                        score: query.weight,
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
            // ponytail: two missing slots per series. Upgrade by listing the rest.
            for (number, isNext) in missing.prefix(2) {
                let reason = isNext
                    ? "Next in \(bucket.display)"
                    : "Missing #\(number) in \(bucket.display)"
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

    private struct WeightedName {
        var display: String
        var weight: Double
        var books: Int = 1
    }

    private static func authorQueries(_ habits: [(BookMetadata, Habit)]) -> [ReadingIdeaQuery] {
        var weights: [String: WeightedName] = [:]
        for (book, habit) in habits {
            for name in authorNames(book) {
                let key = normalize(name)
                var entry = weights[key] ?? WeightedName(display: name, weight: 0)
                entry.weight += habit.weight
                weights[key] = entry
            }
        }
        return weights.values
            .sorted { $0.weight > $1.weight }
            .prefix(4)
            .map { entry in
                ReadingIdeaQuery(
                    kind: .author,
                    term: entry.display,
                    weight: entry.weight,
                    missingPosition: nil,
                    authorHint: entry.display,
                    reason: "More by \(entry.display)",
                )
            }
    }

    private static func tagQueries(_ habits: [(BookMetadata, Habit)]) -> [ReadingIdeaQuery] {
        var weights: [String: WeightedName] = [:]
        for (book, habit) in habits {
            var seen: Set<String> = []
            for raw in book.tagNames {
                let display = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = normalize(display)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                var entry = weights[key] ?? WeightedName(display: display, weight: 0, books: 0)
                entry.weight += habit.weight
                entry.books += 1
                weights[key] = entry
            }
        }
        return weights.values
            .filter { $0.books >= 2 }
            .sorted { $0.weight > $1.weight }
            .prefix(3)
            .map { entry in
                ReadingIdeaQuery(
                    kind: .tag,
                    term: entry.display,
                    weight: entry.weight * (1 + 0.2 * Double(entry.books - 1)),
                    missingPosition: nil,
                    authorHint: nil,
                    reason: "Because you read \(entry.display)",
                )
            }
    }

    private static func seriesPlaceholder(_ query: ReadingIdeaQuery, position: Int) -> ReadingIdea {
        let title = "\(query.term) #\(position)"
        return ReadingIdea(
            id: "series:\(normalize(query.term)):\(position)",
            title: title,
            author: query.authorHint ?? "",
            coverURL: nil,
            blurb: nil,
            reason: query.reason,
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
            return OpenLibraryWork(
                key: key,
                title: title,
                author: author,
                coverURL: cover,
                blurb: blurb(doc["first_sentence"]),
            )
        }
    }

    static func url(for query: ReadingIdeaQuery) -> URL? {
        var components = URLComponents(string: "https://openlibrary.org/search.json")
        var items = [
            URLQueryItem(name: "limit", value: query.kind == .author ? "6" : "5"),
            URLQueryItem(name: "fields", value: "key,title,author_name,cover_i,first_sentence"),
        ]
        switch query.kind {
        case .seriesGap:
            items.append(URLQueryItem(name: "q", value: query.term))
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

    private static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
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
