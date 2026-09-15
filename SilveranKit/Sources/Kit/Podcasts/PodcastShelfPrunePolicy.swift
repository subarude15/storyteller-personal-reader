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
        byteSize: Int64? = nil
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
