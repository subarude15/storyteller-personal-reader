//
//  PodcastYouTubeURL.swift
//  SilveranKit
//
//  Detect YouTube *video* URLs in RSS link / show notes / iTunes text.
//  Extract only when a video id parses (watch / youtu.be / embed / shorts / live);
//  skip channel / @handle / /user/ /c/ /playlist. Normalize for in-app resolve
//  (Settings → YouTube resolve URL) or Watch on YouTube handoff. Never treat the
//  watch page itself as an RSS video enclosure — resolve to progressive/HLS first.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Finds the first YouTube watch/share URL in free-form feed text or HTML.
public enum PodcastYouTubeURL: Sendable {
    /// Hosts we treat as YouTube (resolve in-app or open via Safari / YouTube app).
    private static let hosts: Set<String> = [
        "youtube.com",
        "www.youtube.com",
        "m.youtube.com",
        "music.youtube.com",
        "youtu.be",
        "www.youtu.be",
    ]

    /// Returns the first YouTube URL that yields a real video id.
    /// Channel / @handle / /user/ /c/ /playlist (without `v=`) are skipped so
    /// Play in ink+amp never hands off a channel page as if it were an episode.
    public static func extract(from candidates: [String]) -> URL? {
        for raw in candidates {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let direct = URL(string: trimmed), let watch = normalizedWatchURL(direct) {
                return watch
            }
            for match in urlMatches(in: trimmed) {
                if let url = URL(string: match), let watch = normalizedWatchURL(url) {
                    return watch
                }
            }
        }
        return nil
    }

    public static func isYouTubeURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return hosts.contains(host)
    }

    /// Prefer a stable https watch URL when we can parse a video id.
    public static func normalizedWatchURL(_ url: URL) -> URL? {
        guard let id = videoID(from: url) else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(id)")
    }

    public static func videoID(from url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        if host == "youtu.be" || host == "www.youtu.be" {
            let id = url.path.split(separator: "/").first.map(String.init) ?? ""
            return isValidVideoID(id) ? id : nil
        }
        let path = url.path.lowercased()
        if path.hasPrefix("/embed/") || path.hasPrefix("/shorts/") || path.hasPrefix("/live/") {
            let id = url.path.split(separator: "/").dropFirst().first.map(String.init) ?? ""
            return isValidVideoID(id) ? id : nil
        }
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let v = items.first(where: { $0.name == "v" })?.value,
            isValidVideoID(v)
        {
            return v
        }
        return nil
    }

    private static func isValidVideoID(_ id: String) -> Bool {
        // Standard YouTube ids are 11 chars; allow a slightly wider band for edge feeds.
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (8...20).contains(trimmed.count) else { return false }
        return trimmed.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
    }

    /// Loose URL scrape for HTML show notes (href=… and bare https://…).
    private static func urlMatches(in text: String) -> [String] {
        let pattern = #"https?://[^\s"'<>]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard let r = Range(match.range, in: text) else { return nil }
            var s = String(text[r])
            while let last = s.last, ".,);]>\"".contains(last) {
                s.removeLast()
            }
            return s
        }
    }
}
