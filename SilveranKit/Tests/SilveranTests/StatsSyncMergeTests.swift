import Foundation
import SilveranKit
import Testing

@Suite("StatsSyncMerge")
struct StatsSyncMergeTests {
    private func session(
        id: UUID = UUID(),
        endedAt: Date,
        duration: TimeInterval = 60
    ) -> InkampStatsSessionRecord {
        InkampStatsSessionRecord(
            id: id,
            kind: .listening,
            mediaID: "m1",
            mediaTitle: "T",
            startedAt: endedAt.addingTimeInterval(-duration),
            endedAt: endedAt,
            durationSeconds: duration
        )
    }

    @Test func mergeSessionsUnionsDistinctIds() {
        let a = session(endedAt: Date(timeIntervalSince1970: 100))
        let b = session(endedAt: Date(timeIntervalSince1970: 200))
        let merged = StatsSyncMerge.mergeSessions(local: [a], remote: [b])
        #expect(Set(merged.map(\.id)) == Set([a.id, b.id]))
        #expect(merged.map(\.durationSeconds).reduce(0, +) == 120)
    }

    @Test func mergeSessionsLastWriteWinsSameId() {
        let id = UUID()
        let older = session(id: id, endedAt: Date(timeIntervalSince1970: 100), duration: 40)
        let newer = session(id: id, endedAt: Date(timeIntervalSince1970: 200), duration: 90)
        let merged = StatsSyncMerge.mergeSessions(local: [older], remote: [newer])
        #expect(merged.count == 1)
        #expect(merged[0].durationSeconds == 90)
        #expect(merged[0].endedAt == newer.endedAt)
    }

    @Test func mergeNeverDropsLocalOnlySessions() {
        let localOnly = session(endedAt: Date(timeIntervalSince1970: 300), duration: 120)
        let remote = session(endedAt: Date(timeIntervalSince1970: 50), duration: 30)
        let merged = StatsSyncMerge.mergeSessions(local: [localOnly], remote: [remote])
        #expect(merged.contains(where: { $0.id == localOnly.id }))
        let total = merged.map(\.durationSeconds).reduce(0, +)
        #expect(total >= localOnly.durationSeconds)
    }

    @Test func mergeFinishedLastWriteWins() {
        let local = InkampStatsFinishedRecord(
            mediaID: "b1",
            mediaTitle: "A",
            finishedAt: Date(timeIntervalSince1970: 10)
        )
        let remote = InkampStatsFinishedRecord(
            mediaID: "b1",
            mediaTitle: "A*",
            finishedAt: Date(timeIntervalSince1970: 20)
        )
        let other = InkampStatsFinishedRecord(
            mediaID: "b2",
            mediaTitle: "B",
            finishedAt: Date(timeIntervalSince1970: 15)
        )
        let merged = StatsSyncMerge.mergeFinished(local: [local, other], remote: [remote])
        #expect(merged.count == 2)
        #expect(merged.first(where: { $0.mediaID == "b1" })?.mediaTitle == "A*")
    }

    @Test func encodeDecodeRoundTrip() throws {
        let doc = InkampStatsSyncDocument(
            sessions: [session(endedAt: Date(timeIntervalSince1970: 1))],
            finished: [
                InkampStatsFinishedRecord(
                    mediaID: "x",
                    mediaTitle: "X",
                    finishedAt: Date(timeIntervalSince1970: 2)
                )
            ]
        )
        let encoded = try StatsSyncMerge.encodeDescription(doc)
        let decoded = try StatsSyncMerge.decodeDescription(encoded)
        #expect(decoded.sessions.count == 1)
        #expect(decoded.finished.count == 1)
        #expect(decoded.sessions[0].id == doc.sessions[0].id)
    }
}
