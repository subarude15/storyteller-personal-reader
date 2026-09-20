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
    public static func newlyAttentionFormats(
        previous: RequestActivityItem?,
        current: RequestActivityItem,
    ) -> [BookRequestFormat] {
        let fingerprint = attentionFingerprint(for: current)
        let lastNotified =
            previous?.notificationState?.lastNotifiedAttentionFingerprint
            ?? current.notificationState?.lastNotifiedAttentionFingerprint

        let nowAttention = attentionFormats(in: current)
        guard !nowAttention.isEmpty else { return [] }

        let wasAttention = previous.map { attentionFormats(in: $0) } ?? []
        let newly = nowAttention.filter { !wasAttention.contains($0) }
        guard !newly.isEmpty else { return [] }

        // Already notified for this attention generation — avoid spam on refresh.
        if let lastNotified, lastNotified == fingerprint { return [] }
        return newly
    }

    public static func attentionFormats(in item: RequestActivityItem) -> [BookRequestFormat] {
        BookRequestFormat.allCases.filter { format in
            guard item.requestedFormats.contains(format) else { return false }
            return item.status(for: format)?.status.needsAttentionBucket == true
        }
    }

    public static func attentionFingerprint(for item: RequestActivityItem) -> String {
        attentionFormats(in: item).map(\.rawValue).joined(separator: ",")
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
                    // Stable order for encoding / equality.
                    state.lastNotifiedAvailableFormats = BookRequestFormat.allCases.filter {
                        state.lastNotifiedAvailableFormats.contains($0)
                    }
                case .needsAttention:
                    state.lastNotifiedAttentionFingerprint = attentionFingerprint(for: item)
            }
        }

        // Leaving attention clears the fingerprint so a later re-entry may notify again.
        if attentionFormats(in: item).isEmpty {
            state.lastNotifiedAttentionFingerprint = nil
        }

        updated.notificationState = state
        return updated
    }
}
