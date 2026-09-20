import Foundation

extension Notification.Name {
    /// Posted after Request Activity history mutates (upsert / submit / remove / prune).
    /// No secrets in `userInfo` — observers should re-read the store.
    /// Always posted outside the store lock so observers may safely re-enter.
    public static let requestActivityStoreDidChange = Notification.Name(
        "punkRally.requestActivityStoreDidChange"
    )
}

/// Device-local request history. No secrets — BookIDs and statuses only.
public final class RequestActivityStore: @unchecked Sendable {
    public static let shared = RequestActivityStore()

    public static let defaultsKey = "punkRally.requestActivity.items.v1"

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = RequestActivityStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    public func allItems() -> [RequestActivityItem] {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    public func item(forWorkID workID: String) -> RequestActivityItem? {
        allItems().first { $0.canonicalWorkID == workID }
    }

    public func item(id: String) -> RequestActivityItem? {
        allItems().first { $0.id == id }
    }

    public func upsert(_ item: RequestActivityItem) {
        lock.lock()
        var items = loadUnlocked()
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else if let index = items.firstIndex(where: {
            $0.canonicalWorkID == item.canonicalWorkID && $0.provider == item.provider
        }) {
            items[index] = item
        } else {
            items.append(item)
        }
        let didSave = saveUnlocked(items)
        lock.unlock()
        if didSave {
            notifyDidChange()
        }
    }

    public func remove(id: String) {
        lock.lock()
        var items = loadUnlocked()
        items.removeAll { $0.id == id }
        let didSave = saveUnlocked(items)
        lock.unlock()
        if didSave {
            notifyDidChange()
        }
        debugLog("[RequestActivity] removed local tracking id=\(id)")
    }

    public func recordSubmission(
        work: CanonicalBookWork,
        provider: BookRequestProviderKind,
        outcomes: [BookRequestOutcome],
        now: Date = Date(),
    ) {
        guard !outcomes.isEmpty else { return }
        let workID = work.openLibraryWorkID ?? work.workID
        lock.lock()
        var items = loadUnlocked()
        let existingIndex = items.firstIndex {
            $0.canonicalWorkID == workID && $0.provider == provider
        }
        var item =
            existingIndex.map { items[$0] }
            ?? RequestActivityItem(
                canonicalWorkID: workID,
                title: work.title,
                author: work.authors.joined(separator: ", "),
                provider: provider,
                requestedFormats: outcomes.map(\.format),
                createdAt: now,
                updatedAt: now,
            )
        item.title = work.title
        item.author = work.authors.joined(separator: ", ")
        item.provider = provider
        item.updatedAt = now
        if let bookID = outcomes.compactMap(\.providerBookID).first {
            item.providerBookID = bookID
            debugLog(
                "[RequestActivity] provider BookID resolved work=\(workID) provider=\(provider.rawValue) bookID=\(bookID)"
            )
        }
        var formats = Set(item.requestedFormats)
        for outcome in outcomes {
            formats.insert(outcome.format)
            let status = RequestFormatStatus(
                format: outcome.format,
                status: outcome.phase.activityStatus,
                detail: outcome.detail,
                updatedAt: now,
            )
            if let idx = item.formatStatuses.firstIndex(where: { $0.format == outcome.format }) {
                item.formatStatuses[idx] = status
            } else {
                item.formatStatuses.append(status)
            }
            if outcome.phase == .failed {
                item.lastError = outcome.detail
                item.attentionReason = outcome.detail
            }
        }
        item.requestedFormats = BookRequestFormat.allCases.filter { formats.contains($0) }
        item = RequestActivityAttention.apply(item, now: now)
        if let existingIndex {
            items[existingIndex] = item
        } else {
            items.append(item)
        }
        let didSave = saveUnlocked(items)
        let formatLabels = item.requestedFormats.map(\.rawValue).joined(separator: ",")
        lock.unlock()
        if didSave {
            notifyDidChange()
        }
        debugLog(
            "[RequestActivity] saved request work=\(workID) provider=\(provider.rawValue) formats=\(formatLabels)"
        )
    }

    public func prune(now: Date = Date()) {
        lock.lock()
        let retention = RequestActivityGrouping.completedRetentionInterval
        var items = loadUnlocked()
        let before = items.count
        items.removeAll { item in
            let section = RequestActivityGrouping.section(for: item, now: now)
            switch section {
                case .inProgress, .needsAttention:
                    // Needs attention retained 30 days from last update.
                    if section == .needsAttention {
                        return now.timeIntervalSince(item.updatedAt) > retention
                    }
                    return false
                case .completed, .recent:
                    return now.timeIntervalSince(item.updatedAt) > retention
            }
        }
        let removed = before - items.count
        let didSave = removed > 0 ? saveUnlocked(items) : false
        lock.unlock()
        if didSave {
            notifyDidChange()
            debugLog("[RequestActivity] pruned history removed=\(removed)")
        }
    }

    private func loadUnlocked() -> [RequestActivityItem] {
        guard let data = defaults.data(forKey: key) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RequestActivityItem].self, from: data)) ?? []
    }

    /// Persist only. Callers must hold `lock` and post notifications after unlocking.
    @discardableResult
    private func saveUnlocked(_ items: [RequestActivityItem]) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(items) else { return false }
        defaults.set(data, forKey: key)
        return true
    }

    private func notifyDidChange() {
        NotificationCenter.default.post(name: .requestActivityStoreDidChange, object: nil)
    }

    public func librarySummary(now: Date = Date()) -> RequestActivityLibrarySummary {
        RequestActivityGrouping.librarySummary(allItems(), now: now)
    }
}

public enum RequestActivityAttention {
    /// Stale Wanted/Searching/Requested is a LazyLibrarian signal. Shelfarr only
    /// reports acceptance, so age alone is not an error.
    public static func apply(_ item: RequestActivityItem, now: Date = Date()) -> RequestActivityItem {
        var updated = item
        var reason: String? = item.attentionReason
        for index in updated.formatStatuses.indices {
            var format = updated.formatStatuses[index]
            if format.status == .failed {
                reason = format.detail ?? "Request failed"
                format.status = .needsAttention
                updated.formatStatuses[index] = format
                continue
            }
            if item.provider == .shelfarr {
                continue
            }
            if format.consecutiveLookupFailures
                >= RequestActivityGrouping.lookupFailureAttentionThreshold
            {
                reason = "Status lookup failed repeatedly"
                format.status = .needsAttention
                format.detail = reason
                updated.formatStatuses[index] = format
                continue
            }
            let age = now.timeIntervalSince(format.updatedAt)
            let staleCandidate =
                format.status == .wanted
                || format.status == .searching
                || format.status == .requested
                || format.status == .alreadyRequested
            if staleCandidate, age >= RequestActivityGrouping.staleWantedInterval {
                reason = "Still waiting after \(ServiceHealthURLSanitizer.relativeAge(from: format.updatedAt, now: now))"
                format.status = .needsAttention
                format.detail = reason
                updated.formatStatuses[index] = format
            }
        }
        let stillFlagged = updated.formatStatuses.contains { $0.status.needsAttentionBucket }
        updated.attentionReason = stillFlagged ? reason : nil
        return updated
    }
}
