import Foundation

/// Runs enabled adapters in priority order and merges into one `NormalizedBook`.
public struct FetcherService: Sendable {
    public var settings: AdapterSettings
    public var cache: BookCache
    public var library: PlaytorioLibraryStore
    public var http: any HTTPClient
    /// Optional logger so the iOS layer can pipe search diagnostics into its
    /// `debugLog` stream; nil (silent) on Linux where no logging backend exists.
    public var log: (@Sendable (String) -> Void)?

    public init(
        settings: AdapterSettings = AdapterSettings(),
        cache: BookCache = BookCache(),
        library: PlaytorioLibraryStore = PlaytorioLibraryStore(),
        http: any HTTPClient = URLSessionHTTPClient(),
        log: (@Sendable (String) -> Void)? = nil
    ) {
        self.settings = settings
        self.cache = cache
        self.library = library
        self.http = http
        self.log = log
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
    /// `mode` (ebooks / audiobooks / comics) overrides the RaveBookSearch adapter's
    /// search mode for this call and scopes the cache key so a title searched as an
    /// ebook and again as an audiobook don't collide.
    public func fetch(query: String, persist: Bool = true, mode: String? = nil) async throws -> NormalizedBook? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let cacheKey = mode.map { "\(trimmed) [mode:\($0)]" } ?? trimmed
        if let cached = cache.get(query: cacheKey) {
            if persist {
                library.upsert(cached)
            }
            return cached
        }

        // Always reload settings so user CRUD changes take effect without restart.
        let planned = try plannedAdapters()
        log?("[FetcherService] fetch '\(trimmed)' mode=\(mode ?? "default") via \(planned.count) adapter(s): \(planned.map(\.id).joined(separator: ", "))")
        var results: [AdapterResult] = []
        for var config in planned {
            if let mode, Self.isModeAwareAdapter(config) {
                config.config["mode"] = mode
            }
            let adapter: any BookAdapter
            do {
                adapter = try makeAdapter(for: config)
            } catch {
                // A malformed adapter is not fatal — skip it and keep the search alive.
                log?("[FetcherService] adapter \(config.id) failed to build: \(error.localizedDescription)")
                continue
            }
            do {
                let result = try await adapter.fetch(query: trimmed)
                results.append(result)
                log?("[FetcherService] adapter \(config.id) -> \(result.summary)")
            } catch {
                // A dead or slow backend (timeout, network drop, malformed response)
                // must never abort the whole search: other adapters may still return
                // usable results, so treat this one as "no result" and continue.
                log?("[FetcherService] adapter \(config.id) failed: \(error.localizedDescription)")
                continue
            }
        }

        guard var merged = BookNormalizer.merge(results) else { return nil }
        // LibGen/OpenLibrary-style providers can return enrichment-only results
        // (formats / cover, but no definitive identity). Without a title fallback
        // those rows persist as "Untitled", so Explore immediately hides them when
        // the user searches for the title they just entered.
        if merged.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            merged.title = trimmed
        }
        cache.set(query: cacheKey, book: merged)
        if persist {
            library.upsert(merged)
        }
        return merged
    }

    /// Adapters that understand a search `mode` override (currently RaveBookSearch).
    /// Matches by id/type so user-added Rave-style sources also honor the mode.
    private static func isModeAwareAdapter(_ config: AdapterConfig) -> Bool {
        let loweredId = config.id.lowercased()
        let loweredType = config.type.lowercased()
        return config.id == RaveBookSearchAdapter.defaultId
            || loweredId == "ravebook-search"
            || loweredId == "rave-book-search"
            || loweredId.contains("rave")
            || loweredType.contains("rave")
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
