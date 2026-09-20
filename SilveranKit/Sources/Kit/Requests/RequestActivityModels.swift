import Foundation

/// Normalized request lifecycle for Request Activity (provider-neutral).
public enum RequestActivityStatus: String, Codable, Equatable, Sendable, CaseIterable {
    case requested
    case searching
    case wanted
    case snatched
    case downloaded
    /// Provider reports the file (e.g. LazyLibrarian Have). Not yet in Storyteller.
    case available
    case alreadyAvailable
    /// Storyteller library contains this format — true completion for the reader.
    case availableInLibrary
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
            case .available: "Available from LazyLibrarian"
            case .alreadyAvailable: "Already available"
            case .availableInLibrary: "Available in Library"
            case .alreadyRequested: "Already requested"
            case .failed: "Failed"
            case .needsAttention: "Needs attention"
            case .unknown: "Unknown"
        }
    }

    /// Still waiting from the user's perspective (including provider-side Have).
    /// Only `availableInLibrary` counts as fully done — the goal is to read/listen here.
    public var isInProgress: Bool {
        switch self {
            case .requested, .searching, .wanted, .snatched, .downloaded, .alreadyRequested,
                .available, .alreadyAvailable, .unknown:
                true
            case .availableInLibrary, .failed, .needsAttention:
                false
        }
    }

    /// Truly completed: present in the Storyteller / local library.
    /// Provider-side `.available` / `.alreadyAvailable` / `.downloaded` stay in progress.
    public var isCompleted: Bool {
        self == .availableInLibrary
    }

    public var needsAttentionBucket: Bool {
        self == .needsAttention || self == .failed
    }

    /// LazyLibrarian (or similar) reports the file on the provider.
    public var isProviderAvailable: Bool {
        switch self {
            case .available, .alreadyAvailable, .downloaded: true
            default: false
        }
    }
}

/// Persisted notification dedupe for one Request Activity row.
/// Optional on `RequestActivityItem` so legacy JSON keeps decoding.
public struct RequestActivityNotificationState: Codable, Equatable, Sendable {
    /// Formats already notified as Available in Library.
    public var lastNotifiedAvailableFormats: [BookRequestFormat]
    /// Formats already notified for Needs Attention.
    /// A format is removed when it leaves attention so a later re-entry may notify again,
    /// even if sibling formats remain in attention.
    public var lastNotifiedAttentionFormats: [BookRequestFormat]

    public init(
        lastNotifiedAvailableFormats: [BookRequestFormat] = [],
        lastNotifiedAttentionFormats: [BookRequestFormat] = [],
    ) {
        self.lastNotifiedAvailableFormats = lastNotifiedAvailableFormats
        self.lastNotifiedAttentionFormats = lastNotifiedAttentionFormats
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastNotifiedAvailableFormats =
            try container.decodeIfPresent([BookRequestFormat].self, forKey: .lastNotifiedAvailableFormats)
            ?? []
        var attentionFormats =
            try container.decodeIfPresent([BookRequestFormat].self, forKey: .lastNotifiedAttentionFormats)
            ?? []
        // Legacy fingerprint (`"ebook"`, `"audiobook"`, `"audiobook,ebook"`) → per-format set.
        if attentionFormats.isEmpty,
            let fingerprint = try container.decodeIfPresent(
                String.self,
                forKey: .lastNotifiedAttentionFingerprint
            ),
            !fingerprint.isEmpty
        {
            let parts = Set(fingerprint.split(separator: ",").map(String.init))
            attentionFormats = BookRequestFormat.allCases.filter { parts.contains($0.rawValue) }
        }
        lastNotifiedAttentionFormats = BookRequestFormat.allCases.filter {
            attentionFormats.contains($0)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lastNotifiedAvailableFormats, forKey: .lastNotifiedAvailableFormats)
        try container.encode(lastNotifiedAttentionFormats, forKey: .lastNotifiedAttentionFormats)
        // Intentionally omit legacy fingerprint — new writes use per-format state only.
    }

    private enum CodingKeys: String, CodingKey {
        case lastNotifiedAvailableFormats
        case lastNotifiedAttentionFormats
        case lastNotifiedAttentionFingerprint
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
    /// Optional matching hints — absent on older stored rows.
    public var openLibraryWorkID: String?
    public var openLibraryEditionID: String?
    public var isbn: String?
    /// Local notification dedupe metadata — absent on legacy rows (safe default).
    public var notificationState: RequestActivityNotificationState?
    /// Request Activity row this attempt was started from. Absent on older rows.
    public var fallbackFromRequestID: String?

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
        openLibraryWorkID: String? = nil,
        openLibraryEditionID: String? = nil,
        isbn: String? = nil,
        notificationState: RequestActivityNotificationState? = nil,
        fallbackFromRequestID: String? = nil,
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
        self.openLibraryWorkID = openLibraryWorkID
        self.openLibraryEditionID = openLibraryEditionID
        self.isbn = isbn
        self.notificationState = notificationState
        self.fallbackFromRequestID = fallbackFromRequestID
    }

    public var overallStatus: RequestActivityStatus {
        if let attention = formatStatuses.first(where: { $0.status.needsAttentionBucket }) {
            return attention.status
        }
        if formatStatuses.contains(where: \.status.isInProgress) {
            return formatStatuses.first(where: \.status.isInProgress)?.status ?? .requested
        }
        if !formatStatuses.isEmpty, formatStatuses.allSatisfy(\.status.isCompleted) {
            return .availableInLibrary
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

    /// True when every requested format is present in Storyteller.
    public var allRequestedFormatsInLibrary: Bool {
        guard !requestedFormats.isEmpty else { return false }
        return requestedFormats.allSatisfy { format in
            status(for: format)?.status == .availableInLibrary
        }
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
            case .completed: "Available in Library"
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
