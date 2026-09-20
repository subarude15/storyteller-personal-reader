import Foundation

/// Refreshes Request Activity rows from providers. Read-only; never queues.
public struct RequestActivityRefreshService: Sendable {
    public var client: LazyLibrarianClient
    public var history: RequestActivityStore
    public var now: @Sendable () -> Date

    public init(
        client: LazyLibrarianClient = LazyLibrarianClient(),
        history: RequestActivityStore = .shared,
        now: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.client = client
        self.history = history
        self.now = now
    }

    public func refreshAll(
        force: Bool = false,
        onUpdate: (@Sendable (RequestActivityItem) async -> Void)? = nil,
    ) async -> [RequestActivityItem] {
        history.prune(now: now())
        let items = history.allItems()
        let settings = await SettingsActor.shared.config
        let key = (try? await AuthenticationActor.shared.loadLazyLibrarianAPIKey()) ?? ""
        let lazyReady =
            settings.lazyLibrarianEnabled
            && !settings.lazyLibrarianBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !key.isEmpty

        var results: [RequestActivityItem] = []
        await withTaskGroup(of: RequestActivityItem.self) { group in
            for item in items {
                group.addTask {
                    await self.refreshOne(
                        item,
                        force: force,
                        lazyReady: lazyReady,
                        baseURL: settings.lazyLibrarianBaseURL,
                        apiKey: key,
                    )
                }
            }
            for await updated in group {
                results.append(updated)
                await onUpdate?(updated)
            }
        }
        return results.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func refreshOne(
        _ item: RequestActivityItem,
        force: Bool,
        lazyReady: Bool,
        baseURL: String,
        apiKey: String,
    ) async -> RequestActivityItem {
        let checkedAt = now()
        if !force,
            let last = item.lastCheckedAt,
            checkedAt.timeIntervalSince(last) < RequestActivityGrouping.refreshStaleInterval
        {
            return item
        }

        debugLog(
            "[RequestActivity] status refresh start id=\(item.id) provider=\(item.provider.rawValue)"
        )

        var updated = item
        updated.lastCheckedAt = checkedAt

        switch item.provider {
            case .automatic:
                break
            case .shelfarr:
                // Shelfarr has no richer lifecycle in this app — keep Requested.
                updated = RequestActivityAttention.apply(updated, now: checkedAt)
                history.upsert(updated)
                return updated
            case .lazyLibrarian:
                guard lazyReady else {
                    updated.lastError = "LazyLibrarian is currently unavailable"
                    // Do not escalate to Needs Attention on a single offline look.
                    history.upsert(updated)
                    debugLog("[RequestActivity] status refresh skipped id=\(item.id) reason=llUnavailable")
                    return updated
                }
                guard let bookID = item.providerBookID, !bookID.isEmpty else {
                    updated.lastError = "Missing LazyLibrarian BookID"
                    updated.attentionReason = "Missing LazyLibrarian BookID"
                    for index in updated.formatStatuses.indices {
                        updated.formatStatuses[index].status = .needsAttention
                        updated.formatStatuses[index].detail = updated.attentionReason
                    }
                    history.upsert(updated)
                    return updated
                }

                switch await client.lookupBook(id: bookID, baseURL: baseURL, apiKey: apiKey) {
                    case .failure(let failure):
                        for index in updated.formatStatuses.indices {
                            updated.formatStatuses[index].consecutiveLookupFailures += 1
                        }
                        updated.lastError = failure.detail
                        if case .missingBook = failure {
                            updated.attentionReason = failure.detail
                            for index in updated.formatStatuses.indices {
                                updated.formatStatuses[index].status = .needsAttention
                                updated.formatStatuses[index].detail = failure.detail
                            }
                        }
                        updated = RequestActivityAttention.apply(updated, now: checkedAt)
                        history.upsert(updated)
                        debugLog(
                            "[RequestActivity] status refresh failed id=\(item.id) error=\(failure.detail)"
                        )
                        return updated
                    case .success(nil):
                        updated.attentionReason = LazyLibrarianLookupFailure.missingBook.detail
                        updated.lastError = updated.attentionReason
                        for index in updated.formatStatuses.indices {
                            updated.formatStatuses[index].status = .needsAttention
                            updated.formatStatuses[index].detail = updated.attentionReason
                            updated.formatStatuses[index].consecutiveLookupFailures = 0
                        }
                        history.upsert(updated)
                        return updated
                    case .success(let snapshot?):
                        let previous = updated.formatStatuses
                        for format in updated.requestedFormats {
                            let ll = snapshot.state(for: format)
                            let mapped = ll.activityStatus
                            let detail: String
                            switch mapped {
                                case .available:
                                    detail = "Available from LazyLibrarian"
                                case .snatched:
                                    detail = "Snatched — download in progress on the server"
                                case .wanted:
                                    detail = "Wanted — waiting for a release"
                                case .needsAttention:
                                    detail = "Marked ignored in LazyLibrarian"
                                default:
                                    detail = mapped.label
                            }
                            var status = RequestFormatStatus(
                                format: format,
                                status: mapped,
                                detail: detail,
                                providerRawState: ll.rawLabel,
                                updatedAt: previous.first(where: { $0.format == format })?.updatedAt
                                    ?? checkedAt,
                                consecutiveLookupFailures: 0,
                            )
                            // Only bump updatedAt when the status actually changes.
                            if previous.first(where: { $0.format == format })?.status != mapped {
                                status.updatedAt = checkedAt
                                updated.updatedAt = checkedAt
                                debugLog(
                                    "[RequestActivity] status transition id=\(item.id) format=\(format.rawValue) to=\(mapped.rawValue)"
                                )
                            }
                            if let idx = updated.formatStatuses.firstIndex(where: { $0.format == format }) {
                                updated.formatStatuses[idx] = status
                            } else {
                                updated.formatStatuses.append(status)
                            }
                        }
                        updated.lastError = nil
                        if !updated.formatStatuses.contains(where: {
                            $0.status.needsAttentionBucket
                        }) {
                            updated.attentionReason = nil
                        }
                        updated = RequestActivityAttention.apply(updated, now: checkedAt)
                        history.upsert(updated)
                        debugLog("[RequestActivity] status refresh end id=\(item.id) ok=true")
                        return updated
                }
        }
        history.upsert(updated)
        return updated
    }
}
