import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Snapshot of settings the health layer needs. Secrets stay out of the snapshot
/// except for tokens that are read only for the live probe and never cached.
public struct ServiceHealthSettingsSnapshot: Sendable {
    public var lazyLibrarianEnabled: Bool
    public var lazyLibrarianBaseURL: String
    public var lazyLibrarianAPIKey: String
    public var shelfarrBaseURL: String
    public var shelfarrAPIToken: String
    public var bookSearchLANEnabled: Bool
    public var bookSearchLANBaseURL: String
    public var storytellerLastSync: Date?

    public init(
        lazyLibrarianEnabled: Bool = false,
        lazyLibrarianBaseURL: String = "",
        lazyLibrarianAPIKey: String = "",
        shelfarrBaseURL: String = "",
        shelfarrAPIToken: String = "",
        bookSearchLANEnabled: Bool = false,
        bookSearchLANBaseURL: String = "",
        storytellerLastSync: Date? = nil,
    ) {
        self.lazyLibrarianEnabled = lazyLibrarianEnabled
        self.lazyLibrarianBaseURL = lazyLibrarianBaseURL
        self.lazyLibrarianAPIKey = lazyLibrarianAPIKey
        self.shelfarrBaseURL = shelfarrBaseURL
        self.shelfarrAPIToken = shelfarrAPIToken
        self.bookSearchLANEnabled = bookSearchLANEnabled
        self.bookSearchLANBaseURL = bookSearchLANBaseURL
        self.storytellerLastSync = storytellerLastSync
    }
}

public protocol ServiceHealthChecking: Sendable {
    var serviceID: ServiceHealthID { get }
    func check(settings: ServiceHealthSettingsSnapshot) async -> ServiceHealthResult
}

public struct ServiceHealthDiagnostics: Sendable {
    public var checkers: [any ServiceHealthChecking]
    public var loadSettings: @Sendable () async -> ServiceHealthSettingsSnapshot
    public var cache: ServiceHealthCache
    public var now: @Sendable () -> Date

    public init(
        checkers: [any ServiceHealthChecking]? = nil,
        loadSettings: (@Sendable () async -> ServiceHealthSettingsSnapshot)? = nil,
        cache: ServiceHealthCache = .shared,
        now: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.checkers = checkers ?? Self.defaultCheckers()
        self.loadSettings = loadSettings ?? Self.liveSettingsLoader
        self.cache = cache
        self.now = now
    }

    public static func defaultCheckers(
        lazyLibrarianTransport: any LazyLibrarianTransport = LiveLazyLibrarianTransport(),
        shelfarrSession: URLSession = ShelfarrClient.sharedSession,
        libriVoxFetch: @escaping @Sendable (URL) async throws -> Data = LibriVoxAudiobookProvider
            .liveFetch,
        bookSearchTransport: any BookSearchLANTransport = LiveBookSearchLANTransport(),
        storytellerProbe: any StorytellerHealthProbing = LiveStorytellerHealthProbe(),
    ) -> [any ServiceHealthChecking] {
        [
            LazyLibrarianHealthChecker(transport: lazyLibrarianTransport),
            ShelfarrHealthChecker(session: shelfarrSession),
            LibriVoxHealthChecker(fetch: libriVoxFetch),
            StorytellerHealthChecker(probe: storytellerProbe),
            BookSearchLANHealthChecker(transport: bookSearchTransport),
        ]
    }

    public static func liveSettingsLoader() async -> ServiceHealthSettingsSnapshot {
        let config = await SettingsActor.shared.config
        let apiKey = (try? await AuthenticationActor.shared.loadLazyLibrarianAPIKey()) ?? ""
        let lastSync =
            UserDefaults.standard.object(
                forKey: InkampStatsSyncDefaults.lastSuccessfulSyncAtKey
            ) as? Date
        return ServiceHealthSettingsSnapshot(
            lazyLibrarianEnabled: config.lazyLibrarianEnabled,
            lazyLibrarianBaseURL: config.lazyLibrarianBaseURL,
            lazyLibrarianAPIKey: apiKey,
            shelfarrBaseURL: config.shelfarrBaseURL,
            shelfarrAPIToken: config.shelfarrAPIToken,
            bookSearchLANEnabled: config.bookSearchLANEnabled,
            bookSearchLANBaseURL: config.bookSearchLANBaseURL,
            storytellerLastSync: lastSync,
        )
    }

    /// Runs every checker in parallel. Invokes `onUpdate` as each result lands.
    public func runAll(
        force: Bool = true,
        onUpdate: (@Sendable (ServiceHealthResult) async -> Void)? = nil,
    ) async -> [ServiceHealthResult] {
        let settings = await loadSettings()
        let cached = cache.load()
        let cachedByID = Dictionary(uniqueKeysWithValues: cached.map { ($0.serviceID, $0) })

        if !force, !cache.shouldAutoRefresh(now: now()) {
            for result in ordered(cached) {
                await onUpdate?(result)
            }
            return ordered(cached)
        }

        var placeholders: [ServiceHealthResult] = []
        for checker in checkers {
            let previous = cachedByID[checker.serviceID]
            let placeholder = ServiceHealthResult.checking(checker.serviceID, previous: previous)
            placeholders.append(placeholder)
            await onUpdate?(placeholder)
        }

        let started = now()
        debugLog(
            "[ServiceHealth] diagnostics start services=\(checkers.map(\.serviceID.rawValue).joined(separator: ","))"
        )

        var collected: [ServiceHealthID: ServiceHealthResult] = [:]
        await withTaskGroup(of: ServiceHealthResult.self) { group in
            for checker in checkers {
                group.addTask {
                    await self.runOne(checker: checker, settings: settings)
                }
            }
            for await result in group {
                collected[result.serviceID] = result
                cache.upsert(result)
                await onUpdate?(result)
            }
        }

        let results = checkers.compactMap { collected[$0.serviceID] }
        let elapsed = now().timeIntervalSince(started) * 1000
        debugLog(
            "[ServiceHealth] diagnostics end elapsed=\(String(format: "%.0f", elapsed))ms healthy=\(ServiceHealthSummary(results: results).healthy) warnings=\(ServiceHealthSummary(results: results).warnings) unavailable=\(ServiceHealthSummary(results: results).unavailable)"
        )
        cache.save(results)
        return results
    }

    public func run(
        _ serviceID: ServiceHealthID,
        onUpdate: (@Sendable (ServiceHealthResult) async -> Void)? = nil,
    ) async -> ServiceHealthResult {
        let settings = await loadSettings()
        guard let checker = checkers.first(where: { $0.serviceID == serviceID }) else {
            let missing = ServiceHealthResult(
                serviceID: serviceID,
                status: .unavailable,
                summary: "Unknown service",
                lastChecked: now(),
            )
            await onUpdate?(missing)
            return missing
        }
        let placeholder = ServiceHealthResult.checking(
            serviceID,
            previous: cache.result(for: serviceID),
        )
        await onUpdate?(placeholder)
        let result = await runOne(checker: checker, settings: settings)
        cache.upsert(result)
        await onUpdate?(result)
        return result
    }

    private func runOne(
        checker: any ServiceHealthChecking,
        settings: ServiceHealthSettingsSnapshot,
    ) async -> ServiceHealthResult {
        let start = now()
        debugLog("[ServiceHealth] check start service=\(checker.serviceID.rawValue)")
        let result = await checker.check(settings: settings)
        let elapsed = now().timeIntervalSince(start) * 1000
        let errorType = result.technicalDetail ?? result.lastError ?? "none"
        debugLog(
            "[ServiceHealth] check end service=\(checker.serviceID.rawValue) status=\(result.status.rawValue) elapsed=\(String(format: "%.0f", elapsed))ms error=\(errorType)"
        )
        return result
    }

    private func ordered(_ results: [ServiceHealthResult]) -> [ServiceHealthResult] {
        let order = ServiceHealthID.allCases
        return results.sorted {
            (order.firstIndex(of: $0.serviceID) ?? 0) < (order.firstIndex(of: $1.serviceID) ?? 0)
        }
    }
}
