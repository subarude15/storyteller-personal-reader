import Foundation

/// Settings for podcast Shelf auto-prune (RSS downloads only — never Storyteller media).
public struct PodcastDownloadSettings: Codable, Equatable, Sendable {
    public var autoCleanEnabled: Bool
    public var removeWhenFinished: Bool
    /// `nil` = Off.
    public var maxAgeDays: Int?
    /// `nil` = Off.
    public var maxDownloads: Int?
    /// Progress floor (0...1). At/above this and below finished threshold = in-progress (cap skip).
    public var protectProgress: Double
    public var hasSeenAutoCleanExplainer: Bool
    public var lastPruneAt: Date?
    public var lastPruneCount: Int

    public static let finishedProgressThreshold: Double = 0.95

    public static let `default` = PodcastDownloadSettings(
        autoCleanEnabled: true,
        removeWhenFinished: true,
        maxAgeDays: 30,
        maxDownloads: 50,
        protectProgress: 0.10,
        hasSeenAutoCleanExplainer: false,
        lastPruneAt: nil,
        lastPruneCount: 0
    )

    public init(
        autoCleanEnabled: Bool = true,
        removeWhenFinished: Bool = true,
        maxAgeDays: Int? = 30,
        maxDownloads: Int? = 50,
        protectProgress: Double = 0.10,
        hasSeenAutoCleanExplainer: Bool = false,
        lastPruneAt: Date? = nil,
        lastPruneCount: Int = 0
    ) {
        self.autoCleanEnabled = autoCleanEnabled
        self.removeWhenFinished = removeWhenFinished
        self.maxAgeDays = maxAgeDays
        self.maxDownloads = maxDownloads
        self.protectProgress = protectProgress
        self.hasSeenAutoCleanExplainer = hasSeenAutoCleanExplainer
        self.lastPruneAt = lastPruneAt
        self.lastPruneCount = lastPruneCount
    }

    public static let maxAgeOptions: [Int?] = [nil, 7, 14, 30, 90]
    public static let maxDownloadsOptions: [Int?] = [nil, 25, 50, 100]
    public static let protectProgressOptions: [Double] = [0, 0.10, 0.25, 0.50]
}

/// One downloaded RSS episode on disk (podcast Shelf only).
public struct PodcastDownloadRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: String { episodeID }
    public let episodeID: String
    public var title: String
    public var showTitle: String?
    public var feedURL: URL?
    public var remoteAudioURL: URL?
    public var localFileName: String
    public var downloadedAt: Date
    public var lastPlayedAt: Date?
    public var durationSeconds: TimeInterval?
    public var positionSeconds: TimeInterval
    public var isFinished: Bool
    public var isPinned: Bool
    public var byteSize: Int64?
    /// Ad-strip UX chip: Original / Cleaning… / Clean / Clean failed.
    public var adStripState: PodcastAdStripState
    /// Sibling Clean file under the same episode folder (e.g. `audio.clean.mp3`).
    public var cleanLocalFileName: String?
    /// True when the user (or Keep/queue) asked for the Clean path — drives Clean pending filter.
    public var wantsClean: Bool

    public init(
        episodeID: String,
        title: String,
        showTitle: String? = nil,
        feedURL: URL? = nil,
        remoteAudioURL: URL? = nil,
        localFileName: String,
        downloadedAt: Date = Date(),
        lastPlayedAt: Date? = nil,
        durationSeconds: TimeInterval? = nil,
        positionSeconds: TimeInterval = 0,
        isFinished: Bool = false,
        isPinned: Bool = false,
        byteSize: Int64? = nil,
        adStripState: PodcastAdStripState = .original,
        cleanLocalFileName: String? = nil,
        wantsClean: Bool = false
    ) {
        self.episodeID = episodeID
        self.title = title
        self.showTitle = showTitle
        self.feedURL = feedURL
        self.remoteAudioURL = remoteAudioURL
        self.localFileName = localFileName
        self.downloadedAt = downloadedAt
        self.lastPlayedAt = lastPlayedAt
        self.durationSeconds = durationSeconds
        self.positionSeconds = positionSeconds
        self.isFinished = isFinished
        self.isPinned = isPinned
        self.byteSize = byteSize
        self.adStripState = adStripState
        self.cleanLocalFileName = cleanLocalFileName
        self.wantsClean = wantsClean
    }

    public var progress: Double {
        guard let durationSeconds, durationSeconds > 0 else {
            return isFinished ? 1 : 0
        }
        return min(max(positionSeconds / durationSeconds, 0), 1)
    }

    public func activityDate(relativeTo now: Date = Date()) -> Date {
        max(downloadedAt, lastPlayedAt ?? downloadedAt)
    }

    enum CodingKeys: String, CodingKey {
        case episodeID, title, showTitle, feedURL, remoteAudioURL, localFileName
        case downloadedAt, lastPlayedAt, durationSeconds, positionSeconds
        case isFinished, isPinned, byteSize, adStripState, cleanLocalFileName, wantsClean
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episodeID = try c.decode(String.self, forKey: .episodeID)
        title = try c.decode(String.self, forKey: .title)
        showTitle = try c.decodeIfPresent(String.self, forKey: .showTitle)
        feedURL = try c.decodeIfPresent(URL.self, forKey: .feedURL)
        remoteAudioURL = try c.decodeIfPresent(URL.self, forKey: .remoteAudioURL)
        localFileName = try c.decode(String.self, forKey: .localFileName)
        downloadedAt = try c.decode(Date.self, forKey: .downloadedAt)
        lastPlayedAt = try c.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        durationSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .durationSeconds)
        positionSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .positionSeconds) ?? 0
        isFinished = try c.decodeIfPresent(Bool.self, forKey: .isFinished) ?? false
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        byteSize = try c.decodeIfPresent(Int64.self, forKey: .byteSize)
        adStripState = try c.decodeIfPresent(PodcastAdStripState.self, forKey: .adStripState) ?? .original
        cleanLocalFileName = try c.decodeIfPresent(String.self, forKey: .cleanLocalFileName)
        wantsClean = try c.decodeIfPresent(Bool.self, forKey: .wantsClean) ?? false
    }
}

/// Playback / download chip for ad-strip UX.
public enum PodcastAdStripState: String, Codable, Sendable, Equatable {
    case original
    case cleaning
    case clean
    case failed

    public var chipLabel: String {
        switch self {
            case .original: return "Original"
            // Job chip only — never duration-looking copy (Xm left stays on progress).
            case .cleaning: return "Cleaning…"
            case .clean: return "Clean"
            case .failed: return "Clean failed"
        }
    }

    /// Show the Clean-path chip whenever we have an on-disk Original or an active strip.
    public var showsChip: Bool {
        switch self {
            case .original, .cleaning, .clean, .failed: return true
        }
    }
}

/// How the user asked to download an episode.
public enum PodcastDownloadIntent: String, Codable, Sendable, Equatable {
    /// Manual “Download now” — Original file only (no strip).
    case original
    /// “Strip ads, then download” or queue/Keep add — Clean pending after Original lands.
    case clean
}

/// Compact finishability copy for Home / Library / episode rows (“12m left”, “Played”).
public enum PlaybackFinishabilityCopy {
    /// ≥95% → “Played”; else duration-based “Xm left” or percent when duration unknown.
    public static func label(progress: Double, durationSeconds: TimeInterval?) -> String? {
        guard progress > 0.001 else { return nil }
        if progress >= 0.95 { return "Played" }
        if let left = remainingSeconds(progress: progress, durationSeconds: durationSeconds) {
            return "\(compactDuration(left)) left"
        }
        let pct = Int((min(max(progress, 0), 1) * 100).rounded())
        return "\(pct)%"
    }

    /// Remaining play/read time when duration is known; nil when unknown or already “Played”.
    public static func remainingSeconds(
        progress: Double,
        durationSeconds: TimeInterval?
    ) -> TimeInterval? {
        guard progress > 0.001, progress < 0.95 else { return nil }
        guard let durationSeconds, durationSeconds > 0 else { return nil }
        return max(0, durationSeconds * (1 - min(max(progress, 0), 1)))
    }

    public static func compactDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }
}

public enum PodcastPruneReason: String, Sendable, Equatable {
    case finished = "Finished"
    case agedOut = "Aged out"
    case overLimit = "Over limit"
}

public struct PodcastPruneCandidate: Sendable, Equatable, Identifiable {
    public var id: String { record.episodeID }
    public let record: PodcastDownloadRecord
    public let reason: PodcastPruneReason

    public init(record: PodcastDownloadRecord, reason: PodcastPruneReason) {
        self.record = record
        self.reason = reason
    }
}

/// Pure Shelf auto-prune for podcast downloads (policy: PODCASTS-SHELF-PRUNE.md).
public enum PodcastShelfPrunePolicy {
    /// Preview / apply: finished → age → over-cap, never touching pinned.
    public static func candidates(
        from records: [PodcastDownloadRecord],
        settings: PodcastDownloadSettings,
        now: Date = Date()
    ) -> [PodcastPruneCandidate] {
        guard settings.autoCleanEnabled else { return [] }

        var remaining = records
        var result: [PodcastPruneCandidate] = []

        // 1. Finished
        if settings.removeWhenFinished {
            let finished = remaining.filter { !$0.isPinned && isFinished($0, settings: settings) }
            for record in finished {
                result.append(PodcastPruneCandidate(record: record, reason: .finished))
            }
            let finishedIDs = Set(finished.map(\.episodeID))
            remaining.removeAll { finishedIDs.contains($0.episodeID) }
        }

        // 2. Max age (pinned already excluded; max-age lifts progress protection)
        if let maxAgeDays = settings.maxAgeDays, maxAgeDays > 0 {
            let maxAge = TimeInterval(maxAgeDays) * 24 * 3600
            let aged = remaining.filter { record in
                guard !record.isPinned else { return false }
                return now.timeIntervalSince(record.activityDate(relativeTo: now)) > maxAge
            }
            for record in aged {
                result.append(PodcastPruneCandidate(record: record, reason: .agedOut))
            }
            let agedIDs = Set(aged.map(\.episodeID))
            remaining.removeAll { agedIDs.contains($0.episodeID) }
        }

        // 3. Max downloads — oldest by last-play then download date;
        //    skip pinned + in-progress (≥ protect && < finished).
        if let maxDownloads = settings.maxDownloads, maxDownloads > 0, remaining.count > maxDownloads {
            let eligible = remaining.filter { !isProtectedFromCap($0, settings: settings) }
            let sorted = eligible.sorted { lhs, rhs in
                let lPlay = lhs.lastPlayedAt ?? .distantPast
                let rPlay = rhs.lastPlayedAt ?? .distantPast
                if lPlay != rPlay { return lPlay < rPlay }
                return lhs.downloadedAt < rhs.downloadedAt
            }
            let overflow = remaining.count - maxDownloads
            for record in sorted.prefix(overflow) {
                result.append(PodcastPruneCandidate(record: record, reason: .overLimit))
            }
        }

        return result
    }

    public static func isFinished(
        _ record: PodcastDownloadRecord,
        settings: PodcastDownloadSettings = .default
    ) -> Bool {
        if record.isFinished { return true }
        return record.progress >= PodcastDownloadSettings.finishedProgressThreshold
    }

    /// In-progress for over-cap: progress ≥ protect floor and not finished.
    public static func isProtectedFromCap(
        _ record: PodcastDownloadRecord,
        settings: PodcastDownloadSettings
    ) -> Bool {
        if record.isPinned { return true }
        let progress = record.progress
        return progress >= settings.protectProgress
            && progress < PodcastDownloadSettings.finishedProgressThreshold
    }
}
