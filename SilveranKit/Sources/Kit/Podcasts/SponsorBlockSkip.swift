//
//  SponsorBlockSkip.swift
//  SilveranKit
//
//  SponsorBlock public API for in-app YouTube skip (not podcast Clean).
//  https://sponsor.ajay.app/api/skipSegments?videoID=…&categories=[…]
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// One skippable range from SponsorBlock (seconds on the video timeline).
public struct SponsorBlockSegment: Equatable, Sendable, Identifiable {
    public var id: String { "\(category)-\(start)-\(end)" }
    public let category: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(category: String, start: TimeInterval, end: TimeInterval) {
        self.category = category
        self.start = start
        self.end = end
    }
}

/// v1 categories Josh can toggle in Settings.
public enum SponsorBlockCategory: String, CaseIterable, Sendable, Identifiable {
    case sponsor
    case selfpromo
    case intro
    case outro
    case interaction

    public var id: String { rawValue }

    public var settingsTitle: String {
        switch self {
            case .sponsor: return "Sponsor"
            case .selfpromo: return "Self-promo"
            case .intro: return "Intro"
            case .outro: return "Outro"
            case .interaction: return "Interaction"
        }
    }

    /// Defaults on for sponsor / selfpromo / intro / outro; interaction off.
    public var defaultEnabled: Bool {
        switch self {
            case .sponsor, .selfpromo, .intro, .outro: return true
            case .interaction: return false
        }
    }
}

/// UserDefaults for SponsorBlock skip (in-app YouTube only).
public enum SponsorBlockSettings: Sendable {
    public static let enabledKey = "punkRally.sponsorBlock.enabled.v1"
    public static let categoriesKey = "punkRally.sponsorBlock.categories.v1"
    public static let apiBaseKey = "punkRally.sponsorBlock.apiBase.v1"
    public static let showToastKey = "punkRally.sponsorBlock.showToast.v1"

    public static let defaultAPIBase = "https://sponsor.ajay.app"

    public static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// One-shot “Skipped …” toast when a segment is skipped (default on).
    public static var showSkipToast: Bool {
        get {
            if UserDefaults.standard.object(forKey: showToastKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: showToastKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: showToastKey) }
    }

    public static var apiBaseURLString: String {
        get {
            let stored = UserDefaults.standard.string(forKey: apiBaseKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let stored, !stored.isEmpty { return stored }
            return defaultAPIBase
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed.isEmpty ? defaultAPIBase : trimmed, forKey: apiBaseKey)
        }
    }

    public static var enabledCategories: Set<String> {
        get {
            if let stored = UserDefaults.standard.array(forKey: categoriesKey) as? [String] {
                return Set(stored)
            }
            return Set(SponsorBlockCategory.allCases.filter(\.defaultEnabled).map(\.rawValue))
        }
        set {
            UserDefaults.standard.set(Array(newValue).sorted(), forKey: categoriesKey)
        }
    }

    public static func isCategoryEnabled(_ category: SponsorBlockCategory) -> Bool {
        enabledCategories.contains(category.rawValue)
    }

    public static func setCategory(_ category: SponsorBlockCategory, enabled: Bool) {
        var next = enabledCategories
        if enabled {
            next.insert(category.rawValue)
        } else {
            next.remove(category.rawValue)
        }
        enabledCategories = next
    }
}

/// Pure helpers — fetch lives in `SponsorBlockClient`.
public enum SponsorBlockSkipLogic {
    /// First segment containing `time` (`start <= time < end`), preferring earliest start.
    public static func activeSegment(
        at time: TimeInterval,
        in segments: [SponsorBlockSegment],
        allowedCategories: Set<String>
    ) -> SponsorBlockSegment? {
        guard time.isFinite, time >= 0 else { return nil }
        return segments
            .filter { allowedCategories.contains($0.category) }
            .filter { $0.end > $0.start + 0.15 }
            .filter { time >= $0.start && time < $0.end }
            .sorted { $0.start < $1.start }
            .first
    }

    /// Parse SponsorBlock skipSegments JSON array.
    public static func parseSegments(_ data: Data) throws -> [SponsorBlockSegment] {
        let rows = try JSONDecoder().decode([WireSegment].self, from: data)
        return rows.compactMap { row -> SponsorBlockSegment? in
            // v1: only auto-skip action (default when omitted).
            if let action = row.actionType, action != "skip" { return nil }
            guard row.segment.count >= 2 else { return nil }
            let start = row.segment[0]
            let end = row.segment[1]
            guard start.isFinite, end.isFinite, end > start else { return nil }
            let category = row.category.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !category.isEmpty else { return nil }
            return SponsorBlockSegment(category: category, start: start, end: end)
        }
        .sorted { $0.start < $1.start }
    }

    public static func skipSegmentsURL(
        apiBase: String,
        videoID: String,
        categories: Set<String>
    ) -> URL? {
        let base = apiBase.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty, !videoID.isEmpty else { return nil }
        let cats = categories.sorted()
        guard !cats.isEmpty else { return nil }
        guard
            let catsJSON = try? JSONSerialization.data(withJSONObject: cats),
            let catsString = String(data: catsJSON, encoding: .utf8)
        else { return nil }
        var components = URLComponents(string: "\(base)/api/skipSegments")
        components?.queryItems = [
            URLQueryItem(name: "videoID", value: videoID),
            URLQueryItem(name: "categories", value: catsString),
        ]
        return components?.url
    }

    private struct WireSegment: Decodable {
        let category: String
        let actionType: String?
        let segment: [Double]
    }
}

/// Fetches skip segments; soft-fails to empty on network / 404 / bad JSON.
public struct SponsorBlockClient: Sendable {
    public static let shared = SponsorBlockClient()

    public init() {}

    public func fetchSegments(
        videoID: String,
        categories: Set<String>,
        apiBase: String = SponsorBlockSettings.apiBaseURLString
    ) async -> [SponsorBlockSegment] {
        guard
            let url = SponsorBlockSkipLogic.skipSegmentsURL(
                apiBase: apiBase,
                videoID: videoID,
                categories: categories
            )
        else { return [] }

        var request = URLRequest(url: url)
        request.setValue("ink-amp/1.0 (SponsorBlock)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return [] }
            // 404 = no segments — play normally.
            guard (200..<300).contains(http.statusCode) else { return [] }
            return try SponsorBlockSkipLogic.parseSegments(data)
        } catch {
            return []
        }
    }
}
