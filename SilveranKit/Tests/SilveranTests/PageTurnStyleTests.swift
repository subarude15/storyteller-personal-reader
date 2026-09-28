import Foundation
import Testing
@testable import SilveranKit

@Suite("Page turn style")
struct PageTurnStyleTests {
    @Test("Default page turn style is slide")
    func defaultIsSlide() {
        #expect(kDefaultPageTurnStyle == .slide)
        #expect(SilveranGlobalConfig.Reading().pageTurnStyle == .slide)
        #expect(PageTurnStyle.resolved(from: nil) == .slide)
    }

    @Test("Unknown raw values fall back to slide")
    func unknownFallsBackToSlide() {
        #expect(PageTurnStyle.resolved(from: "bogus") == .slide)
        #expect(PageTurnStyle.resolved(from: "") == .slide)
        #expect(PageTurnStyle.resolved(from: "SLIDE") == .slide)
    }

    @Test("Known raw values decode")
    func knownRawValues() {
        #expect(PageTurnStyle.resolved(from: "slide") == .slide)
        #expect(PageTurnStyle.resolved(from: "curl") == .curl)
        #expect(PageTurnStyle.resolved(from: "instant") == .instant)
    }

    @Test("Reading persistence round-trips pageTurnStyle")
    func persistenceRoundTrip() throws {
        for style in PageTurnStyle.allCases {
            var reading = SilveranGlobalConfig.Reading()
            reading.pageTurnStyle = style
            let data = try JSONEncoder().encode(reading)
            let decoded = try JSONDecoder().decode(SilveranGlobalConfig.Reading.self, from: data)
            #expect(decoded.pageTurnStyle == style)
        }
    }

    @Test("Serialized reading JSON includes pageTurnStyle")
    func serializationIncludesKey() throws {
        var reading = SilveranGlobalConfig.Reading()
        reading.pageTurnStyle = .instant
        let data = try JSONEncoder().encode(reading)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["pageTurnStyle"] as? String == "instant")
    }

    @Test("Missing pageTurnStyle in stored JSON defaults to slide")
    func missingKeyDefaultsToSlide() throws {
        let json = Data(#"{"fontSize":24,"scrollingMode":false}"#.utf8)
        let decoded = try JSONDecoder().decode(SilveranGlobalConfig.Reading.self, from: json)
        #expect(decoded.pageTurnStyle == .slide)
    }

    @Test("Unknown stored pageTurnStyle string defaults to slide")
    func unknownStoredStringDefaultsToSlide() throws {
        let json = Data(#"{"pageTurnStyle":"flippy"}"#.utf8)
        let decoded = try JSONDecoder().decode(SilveranGlobalConfig.Reading.self, from: json)
        #expect(decoded.pageTurnStyle == .slide)
    }
}
