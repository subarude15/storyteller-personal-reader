//
//  PodcastAdStripPipeline.swift
//  SilveranAppleKit
//
//  Clean-path ad strip: upload Original to NAS worker (AD_STRIP_URL), poll job,
//  write Clean sibling. Never deletes Original. Stub remains for offline UI smoke
//  when explicitly selected (tests); production uses PodcastAdStripHTTPPipeline.
//
//  SPDX-License-Identifier: AGPL-3.0-only

#if os(iOS)
import Foundation
import SilveranKit

/// Produces a Clean sibling from an on-disk Original podcast file.
public protocol PodcastAdStripPipeline: Sendable {
    /// Write Clean audio at `cleanURL` from `originalURL`. Must not delete Original.
    func produceCleanCopy(originalURL: URL, cleanURL: URL) async throws
}

/// Stub: byte-copy Original → Clean after a short delay (UI smoke / tests only).
public struct StubPodcastAdStripPipeline: PodcastAdStripPipeline {
    public static let shared = StubPodcastAdStripPipeline()

    /// Artificial delay so the Cleaning… chip is visible in smoke tests.
    public var delaySeconds: TimeInterval

    public init(delaySeconds: TimeInterval = 1.2) {
        self.delaySeconds = delaySeconds
    }

    public func produceCleanCopy(originalURL: URL, cleanURL: URL) async throws {
        if delaySeconds > 0 {
            try await Task.sleep(for: .seconds(delaySeconds))
        }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: cleanURL.path) {
            try FileManager.default.removeItem(at: cleanURL)
        }
        try FileManager.default.copyItem(at: originalURL, to: cleanURL)
    }
}

/// Errors from the NAS ad-strip worker path.
public enum PodcastAdStripError: Error, LocalizedError, Sendable {
    case missingURL
    case unreachable(String)
    case jobFailed(String)
    case timedOut
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
            case .missingURL:
                return "Ad strip URL not set"
            case .unreachable(let detail):
                return "Ad strip worker unreachable (\(detail))"
            case .jobFailed(let detail):
                return detail
            case .timedOut:
                return "Ad strip timed out"
            case .badResponse(let detail):
                return "Ad strip bad response (\(detail))"
        }
    }
}

/// UserDefaults + reachability for Settings → Ad strip URL.
@MainActor
public enum PodcastAdStripSettings {
    public static let urlDefaultsKey = "punkRally.adStripURL.v1"
    public static let lastReachableAtKey = "punkRally.adStripLastReachableAt.v1"
    public static let lastReachErrorKey = "punkRally.adStripLastReachError.v1"

    /// Prefill for PrincessDonut LAN (Josh can edit).
    public static let defaultURLString = "http://192.168.1.2:20129"

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

    /// Clear offline / last-error state after a successful Test.
    public static func clearOfflineState() {
        lastReachError = nil
        lastReachableAt = Date()
    }

    public static func markUnreachable(_ message: String) {
        lastReachError = message
    }
}

/// HTTP client for the PrincessDonut ad-strip worker (`docs/AD_STRIP.md`).
public struct PodcastAdStripHTTPPipeline: PodcastAdStripPipeline {
    public static let shared = PodcastAdStripHTTPPipeline()

    /// Soft overall ceiling so Cleaning… never hangs forever.
    public var overallTimeoutSeconds: TimeInterval
    /// Per-request timeout (upload uses a longer session timeout).
    public var requestTimeoutSeconds: TimeInterval
    public var pollIntervalSeconds: TimeInterval

    public init(
        overallTimeoutSeconds: TimeInterval = 180,
        requestTimeoutSeconds: TimeInterval = 12,
        pollIntervalSeconds: TimeInterval = 1.5
    ) {
        self.overallTimeoutSeconds = overallTimeoutSeconds
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.pollIntervalSeconds = pollIntervalSeconds
    }

    public func produceCleanCopy(originalURL: URL, cleanURL: URL) async throws {
        guard let base = await MainActor.run(body: { PodcastAdStripSettings.baseURL }) else {
            throw PodcastAdStripError.missingURL
        }

        try await Self.withTimeout(seconds: overallTimeoutSeconds) {
            try await self.runJob(base: base, originalURL: originalURL, cleanURL: cleanURL)
        }
    }

    /// Settings Test: GET /health with a short timeout.
    public func testReachability(baseURL: URL) async -> Result<String, PodcastAdStripError> {
        guard let healthURL = Self.endpoint(baseURL, "health") else {
            return .failure(.badResponse("health URL"))
        }
        do {
            let data = try await Self.withTimeout(seconds: min(requestTimeoutSeconds, 8)) {
                try await self.getJSON(url: healthURL, timeout: 8)
            }
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let ok = obj["ok"] as? Bool
            {
                return ok
                    ? .success("Reachable")
                    : .failure(.badResponse("health ok=false"))
            }
            return .success("Reachable")
        } catch let err as PodcastAdStripError {
            return .failure(err)
        } catch {
            return .failure(.unreachable(error.localizedDescription))
        }
    }

    // MARK: - Job flow

    private func runJob(base: URL, originalURL: URL, cleanURL: URL) async throws {
        let jobID = try await createJob(base: base, originalURL: originalURL)
        try await pollUntilReady(base: base, jobID: jobID)
        try await downloadAudio(base: base, jobID: jobID, cleanURL: cleanURL)
    }

    private func createJob(base: URL, originalURL: URL) async throws -> String {
        guard let url = Self.endpoint(base, "v1/jobs") else {
            throw PodcastAdStripError.badResponse("jobs URL")
        }
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.timeoutInterval = max(requestTimeoutSeconds, 60)

        let filename = originalURL.lastPathComponent.isEmpty
            ? "audio.mp3"
            : originalURL.lastPathComponent
        let fileData = try Data(contentsOf: originalURL)
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PodcastAdStripError.badResponse("no HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw PodcastAdStripError.unreachable(detail)
        }
        guard
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = obj["id"] as? String,
            !id.isEmpty
        else {
            throw PodcastAdStripError.badResponse("missing job id")
        }
        return id
    }

    private func pollUntilReady(base: URL, jobID: String) async throws {
        guard let statusURL = Self.endpoint(base, "v1/jobs/\(jobID)") else {
            throw PodcastAdStripError.badResponse("job status URL")
        }
        while true {
            try Task.checkCancellation()
            let data = try await getJSON(url: statusURL, timeout: requestTimeoutSeconds)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let status = obj["status"] as? String
            else {
                throw PodcastAdStripError.badResponse("job status")
            }
            switch status {
                case "queued", "processing":
                    try await Task.sleep(for: .seconds(pollIntervalSeconds))
                case "done":
                    return
                case "failed":
                    let err = (obj["error"] as? String) ?? "worker failed"
                    throw PodcastAdStripError.jobFailed(err)
                default:
                    throw PodcastAdStripError.badResponse("unknown status \(status)")
            }
        }
    }

    private func downloadAudio(base: URL, jobID: String, cleanURL: URL) async throws {
        guard let audioURL = Self.endpoint(base, "v1/jobs/\(jobID)/audio") else {
            throw PodcastAdStripError.badResponse("audio URL")
        }        var request = URLRequest(url: audioURL)
        request.timeoutInterval = max(requestTimeoutSeconds, 60)
        let (tempURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw PodcastAdStripError.badResponse("audio download")
        }
        if FileManager.default.fileExists(atPath: cleanURL.path) {
            try FileManager.default.removeItem(at: cleanURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: cleanURL)
    }

    private func getJSON(url: URL, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw PodcastAdStripError.badResponse("no HTTP response")
            }
            guard (200...299).contains(http.statusCode) else {
                let detail = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                throw PodcastAdStripError.unreachable(detail)
            }
            return data
        } catch let err as PodcastAdStripError {
            throw err
        } catch {
            throw PodcastAdStripError.unreachable(error.localizedDescription)
        }
    }

    /// Join path segments without percent-encoding `/` (unlike `URL.appending(path:)`).
    static func endpoint(_ base: URL, _ path: String) -> URL? {
        let trimmedBase = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(trimmedBase)/\(trimmedPath)")
    }

    /// Soft timeout: first finisher wins; sleep path throws `.timedOut`.
    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw PodcastAdStripError.timedOut
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else {
                throw PodcastAdStripError.timedOut
            }
            return value
        }
    }
}
#endif
