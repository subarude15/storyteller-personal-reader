import Foundation

/// Pure transition detector: previous → current → notification events.
/// Does not schedule; does not touch UserNotifications.
public enum RequestActivityTransitionDetector {
    public static func events(
        previous: RequestActivityItem?,
        current: RequestActivityItem,
        settings: RequestNotificationSettingsSnapshot = .init(enabled: true),
    ) -> [RequestNotificationEvent] {
        guard settings.enabled else { return [] }

        var result: [RequestNotificationEvent] = []

        if settings.allowsAvailable {
            let newlyAvailable = newlyAvailableFormats(previous: previous, current: current)
            if !newlyAvailable.isEmpty {
                result.append(
                    .available(
                        requestID: current.id,
                        title: current.title,
                        formats: newlyAvailable,
                    )
                )
            }
        }

        if settings.allowsNeedsAttention {
            let newlyAttention = newlyAttentionFormats(previous: previous, current: current)
            if !newlyAttention.isEmpty {
                result.append(
                    .needsAttention(
                        requestID: current.id,
                        title: current.title,
                        formats: newlyAttention,
                    )
                )
            }
        }

        return result
    }

    /// Formats that newly became Available in Library and were not already notified.
    public static func newlyAvailableFormats(
        previous: RequestActivityItem?,
        current: RequestActivityItem,
    ) -> [BookRequestFormat] {
        let alreadyNotified = Set(
            (previous?.notificationState ?? current.notificationState)?
                .lastNotifiedAvailableFormats ?? []
        )
        return BookRequestFormat.allCases.filter { format in
            guard current.requestedFormats.contains(format) else { return false }
            let isNow = current.status(for: format)?.status == .availableInLibrary
            guard isNow else { return false }
            if alreadyNotified.contains(format) { return false }
            let was = previous?.status(for: format)?.status == .availableInLibrary
            // Transition only — stay-available on refresh / upgrade must not notify.
            return !was
        }
    }

    /// Formats that newly entered Needs Attention / Failed (attention bucket).
    /// Per-format: a recovered format may notify again even if siblings stay in attention.
    public static func newlyAttentionFormats(
        previous: RequestActivityItem?,
        current: RequestActivityItem,
    ) -> [BookRequestFormat] {
        let alreadyNotified = Set(
            (previous?.notificationState ?? current.notificationState)?
                .lastNotifiedAttentionFormats ?? []
        )
        let nowAttention = Set(attentionFormats(in: current))
        let wasAttention = Set(previous.map { attentionFormats(in: $0) } ?? [])

        return BookRequestFormat.allCases.filter { format in
            guard current.requestedFormats.contains(format) else { return false }
            guard nowAttention.contains(format) else { return false }
            // Still in attention from previous update — not a new transition.
            if wasAttention.contains(format) { return false }
            // Restart / reload with persisted notify state while still in attention.
            if previous == nil, alreadyNotified.contains(format) { return false }
            // Transition into attention (including re-entry after recovery).
            return true
        }
    }

    public static func attentionFormats(in item: RequestActivityItem) -> [BookRequestFormat] {
        BookRequestFormat.allCases.filter { format in
            guard item.requestedFormats.contains(format) else { return false }
            return item.status(for: format)?.status.needsAttentionBucket == true
        }
    }

    /// Apply notified-state onto the item after events are accepted.
    public static func applyingNotificationState(
        _ item: RequestActivityItem,
        events: [RequestNotificationEvent],
        previous: RequestActivityItem?,
    ) -> RequestActivityItem {
        var updated = item
        var state =
            item.notificationState
            ?? previous?.notificationState
            ?? RequestActivityNotificationState()

        for event in events {
            switch event {
                case .available(_, _, let formats):
                    for format in formats where !state.lastNotifiedAvailableFormats.contains(format)
                    {
                        state.lastNotifiedAvailableFormats.append(format)
                    }
                    state.lastNotifiedAvailableFormats = BookRequestFormat.allCases.filter {
                        state.lastNotifiedAvailableFormats.contains($0)
                    }
                case .needsAttention(_, _, let formats):
                    for format in formats where !state.lastNotifiedAttentionFormats.contains(format)
                    {
                        state.lastNotifiedAttentionFormats.append(format)
                    }
            }
        }

        // Drop formats that left attention so a later re-entry may notify again,
        // even when sibling formats remain in attention.
        let stillAttention = Set(attentionFormats(in: item))
        state.lastNotifiedAttentionFormats = BookRequestFormat.allCases.filter {
            state.lastNotifiedAttentionFormats.contains($0) && stillAttention.contains($0)
        }

        updated.notificationState = state
        return updated
    }
}
