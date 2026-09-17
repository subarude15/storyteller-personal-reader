//
//  PodcastYouTubeSearchPick.swift
//  SilveranKit
//
//  Pure parser: Invidious /api/v1/search JSON → ranked video hits for Match on YouTube.
//  No network. Used by PodcastYouTubeResolver (AppleKit).
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// One Invidious search hit the user can confirm as the episode’s YouTube video.
public struct PodcastYouTubeSearchResult: Sendable, Equatable, Identifiable {
    public var id: String { videoID }
    public let videoID: String
    public let title: String
    public let author: String?
    public let lengthSeconds: Int?
    public let thumbnailURL: URL?

    public init(
        videoID: String,
        title: String,
        author: String? = nil,
        lengthSeconds: Int? = nil,
        thumbnailURL: URL? = nil
    ) {
        self.videoID = videoID
        self.title = title
        self.author = author
        self.lengthSeconds = lengthSeconds
        self.thumbnailURL = thumbnailURL
    }

    public var watchURL: URL {
        URL(string: "https://www.youtube.com/watch?v=\(videoID)")!
    }

    public var durationLabel: String? {
        guard let lengthSeconds, lengthSeconds > 0 else { return nil }
        let h = lengthSeconds / 3600
        let m = (lengthSeconds % 3600) / 60
        let s = lengthSeconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

/// Parses Invidious `/api/v1/search` (and Piped-shaped) JSON into video results.
public enum PodcastYouTubeSearchPicker: Sendable {
    /// Parse search JSON; keep only `type == video` (or entries with videoId). Cap at `limit`.
    public static func pick(from data: Data, limit: Int = 5) -> [PodcastYouTubeSearchResult] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return pick(from: json, limit: limit)
    }

    public static func pick(from json: Any, limit: Int = 5) -> [PodcastYouTubeSearchResult] {
        let items: [[String: Any]]
        if let array = json as? [[String: Any]] {
            items = array
        } else if let root = json as? [String: Any],
            let nested = root["items"] as? [[String: Any]] ?? root["results"] as? [[String: Any]]
        {
            items = nested
        } else {
            return []
        }

        var results: [PodcastYouTubeSearchResult] = []
        results.reserveCapacity(min(limit, items.count))
        for item in items {
            guard results.count < limit else { break }
            if let type = item["type"] as? String, type.lowercased() != "video" {
                continue
            }
            guard let videoID = stringValue(item["videoId"] ?? item["videoID"] ?? item["id"]),
                isLikelyVideoID(videoID)
            else { continue }
            let title = stringValue(item["title"]) ?? "Untitled"
            let author = stringValue(item["author"] ?? item["uploader"] ?? item["channelName"])
            let length = intValue(item["lengthSeconds"] ?? item["duration"] ?? item["length"])
            let thumb = thumbnailURL(from: item)
            results.append(
                PodcastYouTubeSearchResult(
                    videoID: videoID,
                    title: title,
                    author: author,
                    lengthSeconds: length,
                    thumbnailURL: thumb
                )
            )
        }
        return results
    }

    // MARK: - Helpers

    private static func stringValue(_ any: Any?) -> String? {
        guard let s = any as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let s = any as? String, let i = Int(s) { return i }
        return nil
    }

    private static func isLikelyVideoID(_ id: String) -> Bool {
        guard (8...20).contains(id.count) else { return false }
        return id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
    }

    private static func thumbnailURL(from item: [String: Any]) -> URL? {
        if let direct = stringValue(item["thumbnail"] ?? item["thumbnailUrl"] ?? item["thumbnailURL"]),
            let url = URL(string: direct)
        {
            return url
        }
        guard let thumbs = item["videoThumbnails"] as? [[String: Any]] else { return nil }
        // Prefer medium / high quality labels when present.
        let preferred = ["medium", "high", "sddefault", "hqdefault", "default"]
        for quality in preferred {
            if let match = thumbs.first(where: {
                ($0["quality"] as? String)?.lowercased() == quality
            }), let raw = stringValue(match["url"]), let url = URL(string: raw)
            {
                return url
            }
        }
        for thumb in thumbs {
            if let raw = stringValue(thumb["url"]), let url = URL(string: raw) {
                return url
            }
        }
        return nil
    }
}
