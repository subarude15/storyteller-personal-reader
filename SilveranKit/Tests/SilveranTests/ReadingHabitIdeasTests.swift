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

@Test func openLibraryIdeaParseReadsCoverAndFirstSentence() throws {
    let json = """
    {"docs":[{"key":"/works/OL9W","title":"The Dispossessed","author_name":["Ursula K. Le Guin"],"cover_i":42,"first_sentence":["She was a visitor."]}]}
    """.data(using: .utf8)!
    let works = OpenLibraryIdeaLookup.parse(json)
    #expect(works.count == 1)
    #expect(works[0].title == "The Dispossessed")
    #expect(works[0].author == "Ursula K. Le Guin")
    #expect(works[0].coverURL?.absoluteString == "https://covers.openlibrary.org/b/id/42-M.jpg")
    #expect(works[0].blurb == "She was a visitor.")
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

private func ideaBook(
    id: String,
    title: String,
    authors: [String] = [],
    series: [(String, Float?)] = [],
    tags: [String] = [],
    status: String? = nil,
    updatedAt: String? = nil,
) -> BookMetadata {
    BookMetadata(
        bookID: BookID(sourceID: "storyteller", uuid: id),
        title: title,
        subtitle: nil,
        description: nil,
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
