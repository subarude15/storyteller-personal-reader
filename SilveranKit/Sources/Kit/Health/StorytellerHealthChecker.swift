import Foundation

public struct StorytellerHealthProbeResult: Equatable, Sendable {
    public var isConfigured: Bool
    public var isReachable: Bool
    public var sanitizedHost: String?
    public var errorDetail: String?

    public init(
        isConfigured: Bool,
        isReachable: Bool,
        sanitizedHost: String? = nil,
        errorDetail: String? = nil,
    ) {
        self.isConfigured = isConfigured
        self.isReachable = isReachable
        self.sanitizedHost = sanitizedHost
        self.errorDetail = errorDetail
    }
}

public protocol StorytellerHealthProbing: Sendable {
    func probe() async -> StorytellerHealthProbeResult
}

/// Uses existing Storyteller auth (`canReachStorytellerForStatsSync`) — no full library sync.
/// Does not use stats/podcast/YouTube sync timestamps; those are not library sync.
public struct LiveStorytellerHealthProbe: StorytellerHealthProbing {
    public init() {}

    public func probe() async -> StorytellerHealthProbeResult {
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
        if reachable {
            return StorytellerHealthProbeResult(
                isConfigured: true,
                isReachable: true,
                sanitizedHost: host,
            )
        }
        return StorytellerHealthProbeResult(
            isConfigured: true,
            isReachable: false,
            sanitizedHost: host,
            errorDetail: "Authentication or connection failed",
        )
    }
}

public struct StorytellerHealthChecker: ServiceHealthChecking {
    public var serviceID: ServiceHealthID { .storyteller }
    private let probe: any StorytellerHealthProbing

    public init(probe: any StorytellerHealthProbing = LiveStorytellerHealthProbe()) {
        self.probe = probe
    }

    public func check(settings: ServiceHealthSettingsSnapshot) async -> ServiceHealthResult {
        _ = settings
        let now = Date()
        let result = await probe.probe()

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
                sanitizedHost: result.sanitizedHost,
                lastError: result.errorDetail ?? "unreachable",
                technicalDetail: "unreachable",
                suggestedAction: "Open Storyteller settings or retry connection",
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
