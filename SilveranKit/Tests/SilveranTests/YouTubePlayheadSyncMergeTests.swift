import Foundation
import SilveranKit
import Testing

@Suite("YouTubePlayheadSyncMerge")
struct YouTubePlayheadSyncMergeTests {
    private func record(
        videoID: String,
        position: TimeInterval,
        updatedAt: Date,
        cleared: Bool = false
    ) -> InkampYouTubePlayheadRecord {
        InkampYouTubePlayheadRecord(
            videoID: videoID,
            positionSeconds: position,
            durationSeconds: 600,
            episodeID: "ep-\(videoID)",
            showTitle: "Show",
            updatedAt: updatedAt,
            cleared: cleared
        )
    }

    @Test func mergeUnionsDistinctVideoIds() {
        let a = record(videoID: "aaa", position: 10, updatedAt: Date(timeIntervalSince1970: 100))
        let b = record(videoID: "bbb", position: 20, updatedAt: Date(timeIntervalSince1970: 200))
        let merged = YouTubePlayheadSyncMerge.mergePlayheads(local: [a], remote: [b])
        #expect(Set(merged.map(\.videoID)) == Set(["aaa", "bbb"]))
    }

    @Test func mergeLastWriteWinsSameVideoId() {
        let older = record(
            videoID: "vid",
            position: 30,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let newer = record(
            videoID: "vid",
            position: 120,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let merged = YouTubePlayheadSyncMerge.mergePlayheads(local: [older], remote: [newer])
        #expect(merged.count == 1)
        #expect(merged[0].positionSeconds == 120)
        #expect(merged[0].updatedAt == newer.updatedAt)
    }

    @Test func mergeNeverDropsLocalOnlyIds() {
        let localOnly = record(
            videoID: "phone-only",
            position: 45,
            updatedAt: Date(timeIntervalSince1970: 300)
        )
        let remote = record(
            videoID: "ipad-only",
            position: 10,
            updatedAt: Date(timeIntervalSince1970: 50)
        )
        let merged = YouTubePlayheadSyncMerge.mergePlayheads(local: [localOnly], remote: [remote])
        #expect(merged.contains(where: { $0.videoID == "phone-only" }))
        #expect(merged.contains(where: { $0.videoID == "ipad-only" }))
    }

    @Test func clearedTombstoneWinsOverOlderPosition() {
        let mid = record(
            videoID: "vid",
            position: 200,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let finished = record(
            videoID: "vid",
            position: 0,
            updatedAt: Date(timeIntervalSince1970: 200),
            cleared: true
        )
        let merged = YouTubePlayheadSyncMerge.mergePlayheads(local: [mid], remote: [finished])
        #expect(merged.count == 1)
        #expect(merged[0].cleared)
    }

    @Test func encodeDecodeRoundTrip() throws {
        let doc = InkampYouTubePlayheadSyncDocument(
            playheads: [
                record(videoID: "x", position: 42, updatedAt: Date(timeIntervalSince1970: 1))
            ]
        )
        let encoded = try YouTubePlayheadSyncMerge.encodeDescription(doc)
        let decoded = try YouTubePlayheadSyncMerge.decodeDescription(encoded)
        #expect(decoded.playheads.count == 1)
        #expect(decoded.playheads[0].videoID == "x")
        #expect(decoded.playheads[0].positionSeconds == 42)
    }
}
