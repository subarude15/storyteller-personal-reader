import Foundation

/// Persists non-sensitive last-result metadata for the Services & Health screen.
public struct ServiceHealthCache: @unchecked Sendable {
    // UserDefaults is thread-safe. Linux's SDK does not mark it Sendable.
    public static let shared = ServiceHealthCache()
    public static let cacheAgeLimit: TimeInterval = 5 * 60

    private let defaults: UserDefaults
    private let key = "punkRally.serviceHealth.results.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [ServiceHealthResult] {
        guard let data = defaults.data(forKey: key) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ServiceHealthResult].self, from: data)) ?? []
    }

    public func save(_ results: [ServiceHealthResult]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(results) else { return }
        defaults.set(data, forKey: key)
    }

    public func result(for id: ServiceHealthID) -> ServiceHealthResult? {
        load().first { $0.serviceID == id }
    }

    public func upsert(_ result: ServiceHealthResult) {
        var all = load()
        if let index = all.firstIndex(where: { $0.serviceID == result.serviceID }) {
            all[index] = result
        } else {
            all.append(result)
        }
        // Keep a stable dashboard order.
        let order = ServiceHealthID.allCases
        all.sort {
            (order.firstIndex(of: $0.serviceID) ?? 0) < (order.firstIndex(of: $1.serviceID) ?? 0)
        }
        save(all)
    }

    public func isFresh(_ result: ServiceHealthResult, now: Date = Date()) -> Bool {
        guard let checked = result.lastChecked else { return false }
        return now.timeIntervalSince(checked) < Self.cacheAgeLimit
    }

    public func shouldAutoRefresh(now: Date = Date()) -> Bool {
        let results = load()
        guard !results.isEmpty else { return true }
        guard let oldest = results.compactMap(\.lastChecked).min() else { return true }
        return now.timeIntervalSince(oldest) >= Self.cacheAgeLimit
    }
}
