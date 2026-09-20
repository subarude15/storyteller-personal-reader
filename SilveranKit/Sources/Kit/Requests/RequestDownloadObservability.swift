import Foundation

/// Pure Deluge → Request Activity download observability helpers.
public enum RequestDownloadObservability {
    /// After Deluge completes, wait this long before escalating to Needs Attention.
    public static let importGracePeriod: TimeInterval = 12 * 3600

    /// Apply one torrent index to a request row. Storyteller presence must already win.
    public static func applying(
        _ item: RequestActivityItem,
        index: DelugeTorrentIndex,
        now: Date = Date(),
    ) -> RequestActivityItem {
        var updated = item
        var states = updated.downloadStates ?? []

        for format in BookRequestFormat.allCases where item.requestedFormats.contains(format) {
            // Storyteller always wins — clear active download control for completed formats.
            if item.status(for: format)?.status == .availableInLibrary {
                if let idx = states.firstIndex(where: { $0.format == format }) {
                    var done = states[idx]
                    done.status = .completed
                    done.detail = nil
                    done.delugeUnavailable = false
                    done.updatedAt = now
                    states[idx] = done
                }
                continue
            }

            let previous = states.first { $0.format == format }
            let next: RequestFormatDownloadState

            if index.unavailable {
                if var kept = previous, kept.status.isActivelyDownloading || kept.status == .completed
                    || kept.status == .waitingForImport
                {
                    kept.delugeUnavailable = true
                    kept.detail = kept.detail ?? "Last known download state"
                    kept.updatedAt = now
                    next = kept
                } else {
                    next = RequestFormatDownloadState(
                        format: format,
                        status: previous?.status ?? .unknown,
                        progress: previous?.progress,
                        etaSeconds: previous?.etaSeconds,
                        detail: "Deluge unavailable",
                        torrentID: previous?.torrentID,
                        torrentName: previous?.torrentName,
                        completedAt: previous?.completedAt,
                        updatedAt: now,
                        delugeUnavailable: true,
                    )
                }
            } else {
                next = resolveState(
                    item: item,
                    format: format,
                    previous: previous,
                    index: index,
                    now: now,
                )
            }

            if let idx = states.firstIndex(where: { $0.format == format }) {
                states[idx] = next
            } else if next.status != .unknown && next.status != .notFound {
                states.append(next)
            } else if next.torrentID != nil || next.delugeUnavailable {
                states.append(next)
            }
        }

        updated.downloadStates = states.isEmpty ? updated.downloadStates : states
        updated = recordingDownloadTransitions(previous: item, incoming: updated, now: now)
        updated = applyingImportGrace(updated, now: now)
        return updated
    }

    /// True when automatic provider fallback should stay quiet for this format.
    public static func suppressesAutomaticFallback(
        item: RequestActivityItem,
        format: BookRequestFormat,
        now: Date = Date(),
    ) -> Bool {
        guard let download = item.downloadState(for: format) else { return false }
        if item.status(for: format)?.status == .availableInLibrary { return false }
        switch download.status {
            case .queued, .downloading, .stalled, .checking:
                return true
            case .waitingForImport, .completed:
                guard let completedAt = download.completedAt else { return true }
                return now.timeIntervalSince(completedAt) < importGracePeriod
            case .error, .unknown, .notFound:
                return false
        }
    }

    public static func mapSnapshot(
        _ snapshot: DelugeTorrentSnapshot,
        previous: RequestFormatDownloadState?,
        format: BookRequestFormat,
        inLibrary: Bool,
        now: Date,
    ) -> RequestFormatDownloadState {
        if inLibrary {
            return RequestFormatDownloadState(
                format: format,
                status: .completed,
                progress: 1,
                torrentID: snapshot.id,
                torrentName: snapshot.name,
                completedAt: previous?.completedAt ?? snapshot.completedAt ?? now,
                updatedAt: now,
            )
        }

        var status = DelugeWebClient.mapState(snapshot)
        var completedAt = previous?.completedAt ?? snapshot.completedAt
        var detail = snapshot.error

        if status == .completed {
            completedAt = completedAt ?? snapshot.completedAt ?? now
            status = .waitingForImport
            detail = "Waiting for Storyteller import"
        } else if status == .error {
            detail = snapshot.error ?? "Deluge reported an error"
        }

        return RequestFormatDownloadState(
            format: format,
            status: status,
            progress: snapshot.progress,
            etaSeconds: snapshot.etaSeconds,
            detail: detail,
            torrentID: snapshot.id,
            torrentName: snapshot.name,
            completedAt: completedAt,
            updatedAt: now,
        )
    }

    // MARK: - Internals

    private static func resolveState(
        item: RequestActivityItem,
        format: BookRequestFormat,
        previous: RequestFormatDownloadState?,
        index: DelugeTorrentIndex,
        now: Date,
    ) -> RequestFormatDownloadState {
        switch DelugeRequestMatcher.match(item: item, format: format, index: index) {
            case .matched(let snapshot):
                return mapSnapshot(
                    snapshot,
                    previous: previous,
                    format: format,
                    inLibrary: false,
                    now: now,
                )
            case .ambiguous:
                return RequestFormatDownloadState(
                    format: format,
                    status: .unknown,
                    detail: "Multiple Deluge torrents could match",
                    torrentID: previous?.torrentID,
                    torrentName: previous?.torrentName,
                    completedAt: previous?.completedAt,
                    updatedAt: now,
                )
            case .noMatch:
                // Keep a completed/waiting linkage if the torrent disappeared briefly.
                if let previous,
                    previous.status == .waitingForImport || previous.status == .completed,
                    previous.torrentID != nil
                {
                    var kept = previous
                    kept.updatedAt = now
                    kept.detail = previous.detail ?? "Waiting for Storyteller import"
                    return kept
                }
                return RequestFormatDownloadState(
                    format: format,
                    status: .notFound,
                    torrentID: nil,
                    torrentName: nil,
                    completedAt: previous?.completedAt,
                    updatedAt: now,
                )
        }
    }

    private static func applyingImportGrace(
        _ item: RequestActivityItem,
        now: Date,
    ) -> RequestActivityItem {
        var updated = item
        guard var states = updated.downloadStates, !states.isEmpty else { return updated }

        for index in states.indices {
            let format = states[index].format
            if updated.status(for: format)?.status == .availableInLibrary { continue }
            guard states[index].status == .waitingForImport || states[index].status == .completed
            else { continue }
            guard let completedAt = states[index].completedAt else { continue }
            let age = now.timeIntervalSince(completedAt)
            if age < importGracePeriod {
                states[index].status = .waitingForImport
                states[index].detail = "Waiting for Storyteller import"
                continue
            }
            // Escalate request format to Needs Attention after grace.
            states[index].status = .waitingForImport
            states[index].detail = "Downloaded, but not yet available in Storyteller."
            if let formatIndex = updated.formatStatuses.firstIndex(where: { $0.format == format }) {
                RequestActivityAttention.enterNeedsAttention(
                    &updated.formatStatuses[formatIndex],
                    detail: "Downloaded, but not yet available in Storyteller.",
                    now: now,
                )
                updated.attentionReason = "Downloaded, but not yet available in Storyteller."
                updated.updatedAt = now
            } else {
                var status = RequestFormatStatus(
                    format: format,
                    status: .needsAttention,
                    detail: "Downloaded, but not yet available in Storyteller.",
                    updatedAt: now,
                )
                RequestActivityAttention.enterNeedsAttention(
                    &status,
                    detail: "Downloaded, but not yet available in Storyteller.",
                    now: now,
                )
                updated.formatStatuses.append(status)
                updated.attentionReason = "Downloaded, but not yet available in Storyteller."
                updated.updatedAt = now
            }
        }
        updated.downloadStates = states
        return updated
    }

    private static func recordingDownloadTransitions(
        previous: RequestActivityItem,
        incoming: RequestActivityItem,
        now: Date,
    ) -> RequestActivityItem {
        var updated = incoming
        var events = updated.events ?? []
        for format in BookRequestFormat.allCases where incoming.requestedFormats.contains(format) {
            let old = previous.downloadState(for: format)?.status
            let new = incoming.downloadState(for: format)?.status
            guard let new, old != new else { continue }

            var kinds: [RequestActivityEventKind] = []
            switch new {
                case .queued:
                    if old == nil || old == .notFound || old == .unknown || old == .error {
                        kinds.append(.downloadQueued)
                    }
                case .downloading, .checking, .stalled:
                    if old != .downloading && old != .checking && old != .stalled {
                        kinds.append(.downloadStarted)
                    }
                case .completed:
                    kinds.append(.downloadCompleted)
                case .waitingForImport:
                    if old != .waitingForImport && old != .completed {
                        kinds.append(.downloadCompleted)
                    }
                    if old != .waitingForImport {
                        kinds.append(.waitingForImport)
                    }
                case .error:
                    kinds.append(.downloadError)
                case .unknown, .notFound:
                    break
            }

            for kind in kinds {
                if events.contains(where: {
                    $0.kind == kind && $0.format == format && $0.sourceLabel == "Deluge"
                }) {
                    continue
                }
                events.append(
                    RequestActivityEvent(
                        date: now,
                        kind: kind,
                        format: format,
                        provider: nil,
                        title: RequestActivityTimeline.title(for: kind),
                        detail: incoming.downloadState(for: format)?.detail,
                        relatedRequestID: nil,
                        sourceLabel: "Deluge",
                    )
                )
            }
        }
        if events.count != (updated.events?.count ?? 0) {
            updated.events = events
            updated.updatedAt = now
        }
        return updated
    }
}
