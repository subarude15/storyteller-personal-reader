//
//  PodcastActivityTests.swift
//  SilveranTests
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing

@testable import SilveranKit

@Suite("PodcastActivity")
struct PodcastActivityTests {
    private let older = Date(timeIntervalSince1970: 1_000)
    private let newer = Date(timeIntervalSince1970: 2_000)
    private let newest = Date(timeIntervalSince1970: 3_000)

    @Test func noIndicatorWhenLatestMatchesAcknowledged() {
        #expect(
            !PodcastActivity.showsNewActivity(
                latestPublish: older,
                acknowledgedPublish: older
            )
        )
    }

    @Test func indicatorWhenEpisodeIsNewerThanLastViewed() {
        #expect(
            PodcastActivity.showsNewActivity(
                latestPublish: newer,
                acknowledgedPublish: older
            )
        )
    }

    @Test func openingShowClearsIndicatorUntilALaterEpisode() {
        let acknowledged = PodcastActivity.acknowledge(
            acknowledgedPublish: older,
            latestPublish: newer
        )
        #expect(acknowledged == newer)
        #expect(
            !PodcastActivity.showsNewActivity(
                latestPublish: newer,
                acknowledgedPublish: acknowledged
            )
        )

        #expect(
            PodcastActivity.showsNewActivity(
                latestPublish: newest,
                acknowledgedPublish: acknowledged
            )
        )
    }

    @Test func refreshDoesNotMoveAnExistingWatermark() {
        let kept = PodcastActivity.baselineIfNeeded(
            acknowledgedPublish: older,
            latestPublish: newer
        )
        #expect(kept == older)
        #expect(
            PodcastActivity.showsNewActivity(
                latestPublish: newer,
                acknowledgedPublish: kept
            )
        )
    }

    @Test func missingWatermarkDoesNotMarkExistingLibraryNew() {
        #expect(
            !PodcastActivity.showsNewActivity(
                latestPublish: newer,
                acknowledgedPublish: nil
            )
        )
        #expect(
            PodcastActivity.baselineIfNeeded(
                acknowledgedPublish: nil,
                latestPublish: newer
            ) == newer
        )
        #expect(
            !PodcastActivity.showsNewActivity(
                latestPublish: newer,
                acknowledgedPublish: newer
            )
        )
    }

    @Test func acknowledgeDoesNotMoveWatermarkBackward() {
        #expect(
            PodcastActivity.acknowledge(
                acknowledgedPublish: newer,
                latestPublish: older
            ) == newer
        )
    }

    @Test func releaseDateLabelUsesRelativeThenCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US")
        let now = Date(timeIntervalSince1970: 1_789_837_200) // 2026-09-19 17:00:00 UTC

        func date(daysBefore now: Date, days: Int) -> Date {
            calendar.date(byAdding: .day, value: -days, to: now)!
        }

        #expect(
            PodcastActivity.releaseDateLabel(for: now, now: now, calendar: calendar) == "Today"
        )
        #expect(
            PodcastActivity.releaseDateLabel(
                for: date(daysBefore: now, days: 1),
                now: now,
                calendar: calendar
            ) == "Yesterday"
        )
        #expect(
            PodcastActivity.releaseDateLabel(
                for: date(daysBefore: now, days: 3),
                now: now,
                calendar: calendar
            ) == "3 days ago"
        )
        #expect(
            PodcastActivity.releaseDateLabel(
                for: date(daysBefore: now, days: 10),
                now: now,
                calendar: calendar
            ) == "Sep 9, 2026"
        )
    }
}

@Suite("PodcastActivityStore")
@MainActor
struct PodcastActivityStoreTests {
    private let feed = URL(string: "https://example.com/feed.xml")!

    private func makeStore() -> PodcastActivityStore {
        let name = "inkamp.podcastActivity.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return PodcastActivityStore(defaults: defaults, defaultsKey: name)
    }

    @Test func firstSightBaselinesWithoutAChip() {
        let store = makeStore()
        let latest = Date(timeIntervalSince1970: 1_700_000_000)
        store.baselineIfNeeded(feedURL: feed, latestPublish: latest)
        #expect(!store.showsNewActivity(feedURL: feed, latestPublish: latest))
    }

    @Test func refreshKeepsChipUntilShowIsOpened() {
        let store = makeStore()
        let seen = Date(timeIntervalSince1970: 1_700_000_000)
        let arrived = seen.addingTimeInterval(86_400)
        store.baselineIfNeeded(feedURL: feed, latestPublish: seen)

        store.baselineIfNeeded(feedURL: feed, latestPublish: arrived)
        #expect(store.showsNewActivity(feedURL: feed, latestPublish: arrived))

        // Another refresh of the same feed must not clear the chip.
        store.baselineIfNeeded(feedURL: feed, latestPublish: arrived)
        #expect(store.showsNewActivity(feedURL: feed, latestPublish: arrived))

        store.acknowledge(feedURL: feed, latestPublish: arrived)
        #expect(!store.showsNewActivity(feedURL: feed, latestPublish: arrived))
    }

    @Test func laterEpisodeBringsTheChipBack() {
        let store = makeStore()
        let seen = Date(timeIntervalSince1970: 1_700_000_000)
        let firstNew = seen.addingTimeInterval(86_400)
        let secondNew = firstNew.addingTimeInterval(86_400)
        store.baselineIfNeeded(feedURL: feed, latestPublish: seen)
        store.acknowledge(feedURL: feed, latestPublish: firstNew)
        #expect(!store.showsNewActivity(feedURL: feed, latestPublish: firstNew))

        store.baselineIfNeeded(feedURL: feed, latestPublish: secondNew)
        #expect(store.showsNewActivity(feedURL: feed, latestPublish: secondNew))
    }

    @Test func watermarkSurvivesANewStoreInstance() {
        let name = "inkamp.podcastActivity.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let seen = Date(timeIntervalSince1970: 1_700_000_000)
        let arrived = seen.addingTimeInterval(3_600)

        let first = PodcastActivityStore(defaults: defaults, defaultsKey: name)
        first.baselineIfNeeded(feedURL: feed, latestPublish: seen)

        let reloaded = PodcastActivityStore(defaults: defaults, defaultsKey: name)
        #expect(!reloaded.showsNewActivity(feedURL: feed, latestPublish: seen))
        #expect(reloaded.showsNewActivity(feedURL: feed, latestPublish: arrived))
    }
}
