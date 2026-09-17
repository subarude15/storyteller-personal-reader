//
//  BookRecentStore.swift
//  SilveranAppleKit
//
//  Local wall-clock last-touched for Storyteller books on Home mixed queue.
//  Complements server BookProgress timestamps so Continue / Up next sort by
//  real open/dismiss activity even when progress cache is stale or missing ts.
//
//  SPDX-License-Identifier: AGPL-3.0-only

#if os(iOS)
import Foundation
import SilveranKit

/// Persists per-book open/dismiss times for Home last-touched ordering.
public struct BookRecentStore: Sendable {
    private static let defaultsKey = "punkRally.bookRecents.v1"
    private static let maxEntries = 40

    public static let shared = BookRecentStore()
    private init() {}

    private var defaults: UserDefaults {
        if let group = UserDefaults(suiteName: "group.com.punkrally.reader") {
            return group
        }
        return .standard
    }

    public func all() -> [BookID: Date] {
        Dictionary(uniqueKeysWithValues: load().map { ($0.bookID, $0.lastTouched) })
    }

    public func lastTouched(for bookID: BookID) -> Date? {
        load().first(where: { $0.bookID == bookID })?.lastTouched
    }

    public func record(_ bookID: BookID, at date: Date = Date()) {
        var items = load().filter { $0.bookID != bookID }
        items.insert(Entry(bookID: bookID, lastTouched: date), at: 0)
        if items.count > Self.maxEntries {
            items = Array(items.prefix(Self.maxEntries))
        }
        save(items)
    }

    private struct Entry: Codable, Equatable {
        var bookID: BookID
        var lastTouched: Date
    }

    private func load() -> [Entry] {
        guard
            let data = defaults.data(forKey: Self.defaultsKey),
            let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return decoded
    }

    private func save(_ items: [Entry]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
#endif
