import Foundation

/// Pure decision for one automatic hop. Never opens Book Search LAN.
public enum AutomaticFallbackDecision: Equatable, Sendable {
    case none
    /// Alternate is known unavailable — skip without marking an attempt.
    case skipUnavailable(target: BookRequestProviderKind)
    case submit(
        sourceRequestID: String,
        provider: BookRequestProviderKind,
        formats: [BookRequestFormat]
    )
}

/// Conservative, one-hop automatic provider fallback rules.
public enum AutomaticFallbackPolicy {
    /// Decide whether `item` may automatically submit to the other provider.
    public static func decide(
        item: RequestActivityItem,
        history: [RequestActivityItem],
        settings: AutomaticFallbackSettingsSnapshot,
        context: RequestActivityActionContext,
        now: Date = Date(),
        unavailableLazyLibrarian: Bool = false,
        unavailableShelfarr: Bool = false,
    ) -> AutomaticFallbackDecision {
        guard settings.enabled else { return .none }
        // Already an automatic hop — never bounce back.
        if item.fallbackKind == .automatic { return .none }

        guard let current = RequestActivityFallbackPolicy.resolvedProvider(item),
            let target = alternateProvider(for: current, context: context)
        else { return .none }

        let retryable = RequestActivityRetryPolicy.retryableFormats(for: item)
        let formats = retryable.filter { format in
            guard let status = item.status(for: format) else { return false }
            if status.status == .availableInLibrary { return false }
            if hasAttempted(item: item, format: format, target: target) { return false }
            if !delayElapsed(status: status, delay: settings.delay, now: now) { return false }
            return true
        }
        guard !formats.isEmpty else { return .none }

        // Storyteller presence on the source row already filtered availableInLibrary.
        // History may still show an alternate active/complete row.
        let decision = RequestActivityFallbackPolicy.decision(
            item: item,
            provider: target,
            formats: formats,
            history: history,
        )
        guard !decision.formats.isEmpty else { return .none }

        // A prior automatic hop to this provider for these formats must not repeat.
        let remaining = decision.formats.filter { format in
            !alreadyHopped(
                source: item,
                target: target,
                format: format,
                history: history,
            )
        }
        guard !remaining.isEmpty else { return .none }

        let unavailable =
            (target == .lazyLibrarian && unavailableLazyLibrarian)
            || (target == .shelfarr && unavailableShelfarr)
        if unavailable {
            return .skipUnavailable(target: target)
        }

        return .submit(
            sourceRequestID: item.id,
            provider: target,
            formats: remaining,
        )
    }

    /// Secondary copy when eligible but still waiting on the delay.
    public static func pendingMessage(
        item: RequestActivityItem,
        settings: AutomaticFallbackSettingsSnapshot,
        context: RequestActivityActionContext,
        now: Date = Date(),
    ) -> String? {
        guard settings.enabled, settings.delay != .immediately else { return nil }
        if item.fallbackKind == .automatic { return nil }
        guard let current = RequestActivityFallbackPolicy.resolvedProvider(item),
            let target = alternateProvider(for: current, context: context)
        else { return nil }

        let waiting = RequestActivityRetryPolicy.retryableFormats(for: item).compactMap {
            format -> TimeInterval? in
            guard let status = item.status(for: format) else { return nil }
            if hasAttempted(item: item, format: format, target: target) { return nil }
            let remaining =
                settings.delay.seconds - now.timeIntervalSince(status.updatedAt)
            return remaining > 0 ? remaining : nil
        }
        guard let longest = waiting.max(), longest > 0 else { return nil }
        let hours = max(1, Int((longest / 3600.0).rounded(.up)))
        let unit = hours == 1 ? "hour" : "hours"
        return "Automatic fallback to \(target.shortName) available in about \(hours) \(unit)"
    }

    public static func alternateProvider(
        for current: BookRequestProviderKind,
        context: RequestActivityActionContext,
    ) -> BookRequestProviderKind? {
        switch current {
            case .lazyLibrarian:
                return RequestActivityFallbackPolicy.isShelfarrConfigured(context) ? .shelfarr : nil
            case .shelfarr:
                return RequestActivityFallbackPolicy.isLazyLibrarianConfigured(context)
                    ? .lazyLibrarian : nil
            case .automatic:
                return nil
        }
    }

    public static func hasAttempted(
        item: RequestActivityItem,
        format: BookRequestFormat,
        target: BookRequestProviderKind,
    ) -> Bool {
        item.automaticFallbackAttempts?.contains {
            $0.format == format && $0.targetProvider == target
        } == true
    }

    public static func delayElapsed(
        status: RequestFormatStatus,
        delay: AutomaticFallbackDelay,
        now: Date,
    ) -> Bool {
        now.timeIntervalSince(status.updatedAt) >= delay.seconds
    }

    /// Persist intent on the source before submit so a crash cannot double-send.
    public static func markAttempts(
        on item: RequestActivityItem,
        formats: [BookRequestFormat],
        target: BookRequestProviderKind,
        now: Date = Date(),
    ) -> RequestActivityItem {
        var updated = item
        var attempts = updated.automaticFallbackAttempts ?? []
        for format in formats {
            if let index = attempts.firstIndex(where: {
                $0.format == format && $0.targetProvider == target
            }) {
                attempts[index].attemptedAt = now
            } else {
                attempts.append(
                    AutomaticFallbackAttempt(
                        format: format,
                        targetProvider: target,
                        attemptedAt: now,
                    )
                )
            }
        }
        updated.automaticFallbackAttempts = attempts
        updated.updatedAt = now
        return updated
    }

    public static func attachResultingID(
        on item: RequestActivityItem,
        formats: [BookRequestFormat],
        target: BookRequestProviderKind,
        resultingRequestID: String,
    ) -> RequestActivityItem {
        var updated = item
        var attempts = updated.automaticFallbackAttempts ?? []
        for format in formats {
            if let index = attempts.firstIndex(where: {
                $0.format == format && $0.targetProvider == target
            }) {
                attempts[index].resultingRequestID = resultingRequestID
            }
        }
        updated.automaticFallbackAttempts = attempts
        return updated
    }

    private static func alreadyHopped(
        source: RequestActivityItem,
        target: BookRequestProviderKind,
        format: BookRequestFormat,
        history: [RequestActivityItem],
    ) -> Bool {
        history.contains { row in
            row.canonicalWorkID == source.canonicalWorkID
                && row.provider == target
                && row.fallbackFromRequestID == source.id
                && row.fallbackKind == .automatic
                && (row.requestedFormats.contains(format) || row.status(for: format) != nil)
        }
    }
}
