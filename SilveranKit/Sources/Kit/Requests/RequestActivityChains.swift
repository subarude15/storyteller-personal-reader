import Foundation

/// Presentation wrapper for a timeline event that still knows its source attempt.
public struct RequestActivityChainEvent: Equatable, Sendable, Identifiable {
    public var event: RequestActivityEvent
    public var sourceRequestID: String

    public var id: String {
        "\(sourceRequestID):\(event.id)"
    }

    public init(event: RequestActivityEvent, sourceRequestID: String) {
        self.event = event
        self.sourceRequestID = sourceRequestID
    }
}

/// Effective per-format state for one logical request chain.
public struct RequestActivityChainFormatState: Equatable, Sendable {
    public var format: BookRequestFormat
    public var status: RequestActivityStatus
    public var sourceRequestID: String
    public var providerLabel: String
    public var detail: String?

    public init(
        format: BookRequestFormat,
        status: RequestActivityStatus,
        sourceRequestID: String,
        providerLabel: String,
        detail: String? = nil,
    ) {
        self.format = format
        self.status = status
        self.sourceRequestID = sourceRequestID
        self.providerLabel = providerLabel
        self.detail = detail
    }
}

/// One logical book request spanning one or more provider attempt rows.
/// Presentation only — does not replace persisted `RequestActivityItem` storage.
public struct RequestActivityChain: Equatable, Sendable, Identifiable {
    public var id: String
    public var rootRequestID: String
    public var canonicalWorkID: String
    public var items: [RequestActivityItem]
    public var title: String
    public var author: String
    public var requestedFormats: [BookRequestFormat]
    public var formatStates: [RequestActivityChainFormatState]
    public var currentStatus: RequestActivityStatus
    public var effectiveProviderLabel: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastCheckedAt: Date?
    public var attemptCount: Int
    public var hasFallback: Bool
    public var latestItemID: String

    public init(
        id: String,
        rootRequestID: String,
        canonicalWorkID: String,
        items: [RequestActivityItem],
        title: String,
        author: String,
        requestedFormats: [BookRequestFormat],
        formatStates: [RequestActivityChainFormatState],
        currentStatus: RequestActivityStatus,
        effectiveProviderLabel: String?,
        createdAt: Date,
        updatedAt: Date,
        lastCheckedAt: Date?,
        attemptCount: Int,
        hasFallback: Bool,
        latestItemID: String,
    ) {
        self.id = id
        self.rootRequestID = rootRequestID
        self.canonicalWorkID = canonicalWorkID
        self.items = items
        self.title = title
        self.author = author
        self.requestedFormats = requestedFormats
        self.formatStates = formatStates
        self.currentStatus = currentStatus
        self.effectiveProviderLabel = effectiveProviderLabel
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastCheckedAt = lastCheckedAt
        self.attemptCount = attemptCount
        self.hasFallback = hasFallback
        self.latestItemID = latestItemID
    }

    public var rootItem: RequestActivityItem? {
        items.first { $0.id == rootRequestID } ?? items.first
    }

    public var latestItem: RequestActivityItem? {
        items.first { $0.id == latestItemID } ?? items.max(by: { $0.updatedAt < $1.updatedAt })
    }

    public var needsAttention: Bool {
        currentStatus.needsAttentionBucket
    }

    public var availableInLibrary: Bool {
        guard !requestedFormats.isEmpty else { return false }
        return requestedFormats.allSatisfy { format in
            formatStates.first { $0.format == format }?.status == .availableInLibrary
        }
    }

    public var formatsLabel: String {
        let labels = requestedFormats.map(\.label)
        if labels.count == 2 { return "Both" }
        return labels.first ?? "—"
    }

    /// Compact secondary line for the Request Activity list.
    public var listFormatProviderLine: String {
        let incomplete = formatStates.filter { !$0.status.isCompleted }
        let focus = incomplete.first ?? formatStates.first
        if let focus {
            if incomplete.count <= 1, requestedFormats.count <= 1 {
                return "\(focus.format.label) · \(focus.providerLabel)"
            }
            if incomplete.count == 1 {
                return "\(focus.format.label) · \(focus.providerLabel)"
            }
            if let provider = effectiveProviderLabel {
                return "\(formatsLabel) · \(provider)"
            }
            return formatsLabel
        }
        if let provider = effectiveProviderLabel {
            return "\(formatsLabel) · \(provider)"
        }
        return formatsLabel
    }

    public var libraryDetailStatusLine: String {
        let parts = formatStates.map { state in
            "\(state.format.label) · \(Self.displayLabel(for: state.status))"
        }
        if parts.isEmpty {
            return "\(formatsLabel) · \(Self.displayLabel(for: currentStatus))"
        }
        if parts.count == 1 { return parts[0] }
        if formatStates.allSatisfy({ $0.status == .availableInLibrary }) {
            return "Both · Available in Library"
        }
        return parts.joined(separator: "; ")
    }

    public func formatState(for format: BookRequestFormat) -> RequestActivityChainFormatState? {
        formatStates.first { $0.format == format }
    }

    private static func displayLabel(for status: RequestActivityStatus) -> String {
        switch status {
            case .availableInLibrary:
                "Available in Library"
            case .available, .alreadyAvailable:
                "Available"
            case .wanted, .searching:
                "Searching"
            case .requested, .alreadyRequested, .unknown:
                "In progress"
            case .snatched:
                "Snatched"
            case .downloaded:
                "Downloaded"
            case .failed, .needsAttention:
                "Needs attention"
        }
    }
}

/// Snapshot maps for O(1) request → chain resolution. Built once per store snapshot.
public struct RequestActivityChainIndex: Equatable, Sendable {
    public var chains: [RequestActivityChain]
    public var requestIDToChainID: [String: String]
    private var chainsByID: [String: RequestActivityChain]

    public init(chains: [RequestActivityChain] = []) {
        self.chains = chains
        var requestMap: [String: String] = [:]
        var byID: [String: RequestActivityChain] = [:]
        for chain in chains {
            byID[chain.id] = chain
            for item in chain.items {
                requestMap[item.id] = chain.id
            }
        }
        self.requestIDToChainID = requestMap
        self.chainsByID = byID
    }

    public func chain(id: String) -> RequestActivityChain? {
        chainsByID[id]
    }

    public func chain(containingRequestID requestID: String) -> RequestActivityChain? {
        guard let chainID = requestIDToChainID[requestID] else { return nil }
        return chainsByID[chainID]
    }

    public var isEmpty: Bool { chains.isEmpty }
}

/// Pure helpers that group provider attempt rows into logical request chains.
public enum RequestActivityChains {
    /// Follow `fallbackFromRequestID` to the root. Missing parents and cycles are safe.
    public static func rootID(
        for item: RequestActivityItem,
        byID: [String: RequestActivityItem],
    ) -> String {
        var current = item
        var visited: Set<String> = []
        while true {
            if !visited.insert(current.id).inserted {
                // Cycle: pick a deterministic root among the cycle members.
                return visited.min() ?? current.id
            }
            guard let parentID = current.fallbackFromRequestID?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !parentID.isEmpty,
                parentID != current.id,
                let parent = byID[parentID]
            else {
                return current.id
            }
            current = parent
        }
    }

    public static func build(
        from items: [RequestActivityItem],
        now: Date = Date(),
    ) -> RequestActivityChainIndex {
        _ = now
        guard !items.isEmpty else { return RequestActivityChainIndex() }

        var byID: [String: RequestActivityItem] = [:]
        byID.reserveCapacity(items.count)
        for item in items {
            byID[item.id] = item
        }

        var grouped: [String: [RequestActivityItem]] = [:]
        for item in items {
            let root = rootID(for: item, byID: byID)
            grouped[root, default: []].append(item)
        }

        let chains = grouped.map { rootID, members in
            makeChain(rootID: rootID, members: members, byID: byID)
        }
        .sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id < rhs.id
        }

        return RequestActivityChainIndex(chains: chains)
    }

    public static func section(
        for chain: RequestActivityChain,
        now: Date = Date(),
    ) -> RequestActivitySection {
        _ = now
        if chain.formatStates.contains(where: { $0.status.needsAttentionBucket }) {
            return .needsAttention
        }
        if chain.formatStates.contains(where: \.status.isInProgress) {
            return .inProgress
        }
        if !chain.requestedFormats.isEmpty,
            chain.requestedFormats.allSatisfy({ format in
                chain.formatState(for: format)?.status.isCompleted == true
            })
        {
            return .completed
        }
        if chain.formatStates.contains(where: \.status.isCompleted) {
            return .completed
        }
        return .recent
    }

    public static func groups(
        _ chains: [RequestActivityChain],
        now: Date = Date(),
    ) -> [(RequestActivitySection, [RequestActivityChain])] {
        var buckets: [RequestActivitySection: [RequestActivityChain]] = [:]
        for chain in chains {
            buckets[section(for: chain, now: now), default: []].append(chain)
        }
        return RequestActivitySection.allCases.compactMap { section in
            guard let rows = buckets[section], !rows.isEmpty else { return nil }
            let sorted = rows.sorted { $0.updatedAt > $1.updatedAt }
            return (section, sorted)
        }
    }

    public static func librarySummary(
        _ items: [RequestActivityItem],
        now: Date = Date(),
        recentWindow: TimeInterval = RequestActivityGrouping.recentCompletionWindow,
    ) -> RequestActivityLibrarySummary {
        let index = build(from: items, now: now)
        return librarySummary(chains: index.chains, now: now, recentWindow: recentWindow)
    }

    public static func librarySummary(
        chains: [RequestActivityChain],
        now: Date = Date(),
        recentWindow: TimeInterval = RequestActivityGrouping.recentCompletionWindow,
    ) -> RequestActivityLibrarySummary {
        guard !chains.isEmpty else {
            return RequestActivityLibrarySummary(hasTrackedRequests: false)
        }

        var needsAttention = 0
        var inProgress = 0
        var recentlyAvailable = 0

        for chain in chains {
            switch section(for: chain, now: now) {
                case .needsAttention:
                    needsAttention += 1
                case .inProgress:
                    inProgress += 1
                case .completed:
                    if now.timeIntervalSince(chain.updatedAt) <= recentWindow {
                        recentlyAvailable += 1
                    }
                case .recent:
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

    /// Combined oldest → newest timeline. Dedupes equivalent fallback hops.
    public static func combinedTimeline(
        for chain: RequestActivityChain,
    ) -> [RequestActivityChainEvent] {
        var wrapped: [RequestActivityChainEvent] = []
        for item in chain.items {
            for event in RequestActivityTimeline.displayEvents(for: item) {
                wrapped.append(RequestActivityChainEvent(event: event, sourceRequestID: item.id))
            }
        }

        var seenFallbackKeys: Set<String> = []
        let deduped = wrapped.filter { wrap in
            let event = wrap.event
            switch event.kind {
                case .manualFallback, .automaticFallback:
                    let key = fallbackDedupeKey(event)
                    if seenFallbackKeys.contains(key) { return false }
                    seenFallbackKeys.insert(key)
                    return true
                default:
                    return true
            }
        }

        return deduped.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.event.date != rhs.element.event.date {
                    return lhs.element.event.date < rhs.element.event.date
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Resolve a provider-row notification / deep-link id to its chain id.
    public static func resolveChainID(
        requestID: String,
        index: RequestActivityChainIndex,
    ) -> String? {
        index.requestIDToChainID[requestID]
    }

    /// Attempt the chain actions should operate on (latest meaningful incomplete attempt).
    public static func actionItem(for chain: RequestActivityChain) -> RequestActivityItem? {
        let incompleteFormats = chain.formatStates
            .filter { !$0.status.isCompleted }
            .map(\.format)
        if let attentionFormat = chain.formatStates.first(where: {
            $0.status.needsAttentionBucket
        })?.format,
            let item = activeItem(for: attentionFormat, in: chain.items)
        {
            return item
        }
        if let format = incompleteFormats.first,
            let item = activeItem(for: format, in: chain.items)
        {
            return item
        }
        return chain.latestItem ?? chain.rootItem
    }

    /// Provider attempt that currently owns `format` inside the chain.
    public static func activeItem(
        for format: BookRequestFormat,
        in items: [RequestActivityItem],
    ) -> RequestActivityItem? {
        let candidates = items.filter { tracks($0, format: format) }
        guard !candidates.isEmpty else { return nil }

        if let inLibrary = candidates.first(where: {
            $0.status(for: format)?.status == .availableInLibrary
        }) {
            return inLibrary
        }

        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let depths = Dictionary(
            uniqueKeysWithValues: candidates.map {
                ($0.id, hopDepth(of: $0, byID: byID))
            }
        )
        return candidates.max { lhs, rhs in
            let leftDepth = depths[lhs.id] ?? 0
            let rightDepth = depths[rhs.id] ?? 0
            if leftDepth != rightDepth { return leftDepth < rightDepth }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            return lhs.createdAt < rhs.createdAt
        }
    }

    // MARK: - Internals

    private static func makeChain(
        rootID: String,
        members: [RequestActivityItem],
        byID: [String: RequestActivityItem],
    ) -> RequestActivityChain {
        let sortedMembers = members.sorted { lhs, rhs in
            if lhs.id == rootID { return true }
            if rhs.id == rootID { return false }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id < rhs.id
        }
        let root = byID[rootID] ?? sortedMembers[0]
        let requestedFormats = orderedFormats(
            root.requestedFormats.isEmpty
                ? sortedMembers.flatMap(\.requestedFormats)
                : root.requestedFormats
        )
        let formatStates = requestedFormats.compactMap { format -> RequestActivityChainFormatState? in
            formatState(for: format, items: sortedMembers)
        }
        let currentStatus = summarizeStatus(formatStates: formatStates, requestedFormats: requestedFormats)
        let latest = sortedMembers.max { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            return lhs.createdAt < rhs.createdAt
        } ?? root
        let lastChecked = sortedMembers.compactMap(\.lastCheckedAt).max()
        let effectiveProvider = formatStates.first(where: { !$0.status.isCompleted })?.providerLabel
            ?? formatStates.first?.providerLabel
        let hasFallback = sortedMembers.contains {
            $0.fallbackFromRequestID != nil || $0.fallbackKind != nil
        }

        return RequestActivityChain(
            id: root.id,
            rootRequestID: root.id,
            canonicalWorkID: root.canonicalWorkID,
            items: sortedMembers,
            title: root.title,
            author: root.author,
            requestedFormats: requestedFormats,
            formatStates: formatStates,
            currentStatus: currentStatus,
            effectiveProviderLabel: effectiveProvider,
            createdAt: sortedMembers.map(\.createdAt).min() ?? root.createdAt,
            updatedAt: latest.updatedAt,
            lastCheckedAt: lastChecked,
            attemptCount: sortedMembers.count,
            hasFallback: hasFallback,
            latestItemID: latest.id,
        )
    }

    private static func formatState(
        for format: BookRequestFormat,
        items: [RequestActivityItem],
    ) -> RequestActivityChainFormatState? {
        guard let active = activeItem(for: format, in: items),
            let status = active.status(for: format)
        else { return nil }

        let providerLabel: String
        if status.status == .availableInLibrary {
            providerLabel = "Storyteller"
        } else if active.provider == .automatic {
            providerLabel = "Automatic"
        } else {
            providerLabel = active.provider.shortName
        }

        return RequestActivityChainFormatState(
            format: format,
            status: status.status,
            sourceRequestID: active.id,
            providerLabel: providerLabel,
            detail: status.detail,
        )
    }

    private static func summarizeStatus(
        formatStates: [RequestActivityChainFormatState],
        requestedFormats: [BookRequestFormat],
    ) -> RequestActivityStatus {
        guard !formatStates.isEmpty else { return .unknown }

        let relevant = requestedFormats.isEmpty
            ? formatStates
            : requestedFormats.compactMap { format in formatStates.first { $0.format == format } }
        let states = relevant.isEmpty ? formatStates : relevant

        if !states.isEmpty, states.allSatisfy({ $0.status.isCompleted }) {
            return .availableInLibrary
        }
        if let attention = states.first(where: { $0.status.needsAttentionBucket }) {
            return attention.status
        }
        if let progress = states.first(where: \.status.isInProgress) {
            return progress.status
        }
        return states.first?.status ?? .unknown
    }

    private static func tracks(_ item: RequestActivityItem, format: BookRequestFormat) -> Bool {
        item.requestedFormats.contains(format) || item.status(for: format) != nil
    }

    private static func hopDepth(
        of item: RequestActivityItem,
        byID: [String: RequestActivityItem],
    ) -> Int {
        var depth = 0
        var current = item
        var visited: Set<String> = []
        while visited.insert(current.id).inserted,
            let parentID = current.fallbackFromRequestID?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !parentID.isEmpty,
            parentID != current.id,
            let parent = byID[parentID]
        {
            depth += 1
            current = parent
            if depth > byID.count { break }
        }
        return depth
    }

    private static func orderedFormats(_ formats: [BookRequestFormat]) -> [BookRequestFormat] {
        BookRequestFormat.allCases.filter { formats.contains($0) }
    }

    private static func fallbackDedupeKey(_ event: RequestActivityEvent) -> String {
        let related = event.relatedRequestID ?? ""
        let detail = event.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let provider = event.provider?.rawValue ?? ""
        return "\(event.kind.rawValue)|\(related)|\(detail)|\(provider)"
    }
}
