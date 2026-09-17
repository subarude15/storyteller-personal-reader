//
//  SponsorBlockSkipTests.swift
//  SilveranTests
//
//  SPDX-License-Identifier: AGPL-3.0-only

import XCTest

@testable import SilveranKit

final class SponsorBlockSkipTests: XCTestCase {
    func testParseAndActiveSegment() throws {
        let json = """
            [
              {"category":"sponsor","actionType":"skip","segment":[10.0,20.0],"UUID":"a"},
              {"category":"intro","actionType":"skip","segment":[0.0,5.0],"UUID":"b"},
              {"category":"poi_highlight","actionType":"poi","segment":[30.0,31.0],"UUID":"c"}
            ]
            """.data(using: .utf8)!
        let segments = try SponsorBlockSkipLogic.parseSegments(json)
        XCTAssertEqual(segments.map(\.category), ["intro", "sponsor"])
        XCTAssertNil(
            SponsorBlockSkipLogic.activeSegment(
                at: 7,
                in: segments,
                allowedCategories: ["sponsor", "intro"]
            )
        )
        let hit = SponsorBlockSkipLogic.activeSegment(
            at: 12,
            in: segments,
            allowedCategories: ["sponsor", "intro"]
        )
        XCTAssertEqual(hit?.category, "sponsor")
        XCTAssertEqual(hit?.end, 20)
        XCTAssertNil(
            SponsorBlockSkipLogic.activeSegment(
                at: 12,
                in: segments,
                allowedCategories: ["intro"]
            )
        )
    }

    func testSkipSegmentsURLEncodesCategories() {
        let url = SponsorBlockSkipLogic.skipSegmentsURL(
            apiBase: "https://sponsor.ajay.app",
            videoID: "abc123",
            categories: ["outro", "sponsor"]
        )
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "sponsor.ajay.app")
        XCTAssertEqual(url?.path, "/api/skipSegments")
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "videoID" })?.value, "abc123")
        let cats = items.first(where: { $0.name == "categories" })?.value
        XCTAssertEqual(cats, "[\"outro\",\"sponsor\"]")
    }

    func testDefaultCategories() {
        XCTAssertTrue(SponsorBlockCategory.sponsor.defaultEnabled)
        XCTAssertFalse(SponsorBlockCategory.interaction.defaultEnabled)
    }
}
