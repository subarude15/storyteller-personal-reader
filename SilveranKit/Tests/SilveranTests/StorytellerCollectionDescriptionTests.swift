import Foundation
import SilveranKit
import Testing

@Suite("StorytellerCollection description")
struct StorytellerCollectionDescriptionTests {
    @Test func decodesStringDescription() throws {
        let json = """
            {"uuid":"u1","name":"Shelf","description":"hello","public":false}
            """
        let collection = try JSONDecoder().decode(
            StorytellerCollection.self,
            from: Data(json.utf8)
        )
        #expect(collection.description == "hello")
    }

    @Test func decodesObjectDescriptionAsJSONString() throws {
        let json = """
            {"uuid":"u1","name":".inkamp.stats.v1","description":{"schemaVersion":1,"sessions":[]},"public":false}
            """
        let collection = try JSONDecoder().decode(
            StorytellerCollection.self,
            from: Data(json.utf8)
        )
        #expect(collection.description?.hasPrefix("{") == true)
        #expect(collection.description?.contains("schemaVersion") == true)
    }

    @Test func arrayDecodeSurvivesMixedDescriptions() throws {
        let json = """
            [
              {"uuid":"a","name":"Books","description":{"note":"meta"},"public":true},
              {"uuid":"b","name":".inkamp.stats.v1","description":"{\\"schemaVersion\\":1}","public":false}
            ]
            """
        let collections = try JSONDecoder().decode(
            [StorytellerCollection].self,
            from: Data(json.utf8)
        )
        #expect(collections.count == 2)
        #expect(collections[0].description?.contains("note") == true)
        #expect(collections[1].name == ".inkamp.stats.v1")
    }
}
