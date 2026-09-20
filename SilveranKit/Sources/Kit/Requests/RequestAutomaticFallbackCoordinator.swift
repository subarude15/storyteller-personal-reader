import Foundation

/// Submits automatic fallbacks. Injected in tests — no network by default in unit tests.
public protocol AutomaticFallbackSubmitting: Sendable {
    func submitFallback(
        work: CanonicalBookWork,
        formats: [BookRequestFormat],
        provider: BookRequestProviderKind,
        fallbackFromRequestID: String,
        history: RequestActivityStore,
        now: Date,
    ) async -> BookRequestSubmission
}

public struct BookRequestAutomaticFallbackSubmitter: AutomaticFallbackSubmitting {
    public init() {}

    public func submitFallback(
        work: CanonicalBookWork,
        formats: [BookRequestFormat],
        provider: BookRequestProviderKind,
        fallbackFromRequestID: String,
        history: RequestActivityStore,
        now: Date,
    ) async -> BookRequestSubmission {
        await BookRequests.submit(
            work: work,
            formats: formats,
            history: history,
            now: now,
            providerOverride: provider,
            fallbackFromRequestID: fallbackFromRequestID,
            fallbackKind: .automatic,
        )
    }
}

/// Evaluates eligible rows and submits at most one automatic hop.
///
/// Marking order:
/// 1. Policy decides eligibility.
/// 2. Persist attempt metadata on the source row (prevents double-submit after a crash).
/// 3. Submit via BookRequests with fallbackKind = automatic.
/// 4. Attach resultingRequestID on the source attempts.
///
/// Never holds the RequestActivityStore lock across network work.
public actor RequestAutomaticFallbackCoordinator {
    public static let shared = RequestAutomaticFallbackCoordinator()

    private let history: RequestActivityStore
    private let submitter: any AutomaticFallbackSubmitting
    private let settingsProvider: @Sendable () -> AutomaticFallbackSettingsSnapshot
    private let healthProvider: @Sendable () -> (Bool, Bool)
    private var inFlight: Set<String> = []

    public init(
        history: RequestActivityStore = .shared,
        submitter: any AutomaticFallbackSubmitting = BookRequestAutomaticFallbackSubmitter(),
        settings: @escaping @Sendable () -> AutomaticFallbackSettingsSnapshot = {
            RequestAutomaticFallbackSettings.current
        },
        health: @escaping @Sendable () -> (Bool, Bool) = {
            (
                ServiceHealthCache.shared.result(for: .lazyLibrarian)?.status == .unavailable,
                ServiceHealthCache.shared.result(for: .shelfarr)?.status == .unavailable
            )
        },
    ) {
        self.history = history
        self.submitter = submitter
        self.settingsProvider = settings
        self.healthProvider = health
    }

    /// Evaluate every tracked request. Safe to call from refresh / foreground / status check.
    @discardableResult
    public func evaluate(
        libraryBooks: [BookMetadata] = [],
        actionContext: RequestActivityActionContext,
        now: Date = Date(),
    ) async -> Int {
        let settings = settingsProvider()
        guard settings.enabled else { return 0 }

        // Re-check Storyteller before any automatic submit.
        _ = RequestActivityRefreshService(history: history).applyLibraryPresence(
            libraryBooks: libraryBooks,
            now: now,
        )

        let health = healthProvider()
        let items = history.allItems()
        var submitted = 0
        for item in items {
            let decision = AutomaticFallbackPolicy.decide(
                item: item,
                history: items,
                settings: settings,
                context: actionContext,
                now: now,
                unavailableLazyLibrarian: health.0,
                unavailableShelfarr: health.1,
            )
            switch decision {
                case .none, .skipUnavailable:
                    continue
                case .submit(let sourceID, let provider, let formats):
                    let key = inFlightKey(sourceID: sourceID, provider: provider, formats: formats)
                    guard !inFlight.contains(key) else { continue }
                    inFlight.insert(key)
                    defer { inFlight.remove(key) }
                    if await perform(
                        sourceID: sourceID,
                        provider: provider,
                        formats: formats,
                        now: now,
                    ) {
                        submitted += 1
                    }
            }
        }
        return submitted
    }

    private func perform(
        sourceID: String,
        provider: BookRequestProviderKind,
        formats: [BookRequestFormat],
        now: Date,
    ) async -> Bool {
        guard var source = history.item(id: sourceID) else { return false }
        // Re-read after library presence — formats may have cleared.
        let freshDecision = RequestActivityFallbackPolicy.decision(
            item: source,
            provider: provider,
            formats: formats,
            history: history.allItems(),
        )
        guard !freshDecision.formats.isEmpty else { return false }

        // Persist intent before network so a crash cannot repeat the hop.
        source = AutomaticFallbackPolicy.markAttempts(
            on: source,
            formats: freshDecision.formats,
            target: provider,
            now: now,
        )
        history.upsert(source)

        let submission = await submitter.submitFallback(
            work: source.canonicalWorkForRetry(),
            formats: freshDecision.formats,
            provider: provider,
            fallbackFromRequestID: source.id,
            history: history,
            now: now,
        )

        if let created = history.item(forWorkID: source.canonicalWorkID, provider: provider),
            let refreshed = history.item(id: sourceID)
        {
            let linked = AutomaticFallbackPolicy.attachResultingID(
                on: refreshed,
                formats: freshDecision.formats,
                target: provider,
                resultingRequestID: created.id,
            )
            history.upsert(linked)
        }

        // Count as attempted even when the provider rejected — do not hammer.
        _ = submission
        return true
    }

    private func inFlightKey(
        sourceID: String,
        provider: BookRequestProviderKind,
        formats: [BookRequestFormat],
    ) -> String {
        let formatKey = BookRequestFormat.allCases
            .filter { formats.contains($0) }
            .map(\.rawValue)
            .joined(separator: ",")
        return "\(sourceID)|\(provider.rawValue)|\(formatKey)"
    }
}
