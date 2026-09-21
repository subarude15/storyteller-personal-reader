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
                case .complete:
                    recent.append(job)
                case .submitted, .queued, .downloading, .downloaded, .uploading, .unknown:
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
            hash = hash.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            if hash.count == 40, hash.allSatisfy(\.isHexDigit) {
                return hash.lowercased()
            }
            if hash.count == 32 {
                return hash.uppercased()
            }
        }
        return nil
    }

    public static func retryDetectedType(sourceURL: String, mediaType: NASMediaKind)
        -> ManualAcquisitionDetectedType
    {
        let trimmed = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("magnet:") { return .magnet }
        let path = (trimmed as NSString).pathExtension.lowercased()
        if path == "torrent" { return .torrent }
        return mediaType == .audiobook ? .m4b : .epub
    }
}

public enum DownloadsNavigation {
    public static let settingsDestination = "NAS Downloads"
    public static let downloadsDestination = "Downloads"
    public static let settingsContainsOperationalList = false
    public static let settingsKeepsNASConfiguration = true
}
