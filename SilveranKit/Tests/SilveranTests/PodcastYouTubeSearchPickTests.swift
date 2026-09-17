import Foundation
import Testing

@testable import SilveranKit

@Test func youtubeSearchPickTakesTopVideos() throws {
    let json: [[String: Any]] = [
        [
            "type": "video",
            "title": "Vergecast Ep 1",
            "videoId": "abcdefghijk",
            "author": "The Verge",
            "lengthSeconds": 3723,
            "videoThumbnails": [
                ["quality": "medium", "url": "https://cdn.example/m.jpg"],
            ],
        ],
        [
            "type": "channel",
            "title": "The Verge",
            "authorId": "UCxxxxxxxx",
        ],
        [
            "type": "video",
            "title": "Shrek",
            "videoId": "lmnopqrstuv",
            "author": "DreamWorks",
            "lengthSeconds": 95,
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: json)
    let hits = PodcastYouTubeSearchPicker.pick(from: data, limit: 5)
    #expect(hits.count == 2)
    #expect(hits[0].videoID == "abcdefghijk")
    #expect(hits[0].author == "The Verge")
    #expect(hits[0].durationLabel == "1:02:03")
    #expect(hits[0].thumbnailURL?.absoluteString == "https://cdn.example/m.jpg")
    #expect(hits[0].watchURL.absoluteString == "https://www.youtube.com/watch?v=abcdefghijk")
    #expect(hits[1].videoID == "lmnopqrstuv")
    #expect(hits[1].durationLabel == "1:35")
}

@Test func youtubeSearchPickRespectsLimit() throws {
    let items: [[String: Any]] = (0..<10).map { i in
        [
            "type": "video",
            "title": "Ep \(i)",
            "videoId": String(format: "vid%08dxx", i),
        ]
    }
    let data = try JSONSerialization.data(withJSONObject: items)
    let hits = PodcastYouTubeSearchPicker.pick(from: data, limit: 5)
    #expect(hits.count == 5)
}

@Test func youtubeSearchPickEmpty() {
    let hits = PodcastYouTubeSearchPicker.pick(from: Data("[]".utf8), limit: 5)
    #expect(hits.isEmpty)
}

@Test func matchedYouTubeStoreRoundTrip() {
    let store = PodcastMatchedYouTubeStore.shared
    let episodeID = "test-match-\(UUID().uuidString)"
    defer { store.remove(for: episodeID) }

    #expect(store.watchURL(for: episodeID) == nil)
    store.save(
        watchURL: URL(string: "https://youtu.be/iURXlAXLIVA")!,
        for: episodeID
    )
    #expect(
        store.watchURL(for: episodeID)?.absoluteString
            == "https://www.youtube.com/watch?v=iURXlAXLIVA"
    )
}

@Test func matchedYouTubeStoreRejectsChannelURL() {
    let store = PodcastMatchedYouTubeStore.shared
    let episodeID = "test-match-channel-\(UUID().uuidString)"
    defer { store.remove(for: episodeID) }
    store.save(
        watchURL: URL(string: "https://www.youtube.com/@SomeHandle")!,
        for: episodeID
    )
    #expect(store.watchURL(for: episodeID) == nil)
}
