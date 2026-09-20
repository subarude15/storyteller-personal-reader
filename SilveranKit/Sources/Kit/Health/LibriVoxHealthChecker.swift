import Foundation

/// LibriVox public catalog health. Harmless limit=1 probe — no library book search.
public struct LibriVoxHealthChecker: ServiceHealthChecking {
    public var serviceID: ServiceHealthID { .librivox }
    private let fetch: @Sendable (URL) async throws -> Data

    public init(
        fetch: @escaping @Sendable (URL) async throws -> Data = LibriVoxAudiobookProvider.liveFetch
    ) {
        self.fetch = fetch
    }

    /// Lightweight public catalog ping. Does not search a real library title.
    public static var healthCheckURL: URL {
        var components = URLComponents(string: "https://librivox.org/api/feed/audiobooks/")!
        components.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        return components.url!
    }

    public func check(settings: ServiceHealthSettingsSnapshot) async -> ServiceHealthResult {
        _ = settings
        let now = Date()
        let host = "https://librivox.org"
        let url = Self.healthCheckURL
        do {
            let data = try await fetch(url)
            _ = try LibriVoxAudiobookProvider.decode(data)
            return ServiceHealthResult(
                serviceID: .librivox,
                status: .healthy,
                summary: "Public catalog reachable",
                detail: "Endpoint returned valid JSON",
                lastChecked: now,
                lastSuccess: now,
                sanitizedHost: host,
            )
        } catch let error as AudiobookProviderError {
            return mapProviderError(error, host: host, now: now)
        } catch let error as URLError {
            switch error.code {
                case .timedOut:
                    return mapProviderError(.timeout, host: host, now: now)
                default:
                    return mapProviderError(.unreachable, host: host, now: now)
            }
        } catch {
            return mapProviderError(.unreachable, host: host, now: now)
        }
    }

    private func mapProviderError(
        _ error: AudiobookProviderError,
        host: String,
        now: Date,
    ) -> ServiceHealthResult {
        switch error {
            case .rateLimited:
                return ServiceHealthResult(
                    serviceID: .librivox,
                    status: .warning,
                    summary: "Rate limited",
                    detail: "LibriVox asked the app to slow down",
                    lastChecked: now,
                    sanitizedHost: host,
                    lastError: "HTTP 429",
                    technicalDetail: "rateLimited",
                    suggestedAction: "Wait a few minutes and run diagnostics again",
                )
            case .timeout:
                return ServiceHealthResult(
                    serviceID: .librivox,
                    status: .unavailable,
                    summary: "Could not reach LibriVox",
                    detail: "Timed out",
                    lastChecked: now,
                    sanitizedHost: host,
                    lastError: "Timed out",
                    technicalDetail: "URLError timedOut",
                    suggestedAction: "Check your network connection and try again",
                )
            case .unreachable:
                return ServiceHealthResult(
                    serviceID: .librivox,
                    status: .unavailable,
                    summary: "Could not reach LibriVox",
                    detail: "Catalog endpoint did not respond",
                    lastChecked: now,
                    sanitizedHost: host,
                    lastError: "Unreachable",
                    technicalDetail: "unreachable",
                    suggestedAction: "Check your network connection and try again",
                )
            case .httpStatus(let code):
                return ServiceHealthResult(
                    serviceID: .librivox,
                    status: .warning,
                    summary: "Unexpected response",
                    detail: "HTTP \(code)",
                    lastChecked: now,
                    sanitizedHost: host,
                    lastError: "HTTP \(code)",
                    technicalDetail: "HTTP \(code)",
                    suggestedAction: "Retry later; LibriVox may be having trouble",
                )
            case .undecodable:
                return ServiceHealthResult(
                    serviceID: .librivox,
                    status: .warning,
                    summary: "Unexpected response",
                    detail: "Response was not valid LibriVox JSON",
                    lastChecked: now,
                    sanitizedHost: host,
                    lastError: "Malformed response",
                    technicalDetail: "undecodable",
                    suggestedAction: "Retry later; LibriVox may be having trouble",
                )
        }
    }
}
