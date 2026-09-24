import Foundation
import Testing
@testable import SilveranKit

@Suite("PodcastShelfPrunePolicy")
struct PodcastShelfPrunePolicyTests {
    private let settings = PodcastDownloadSettings.default
    private let now = Date(timeIntervalSince1970: 1_800_000_000) // fixed

    private func record(
        id: String,
        progress: Double,
        ageDays: Double,
        pinned: Bool = false,
        lastPlayedDaysAgo: Double? = nil,
        downloadedDaysAgo: Double? = nil
    ) -> PodcastDownloadRecord {
        let downloaded = now.addingTimeInterval(-(downloadedDaysAgo ?? ageDays) * 24 * 3600)
        let lastPlayed =
            lastPlayedDaysAgo.map { now.addingTimeInterval(-$0 * 24 * 3600) } ?? downloaded
        let duration: TimeInterval = 1000
        return PodcastDownloadRecord(
            episodeID: id,
            title: id,
            localFileName: "audio.mp3",
            downloadedAt: downloaded,
            lastPlayedAt: lastPlayed,
            durationSeconds: duration,
            positionSeconds: duration * progress,
            isFinished: progress >= 0.95,
            isPinned: pinned
        )
    }

    @Test("Pinned never wiped")
    func pinnedNeverWiped() {
        let pinnedFinished = record(id: "pin", progress: 0.99, ageDays: 40, pinned: true)
        let candidates = PodcastShelfPrunePolicy.candidates(
            from: [pinnedFinished],
            settings: settings,
            now: now
        )
        #expect(candidates.isEmpty)
    }

    @Test("40% played, 10d old, under cap → kept")
    func inProgressUnderAgeKept() {
        let ep = record(id: "mid", progress: 0.40, ageDays: 10)
        let candidates = PodcastShelfPrunePolicy.candidates(
            from: [ep],
            settings: settings,
            now: now
        )
        #expect(candidates.isEmpty)
    }

    @Test("2% played, 35d old → pruned (age)")
    func barelyStartedOverAgePruned() {
        let ep = record(id: "bare", progress: 0.02, ageDays: 35)
        let candidates = PodcastShelfPrunePolicy.candidates(
            from: [ep],
            settings: settings,
            now: now
        )
        #expect(candidates.count == 1)
        #expect(candidates.first?.reason == .agedOut)
    }

    @Test("98% → pruned when finished rule on")
    func nearlyFinishedPruned() {
        let ep = record(id: "done", progress: 0.98, ageDays: 2)
        let candidates = PodcastShelfPrunePolicy.candidates(
            from: [ep],
            settings: settings,
            now: now
        )
        #expect(candidates.count == 1)
        #expect(candidates.first?.reason == .finished)
    }

    @Test("Over 50 downloads → oldest eligible until ≤50")
    func overCapPrunesOldestEligible() {
        var records: [PodcastDownloadRecord] = []
        // 45 in-progress (≥10%, <95%) — protected from cap
        // Keep in-progress ages under maxAgeDays so over-cap (not aged-out) is what fires.
        for i in 0..<45 {
            records.append(
                record(
                    id: "prog-\(i)",
                    progress: 0.40,
                    ageDays: Double(i % 20),
                    lastPlayedDaysAgo: Double(i % 20)
                )
            )
        }
        // 10 barely started — eligible for over-cap
        for i in 0..<10 {
            records.append(
                record(
                    id: "bare-\(i)",
                    progress: 0.02,
                    ageDays: Double(20 + i),
                    lastPlayedDaysAgo: Double(100 + i)
                )
            )
        }
        // total 55 → need to remove 5 oldest eligible (bare-*)
        let candidates = PodcastShelfPrunePolicy.candidates(
            from: records,
            settings: settings,
            now: now
        )
        let overLimit = candidates.filter { $0.reason == .overLimit }
        #expect(overLimit.count == 5)
        #expect(overLimit.allSatisfy { $0.record.episodeID.hasPrefix("bare-") })
        // oldest last-play first: bare-9 ... bare-5 (lastPlayedDaysAgo 109..105)
        let ids = overLimit.map(\.record.episodeID)
        #expect(ids.contains("bare-9"))
        #expect(ids.contains("bare-5"))
        #expect(!ids.contains("bare-0"))
    }
}
