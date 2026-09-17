import Foundation
import Testing

@testable import SilveranKit

@Test func localRecommendationsOrderSeriesThenAllAuthorsThenTagOverlap() {
    let current = recommendationBook(
        id: "current",
        title: "Current",
        authors: ["Primary Author", "Co Writer"],
        series: [("Ink Saga", 2)],
        tags: ["Fantasy", "Found Family"],
    )
    let seriesThree = recommendationBook(
        id: "series-3",
        title: "Volume Three",
        authors: ["Someone Else"],
        series: [("ink saga", 3)],
    )
    let author = recommendationBook(
        id: "author",
        title: "Another Collaboration",
        authors: ["Different Person", "Co Writer"],
    )
    let tagOne = recommendationBook(
        id: "tag-one",
        title: "Only Fantasy",
        tags: ["Fantasy"],
    )
    let seriesOne = recommendationBook(
        id: "series-1",
        title: "Volume One",
        series: [("Ink Saga", 1)],
    )
    let tagTwo = recommendationBook(
        id: "tag-two",
        title: "Both Tags",
        tags: ["found family", "fantasy"],
    )
    let seriesUnknown = recommendationBook(
        id: "series-unknown",
        title: "Unnumbered Volume",
        series: [("Ink Saga", nil)],
    )

    let result = LocalBookRecommendations.recommendations(
        for: current,
        in: [tagOne, seriesThree, current, author, seriesUnknown, tagTwo, seriesOne],
    )

    #expect(
        result.map(\.uuid) == [
            "series-1", "series-3", "series-unknown", "author", "tag-two", "tag-one",
        ]
    )
}

@Test func localRecommendationsDedupeExcludeCurrentAndStayOnCurrentSource() {
    let current = recommendationBook(
        id: "current",
        title: "Current",
        authors: ["Same Author"],
        series: [("Same Series", 1)],
        tags: ["Same Tag"],
    )
    let matchesEverything = recommendationBook(
        id: "one-match",
        title: "One Match",
        authors: ["Same Author"],
        series: [("Same Series", 2)],
        tags: ["Same Tag"],
    )
    let otherSource = recommendationBook(
        id: "other-source",
        sourceID: "other-source",
        title: "Other Source",
        authors: ["Same Author"],
        series: [("Same Series", 3)],
        tags: ["Same Tag"],
    )

    let result = LocalBookRecommendations.recommendations(
        for: current,
        in: [current, matchesEverything, matchesEverything, otherSource],
    )

    #expect(result.map(\.uuid) == ["one-match"])
}

@Test func localRecommendationsHideWhenNothingMatchesAndRespectCap() {
    let current = recommendationBook(id: "current", title: "Current", tags: ["match"])
    let unmatched = recommendationBook(id: "unmatched", title: "Unmatched", tags: ["other"])
    let matches = (0..<20).map { index in
        recommendationBook(
            id: "match-\(index)",
            title: String(format: "Match %02d", index),
            tags: ["match"],
        )
    }

    #expect(
        LocalBookRecommendations.recommendations(for: current, in: [current, unmatched]).isEmpty
    )
    #expect(
        LocalBookRecommendations.recommendations(for: current, in: matches, limit: 12).count == 12
    )
}

private func recommendationBook(
    id: String,
    sourceID: BookSourceID = "storyteller",
    title: String,
    authors: [String] = [],
    series: [(String, Float?)] = [],
    tags: [String] = [],
) -> BookMetadata {
    BookMetadata(
        bookID: BookID(sourceID: sourceID, uuid: id),
        title: title,
        subtitle: nil,
        description: nil,
        language: nil,
        createdAt: nil,
        updatedAt: nil,
        publicationDate: nil,
        authors: authors.map {
            BookCreator(
                uuid: nil,
                id: nil,
                name: $0,
                fileAs: nil,
                role: nil,
                createdAt: nil,
                updatedAt: nil,
            )
        },
        narrators: nil,
        creators: nil,
        series: series.map(recommendationSeries),
        tags: tags.map {
            BookTag(uuid: nil, name: $0, createdAt: nil, updatedAt: nil)
        },
        collections: nil,
        ebook: nil,
        audiobook: nil,
        readaloud: nil,
        status: nil,
        position: nil,
        rating: nil,
    )
}

private func recommendationSeries(_ value: (String, Float?)) -> BookSeries {
    var json: [String: Any] = [
        "name": value.0,
        "featured": 0,
    ]
    if let position = value.1 { json["position"] = position }
    let data = try! JSONSerialization.data(withJSONObject: json)
    return try! JSONDecoder().decode(BookSeries.self, from: data)
}
