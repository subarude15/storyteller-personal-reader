import Foundation

/// Normalized request lifecycle for Request Activity (provider-neutral).
public enum RequestActivityStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case requested
    case searching
    case wanted
    case snatched
    case downloaded
    case available
    case alreadyAvailable
    case alreadyRequested
    case failed
    case needsAttention
    case unknown

    public var label: String {
        switch self {
            case .requested: "Requested"
            case .searching: "Searching"
            case .wanted: "Wanted"
            case .snatched: "Snatched"
            case .downloaded: "Downloaded"
            case .available: "Available"
            case .alreadyAvailable: "Already available"
            case .alreadyRequested: "Already requested"
            case .failed: "Failed"
            case .needsAttention: "Needs attention"
            case .unknown: "Unknown"
        }
    }

    /// Still actively waiting on the provider.
    public var isInProgress: Bool {
        switch self {
            case .requested, .searching, .wanted, .snatched, .downloaded, .alreadyRequested, .unknown:
                true
            case .available, .alreadyAvailable, .failed, .needsAttention:
                false
        }
    }

    public var isCompleted: Bool {
        switch self {
            case .available, .alreadyAvailable, .downloaded: true
            default: false
        }
    }

    public var needsAttentionBucket: Bool {
        self == .needsAttention || self == .failed
    }
}

public struct RequestFormatStatus: Codable, Equatable, Sendable {
    public var format: BookRequestFormat
    public var status: RequestActivityStatus
    public var detail: String?
    public var providerRawState: String?
    public var updatedAt: Date
    public var consecutiveLookupFailures: Int

    public init(
        format: BookRequestFormat,
        status: RequestActivityStatus,
        detail: String? = nil,
        providerRawState: String? = nil,
        updatedAt: Date = Date(),
        consecutiveLookupFailures: Int = 0,
    ) {
        self.format = format
        self.status = status
        self.detail = detail
        self.providerRawState = providerRawState
        self.updatedAt = updatedAt
        self.consecutiveLookupFailures = consecutiveLookupFailures
    }
}

public struct RequestActivityItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var canonicalWorkID: String
    public var title: String
    public var author: String
    public var provider: BookRequestProviderKind
    public var providerBookID: String?
    public var requestedFormats: [BookRequestFormat]
    public var createdAt: Date
    public var updatedAt: Date
    public var lastCheckedAt: Date?
    public var formatStatuses: [RequestFormatStatus]
    public var lastError: String?
    public var attentionReason: String?

    public init(
        id: String = UUID().uuidString,
        canonicalWorkID: String,
        title: String,
        author: String,
        provider: BookRequestProviderKind,
        providerBookID: String? = nil,
        requestedFormats: [BookRequestFormat],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastCheckedAt: Date? = nil,
        formatStatuses: [RequestFormatStatus] = [],
        lastError: String? = nil,
        attentionReason: String? = nil,
    ) {
        self.id = id
        self.canonicalWorkID = canonicalWorkID
        self.title = title
        self.author = author
        self.provider = provider
        self.providerBookID = providerBookID
        self.requestedFormats = requestedFormats
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastCheckedAt = lastCheckedAt
        self.formatStatuses = formatStatuses
        self.lastError = lastError
        self.attentionReason = attentionReason
    }

    public var overallStatus: RequestActivityStatus {
        if let attention = formatStatuses.first(where: { $0.status.needsAttentionBucket }) {
            return attention.status
        }
        if formatStatuses.contains(where: \.status.isInProgress) {
            return formatStatuses.first(where: \.status.isInProgress)?.status ?? .requested
        }
        if formatStatuses.allSatisfy(\.status.isCompleted) {
            return .available
        }
        return formatStatuses.first?.status ?? .unknown
    }

    public func status(for format: BookRequestFormat) -> RequestFormatStatus? {
        formatStatuses.first { $0.format == format }
    }

    public var formatsLabel: String {
        let labels = requestedFormats.map(\.label)
        if labels.count == 2 { return "Both" }
        return labels.first ?? "—"
    }
}

public enum RequestActivitySection: String, Sendable, CaseIterable, Hashable {
    case needsAttention
    case inProgress
    case completed
    case recent

    public var title: String {
        switch self {
            case .needsAttention: "Needs Attention"
            case .inProgress: "In Progress"
            case .completed: "Completed / Available"
            case .recent: "Recent"
        }
    }
}

public enum RequestActivityGrouping {
    public static let staleWantedInterval: TimeInterval = 24 * 3600
    public static let completedRetentionInterval: TimeInterval = 30 * 24 * 3600
    public static let refreshStaleInterval: TimeInterval = 3 * 60
    public static let lookupFailureAttentionThreshold = 3

    public static func section(for item: RequestActivityItem, now: Date = Date()) -> RequestActivitySection {
        if item.attentionReason != nil
            || item.formatStatuses.contains(where: { $0.status.needsAttentionBucket })
        {
            return .needsAttention
        }
        if item.formatStatuses.contains(where: \.status.isInProgress) {
            return .inProgress
        }
        if item.formatStatuses.contains(where: \.status.isCompleted) {
            return .completed
        }
        _ = now
        return .recent
    }

    public static func groups(
        _ items: [RequestActivityItem],
        now: Date = Date(),
    ) -> [(RequestActivitySection, [RequestActivityItem])] {
        var buckets: [RequestActivitySection: [RequestActivityItem]] = [:]
        for item in items {
            buckets[section(for: item, now: now), default: []].append(item)
        }
        return RequestActivitySection.allCases.compactMap { section in
            guard let rows = buckets[section], !rows.isEmpty else { return nil }
            let sorted = rows.sorted { $0.updatedAt > $1.updatedAt }
            return (section, sorted)
        }
    }
}

extension BookRequestPhase {
    public var activityStatus: RequestActivityStatus {
        switch self {
            case .requested: .requested
            case .searching: .searching
            case .alreadyRequested: .alreadyRequested
            case .alreadyAvailable: .alreadyAvailable
            case .failed: .failed
        }
    }
}
