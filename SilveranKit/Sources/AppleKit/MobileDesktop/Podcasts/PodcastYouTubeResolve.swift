//
//  PodcastYouTubeResolve.swift
//  SilveranAppleKit
//
//  Resolve a YouTube video id to an AVPlayer URL via a configurable
//  Invidious / Piped-style base URL (Settings), matching the Ad strip URL pattern.
//  Soft timeout so resolve never hangs forever. No official YouTube SDK.
//
//  SPDX-License-Identifier: AGPL-3.0-only

#if os(iOS)
import Foundation
import SilveranKit

/// Errors from the YouTube in-app resolve path.
public enum PodcastYouTubeResolveError: Error, LocalizedError, Sendable {
    case missingURL
    case missingVideoID
    case unreachable(String)
    case noStream
    case timedOut
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
            case .missingURL:
                return "YouTube resolve URL not set"
            case .missingVideoID:
                return "Couldn't read YouTube video id"
            case .unreachable(let detail):
                return "YouTube resolve unreachable (\(detail))"
            case .noStream:
                return "No playable stream from resolve"
            case .timedOut:
                return "YouTube resolve timed out"
            case .badResponse(let detail):
                return "YouTube resolve bad response (\(detail))"
        }
    }
}

/// UserDefaults + reachability for Settings → YouTube resolve URL.
@MainActor
public enum PodcastYouTubeResolveSettings {
    public static let urlDefaultsKey = "punkRally.youtubeResolveURL.v1"
    public static let lastReachableAtKey = "punkRally.youtubeResolveLastReachableAt.v1"
    public static let lastReachErrorKey = "punkRally.youtubeResolveLastReachError.v1"

    /// Prefill for PrincessDonut LAN Invidious (Josh can edit).
    public static let defaultURLString = "http://192.168.1.2:20130"

    public static var urlString: String {
        get {
            let stored = UserDefaults.standard.string(forKey: urlDefaultsKey)
            if let stored { return stored }
            return defaultURLString
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed, forKey: urlDefaultsKey)
        }
    }

    public static var baseURL: URL? {
        let raw = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    public static var lastReachableAt: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: lastReachableAtKey)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: lastReachableAtKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastReachableAtKey)
            }
        }
    }

    public static var lastReachError: String? {
        get { UserDefaults.standard.string(forKey: lastReachErrorKey) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: lastReachErrorKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastReachErrorKey)
            }
        }
    }

    public static func clearOfflineState() {
        lastReachError = nil
        lastReachableAt = Date()
    }

    public static func markUnreachable(_ message: String) {
        lastReachError = message
    }
}

/// HTTP client: Invidious `/api/v1/videos/:id` (preferred), Piped `/streams/:id` fallback.
public struct PodcastYouTubeResolver: Sendable {
    public static let shared = PodcastYouTubeResolver()

    /// Soft overall ceiling so Resolving… never hangs (ad-strip-like 12–30s).
    public var overallTimeoutSeconds: TimeInterval
    public var requestTimeoutSeconds: TimeInterval

    public init(
        overallTimeoutSeconds: TimeInterval = 20,
        requestTimeoutSeconds: TimeInterval = 12
    ) {
        self.overallTimeoutSeconds = overallTimeoutSeconds
        self.requestTimeoutSeconds = requestTimeoutSeconds
    }

    /// Resolve a watch/share URL to a progressive or HLS media URL for AVPlayer.
    public func resolve(watchURL: URL) async throws -> PodcastYouTubeStreamPick {
        guard let videoID = PodcastYouTubeURL.videoID(from: watchURL) else {
            throw PodcastYouTubeResolveError.missingVideoID
        }
        return try await resolve(videoID: videoID)
    }

    public func resolve(videoID: String) async throws -> PodcastYouTubeStreamPick {
        guard let base = await MainActor.run(body: { PodcastYouTubeResolveSettings.baseURL }) else {
            throw PodcastYouTubeResolveError.missingURL
        }
        return try await Self.withTimeout(seconds: overallTimeoutSeconds) {
            try await self.resolveAgainstBase(base: base, videoID: videoID)
        }
    }

    /// Invidious search for Match on YouTube. Soft timeout; empty array = no matches.
    public func search(query: String, limit: Int = 5) async throws -> [PodcastYouTubeSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard let base = await MainActor.run(body: { PodcastYouTubeResolveSettings.baseURL }) else {
            throw PodcastYouTubeResolveError.missingURL
        }
        return try await Self.withTimeout(seconds: overallTimeoutSeconds) {
            try await self.searchAgainstBase(base: base, query: trimmed, limit: limit)
        }
    }

    /// Settings Test: GET `/api/v1/stats` (Invidious) or `/health` (thin NAS).
    public func testReachability(baseURL: URL) async -> Result<String, PodcastYouTubeResolveError> {
        let candidates = ["api/v1/stats", "health"].compactMap { Self.endpoint(baseURL, $0) }
        guard !candidates.isEmpty else {
            return .failure(.badResponse("test URL"))
        }
        var lastError: PodcastYouTubeResolveError = .unreachable("no endpoint")
        for url in candidates {
            do {
                let data = try await Self.withTimeout(seconds: min(requestTimeoutSeconds, 8)) {
                    try await self.getJSON(url: url, timeout: 8)
                }
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let software = obj["software"] as? [String: Any],
                        (software["name"] as? String)?.lowercased() == "invidious"
                    {
                        return .success("Invidious")
                    }
                    if let ok = obj["ok"] as? Bool, ok {
                        return .success("Reachable")
                    }
                }
                return .success("Reachable")
            } catch let err as PodcastYouTubeResolveError {
                lastError = err
            } catch {
                lastError = .unreachable(error.localizedDescription)
            }
        }
        return .failure(lastError)
    }

    // MARK: - Search

    private func searchAgainstBase(
        base: URL,
        query: String,
        limit: Int
    ) async throws -> [PodcastYouTubeSearchResult] {
        var components = URLComponents(
            url: Self.endpoint(base, "api/v1/search") ?? base.appendingPathComponent("api/v1/search"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "video"),
        ]
        guard let url = components?.url else {
            throw PodcastYouTubeResolveError.badResponse("search URL")
        }
        do {
            let data = try await getJSON(url: url, timeout: requestTimeoutSeconds)
            await MainActor.run { PodcastYouTubeResolveSettings.clearOfflineState() }
            return PodcastYouTubeSearchPicker.pick(from: data, limit: limit)
        } catch let err as PodcastYouTubeResolveError {
            await MainActor.run {
                PodcastYouTubeResolveSettings.markUnreachable(err.errorDescription ?? "failed")
            }
            throw err
        }
    }

    // MARK: - Resolve

    private func resolveAgainstBase(base: URL, videoID: String) async throws -> PodcastYouTubeStreamPick {
        // Try Invidious first, then Piped.
        let paths = [
            "api/v1/videos/\(videoID)",
            "streams/\(videoID)",
            "v1/resolve?v=\(videoID)",
        ]
        var lastError: PodcastYouTubeResolveError = .noStream
        for path in paths {
            guard let url = Self.endpoint(base, path) else { continue }
            do {
                let data = try await getJSON(url: url, timeout: requestTimeoutSeconds)
                if let pick = PodcastYouTubeStreamPicker.pick(from: data, baseURL: base) {
                    await MainActor.run { PodcastYouTubeResolveSettings.clearOfflineState() }
                    return pick
                }
                lastError = .noStream
            } catch let err as PodcastYouTubeResolveError {
                lastError = err
            }
        }
        await MainActor.run {
            PodcastYouTubeResolveSettings.markUnreachable(lastError.errorDescription ?? "failed")
        }
        throw lastError
    }

    private func getJSON(url: URL, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("ink-amp/1.0 (YouTube resolve)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw PodcastYouTubeResolveError.badResponse("no HTTP response")
            }
            guard (200...299).contains(http.statusCode) else {
                let detail = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                throw PodcastYouTubeResolveError.unreachable(String(detail.prefix(120)))
            }
            return data
        } catch let err as PodcastYouTubeResolveError {
            throw err
        } catch {
            throw PodcastYouTubeResolveError.unreachable(error.localizedDescription)
        }
    }

    /// Join path (may include query) without percent-encoding `/` or `?`.
    static func endpoint(_ base: URL, _ path: String) -> URL? {
        let trimmedBase = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(trimmedBase)/\(trimmedPath)")
    }

    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw PodcastYouTubeResolveError.timedOut
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else {
                throw PodcastYouTubeResolveError.timedOut
            }
            return value
        }
    }
}
#endif
