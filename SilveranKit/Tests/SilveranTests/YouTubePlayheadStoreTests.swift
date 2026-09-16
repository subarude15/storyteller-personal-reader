import Foundation
import Testing

@testable import SilveranKit

@Test func youtubePlayheadSaveAndResumeByVideoID() {
    let store = YouTubePlayheadStore.shared
    let videoID = "ytPlayheadTst1"
    store.clear(videoID: videoID)

    store.save(
        videoID: videoID,
        positionSeconds: 123,
        durationSeconds: 600,
        episodeID: "ep-shrek",
        showTitle: "Sounds Like A Cult"
    )

    let entry = store.entry(for: videoID)
    #expect(entry?.positionSeconds == 123)
    #expect(entry?.episodeID == "ep-shrek")
    #expect(entry?.showTitle == "Sounds Like A Cult")
    #expect(store.position(for: videoID) == 123)

    store.clear(videoID: videoID)
    #expect(store.entry(for: videoID) == nil)
}

@Test func youtubePlayheadNearEndClears() {
    let store = YouTubePlayheadStore.shared
    let videoID = "ytPlayheadTst2"
    store.clear(videoID: videoID)

    store.save(
        videoID: videoID,
        positionSeconds: 100,
        durationSeconds: 200,
        episodeID: "ep-a"
    )
    #expect(store.entry(for: videoID) != nil)

    store.save(
        videoID: videoID,
        positionSeconds: 190,
        durationSeconds: 200,
        episodeID: "ep-a"
    )
    #expect(store.entry(for: videoID) == nil)

    store.save(
        videoID: videoID,
        positionSeconds: 50,
        durationSeconds: 200,
        episodeID: "ep-a"
    )
    store.save(
        videoID: videoID,
        positionSeconds: 50,
        durationSeconds: 200,
        markFinished: true
    )
    #expect(store.entry(for: videoID) == nil)
}
