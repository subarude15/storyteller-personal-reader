//
//  PodcastActivity.swift
//  SilveranKit
//
//  Podcast-level "new since you opened this show" — not per-episode read state.
//  The watermark is the latest episode publish date the user has already seen.
//
//  Kept off the subscription sync record on purpose: that ledger is last-write-wins
//  on `updatedAt`, and a view acknowledgement must not outrank an unsubscribe.
//  Device-local UserDefaults survives relaunch and feed refresh without a sync redesign.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Observation

/// Pure decisions for the podcast new-activity chip and episode release labels.
public enum PodcastActivity: Sendable {
    /// Chip only when we already have a watermark and a strictly newer episode.
    /// Missing watermark is not "new" — first sight baselines to the current latest
    /// so an existing library does not light up.
    public static func showsNewActivity(
        latestPublish: Date?,
        acknowledgedPublish: Date?
    ) -> Bool {
        guard let latestPublish, let acknowledgedPublish else { return false }
        return latestPublish > acknowledgedPublish
    }

    /// First observation records the current latest publish date. A later refresh
    /// must leave an existing watermark alone so the chip stays until the show is opened.
    public static func baselineIfNeeded(
        acknowledgedPublish: Date?,
        latestPublish: Date?
    ) -> Date? {
        if let acknowledgedPublish { return acknowledgedPublish }
        return latestPublish
    }

    /// Opening the show acknowledges the newest episode we can see. Never move
    /// the watermark backward (a stale snapshot must not resurrect the chip).
    public static func acknowledge(
        acknowledgedPublish: Date?,
        latestPublish: Date?
    ) -> Date? {
        guard let latestPublish else { return acknowledgedPublish }
        guard let acknowledgedPublish else { return latestPublish }
        return max(acknowledgedPublish, latestPublish)
    }

    /// Secondary label for an episode row. Recent days stay relative; older
    /// dates use a short calendar form (`Sep 18, 2026`).
    public static func releaseDateLabel(
        for date: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "Today"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "Yesterday"
        }
        let start = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        if let days = calendar.dateComponents([.day], from: start, to: today).day,
            days > 1, days < 7
        {
            return "\(days) days ago"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? Locale(identifier: "en_US")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }
}

/// Persisted per-feed acknowledged publish date. Not part of podcast sync.
@MainActor
@Observable
public final class PodcastActivityStore {
    public static let shared = PodcastActivityStore(defaults: .standard)

    private static let defaultKey = "punkRally.podcastActivity.acknowledgedPublish.v1"

    private let defaults: UserDefaults
    private let defaultsKey: String
    private var acknowledged: [String: Date]
    /// Bumped on every write so overview rows refresh after the show is opened.
    private(set) var revision: Int = 0

    public init(defaults: UserDefaults, defaultsKey: String = PodcastActivityStore.defaultKey) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        acknowledged = Self.load(defaults: defaults, key: defaultsKey)
    }

    public func showsNewActivity(feedURL: URL?, latestPublish: Date?) -> Bool {
        _ = revision
        guard let feedURL else { return false }
        return PodcastActivity.showsNewActivity(
            latestPublish: latestPublish,
            acknowledgedPublish: acknowledged[feedURL.absoluteString]
        )
    }

    /// Call after a successful feed load. No-op once a watermark exists.
    public func baselineIfNeeded(feedURL: URL, latestPublish: Date?) {
        let key = feedURL.absoluteString
        let next = PodcastActivity.baselineIfNeeded(
            acknowledgedPublish: acknowledged[key],
            latestPublish: latestPublish
        )
        guard let next, acknowledged[key] != next else { return }
        var updated = acknowledged
        updated[key] = next
        acknowledged = updated
        revision &+= 1
        persist()
    }

    /// Call when the subscribed show's episode screen is opened.
    public func acknowledge(feedURL: URL, latestPublish: Date?) {
        let key = feedURL.absoluteString
        let next = PodcastActivity.acknowledge(
            acknowledgedPublish: acknowledged[key],
            latestPublish: latestPublish
        )
        guard let next, acknowledged[key] != next else { return }
        var updated = acknowledged
        updated[key] = next
        acknowledged = updated
        revision &+= 1
        persist()
    }

    private func persist() {
        let raw = acknowledged.mapValues { $0.timeIntervalSince1970 }
        defaults.set(raw, forKey: defaultsKey)
    }

    private static func load(defaults: UserDefaults, key: String) -> [String: Date] {
        guard let raw = defaults.dictionary(forKey: key) else { return [:] }
        var decoded: [String: Date] = [:]
        for (feed, value) in raw {
            let seconds: Double?
            if let number = value as? Double {
                seconds = number
            } else if let number = value as? Int {
                seconds = Double(number)
            } else {
                seconds = nil
            }
            if let seconds {
                decoded[feed] = Date(timeIntervalSince1970: seconds)
            }
        }
        return decoded
    }
}
