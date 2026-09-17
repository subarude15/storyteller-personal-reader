import Foundation

/// Runs enabled adapters in priority order and merges into one `NormalizedBook`.
public struct FetcherService: Sendable {
    public var settings: AdapterSettings
    public var cache: BookCache
    public var library: PlaytorioLibraryStore
    public var http: any HTTPClient

    public init(
        settings: AdapterSettings = AdapterSettings(),
        cache: BookCache = BookCache(),
        library: PlaytorioLibraryStore = PlaytorioLibraryStore(),
        http: any HTTPClient = URLSessionHTTPClient()
    ) {
        self.settings = settings
        self.cache = cache
        self.library = library
        self.http = http
    }

    /// Adapters that would run for the current settings (enabled, sorted by priority).
    public func plannedAdapters() throws -> [AdapterConfig] {
        try settings.load()
            .filter(\.enabled)
            .sorted { $0.priority < $1.priority }
    }

    public func dryRunDescription() throws -> String {
        let planned = try plannedAdapters()
        if planned.isEmpty {
            return "dry-run: no enabled adapters"
        }
        var lines = ["dry-run: would run \(planned.count) adapter(s):"]
        for config in planned {
            lines.append("  - \(config.id) (priority \(config.priority), type \(config.type))")
        }
        return lines.joined(separator: "\n")
    }

    /// Fetch + merge. When `persist` is true, upserts into the durable Playtorio library
    /// store (visible to Explore) and refreshes the query cache.
    public func fetch(query: String, persist: Bool = true) async throws -> NormalizedBook? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let cached = cache.get(query: trimmed) {
            if persist {
                library.upsert(cached)
            }
            return cached
        }

        // Always reload settings so user CRUD changes take effect without restart.
        let planned = try plannedAdapters()
        var results: [AdapterResult] = []
        for config in planned {
            let adapter: any BookAdapter
            do {
                adapter = try makeAdapter(for: config)
            } catch is AdapterConfigurationError {
                throw AdapterConfigurationError.malformedURL
            }
            do {
                let result = try await adapter.fetch(query: trimmed)
                results.append(result)
            } catch is AdapterConfigurationError {
                throw AdapterConfigurationError.malformedURL
            }
        }

        guard let merged = BookNormalizer.merge(results) else { return nil }
        cache.set(query: trimmed, book: merged)
        if persist {
            library.upsert(merged)
        }
        return merged
    }

    /// Builds an adapter for `config`. Re-reads nothing — callers must pass the
    /// latest settings entry. Throws `AdapterConfigurationError` for bad URLs.
    public func makeAdapter(for config: AdapterConfig) throws -> any BookAdapter {
        let loweredType = config.type.lowercased()
        let loweredId = config.id.lowercased()

        switch config.id {
        case "audible-metadata":
            return AudibleAdapter(http: http)
        case "libgen-catalog":
            return LibGenAdapter(http: http)
        case "openlibrary-normalizer":
            return OpenLibraryAdapter(http: http)
        case RaveBookSearchAdapter.defaultId, "ravebook-search", "rave-book-search":
            return RaveBookSearchAdapter(http: http, config: config)
        default:
            break
        }

        if loweredId.contains("rave") || loweredType.contains("rave") {
            return RaveBookSearchAdapter(http: http, config: config)
        }

        let hasBase = !(config.config["baseURL"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        if hasBase || loweredType == "custom" || loweredType == "html" || loweredType == "user" {
            return try ConfigurableSearchAdapter(config: config, http: http)
        }

        return DisabledAdapter(config: config)
    }
}

/// Placeholder for unknown adapter ids — always returns `.none`.
struct DisabledAdapter: BookAdapter {
    let config: AdapterConfig
    func fetch(query: String) async throws -> AdapterResult { .none }
}
