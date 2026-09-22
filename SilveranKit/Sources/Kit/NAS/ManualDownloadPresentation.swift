//
//  ManualDownloadPresentation.swift
//  SilveranKit
//
//  Buckets, retry detection, and magnet-hash extraction for Downloads.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct ManualDownloadBuckets: Equatable, Sendable {
    public var active: [ManualDownloadJob]
    public var failed: [ManualDownloadJob]
    public var recent: [ManualDownloadJob]

    public init(
        active: [ManualDownloadJob] = [],
        failed: [ManualDownloadJob] = [],
        recent: [ManualDownloadJob] = [],
    ) {
        self.active = active
        self.failed = failed
        self.recent = recent
    }

    public var attentionCount: Int {
        active.count + failed.count
    }

    public static func partition(_ jobs: [ManualDownloadJob]) -> ManualDownloadBuckets {
        var active: [ManualDownloadJob] = []
        var failed: [ManualDownloadJob] = []
        var recent: [ManualDownloadJob] = []
        for job in jobs {
            switch job.status {
                case .failed:
                    failed.append(job)
                case .complete, .ready:
                    recent.append(job)
                case .submitted, .queued, .downloading, .processing, .delugeFinishing, .readyToRoute,
                    .routing, .downloaded, .uploading, .transferring, .unknown:
                    active.append(job)
            }
        }
        return ManualDownloadBuckets(active: active, failed: failed, recent: recent)
    }
}

public enum TorrentHash {
    /// Only the explicit `xt=urn:btih:` payload. Never guessed from a title.
    public static func fromMagnet(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.lowercased().hasPrefix("magnet:") else { return nil }
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            guard key == "xt" || key.hasSuffix("xt") else { continue }
            let value = parts[1].removingPercentEncoding ?? parts[1]
            let lower = value.lowercased()
            guard let range = lower.range(of: "urn:btih:") else { continue }
            var hash = String(value[range.upperBound...])
            if let amp = hash.firstIndex(of: "&") {
                hash = String(hash[..<amp])
            }
            return canonicalInfoHash(hash)
        }
        return nil
    }

    /// 40-char hex or 32-char RFC 4648 base32 → lowercase 40-char hex. Invalid → nil.
    public static func canonicalInfoHash(_ raw: String) -> String? {
        let hash = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if hash.count == 40, hash.allSatisfy(\.isHexDigit) {
            return hash.lowercased()
        }
        if hash.count == 32 {
            return decodeBase32InfoHash(hash)
        }
        return nil
    }

    /// Canonical hex when `raw` is a btih; otherwise keep a non-empty backend id as-is.
    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return canonicalInfoHash(trimmed) ?? trimmed
    }

    public static func retryDetectedType(sourceURL: String, mediaType: NASMediaKind)
        -> ManualAcquisitionDetectedType
    {
        let trimmed = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("magnet:") { return .magnet }
        if let url = URL(string: trimmed), url.pathExtension.lowercased() == "torrent" {
            return .torrent
        }
        return mediaType == .audiobook ? .m4b : .epub
    }

    /// 20-byte SHA-1 info hash encoded as RFC 4648 base32 (no padding).
    private static func decodeBase32InfoHash(_ raw: String) -> String? {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
        var bits: UInt64 = 0
        var bitCount = 0
        var bytes: [UInt8] = []
        bytes.reserveCapacity(20)
        for character in raw.uppercased() {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            bits = (bits << 5) | UInt64(alphabet.distance(from: alphabet.startIndex, to: index))
            bitCount += 5
            if bitCount >= 8 {
                bitCount -= 8
                bytes.append(UInt8(truncatingIfNeeded: bits >> bitCount))
            }
        }
        guard bytes.count == 20, bitCount == 0 else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public enum DownloadsNavigation {
    public static let settingsDestination = "NAS Downloads"
    public static let downloadsDestination = "Downloads"
    public static let moreDestination = "More"
    public static let settingsContainsOperationalList = false
    public static let settingsKeepsNASConfiguration = true
    public static let primaryTabBarIncludesStats = false
    public static let statsLivesUnderMore = true
}
