//
//  PodcastSyncMergeTests.swift
//  SilveranTests
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit
import Testing

@Suite("PodcastSyncMerge")
struct PodcastSyncMergeTests {
    private func sub(
        feed: String,
        updatedAt: Date,
        unsubscribed: Bool = false,
        title: String? = "Show"
    ) -> InkampPodcastSubscriptionRecord {
        InkampPodcastSubscriptionRecord(
            feedURL: feed,
            title: title,
            addedAt: updatedAt,
            updatedAt: updatedAt,
            unsubscribed: unsubscribed
        )
    }

    private func head(
        episodeID: String,
        position: TimeInterval,
        updatedAt: Date,
        cleared: Bool = false
    ) -> InkampPodcastPlayheadRecord {
        InkampPodcastPlayheadRecord(
            episodeID: episodeID,
            positionSeconds: position,
            durationSeconds: 600,
            updatedAt: updatedAt,
            cleared: cleared
        )
    }

    @Test func mergeUnionsDistinctFeedsAndEpisodes() {
        let localSub = sub(feed: "https://a.example/feed", updatedAt: Date(timeIntervalSince1970: 100))
        let remoteSub = sub(feed: "https://b.example/feed", updatedAt: Date(timeIntervalSince1970: 200))
        let localHead = head(episodeID: "ep-a", position: 10, updatedAt: Date(timeIntervalSince1970: 100))
        let remoteHead = head(episodeID: "ep-b", position: 20, updatedAt: Date(timeIntervalSince1970: 200))

        let merged = PodcastSyncMerge.mergeDocuments(
            local: InkampPodcastSyncDocument(
                subscriptions: [localSub],
                playheads: [localHead]
            ),
            remote: InkampPodcastSyncDocument(
                subscriptions: [remoteSub],
                playheads: [remoteHead]
            )
        )
        #expect(Set(merged.subscriptions.map(\.feedURL)) == Set([
            "https://a.example/feed",
            "https://b.example/feed",
        ]))
        #expect(Set(merged.playheads.map(\.episodeID)) == Set(["ep-a", "ep-b"]))
    }

    @Test func mergeLastWriteWinsSameFeedAndEpisode() {
        let olderSub = sub(feed: "https://x.example/feed", updatedAt: Date(timeIntervalSince1970: 100))
        let newerSub = sub(
            feed: "https://x.example/feed",
            updatedAt: Date(timeIntervalSince1970: 200),
            title: "Newer"
        )
        let olderHead = head(episodeID: "ep", position: 30, updatedAt: Date(timeIntervalSince1970: 100))
        let newerHead = head(episodeID: "ep", position: 120, updatedAt: Date(timeIntervalSince1970: 200))

        let merged = PodcastSyncMerge.mergeDocuments(
            local: InkampPodcastSyncDocument(subscriptions: [olderSub], playheads: [olderHead]),
            remote: InkampPodcastSyncDocument(subscriptions: [newerSub], playheads: [newerHead])
        )
        #expect(merged.subscriptions.count == 1)
        #expect(merged.subscriptions[0].title == "Newer")
        #expect(merged.playheads.count == 1)
        #expect(merged.playheads[0].positionSeconds == 120)
    }

    @Test func unsubscribeTombstoneWinsOverOlderSubscribe() {
        let subscribed = sub(
            feed: "https://x.example/feed",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let gone = sub(
            feed: "https://x.example/feed",
            updatedAt: Date(timeIntervalSince1970: 200),
            unsubscribed: true
        )
        let merged = PodcastSyncMerge.mergeSubscriptions(local: [subscribed], remote: [gone])
        #expect(merged.count == 1)
        #expect(merged[0].unsubscribed)
    }

    @Test func clearedPlayheadWinsOverOlderPosition() {
        let mid = head(episodeID: "ep", position: 200, updatedAt: Date(timeIntervalSince1970: 100))
        let finished = head(
            episodeID: "ep",
            position: 0,
            updatedAt: Date(timeIntervalSince1970: 200),
            cleared: true
        )
        let merged = PodcastSyncMerge.mergePlayheads(local: [mid], remote: [finished])
        #expect(merged.count == 1)
        #expect(merged[0].cleared)
    }

    @Test func clearedPlayheadWinsTimestampTie() {
        let timestamp = Date(timeIntervalSince1970: 200)
        let mid = head(episodeID: "ep", position: 200, updatedAt: timestamp)
        let finished = head(
            episodeID: "ep",
            position: 0,
            updatedAt: timestamp,
            cleared: true
        )
        let merged = PodcastSyncMerge.mergePlayheads(local: [mid], remote: [finished])
        #expect(merged.count == 1)
        #expect(merged[0].cleared)
    }

    @Test func encodeRoundTrip() throws {
        let doc = InkampPodcastSyncDocument(
            subscriptions: [
                sub(feed: "https://a.example/feed", updatedAt: Date(timeIntervalSince1970: 50))
            ],
            playheads: [
                head(episodeID: "ep1", position: 42, updatedAt: Date(timeIntervalSince1970: 60))
            ]
        )
        let encoded = try PodcastSyncMerge.encodeDescription(doc)
        let decoded = try PodcastSyncMerge.decodeDescription(encoded)
        #expect(decoded.subscriptions.count == 1)
        #expect(decoded.playheads[0].positionSeconds == 42)
        #expect(decoded.schemaVersion == InkampPodcastSyncDocument.schemaVersion)
    }
}
