import Foundation

public struct StorytellerHealthProbeResult: Equatable, Sendable {
    public var isConfigured: Bool
    public var isReachable: Bool
    public var sanitizedHost: String?
    public var lastSync: Date?
    public var errorDetail: String?

    public init(
        isConfigured: Bool,
        isReachable: Bool,
        sanitizedHost: String? = nil,
        lastSync: Date? = nil,
        errorDetail: String? = nil,
    ) {
        self.isConfigured = isConfigured
        self.isReachable = isReachable
        self.sanitizedHost = sanitizedHost
        self.lastSync = lastSync
        self.errorDetail = errorDetail
    }
}

public protocol StorytellerHealthProbing: Sendable {
    func probe(lastSyncHint: Date?) async -> StorytellerHealthProbeResult
}

/// Uses existing Storyteller auth (`canReachStorytellerForStatsSync`) — no full library sync.
public struct LiveStorytellerHealthProbe: StorytellerHealthProbing {
    public init() {}

    public func probe(lastSyncHint: Date?) async -> StorytellerHealthProbeResult {
        let configured = await BookServiceActor.shared.isConfigured
        guard configured else {
            return StorytellerHealthProbeResult(isConfigured: false, isReachable: false)
        }

        var host: String?
        if let sourceID = await BookServiceActor.shared.primaryStorytellerSourceID(),
            let credentials = await BookServiceActor.shared.credentials(for: sourceID)
        {
            host = ServiceHealthURLSanitizer.sanitize(credentials.url)
        }

        let reachable = await BookServiceActor.shared.canReachStorytellerForStatsSync()
        let lastSync =
            lastSyncHint
            ?? (UserDefaults.standard.object(
                forKey: InkampStatsSyncDefaults.lastSuccessfulSyncAtKey
            ) as? Date)

        if reachable {
            return StorytellerHealthProbeResult(
                isConfigured: true,
                isReachable: true,
                sanitizedHost: host,
                lastSync: lastSync,
            )
        }
        return StorytellerHealthProbeResult(
            isConfigured: true,
            isReachable: false,
            sanitizedHost: host,
            lastSync: lastSync,
            errorDetail: "Authentication or connection failed",
        )
    }
}

public struct StorytellerHealthChecker: ServiceHealthChecking {
    public var serviceID: ServiceHealthID { .storyteller }
    private let probe: any StorytellerHealthProbing
    /// Connected but last successful sync older than this → Warning.
    public var staleSyncInterval: TimeInterval

    public init(
        probe: any StorytellerHealthProbing = LiveStorytellerHealthProbe(),
        staleSyncInterval: TimeInterval = 8 * 3600,
    ) {
        self.probe = probe
        self.staleSyncInterval = staleSyncInterval
    }

    public func check(settings: ServiceHealthSettingsSnapshot) async -> ServiceHealthResult {
        let now = Date()
        let result = await probe.probe(lastSyncHint: settings.storytellerLastSync)

        guard result.isConfigured else {
            return ServiceHealthResult(
                serviceID: .storyteller,
                status: .disabled,
                summary: "Not configured",
                detail: "No Storyteller book source is set up",
                lastChecked: now,
                sanitizedHost: result.sanitizedHost,
                isActionableIssue: false,
            )
        }

        guard result.isReachable else {
            return ServiceHealthResult(
                serviceID: .storyteller,
                status: .unavailable,
                summary: "Could not reach Storyteller",
                detail: result.errorDetail ?? "Server did not authenticate",
                lastChecked: now,
                lastSuccess: result.lastSync,
                sanitizedHost: result.sanitizedHost,
                lastError: result.errorDetail ?? "unreachable",
                technicalDetail: "unreachable",
                suggestedAction: "Open Storyteller settings or retry connection",
            )
        }

        var metadata: [String: String] = [:]
        if let lastSync = result.lastSync {
            metadata["lastSync"] = ISO8601DateFormatter().string(from: lastSync)
            let age = now.timeIntervalSince(lastSync)
            if age >= staleSyncInterval {
                let ageLabel = ServiceHealthURLSanitizer.relativeAge(from: lastSync, now: now)
                return ServiceHealthResult(
                    serviceID: .storyteller,
                    status: .warning,
                    summary: "Connected · last sync \(ageLabel)",
                    detail: "Last successful sync was \(ageLabel)",
                    lastChecked: now,
                    lastSuccess: lastSync,
                    sanitizedHost: result.sanitizedHost,
                    metadata: metadata,
                    suggestedAction: "Open Storyteller settings or retry connection",
                )
            }
            let ageLabel = ServiceHealthURLSanitizer.relativeAge(from: lastSync, now: now)
            return ServiceHealthResult(
                serviceID: .storyteller,
                status: .healthy,
                summary: "Connected · last sync \(ageLabel)",
                detail: "Authenticated",
                lastChecked: now,
                lastSuccess: now,
                sanitizedHost: result.sanitizedHost,
                metadata: metadata,
            )
        }

        return ServiceHealthResult(
            serviceID: .storyteller,
            status: .healthy,
            summary: "Connected",
            detail: "Authenticated",
            lastChecked: now,
            lastSuccess: now,
            sanitizedHost: result.sanitizedHost,
        )
    }
}
