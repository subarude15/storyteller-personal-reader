import Foundation

/// Lightweight persisted timeline entry for one Request Activity row.
public struct RequestActivityEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var date: Date
    public var kind: RequestActivityEventKind
    public var format: BookRequestFormat?
    public var provider: BookRequestProviderKind?
    public var title: String?
    public var detail: String?
    public var relatedRequestID: String?
    /// Presentation source when not a request provider (e.g. "Deluge"). Absent on legacy events.
    public var sourceLabel: String?

    public init(
        id: String = UUID().uuidString,
        date: Date = Date(),
        kind: RequestActivityEventKind,
        format: BookRequestFormat? = nil,
        provider: BookRequestProviderKind? = nil,
        title: String? = nil,
        detail: String? = nil,
        relatedRequestID: String? = nil,
        sourceLabel: String? = nil,
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.format = format
        self.provider = provider
        self.title = title
        self.detail = detail
        self.relatedRequestID = relatedRequestID
        self.sourceLabel = sourceLabel
    }
}

public enum RequestActivityEventKind: String, Codable, Equatable, Sendable {
    case requested
    case searching
    case wanted
    case snatched
    case providerAvailable
    case availableInLibrary
    case needsAttention
    case failed
    case retryStarted
    case manualFallback
    case automaticFallback
    case alreadyRequested
    case alreadyAvailable
    case downloadQueued
    case downloadStarted
    case downloadCompleted
    case downloadError
    case waitingForImport
}

/// Records and presents Request Activity history. Pure helpers — no network.
public enum RequestActivityTimeline {
    /// Append status-transition events when format state meaningfully changes.
    /// Repeated refreshes with the same status do not duplicate.
    public static func recordingTransitions(
        previous: RequestActivityItem?,
        incoming: RequestActivityItem,
        now: Date = Date(),
    ) -> RequestActivityItem {
        var updated = incoming
        var events = updated.events ?? []
        let formats = Set(incoming.requestedFormats).union(
            incoming.formatStatuses.map(\.format)
        )
        for format in BookRequestFormat.allCases where formats.contains(format) {
            let oldStatus = previous?.status(for: format)?.status
            guard let newStatus = incoming.status(for: format)?.status else { continue }
            guard oldStatus != newStatus else { continue }
            guard let kind = kind(for: newStatus) else { continue }
            let detail = incoming.status(for: format)?.detail
            let event = RequestActivityEvent(
                date: incoming.status(for: format)?.updatedAt ?? now,
                kind: kind,
                format: format,
                provider: kind == .availableInLibrary ? nil : incoming.provider,
                title: title(for: kind, status: newStatus),
                detail: detailForStatusEvent(kind: kind, detail: detail),
            )
            events = appending(event, to: events)
        }
        updated.events = events.isEmpty ? updated.events : events
        return updated
    }

    public static func appendRetryStarted(
        to item: RequestActivityItem,
        formats: [BookRequestFormat],
        now: Date = Date(),
    ) -> RequestActivityItem {
        var updated = item
        var events = updated.events ?? []
        for format in BookRequestFormat.allCases where formats.contains(format) {
            let event = RequestActivityEvent(
                date: now,
                kind: .retryStarted,
                format: format,
                provider: item.provider == .automatic ? nil : item.provider,
                title: title(for: .retryStarted),
            )
            events = appending(event, to: events)
        }
        updated.events = events
        updated.updatedAt = now
        return updated
    }

    public static func appendFallbackEvent(
        to item: RequestActivityItem,
        fallbackKind: RequestFallbackKind,
        targetProvider: BookRequestProviderKind,
        formats: [BookRequestFormat],
        relatedRequestID: String?,
        now: Date = Date(),
    ) -> RequestActivityItem {
        let kind: RequestActivityEventKind =
            fallbackKind == .automatic ? .automaticFallback : .manualFallback
        // One event per fallback attempt (not per format) keeps the timeline compact.
        let event = RequestActivityEvent(
            date: now,
            kind: kind,
            format: formats.count == 1 ? formats[0] : nil,
            provider: targetProvider,
            title: title(for: kind),
            detail: "Tried \(targetProvider.shortName)",
            relatedRequestID: relatedRequestID,
        )
        var updated = item
        var events = updated.events ?? []
        if events.contains(where: {
            $0.kind == kind
                && $0.relatedRequestID == relatedRequestID
                && $0.detail == event.detail
        }) {
            return item
        }
        events = appending(event, to: events)
        updated.events = events
        updated.updatedAt = now
        return updated
    }

    /// Display timeline: persisted events, or a conservative synthesis for legacy rows.
    public static func displayEvents(for item: RequestActivityItem) -> [RequestActivityEvent] {
        if let events = item.events, !events.isEmpty {
            return sorted(events)
        }
        return synthesizeLegacy(for: item)
    }

    public static func title(
        for kind: RequestActivityEventKind,
        status: RequestActivityStatus? = nil,
    ) -> String {
        switch kind {
            case .requested:
                return "Requested"
            case .searching:
                return "Searching"
            case .wanted:
                return "Wanted"
            case .snatched:
                return "Snatched"
            case .providerAvailable:
                return status?.label ?? "Available from LazyLibrarian"
            case .availableInLibrary:
                return "Available in Library"
            case .needsAttention:
                return "Needs Attention"
            case .failed:
                return "Failed"
            case .retryStarted:
                return "Retry started"
            case .manualFallback:
                return "Manual fallback"
            case .automaticFallback:
                return "Automatic fallback"
            case .alreadyRequested:
                return "Already requested"
            case .alreadyAvailable:
                return "Already available"
            case .downloadQueued:
                return "Download queued"
            case .downloadStarted:
                return "Download started"
            case .downloadCompleted:
                return "Download completed"
            case .downloadError:
                return "Download needs attention"
            case .waitingForImport:
                return "Waiting for Storyteller import"
        }
    }

    public static func systemImage(for kind: RequestActivityEventKind) -> String {
        switch kind {
            case .requested:
                return "tray.and.arrow.down"
            case .searching:
                return "magnifyingglass"
            case .wanted:
                return "clock"
            case .snatched:
                return "arrow.down.circle"
            case .providerAvailable, .alreadyAvailable:
                return "checkmark.circle"
            case .availableInLibrary:
                return "books.vertical"
            case .needsAttention, .failed, .downloadError:
                return "exclamationmark.triangle"
            case .retryStarted:
                return "arrow.triangle.2.circlepath"
            case .manualFallback:
                return "arrow.left.arrow.right"
            case .automaticFallback:
                return "arrow.triangle.branch"
            case .alreadyRequested:
                return "arrow.triangle.2.circlepath"
            case .downloadQueued:
                return "clock"
            case .downloadStarted:
                return "arrow.down.circle"
            case .downloadCompleted:
                return "checkmark.circle"
            case .waitingForImport:
                return "hourglass"
        }
    }

    public static func providerLabel(for event: RequestActivityEvent) -> String? {
        if let sourceLabel = event.sourceLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
            !sourceLabel.isEmpty
        {
            return sourceLabel
        }
        if event.kind == .availableInLibrary {
            return "Storyteller"
        }
        guard let provider = event.provider, provider != .automatic else { return nil }
        return provider.shortName
    }

    public static func subtitle(for event: RequestActivityEvent) -> String? {
        var parts: [String] = []
        if let format = event.format {
            parts.append(format.label)
        }
        if let provider = providerLabel(for: event) {
            parts.append(provider)
        }
        let joined = parts.joined(separator: " · ")
        return joined.isEmpty ? nil : joined
    }

    /// Presentation-only: hide Last error / Needs attention sections when they
    /// already match a format detail shown in Status. Does not mutate stored fields.
    public static func extraDiagnostics(for item: RequestActivityItem) -> (
        lastError: String?,
        attentionReason: String?
    ) {
        let statusDetails = Set(
            item.formatStatuses.compactMap { status -> String? in
                guard let detail = status.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !detail.isEmpty
                else { return nil }
                return detail
            }
        )
        let lastError = item.lastError?.trimmingCharacters(in: .whitespacesAndNewlines)
        let attention = item.attentionReason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let showError: String?
        if let lastError, !lastError.isEmpty, !statusDetails.contains(lastError) {
            showError = lastError
        } else {
            showError = nil
        }
        let showAttention: String?
        if let attention, !attention.isEmpty, !statusDetails.contains(attention) {
            // Also hide when it only repeats lastError already shown above.
            if showError == attention {
                showAttention = nil
            } else {
                showAttention = attention
            }
        } else {
            showAttention = nil
        }
        return (showError, showAttention)
    }

    public static func kind(for status: RequestActivityStatus) -> RequestActivityEventKind? {
        switch status {
            case .requested:
                return .requested
            case .searching:
                return .searching
            case .wanted:
                return .wanted
            case .snatched:
                return .snatched
            case .downloaded, .available:
                return .providerAvailable
            case .alreadyAvailable:
                return .alreadyAvailable
            case .availableInLibrary:
                return .availableInLibrary
            case .needsAttention:
                return .needsAttention
            case .failed:
                return .failed
            case .alreadyRequested:
                return .alreadyRequested
            case .unknown:
                return nil
        }
    }

    public static func sorted(_ events: [RequestActivityEvent]) -> [RequestActivityEvent] {
        // Stable: date ascending, then original index for equal timestamps.
        events.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.date != rhs.element.date {
                    return lhs.element.date < rhs.element.date
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func appending(
        _ event: RequestActivityEvent,
        to events: [RequestActivityEvent],
    ) -> [RequestActivityEvent] {
        // Guard against accidental double-append in the same recording pass.
        if let last = events.last(where: { $0.format == event.format }),
            last.kind == event.kind,
            last.provider == event.provider,
            last.relatedRequestID == event.relatedRequestID,
            normalized(last.detail) == normalized(event.detail)
        {
            return events
        }
        var next = events
        next.append(event)
        return next
    }

    private static func normalized(_ detail: String?) -> String {
        detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func detailForStatusEvent(
        kind: RequestActivityEventKind,
        detail: String?,
    ) -> String? {
        guard let detail, !detail.isEmpty else { return nil }
        // Skip details that merely repeat the title.
        let title = title(for: kind)
        if detail == title || detail == title.lowercased() { return nil }
        return detail
    }

    /// Display-only reconstruction for rows that never recorded events.
    private static func synthesizeLegacy(for item: RequestActivityItem) -> [RequestActivityEvent] {
        var events: [RequestActivityEvent] = []
        let formats =
            item.requestedFormats.isEmpty
            ? item.formatStatuses.map(\.format)
            : item.requestedFormats
        for format in BookRequestFormat.allCases where formats.contains(format) {
            events.append(
                RequestActivityEvent(
                    date: item.createdAt,
                    kind: .requested,
                    format: format,
                    provider: item.provider == .automatic ? nil : item.provider,
                    title: title(for: .requested),
                )
            )
            if let status = item.status(for: format),
                let kind = kind(for: status.status),
                kind != .requested
            {
                events.append(
                    RequestActivityEvent(
                        date: status.updatedAt,
                        kind: kind,
                        format: format,
                        provider: kind == .availableInLibrary
                            ? nil : (item.provider == .automatic ? nil : item.provider),
                        title: title(for: kind, status: status.status),
                        detail: detailForStatusEvent(kind: kind, detail: status.detail),
                    )
                )
            }
        }
        if let attempts = item.automaticFallbackAttempts {
            for attempt in attempts {
                events.append(
                    RequestActivityEvent(
                        date: attempt.attemptedAt,
                        kind: .automaticFallback,
                        format: attempt.format,
                        provider: attempt.targetProvider,
                        title: title(for: .automaticFallback),
                        detail: "Tried \(attempt.targetProvider.shortName)",
                        relatedRequestID: attempt.resultingRequestID,
                    )
                )
            }
        }
        return sorted(events)
    }
}
