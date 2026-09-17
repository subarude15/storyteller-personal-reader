//
//  PodcastAppleChartsTests.swift
//  SilveranTests
//
//  SPDX-License-Identifier: AGPL-3.0-only

import XCTest

@testable import SilveranKit

final class PodcastAppleChartsTests: XCTestCase {
    func testChartURLTopAndGenre() {
        let top = PodcastAppleCharts.chartURL(storefront: "US", limit: 25, genreID: nil)
        XCTAssertEqual(
            top.absoluteString,
            "https://itunes.apple.com/us/rss/toppodcasts/limit=25/json"
        )
        let genre = PodcastAppleCharts.chartURL(storefront: "us", limit: 10, genreID: 1303)
        XCTAssertEqual(
            genre.absoluteString,
            "https://itunes.apple.com/us/rss/toppodcasts/limit=10/genre=1303/json"
        )
    }

    func testParseClassicChartAndMergeLookup() throws {
        let chartJSON = """
            {"feed":{"entry":[
              {"im:name":{"label":"Show A"},"im:artist":{"label":"Host A"},
               "im:image":[{"label":"https://example.com/a/55x55bb.png"}],
               "id":{"attributes":{"im:id":"111"}}},
              {"im:name":{"label":"Show B"},"im:artist":{"label":"Host B"},
               "im:image":[{"label":"https://example.com/b/170x170bb.png"}],
               "id":{"attributes":{"im:id":"222"}}}
            ]}}
            """.data(using: .utf8)!

        let stubs = try PodcastAppleCharts.parseClassicChart(chartJSON)
        XCTAssertEqual(stubs.map(\.collectionID), [111, 222])
        XCTAssertEqual(stubs[0].coverURL?.absoluteString, "https://example.com/a/600x600bb.jpg")

        let lookupJSON = """
            {"results":[
              {"wrapperType":"track","collectionId":111,"collectionName":"Show A",
               "artistName":"Host A","feedUrl":"https://feeds.example/a.xml",
               "artworkUrl600":"https://art.example/a.jpg"},
              {"wrapperType":"track","collectionId":222,"collectionName":"Show B",
               "artistName":"Host B","feedUrl":"https://feeds.example/b.xml"}
            ]}
            """.data(using: .utf8)!

        let hits = try PodcastAppleCharts.mergeLookup(stubs: stubs, lookupData: lookupJSON)
        XCTAssertEqual(hits.map(\.collectionID), [111, 222])
        XCTAssertEqual(hits[0].feedURL.absoluteString, "https://feeds.example/a.xml")
        XCTAssertEqual(hits[1].title, "Show B")
    }

    func testBrowseGenresIncludeTopChartsFirst() {
        XCTAssertEqual(PodcastBrowseGenre.all.first, .topCharts)
        XCTAssertNil(PodcastBrowseGenre.topCharts.genreID)
        XCTAssertTrue(PodcastBrowseGenre.all.contains { $0.genreID == 1303 })
    }
}
