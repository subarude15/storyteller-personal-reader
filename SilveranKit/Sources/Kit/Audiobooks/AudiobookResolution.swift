import Foundation

// Book-first audiobook lookup. The selected work stays the primary object.
// Providers are queried only when the user asks for audiobook options.
// Results are formats for that work, not new library books.

public enum AudiobookProviderKind: String, Codable, Sendable, CaseIterable {
    case librivox

    public var displayName: String {
        switch self {
            case .librivox: "LibriVox"
        }
    }
}

public enum AudiobookMatchConfidence: String, Codable, Sendable, Comparable {
    case weak
    case near
    case exact

    public var label: String {
        switch self {
            case .exact: "Exact match"
            case .near: "Close match"
            case .weak: "Possible match"
        }
    }

    private var rank: Int {
        switch self {
            case .weak: 0
            case .near: 1
            case .exact: 2
        }
    }

    public static func < (lhs: AudiobookMatchConfidence, rhs: AudiobookMatchConfidence) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct AudiobookMatchEvidence: Equatable, Sendable, Codable {
    public var confidence: AudiobookMatchConfidence
    public var reasons: [String]

    public init(confidence: AudiobookMatchConfidence, reasons: [String]) {
        self.confidence = confidence
        self.reasons = reasons
    }
}

public struct ResolvedAudiobookChapter: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var order: Int
    public var playbackURL: URL
    public var duration: TimeInterval?

    public init(
        id: String,
        title: String,
        order: Int,
        playbackURL: URL,
        duration: TimeInterval?,
    ) {
        self.id = id
        self.title = title
        self.order = order
        self.playbackURL = playbackURL
        self.duration = duration
    }
}

/// Provider-neutral audiobook for one selected work. Not a library book.
public struct ResolvedAudiobook: Equatable, Sendable, Codable, Identifiable {
    public var provider: AudiobookProviderKind
    public var providerItemID: String
    public var title: String
    public var author: String
    public var narrator: String?
    public var language: String?
    public var duration: TimeInterval?
    public var chapterCount: Int
    public var artworkURL: URL?
    public var description: String?
    public var sourceURL: URL?
    public var chapters: [ResolvedAudiobookChapter]
    public var match: AudiobookMatchEvidence

    public var id: String { "\(provider.rawValue):\(providerItemID)" }

    public init(
        provider: AudiobookProviderKind,
        providerItemID: String,
        title: String,
        author: String,
        narrator: String?,
        language: String?,
        duration: TimeInterval?,
        chapterCount: Int,
        artworkURL: URL?,
        description: String?,
        sourceURL: URL?,
        chapters: [ResolvedAudiobookChapter],
        match: AudiobookMatchEvidence,
    ) {
        self.provider = provider
        self.providerItemID = providerItemID
        self.title = title
        self.author = author
        self.narrator = narrator
        self.language = language
        self.duration = duration
        self.chapterCount = chapterCount
        self.artworkURL = artworkURL
        self.description = description
        self.sourceURL = sourceURL
        self.chapters = chapters
        self.match = match
    }

    /// One existing-player track per provider section. Never one fake track for the whole book.
    public func playbackMetadata() -> AudiobookMetadata? {
        let ordered = chapters.sorted { $0.order < $1.order }.filter {
            let scheme = $0.playbackURL.scheme?.lowercased()
            return scheme == "https" || scheme == "http"
        }
        guard !ordered.isEmpty else { return nil }

        var tracks: [AudiobookTrack] = []
        var playbackChapters: [AudiobookChapter] = []
        var cursor: TimeInterval = 0
        for (index, chapter) in ordered.enumerated() {
            // ponytail: unknown durations become 1s so later chapters don't collapse onto t=0.
            // Upgrade path: probe each remote asset before building the timeline.
            let duration = max(chapter.duration ?? 1, 0.1)
            let href = "chapter-\(index)"
            tracks.append(
                AudiobookTrack(
                    href: href,
                    url: chapter.playbackURL,
                    type: "audio/mpeg",
                    duration: duration,
                    startTime: cursor,
                )
            )
            playbackChapters.append(
                AudiobookChapter(
                    id: href,
                    title: chapter.title,
                    startTime: cursor,
                    duration: duration,
                    href: href,
                )
            )
            cursor += duration
        }
        return AudiobookMetadata(
            chapters: playbackChapters,
            tracks: tracks,
            totalDuration: cursor,
            title: title,
            author: author,
        )
    }

    public func globalTime(chapterIndex: Int, position: TimeInterval) -> TimeInterval? {
        guard let metadata = playbackMetadata(),
            metadata.chapters.indices.contains(chapterIndex)
        else { return nil }
        let chapter = metadata.chapters[chapterIndex]
        let clamped = min(max(position, 0), max(chapter.duration - 0.25, 0))
        return chapter.startTime + clamped
    }
}

/// Raw provider row before it is matched to the selected work.
public struct AudiobookProviderItem: Equatable, Sendable {
    public var provider: AudiobookProviderKind
    public var providerItemID: String
    public var title: String
    public var authors: [String]
    public var narrator: String?
    public var language: String?
    public var duration: TimeInterval?
    public var artworkURL: URL?
    public var description: String?
    public var sourceURL: URL?
    public var chapters: [ResolvedAudiobookChapter]
    public var isbn: String?
    public var openLibraryWorkID: String?
    public var openLibraryEditionID: String?

    public init(
        provider: AudiobookProviderKind,
        providerItemID: String,
        title: String,
        authors: [String],
        narrator: String?,
        language: String?,
        duration: TimeInterval?,
        artworkURL: URL?,
        description: String?,
        sourceURL: URL?,
        chapters: [ResolvedAudiobookChapter],
        isbn: String? = nil,
        openLibraryWorkID: String? = nil,
        openLibraryEditionID: String? = nil,
    ) {
        self.provider = provider
        self.providerItemID = providerItemID
        self.title = title
        self.authors = authors
        self.narrator = narrator
        self.language = language
        self.duration = duration
        self.artworkURL = artworkURL
        self.description = description
        self.sourceURL = sourceURL
        self.chapters = chapters
        self.isbn = isbn
        self.openLibraryWorkID = openLibraryWorkID
        self.openLibraryEditionID = openLibraryEditionID
    }
}

public protocol AudiobookCatalogProviding: Sendable {
    var kind: AudiobookProviderKind { get }
    func search(_ work: CanonicalBookWork) async throws -> [AudiobookProviderItem]
}

/// Metadata already known for the selected work. Lookup starts here, not from a catalog browse.
public struct CanonicalBookWork: Equatable, Sendable {
    public var workID: String
    public var title: String
    public var subtitle: String?
    public var authors: [String]
    public var language: String?
    public var isbn: String?
    public var openLibraryWorkID: String?
    public var openLibraryEditionID: String?
    public var publicationYear: String?

    public init(
        workID: String,
        title: String,
        subtitle: String?,
        authors: [String],
        language: String?,
        isbn: String?,
        openLibraryWorkID: String?,
        openLibraryEditionID: String?,
        publicationYear: String?,
    ) {
        self.workID = workID
        self.title = title
        self.subtitle = subtitle
        self.authors = authors
        self.language = language
        self.isbn = isbn
        self.openLibraryWorkID = openLibraryWorkID
        self.openLibraryEditionID = openLibraryEditionID
        self.publicationYear = publicationYear
    }

    public static func library(_ book: BookMetadata) -> CanonicalBookWork {
        let isbn = BookFormatTexts.isbnTokens(in: [
            book.title, book.subtitle, book.description,
        ]).sorted().first
        return CanonicalBookWork(
            workID: book.id.description,
            title: book.title,
            subtitle: book.subtitle,
            authors: book.authors?.compactMap(\.name).filter { !$0.isEmpty } ?? [],
            language: book.language,
            isbn: isbn,
            openLibraryWorkID: nil,
            openLibraryEditionID: nil,
            publicationYear: BookMetadata.publicationYear(from: book.publicationDate),
        )
    }

    public static func idea(_ idea: ReadingIdea) -> CanonicalBookWork {
        let key = idea.id.hasPrefix("ol:") ? String(idea.id.dropFirst(3)) : nil
        let workKey = key?.contains("/works/") == true ? key : nil
        let editionKey = key?.contains("/books/") == true ? key : nil
        return CanonicalBookWork(
            workID: idea.id,
            title: idea.title,
            subtitle: nil,
            authors: idea.author.isEmpty ? [] : [idea.author],
            language: nil,
            isbn: idea.isbn,
            openLibraryWorkID: workKey,
            openLibraryEditionID: editionKey,
            publicationYear: idea.year.map(String.init),
        )
    }

    /// In-memory book for the existing player. Not inserted into the library.
    public func playbackBook() -> BookMetadata {
        BookMetadata(
            bookID: BookID(sourceID: Self.playbackSourceID, uuid: workID),
            title: title,
            subtitle: subtitle,
            description: nil,
            language: language,
            createdAt: nil,
            updatedAt: nil,
            publicationDate: publicationYear.map { "\($0)-01-01" },
            authors: authors.map {
                BookCreator(
                    uuid: nil,
                    id: nil,
                    name: $0,
                    fileAs: nil,
                    role: "aut",
                    createdAt: nil,
                    updatedAt: nil,
                )
            },
            narrators: nil,
            creators: nil,
            series: nil,
            tags: nil,
            collections: nil,
            ebook: nil,
            audiobook: nil,
            readaloud: nil,
            status: nil,
            position: nil,
            rating: nil,
        )
    }

    public static let playbackSourceID = "resolved-audiobook"

    public var hasSearchableTitle: Bool {
        AudiobookText.searchTitle(title, subtitle: subtitle).count >= 2
    }
}

public enum AudiobookResolutionFailure: Equatable, Sendable {
    case insufficientMetadata
    case providerUnavailable(AudiobookProviderKind)
    case playbackSourceUnavailable

    public var message: String {
        switch self {
            case .insufficientMetadata:
                "This book needs a title before audiobook options can be searched."
            case .providerUnavailable(let provider):
                "\(provider.displayName) is unavailable right now. This book was not changed."
            case .playbackSourceUnavailable:
                "Playback source unavailable."
        }
    }
}

public struct AudiobookResolutionOutcome: Equatable, Sendable {
    public var results: [ResolvedAudiobook]
    public var failure: AudiobookResolutionFailure?

    public init(results: [ResolvedAudiobook], failure: AudiobookResolutionFailure?) {
        self.results = results
        self.failure = failure
    }
}

public enum AudiobookResolution {
    /// User-triggered. Callers must not invoke this from book open, search scroll, or library refresh.
    public static func lookup(
        work: CanonicalBookWork,
        providers: [any AudiobookCatalogProviding]? = nil,
    ) async -> AudiobookResolutionOutcome {
        guard work.hasSearchableTitle else {
            return AudiobookResolutionOutcome(results: [], failure: .insufficientMetadata)
        }
        let providers = providers ?? [LibriVoxAudiobookProvider()]
        var items: [AudiobookProviderItem] = []
        var failure: AudiobookResolutionFailure?
        for provider in providers {
            do {
                items.append(contentsOf: try await provider.search(work))
            } catch {
                failure = .providerUnavailable(provider.kind)
            }
        }
        let ranked = AudiobookMatcher.rank(work: work, items: items)
        if ranked.isEmpty, let failure {
            return AudiobookResolutionOutcome(results: [], failure: failure)
        }
        return AudiobookResolutionOutcome(results: ranked, failure: nil)
    }
}

public enum AudiobookText {
    public static func normalizedTitle(_ title: String, subtitle: String? = nil) -> String {
        BookFormatTexts.titleKey(strippedTitle(title, subtitle: subtitle), subtitle: nil)
    }

    public static func normalizedAuthor(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let comma = trimmed.firstIndex(of: ",") {
            let surname = BookFormatTexts.fold(String(trimmed[..<comma]))
            let given = BookFormatTexts.fold(String(trimmed[trimmed.index(after: comma)...]))
            if !surname.isEmpty, !given.isEmpty {
                return "\(given) \(surname)"
            }
        }
        return BookFormatTexts.fold(trimmed)
    }

    public static func authorSurname(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let comma = trimmed.firstIndex(of: ",") {
            return String(trimmed[..<comma]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? trimmed
    }

    /// Title sent to a provider. Keeps articles. Drops a trailing subtitle or parenthetical.
    public static func searchTitle(_ title: String, subtitle: String?) -> String {
        strippedTitle(title, subtitle: subtitle)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func languageCode(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let folded = BookFormatTexts.fold(raw)
        guard !folded.isEmpty else { return nil }
        switch folded {
            case "en", "eng", "english": return "en"
            case "fr", "fre", "fra", "french": return "fr"
            case "de", "ger", "deu", "german": return "de"
            case "es", "spa", "spanish": return "es"
            case "it", "ita", "italian": return "it"
            default: return folded
        }
    }

    private static func strippedTitle(_ title: String, subtitle: String?) -> String {
        var core = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = core.lastIndex(of: "("),
            let close = core.lastIndex(of: ")"),
            close > open,
            core.distance(from: close, to: core.endIndex) <= 1
        {
            let head = core[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
            if head.count >= 3 {
                core = String(head)
            }
        }
        if let subtitle {
            let trimmed = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, core.lowercased().hasSuffix(trimmed.lowercased()),
                core.count > trimmed.count
            {
                core = String(core.dropLast(trimmed.count)).trimmingCharacters(
                    in: .punctuationCharacters.union(.whitespacesAndNewlines)
                )
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
        return core
    }
}

public enum AudiobookMatcher {
    public static func rank(
        work: CanonicalBookWork,
        items: [AudiobookProviderItem],
    ) -> [ResolvedAudiobook] {
        items.compactMap { match(work, item: $0) }
            .sorted { lhs, rhs in
                if lhs.match.confidence != rhs.match.confidence {
                    return lhs.match.confidence > rhs.match.confidence
                }
                return lhs.providerItemID < rhs.providerItemID
            }
    }

    public static func match(
        _ work: CanonicalBookWork,
        item: AudiobookProviderItem,
    ) -> ResolvedAudiobook? {
        if let workID = work.openLibraryWorkID, let itemID = item.openLibraryWorkID,
            !workID.isEmpty, !itemID.isEmpty, workID != itemID
        {
            return nil
        }
        if let edition = work.openLibraryEditionID, let itemEdition = item.openLibraryEditionID,
            !edition.isEmpty, !itemEdition.isEmpty, edition != itemEdition
        {
            return nil
        }

        let identifierMatch =
            identifiersMatch(work.isbn, item.isbn)
            || identifiersMatch(work.openLibraryWorkID, item.openLibraryWorkID)
        let workTitle = AudiobookText.normalizedTitle(work.title, subtitle: work.subtitle)
        let itemTitle = AudiobookText.normalizedTitle(item.title)
        let titlesMatch = !workTitle.isEmpty && workTitle == itemTitle
        guard titlesMatch || identifierMatch else { return nil }

        let workLanguage = AudiobookText.languageCode(work.language)
        let itemLanguage = AudiobookText.languageCode(item.language)
        let languageDiffers =
            workLanguage != nil && itemLanguage != nil && workLanguage != itemLanguage

        let author = authorMatch(work.authors, item.authors)
        let confidence: AudiobookMatchConfidence
        var reasons: [String] = []
        if titlesMatch {
            reasons.append("Title matches")
        }
        if identifierMatch {
            reasons.append("Identifier matches")
        }
        switch author {
            case .full:
                confidence = languageDiffers && !identifierMatch ? .weak : .exact
                reasons.append("Author matches")
            case .lastName:
                confidence = languageDiffers && !identifierMatch ? .weak : .near
                reasons.append("Author last name matches")
            case .missing:
                confidence = identifierMatch && !languageDiffers ? .near : .weak
                reasons.append("Author wasn't available to confirm")
            case .none:
                guard identifierMatch else { return nil }
                confidence = .exact
                reasons.append("Author text didn't match; the identifier did")
        }
        if languageDiffers {
            reasons.append("Language differs from the selected book")
        } else if workLanguage != nil, itemLanguage != nil {
            reasons.append("Language matches")
        }

        let authorLine = item.authors.filter { !$0.isEmpty }.joined(separator: ", ")
        return ResolvedAudiobook(
            provider: item.provider,
            providerItemID: item.providerItemID,
            title: item.title,
            author: authorLine.isEmpty ? work.authors.joined(separator: ", ") : authorLine,
            narrator: item.narrator,
            language: item.language,
            duration: item.duration,
            chapterCount: item.chapters.isEmpty
                ? 0
                : item.chapters.count,
            artworkURL: item.artworkURL,
            description: item.description,
            sourceURL: item.sourceURL,
            chapters: item.chapters.sorted { $0.order < $1.order },
            match: AudiobookMatchEvidence(confidence: confidence, reasons: reasons),
        )
    }

    private enum AuthorMatch {
        case full
        case lastName
        case missing
        case none
    }

    private static func authorMatch(_ work: [String], _ item: [String]) -> AuthorMatch {
        let left = work.map(AudiobookText.normalizedAuthor).filter { !$0.isEmpty }
        let right = item.map(AudiobookText.normalizedAuthor).filter { !$0.isEmpty }
        if left.isEmpty || right.isEmpty { return .missing }

        var lastNameOnly = false
        for author in left {
            for candidate in right {
                let authorParts = parts(author)
                let candidateParts = parts(candidate)
                guard authorParts.last == candidateParts.last, authorParts.last.count >= 2 else {
                    continue
                }
                if authorParts.first.isEmpty || candidateParts.first.isEmpty {
                    lastNameOnly = true
                    continue
                }
                if firstNamesCompatible(authorParts.first, candidateParts.first) {
                    return .full
                }
            }
        }
        return lastNameOnly ? .lastName : .none
    }

    private static func parts(_ name: String) -> (first: String, last: String) {
        let tokens = name.split(separator: " ").map(String.init)
        guard let last = tokens.last else { return ("", "") }
        return (tokens.dropLast().joined(separator: " "), last)
    }

    private static func firstNamesCompatible(_ lhs: String, _ rhs: String) -> Bool {
        let leftFlat = lhs.replacingOccurrences(of: " ", with: "")
        let rightFlat = rhs.replacingOccurrences(of: " ", with: "")
        if leftFlat == rightFlat, !leftFlat.isEmpty { return true }

        let left = givenNameComponents(lhs, counterpartTokenCount: tokenCount(rhs))
        let right = givenNameComponents(rhs, counterpartTokenCount: tokenCount(lhs))
        guard left.count == right.count, !left.isEmpty else { return false }
        for (leftPart, rightPart) in zip(left, right) {
            if leftPart == rightPart { continue }
            if initialMatches(leftPart, rightPart) { continue }
            return false
        }
        return true
    }

    private static func tokenCount(_ name: String) -> Int {
        name.split(separator: " ").count
    }

    /// `jrr` lines up with three given names. Spaced initials are already separate tokens.
    /// ponytail: a single letter-run whose length equals the other side's token count is
    /// treated as glued initials, so `ann` would also match `a n n`. Upgrade path: compare
    /// initials before `BookFormatTexts.fold` strips the periods that mark them.
    private static func givenNameComponents(_ name: String, counterpartTokenCount: Int) -> [String] {
        let tokens = name.split(separator: " ").map(String.init)
        guard tokens.count == 1, let only = tokens.first,
            only.count > 1, only.count == counterpartTokenCount, only.allSatisfy(\.isLetter)
        else { return tokens }
        return only.map { String($0) }
    }

    private static func initialMatches(_ lhs: String, _ rhs: String) -> Bool {
        if lhs.count == 1, rhs.first.map({ String($0) }) == lhs { return true }
        if rhs.count == 1, lhs.first.map({ String($0) }) == rhs { return true }
        return false
    }

    private static func identifiersMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        let left = BookFormatTexts.fold(lhs).replacingOccurrences(of: " ", with: "")
        let right = BookFormatTexts.fold(rhs).replacingOccurrences(of: " ", with: "")
        guard left.count >= 3, right.count >= 3 else { return false }
        if left == right { return true }
        let leftDigits = left.filter(\.isNumber)
        let rightDigits = right.filter(\.isNumber)
        return leftDigits.count >= 10 && leftDigits == rightDigits
    }
}

public struct AudiobookResumeState: Equatable, Sendable, Codable {
    public var workID: String
    public var provider: AudiobookProviderKind
    public var providerItemID: String
    public var chapterIndex: Int
    public var chapterPosition: TimeInterval
    public var completed: Bool
    public var updatedAt: Date

    public init(
        workID: String,
        provider: AudiobookProviderKind,
        providerItemID: String,
        chapterIndex: Int,
        chapterPosition: TimeInterval,
        completed: Bool,
        updatedAt: Date,
    ) {
        self.workID = workID
        self.provider = provider
        self.providerItemID = providerItemID
        self.chapterIndex = chapterIndex
        self.chapterPosition = chapterPosition
        self.completed = completed
        self.updatedAt = updatedAt
    }

    public var key: String { "\(workID)|\(provider.rawValue)|\(providerItemID)" }
}

public final class AudiobookResumeStore: @unchecked Sendable {
    public static let storageKey = "inkamp.audiobookResume.v1"
    public static let shared = AudiobookResumeStore()

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = AudiobookResumeStore.storageKey) {
        self.defaults = defaults
        self.key = key
    }

    public func save(_ state: AudiobookResumeState) {
        var all = loadAll()
        all[state.key] = state
        guard let data = try? JSONEncoder().encode(all) else { return }
        defaults.set(data, forKey: key)
    }

    public func state(
        workID: String,
        provider: AudiobookProviderKind,
        providerItemID: String,
    ) -> AudiobookResumeState? {
        let key = "\(workID)|\(provider.rawValue)|\(providerItemID)"
        return loadAll()[key]
    }

    private func loadAll() -> [String: AudiobookResumeState] {
        guard let data = defaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode([String: AudiobookResumeState].self, from: data)
        else { return [:] }
        return decoded
    }
}

public struct ResolvedAudiobookPlayback: Equatable, Sendable {
    public var workID: String
    public var provider: AudiobookProviderKind
    public var providerItemID: String
    public var artworkURL: URL?

    public init(
        workID: String,
        provider: AudiobookProviderKind,
        providerItemID: String,
        artworkURL: URL?,
    ) {
        self.workID = workID
        self.provider = provider
        self.providerItemID = providerItemID
        self.artworkURL = artworkURL
    }
}

public actor ResolvedAudiobookLaunch {
    public static let shared = ResolvedAudiobookLaunch()

    public struct Context: Sendable {
        public var book: BookMetadata
        public var metadata: AudiobookMetadata
        public var playback: ResolvedAudiobookPlayback
        public var startAt: TimeInterval?

        public init(
            book: BookMetadata,
            metadata: AudiobookMetadata,
            playback: ResolvedAudiobookPlayback,
            startAt: TimeInterval?,
        ) {
            self.book = book
            self.metadata = metadata
            self.playback = playback
            self.startAt = startAt
        }
    }

    private var context: Context?

    public func arm(_ context: Context) {
        self.context = context
    }

    public func context(for bookID: BookID) -> Context? {
        guard context?.book.id == bookID else { return nil }
        return context
    }
}
