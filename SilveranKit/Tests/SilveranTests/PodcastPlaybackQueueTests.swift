import Foundation
import SilveranKit
import Testing

@Suite("PodcastPlaybackQueueEdits")
struct PodcastPlaybackQueueTests {
    private func item(_ id: String) -> PodcastPlaybackQueueItem {
        PodcastPlaybackQueueItem(
            episodeID: id,
            title: id,
            audioURL: URL(string: "https://example.com/\(id).mp3")!
        )
    }

    @Test func playNextInsertsAtFrontAndDedupes() {
        let a = item("a")
        let b = item("b")
        let c = item("c")
        var queue = [a, b]
        queue = PodcastPlaybackQueueEdits.playNext(upcoming: queue, item: c)
        #expect(queue.map(\.episodeID) == ["c", "a", "b"])

        queue = PodcastPlaybackQueueEdits.playNext(upcoming: queue, item: a)
        #expect(queue.map(\.episodeID) == ["a", "c", "b"])
    }

    @Test func playLastAppendsAndDedupes() {
        let a = item("a")
        let b = item("b")
        let c = item("c")
        var queue = [a]
        queue = PodcastPlaybackQueueEdits.playLast(upcoming: queue, item: b)
        #expect(queue.map(\.episodeID) == ["a", "b"])

        queue = PodcastPlaybackQueueEdits.playLast(upcoming: queue, item: a)
        #expect(queue.map(\.episodeID) == ["b", "a"])

        queue = PodcastPlaybackQueueEdits.playLast(upcoming: queue, item: c)
        #expect(queue.map(\.episodeID) == ["b", "a", "c"])
    }
}
