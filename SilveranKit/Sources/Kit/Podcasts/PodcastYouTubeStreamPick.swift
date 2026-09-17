//
//  PodcastYouTubeStreamPick.swift
//  SilveranKit
//
//  Pure picker: Invidious / Piped / thin NAS JSON → one AVPlayer-friendly URL.
//  No network. Used by PodcastYouTubeResolver (AppleKit).
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Result of picking a progressive / HLS media URL from a resolve response.
public struct PodcastYouTubeStreamPick: Sendable, Equatable {
    public let url: URL
    /// Hint only (mp4 / hls / unknown).
    public let kind: Kind

    public enum Kind: String, Sendable, Equatable {
        case progressive
        case hls
        case unknown
    }

    public init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
    }
}

/// Picks a playable stream URL from Invidious (`/api/v1/videos/:id`), Piped
/// (`/streams/:id`), or a thin NAS shim `{ "url": "…" }`.
public enum PodcastYouTubeStreamPicker: Sendable {
    /// Parse JSON bytes and return the best AVPlayer-friendly URL.
    /// Relative paths are resolved against `baseURL` when provided.
    public static func pick(from data: Data, baseURL: URL? = nil) -> PodcastYouTubeStreamPick? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return pick(from: obj, baseURL: baseURL)
    }

    public static func pick(from json: Any, baseURL: URL? = nil) -> PodcastYouTubeStreamPick? {
        guard let root = json as? [String: Any] else { return nil }

        // Thin NAS / custom: { "url": "https://…/file.mp4" } (or mediaUrl).
        if let direct = stringURL(root["url"] ?? root["mediaUrl"] ?? root["media_url"]),
            let url = absoluteURL(direct, base: baseURL)
        {
            return PodcastYouTubeStreamPick(url: url, kind: kindForURL(url, typeHint: root["mime"] as? String))
        }

        // Invidious formatStreams — progressive muxed A+V (preferred for AVPlayer).
        if let streams = root["formatStreams"] as? [[String: Any]],
            let best = bestProgressive(streams, base: baseURL)
        {
            return best
        }

        // Invidious hlsUrl (live / DASH fallback).
        if let hls = stringURL(root["hlsUrl"] ?? root["hls_url"]),
            let url = absoluteURL(hls, base: baseURL)
        {
            return PodcastYouTubeStreamPick(url: url, kind: .hls)
        }

        // Piped: videoStreams with muxed audio (videoOnly == false).
        if let streams = root["videoStreams"] as? [[String: Any]],
            let best = bestPipedMuxed(streams, base: baseURL)
        {
            return best
        }
        if let hls = stringURL(root["hls"]),
            let url = absoluteURL(hls, base: baseURL)
        {
            return PodcastYouTubeStreamPick(url: url, kind: .hls)
        }

        return nil
    }

    // MARK: - Progressive / Piped

    private static func bestProgressive(
        _ streams: [[String: Any]],
        base: URL?
    ) -> PodcastYouTubeStreamPick? {
        var candidates: [(score: Int, pick: PodcastYouTubeStreamPick)] = []
        for s in streams {
            guard let raw = stringURL(s["url"]), let url = absoluteURL(raw, base: base) else {
                continue
            }
            let container = (s["container"] as? String)?.lowercased() ?? ""
            let type = (s["type"] as? String)?.lowercased() ?? ""
            let qualityLabel = (s["qualityLabel"] as? String) ?? (s["quality"] as? String) ?? ""
            let height = parseHeight(qualityLabel) ?? parseHeight(s["resolution"] as? String)
            var score = height ?? 0
            // Prefer mp4 over webm/other for broad AVPlayer support.
            if container.contains("mp4") || type.contains("mp4") {
                score += 10_000
            }
            candidates.append((score, PodcastYouTubeStreamPick(url: url, kind: .progressive)))
        }
        return candidates.max(by: { $0.score < $1.score })?.pick
    }

    private static func bestPipedMuxed(
        _ streams: [[String: Any]],
        base: URL?
    ) -> PodcastYouTubeStreamPick? {
        var candidates: [(score: Int, pick: PodcastYouTubeStreamPick)] = []
        for s in streams {
            // videoOnly true ⇒ adaptive (no audio) — skip for v1.
            if let videoOnly = s["videoOnly"] as? Bool, videoOnly { continue }
            if let videoOnly = s["videoOnly"] as? String, videoOnly.lowercased() == "true" {
                continue
            }
            guard let raw = stringURL(s["url"]), let url = absoluteURL(raw, base: base) else {
                continue
            }
            let mime = (s["mimeType"] as? String ?? s["format"] as? String ?? "").lowercased()
            let height = (s["height"] as? Int) ?? parseHeight(s["quality"] as? String) ?? 0
            var score = height
            if mime.contains("mp4") {
                score += 10_000
            }
            candidates.append((score, PodcastYouTubeStreamPick(url: url, kind: .progressive)))
        }
        return candidates.max(by: { $0.score < $1.score })?.pick
    }

    // MARK: - Helpers

    private static func stringURL(_ any: Any?) -> String? {
        guard let s = any as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func absoluteURL(_ raw: String, base: URL?) -> URL? {
        if let absolute = URL(string: raw), absolute.scheme != nil {
            return absolute
        }
        guard let base else { return nil }
        return URL(string: raw, relativeTo: base)?.absoluteURL
    }

    private static func parseHeight(_ label: String?) -> Int? {
        guard let label else { return nil }
        // "720p", "1080p60", "1280x720"
        if let xRange = label.range(of: #"(\d{3,4})p"#, options: .regularExpression) {
            let digits = label[xRange].filter(\.isNumber)
            return Int(digits)
        }
        if let xRange = label.range(of: #"\d{3,4}x(\d{3,4})"#, options: .regularExpression) {
            let parts = label[xRange].split(separator: "x")
            if parts.count == 2, let h = Int(parts[1]) { return h }
        }
        return Int(label.filter(\.isNumber))
    }

    private static func kindForURL(_ url: URL, typeHint: String?) -> PodcastYouTubeStreamPick.Kind {
        let path = url.path.lowercased()
        let hint = (typeHint ?? "").lowercased()
        if path.contains(".m3u8") || hint.contains("mpegurl") || hint.contains("hls") {
            return .hls
        }
        if path.contains(".mp4") || hint.contains("mp4") {
            return .progressive
        }
        return .unknown
    }
}
