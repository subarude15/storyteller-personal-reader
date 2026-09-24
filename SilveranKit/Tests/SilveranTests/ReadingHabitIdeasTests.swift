import Foundation
import Testing

@testable import SilveranKit

@Test func readingIdeasPreferSeriesGapThenAuthorThenSharedTags() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let stamp = "2023-11-14T22:13:20Z"
    let dune1 = ideaBook(
        id: "dune-1",
        title: "Dune",
        authors: ["Frank Herbert"],
        series: [("Dune", 1)],
        tags: ["Science Fiction"],
        status: "Read",
        updatedAt: stamp,
    )
    let dune3 = ideaBook(
        id: "dune-3",
        title: "Children of Dune",
        authors: ["Frank Herbert"],
        series: [("Dune", 3)],
        tags: ["Science Fiction"],
        status: "Read",
        updatedAt: stamp,
    )
    let unread = ideaBook(id: "unread", title: "Unread", authors: ["Someone Else"], status: "To read")

    let queries = ReadingHabitIdeas.queries(from: [dune3, unread, dune1], now: now)

    #expect(queries.first?.kind == .seriesGap)
    #expect(queries.first?.missingPosition == 2)
    #expect(queries.map(\.kind).contains(.author))
    #expect(queries.map(\.kind).contains(.tag))
    #expect(queries.first?.weight ?? 0 > queries.first { $0.kind == .author }?.weight ?? 0)
}

@Test func readingIdeasSkipUntouchedBooksAndDoNotInventANextWhileInProgress() {
    let reading = ideaBook(
        id: "one",
        title: "Volume One",
        authors: ["Ada"],
        series: [("Saga", 1)],
        status: "Reading",
    )
    #expect(ReadingHabitIdeas.queries(from: [ideaBook(id: "shelf", title: "Shelf")]).isEmpty)
    let queries = ReadingHabitIdeas.queries(from: [reading], now: Date())
    #expect(queries.allSatisfy { $0.kind != .seriesGap })
    #expect(queries.contains { $0.kind == .author && $0.term == "Ada" })
}

@Test func readingIdeasDropOwnedTitlesAndKeepSeriesPlaceholderOffline() {
    let owned = ideaBook(id: "dune", title: "Dune", authors: ["Frank Herbert"])
    let series = ReadingIdeaQuery(
        kind: .seriesGap,
        term: "Dune",
        weight: 3,
        missingPosition: 2,
        authorHint: "Frank Herbert",
        reason: "Missing #2 in Dune",
    )
    let author = ReadingIdeaQuery(
        kind: .author,
        term: "Frank Herbert",
        weight: 1,
        missingPosition: nil,
        authorHint: "Frank Herbert",
        reason: "More by Frank Herbert",
    )
    let works = [
        [
            OpenLibraryWork(key: "/works/OL1W", title: "Dune", author: "Frank Herbert", coverURL: nil, blurb: nil),
        ],
        [
            OpenLibraryWork(key: "/works/OL1W", title: "Dune", author: "Frank Herbert", coverURL: nil, blurb: nil),
            OpenLibraryWork(
                key: "/works/OL2W",
                title: "God Emperor of Dune",
                author: "Frank Herbert",
                coverURL: nil,
                blurb: "A later book.",
            ),
        ],
    ]

    let ideas = ReadingHabitIdeas.ideas(
        queries: [series, author],
        worksByQuery: works,
        owned: [owned],
    )

    #expect(ideas.map(\.title) == ["Dune #2", "God Emperor of Dune"])
    #expect(ideas[0].reason == "Missing #2 in Dune")
    #expect(ideas.allSatisfy { $0.title != "Dune" })
}

@Test func readingIdeasKeepSameTitleByAnotherAuthorAndDropISBN() {
    let owned = ideaBook(
        id: "troop",
        title: "The Troop",
        authors: ["Nick Cutter"],
        description: "isbn 9781476717715",
    )
    let author = ReadingIdeaQuery(
        kind: .author,
        term: "Nick Cutter",
        weight: 1,
        missingPosition: nil,
        authorHint: "Nick Cutter",
        reason: "More by Nick Cutter",
    )
    let ideas = ReadingHabitIdeas.ideas(
        queries: [author],
        worksByQuery: [[
            OpenLibraryWork(
                key: "/works/OL9W",
                title: "The Troop",
                author: "Someone Else",
                coverURL: nil,
                blurb: nil,
            ),
            OpenLibraryWork(
                key: "/works/OL8W",
                title: "Little Heaven",
                author: "Nick Cutter",
                coverURL: nil,
                blurb: nil,
                isbn: "9781476717715",
            ),
            OpenLibraryWork(
                key: "/works/OL7W",
                title: "The Deep",
                author: "Nick Cutter",
                coverURL: nil,
                blurb: nil,
            ),
        ]],
        owned: [owned],
    )
    #expect(ideas.map(\.title) == ["The Deep", "The Troop"])
}

@Test func readingIdeasPreferSeriesPositionInTitle() {
    let query = ReadingIdeaQuery(
        kind: .seriesGap,
        term: "Dune",
        weight: 2,
        missingPosition: 2,
        authorHint: "Frank Herbert",
        reason: "Missing #2 in Dune",
    )
    let ideas = ReadingHabitIdeas.ideas(
        queries: [query],
        worksByQuery: [[
            OpenLibraryWork(key: "/works/A", title: "Dune Messiah", author: "Frank Herbert", coverURL: nil, blurb: nil),
            OpenLibraryWork(key: "/works/B", title: "Dune 2", author: "Frank Herbert", coverURL: nil, blurb: nil),
        ]],
        owned: [],
    )
    #expect(ideas.first?.title == "Dune 2")
}

@Test func readingIdeasUseCacheWhenLookupFailsAndNeverOwnedTitles() {
    let cached = ReadingIdea(
        id: "ol:/works/OL2W",
        title: "God Emperor of Dune",
        author: "Frank Herbert",
        coverURL: nil,
        blurb: nil,
        reason: "Next in Dune",
        score: 2,
    )
    let owned = ideaBook(id: "owned", title: "God Emperor of Dune", authors: ["Frank Herbert"])
    let placeholder = ReadingIdea(
        id: "series:dune:2",
        title: "Dune #2",
        author: "Frank Herbert",
        coverURL: nil,
        blurb: nil,
        reason: "Missing #2 in Dune",
        score: 3,
    )
    let offline = ReadingHabitIdeas.present(
        fresh: [placeholder],
        lookupFailed: true,
        cached: [cached],
        owned: [],
    )
    #expect(offline.map(\.id) == [cached.id])
    let filtered = ReadingHabitIdeas.present(
        fresh: [placeholder],
        lookupFailed: true,
        cached: [cached],
        owned: [owned],
    )
    #expect(filtered.isEmpty)
    let online = ReadingHabitIdeas.present(
        fresh: [placeholder],
        lookupFailed: false,
        cached: [cached],
        owned: [],
    )
    #expect(online.map(\.id) == [placeholder.id])
}

@Test func openLibraryIdeaParseReadsCoverAndFirstSentence() throws {
    let json = """
    {"docs":[{"key":"/works/OL9W","title":"The Dispossessed","author_name":["Ursula K. Le Guin"],"cover_i":42,"first_sentence":["She was a visitor."],"first_publish_year":1974,"subject":["Science fiction","Anarchism"]}]}
    """.data(using: .utf8)!
    let works = OpenLibraryIdeaLookup.parse(json)
    #expect(works.count == 1)
    #expect(works[0].title == "The Dispossessed")
    #expect(works[0].author == "Ursula K. Le Guin")
    #expect(works[0].coverURL?.absoluteString == "https://covers.openlibrary.org/b/id/42-M.jpg")
    #expect(works[0].blurb == "She was a visitor.")
    #expect(works[0].year == 1974)
    #expect(works[0].subjects == ["Science fiction", "Anarchism"])
}

@Test func openLibraryIdeaParseWorkDetailReadsDescriptionSubjectsYear() throws {
    let json = """
    {"description":{"value":"A description of the work."},"subjects":["Science fiction","Anarchism","Utopias"],"first_publish_year":1974}
    """.data(using: .utf8)!
    let detail = OpenLibraryIdeaLookup.parseWorkDetail(json)
    #expect(detail?.description == "A description of the work.")
    #expect(detail?.subjects == ["Science fiction", "Anarchism", "Utopias"])
    #expect(detail?.year == 1974)
}

@Test func openLibraryIdeaParseWorkDetailHandlesStringDescription() throws {
    let json = """
    {"description":"A plain string description."}
    """.data(using: .utf8)!
    let detail = OpenLibraryIdeaLookup.parseWorkDetail(json)
    #expect(detail?.description == "A plain string description.")
    #expect(detail?.subjects == [])
    #expect(detail?.year == nil)
}

@Test func openLibraryIdeaParseDropsNonEnglishFirstSentence() throws {
    let json = """
    {"docs":[{"key":"/works/OL9W","title":"Das Buch","author_name":["A. Author"],"first_sentence":["Ein erstes Satz."],"language":["ger"]}]}
    """.data(using: .utf8)!
    let works = OpenLibraryIdeaLookup.parse(json)
    #expect(works.count == 1)
    #expect(works[0].blurb == nil)
}

@Test func openLibraryIdeaParseKeepsEnglishFirstSentence() throws {
    let json = """
    {"docs":[{"key":"/works/OL9W","title":"The Book","author_name":["A. Author"],"first_sentence":["A first sentence."],"language":["eng"]}]}
    """.data(using: .utf8)!
    let works = OpenLibraryIdeaLookup.parse(json)
    #expect(works[0].blurb == "A first sentence.")
}

@Test func openLibraryIdeaParseKeepsBlurbWhenLanguageUnknown() throws {
    let json = """
    {"docs":[{"key":"/works/OL9W","title":"The Book","author_name":["A. Author"],"first_sentence":["A first sentence."]}]}
    """.data(using: .utf8)!
    let works = OpenLibraryIdeaLookup.parse(json)
    #expect(works[0].blurb == "A first sentence.")
}

@Test func openLibraryIdeaParseWorkDetailFlagsNonEnglishLanguages() throws {
    let json = """
    {"description":{"value":"Una descripción."},"languages":[{"key":"/languages/spa"}]}
    """.data(using: .utf8)!
    let detail = OpenLibraryIdeaLookup.parseWorkDetail(json)
    #expect(detail?.description == "Una descripción.")
    #expect(detail?.isEnglish == false)
}

@Test func openLibraryIdeaParseWorkDetailFlagsEnglishLanguages() throws {
    let json = """
    {"description":{"value":"A description."},"languages":[{"key":"/languages/eng"}]}
    """.data(using: .utf8)!
    let detail = OpenLibraryIdeaLookup.parseWorkDetail(json)
    #expect(detail?.isEnglish == true)
}

@Test func openLibraryIdeaParseWorkDetailUnknownLanguageDefaultsEnglish() throws {
    let json = """
    {"description":{"value":"A description."}}
    """.data(using: .utf8)!
    let detail = OpenLibraryIdeaLookup.parseWorkDetail(json)
    #expect(detail?.isEnglish == true)
}

@Test func openLibraryIdeaParseWorkDetailDescriptionLanguageTagOverrides() throws {
    let json = """
    {"description":{"value":"A description.","language":"eng"},"languages":[{"key":"/languages/fre"}]}
    """.data(using: .utf8)!
    let detail = OpenLibraryIdeaLookup.parseWorkDetail(json)
    #expect(detail?.isEnglish == true)
}

@Test func readingIdeasDropEmptyReasonRows() {
    let query = ReadingIdeaQuery(
        kind: .author,
        term: "Frank Herbert",
        weight: 1,
        missingPosition: nil,
        authorHint: "Frank Herbert",
        reason: "   ",
    )
    let ideas = ReadingHabitIdeas.ideas(
        queries: [query],
        worksByQuery: [[
            OpenLibraryWork(key: "/works/OL2W", title: "God Emperor of Dune", author: "Frank Herbert", coverURL: nil, blurb: nil),
        ]],
        owned: [],
    )
    #expect(ideas.isEmpty)
}

@Test func savedReadingIdeasRoundTrip() {
    let defaults = UserDefaults(suiteName: "ideas-test-\(UUID().uuidString)")!
    let idea = ReadingIdea(
        id: "ol:/works/OL2W",
        title: "God Emperor of Dune",
        author: "Frank Herbert",
        coverURL: nil,
        blurb: nil,
        reason: "More by Frank Herbert",
        score: 1,
    )
    #expect(SavedReadingIdeas.load(defaults: defaults).isEmpty)
    SavedReadingIdeas.save(idea, defaults: defaults)
    #expect(SavedReadingIdeas.contains(idea.id, defaults: defaults))
    SavedReadingIdeas.remove(idea.id, defaults: defaults)
    #expect(SavedReadingIdeas.load(defaults: defaults).isEmpty)
}

@Test func dismissedReadingIdeasRoundTripAndFilter() {
    let defaults = UserDefaults(suiteName: "ideas-test-\(UUID().uuidString)")!
    let idea = ReadingIdea(
        id: "ol:/works/OL2W",
        title: "God Emperor of Dune",
        author: "Frank Herbert",
        coverURL: nil,
        blurb: nil,
        reason: "Because you like Dune, Frank Herbert",
        score: 1,
    )
    #expect(DismissedReadingIdeas.load(defaults: defaults).isEmpty)
    DismissedReadingIdeas.dismiss(ReadingHabitIdeas.dismissKey(for: idea), defaults: defaults)
    #expect(DismissedReadingIdeas.load(defaults: defaults).contains("ol:/works/OL2W"))
    #expect(ReadingHabitIdeas.excludingDismissed([idea], dismissed: DismissedReadingIdeas.load(defaults: defaults)).isEmpty)
    DismissedReadingIdeas.remove(ReadingHabitIdeas.dismissKey(for: idea), defaults: defaults)
    #expect(DismissedReadingIdeas.load(defaults: defaults).isEmpty)
}

@Test func readingIdeasDismissKeyPrefersWorkKeyThenISBNThenTitle() {
    let byWork = ReadingIdea(id: "ol:/works/OL9W", title: "T", author: "A", coverURL: nil, blurb: nil, reason: "r", score: 1, isbn: "9781476717715")
    #expect(ReadingHabitIdeas.dismissKey(for: byWork) == "ol:/works/OL9W")

    let byISBN = ReadingIdea(id: "title:x", title: "The Troop", author: "Nick Cutter", coverURL: nil, blurb: nil, reason: "r", score: 1, isbn: "9781476717715")
    #expect(ReadingHabitIdeas.dismissKey(for: byISBN) == "isbn:9781476717715")

    let byTitle = ReadingIdea(id: "title:x", title: "The Deep", author: "Nick Cutter", coverURL: nil, blurb: nil, reason: "r", score: 1)
    #expect(ReadingHabitIdeas.dismissKey(for: byTitle).hasPrefix("title:"))
}

@Test func readingIdeasBecauseYouLikeAnchors() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let stamp = "2023-11-14T22:13:20Z"
    let dune = ideaBook(
        id: "dune-1",
        title: "Dune",
        authors: ["Frank Herbert"],
        series: [("Dune", 1)],
        tags: ["Science Fiction"],
        status: "Read",
        updatedAt: stamp,
    )
    let children = ideaBook(
        id: "dune-3",
        title: "Children of Dune",
        authors: ["Frank Herbert"],
        series: [("Dune", 3)],
        tags: ["Science Fiction"],
        status: "Read",
        updatedAt: stamp,
    )
    let queries = ReadingHabitIdeas.queries(from: [dune, children], now: now)
    let authorQuery = queries.first { $0.kind == .author }
    #expect(authorQuery != nil)
    let reason = authorQuery?.reason ?? ""
    #expect(reason.hasPrefix("Because you like"))
    #expect(reason.contains("Frank Herbert"))
}

@Test func readingIdeasDenserListKeepsMoreIdeas() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let stamp = "2023-11-14T22:13:20Z"
    var books: [BookMetadata] = []
    for i in 1 ... 8 {
        books.append(ideaBook(
            id: "b\(i)",
            title: "Book \(i)",
            authors: ["Author \(i)"],
            status: "Read",
            updatedAt: stamp,
        ))
    }
    let queries = ReadingHabitIdeas.queries(from: books, now: now)
    // 8 authors → all 8 become author queries (denser than the old 6 cap).
    #expect(queries.filter { $0.kind == .author }.count == 8)
}

@Test func browseRailsSubjectTermsRankLibraryTagsAndFillWithStaples() {
    let books = [
        ideaBook(id: "a", title: "A", authors: ["X"], tags: ["Horror", "Horror"], status: "Read"),
        ideaBook(id: "b", title: "B", authors: ["Y"], tags: ["Horror"], status: "Read"),
        ideaBook(id: "c", title: "C", authors: ["Z"], tags: ["Mystery"], status: "Reading"),
    ]
    let terms = OpenLibraryBrowseRails.subjectTerms(from: books, limit: 4)
    // Horror is the most-weighted library tag, so it leads; the rest fill with staples.
    #expect(terms.first == "Horror")
    #expect(terms.count == 4)
    // No duplicates.
    #expect(Set(terms.map(ReadingHabitIdeas.normalize)).count == terms.count)
}

@Test func browseRailsSubjectTermsUseStaplesWhenLibraryEmpty() {
    let terms = OpenLibraryBrowseRails.subjectTerms(from: [], limit: 3)
    #expect(terms.count == 3)
    #expect(terms == Array(OpenLibraryBrowseRails.stapleSubjects.prefix(3)))
}

@Test func browseRailsAuthorTermsRankFinishedAuthorsFirst() {
    let books = [
        ideaBook(id: "a", title: "A", authors: ["Ada"], status: "Read"),
        ideaBook(id: "b", title: "B", authors: ["Bob"], status: "Reading"),
    ]
    let terms = OpenLibraryBrowseRails.authorTerms(from: books, limit: 4)
    #expect(terms.first == "Ada")
    #expect(terms.contains("Bob"))
}

@Test func browseRailsDropOwned() {
    let owned = ideaBook(id: "owned", title: "Dune", authors: ["Frank Herbert"])
    let idea = ReadingIdea(
        id: "ol:/works/OL1W",
        title: "Dune",
        author: "Frank Herbert",
        coverURL: nil,
        blurb: nil,
        reason: "Because you like Horror",
        score: 1,
    )
    #expect(ReadingHabitIdeas.excludingOwned([idea], library: [owned]).isEmpty)
}

@Test func openLibrarySearchTitlesEmptyQueryReturnsNothing() async {
    let works = await OpenLibraryIdeaLookup.searchTitles("   ")
    #expect(works.isEmpty)
}

private func ideaBook(
    id: String,
    title: String,
    authors: [String] = [],
    series: [(String, Float?)] = [],
    tags: [String] = [],
    status: String? = nil,
    updatedAt: String? = nil,
    description: String? = nil,
) -> BookMetadata {
    BookMetadata(
        bookID: BookID(sourceID: "storyteller", uuid: id),
        title: title,
        subtitle: nil,
        description: description,
        language: nil,
        createdAt: nil,
        updatedAt: updatedAt,
        publicationDate: nil,
        authors: authors.map {
            BookCreator(
                uuid: nil, id: nil, name: $0, fileAs: nil, role: nil, createdAt: nil, updatedAt: nil,
            )
        },
        narrators: nil,
        creators: nil,
        series: series.map(ideaSeries),
        tags: tags.map { BookTag(uuid: nil, name: $0, createdAt: nil, updatedAt: nil) },
        collections: nil,
        ebook: nil,
        audiobook: nil,
        readaloud: nil,
        status: status.map { BookStatus(uuid: nil, name: $0) },
        position: nil,
        rating: nil,
    )
}

private func ideaSeries(_ value: (String, Float?)) -> BookSeries {
    var json: [String: Any] = ["name": value.0, "featured": 0]
    if let position = value.1 { json["position"] = position }
    let data = try! JSONSerialization.data(withJSONObject: json)
    return try! JSONDecoder().decode(BookSeries.self, from: data)
}
