import Foundation

/// Compact library-facing snapshot of request activity.
/// Counts are derived from existing section grouping — no fake statuses.
public struct RequestActivityLibrarySummary: Equatable, Sendable {
    public var needsAttentionCount: Int
    public var inProgressCount: Int
    public var recentlyAvailableCount: Int
    /// True when the store has no tracked items at all.
    public var hasTrackedRequests: Bool

    public init(
        needsAttentionCount: Int = 0,
        inProgressCount: Int = 0,
        recentlyAvailableCount: Int = 0,
        hasTrackedRequests: Bool = false,
    ) {
        self.needsAttentionCount = needsAttentionCount
        self.inProgressCount = inProgressCount
        self.recentlyAvailableCount = recentlyAvailableCount
        self.hasTrackedRequests = hasTrackedRequests
    }

    /// When `nil`, the library entry point should hide itself.
    public var subtitle: String? {
        guard hasTrackedRequests else { return nil }

        var parts: [String] = []
        if inProgressCount > 0 {
            parts.append(
                "\(inProgressCount) in progress"
            )
        }
        if needsAttentionCount > 0 {
            parts.append(
                "\(needsAttentionCount) needs attention"
            )
        }
        if parts.isEmpty, recentlyAvailableCount > 0 {
            return recentlyAvailableCount == 1
                ? "1 recently available"
                : "\(recentlyAvailableCount) recently available"
        }
        if parts.isEmpty {
            return "All caught up"
        }
        return parts.joined(separator: " · ")
    }

    public var accessibilityLabel: String {
        guard let subtitle else { return "Requests" }
        return "Requests. \(subtitle)."
    }

    public var showsAttentionStyling: Bool {
        needsAttentionCount > 0
    }

    public var systemImage: String {
        if needsAttentionCount > 0 {
            return "exclamationmark.triangle"
        }
        if inProgressCount > 0 {
            return "arrow.down.circle"
        }
        if recentlyAvailableCount > 0 {
            return "books.vertical"
        }
        return "tray.full"
    }
}

extension RequestActivityGrouping {
    /// Completed / available items newer than this are mentioned in the library summary.
    public static let recentCompletionWindow: TimeInterval = 48 * 3600

    public static func librarySummary(
        _ items: [RequestActivityItem],
        now: Date = Date(),
        recentWindow: TimeInterval = recentCompletionWindow,
    ) -> RequestActivityLibrarySummary {
        guard !items.isEmpty else {
            return RequestActivityLibrarySummary(hasTrackedRequests: false)
        }

        var needsAttention = 0
        var inProgress = 0
        var recentlyAvailable = 0

        for item in items {
            switch section(for: item, now: now) {
                case .needsAttention:
                    needsAttention += 1
                case .inProgress:
                    inProgress += 1
                case .completed:
                    if now.timeIntervalSince(item.updatedAt) <= recentWindow {
                        recentlyAvailable += 1
                    }
                case .recent:
                    // Uncategorized recent rows are not active requests.
                    break
            }
        }

        return RequestActivityLibrarySummary(
            needsAttentionCount: needsAttention,
            inProgressCount: inProgress,
            recentlyAvailableCount: recentlyAvailable,
            hasTrackedRequests: true,
        )
    }
}

extension RequestActivityItem {
    /// One-line human status for book detail (format · status).
    public var libraryDetailStatusLine: String {
        if let attention = formatStatuses.first(where: { $0.status.needsAttentionBucket }) {
            return "\(attention.format.label) · Needs attention"
        }
        if let active = formatStatuses.first(where: \.status.isInProgress) {
            return "\(active.format.label) · \(humanStatusLabel(active.status))"
        }
        if let completed = formatStatuses.first(where: \.status.isCompleted) {
            return "\(completed.format.label) · \(availableLabel)"
        }
        return "\(formatsLabel) · \(overallStatus.label)"
    }

    private var availableLabel: String {
        switch provider {
            case .lazyLibrarian: "Available from LazyLibrarian"
            case .shelfarr: "Available from Shelfarr"
            case .automatic: "Available"
        }
    }

    private func humanStatusLabel(_ status: RequestActivityStatus) -> String {
        switch status {
            case .wanted, .searching: "Searching"
            case .requested, .alreadyRequested: "In progress"
            case .snatched: "Snatched"
            case .downloaded: "Downloaded"
            case .available, .alreadyAvailable: "Available"
            case .failed, .needsAttention: "Needs attention"
            case .unknown: "In progress"
        }
    }
}
