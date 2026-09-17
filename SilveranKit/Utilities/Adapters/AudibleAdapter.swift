// AudibleAdapter — public Audible product-page metadata fetch.
// HTML extraction uses NSRegularExpression (not SwiftSoup) so Wave 1 stays
// dependency-free on Linux; fixtures are small enough for regex to be reliable.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol HTTPClient: Sendable {
    func get(_ url: URL) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    public func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// Process-lifetime robots.txt cache + inter-request delay for Audible fetches.
actor AudibleRequestGate {
    static let shared = AudibleRequestGate()

    private var lastRequestAt: Date?
    private var robotsByHost: [String: RobotsRules] = [:]

    func allow(path: String, host: String, fetchRobots: () async throws -> Data) async throws -> Bool {
        let rules: RobotsRules
        if let cached = robotsByHost[host] {
            rules = cached
        } else {
            try await throttle()
            let data = try await fetchRobots()
            let parsed = RobotsRules(robotsTxt: String(data: data, encoding: .utf8) ?? "")
            robotsByHost[host] = parsed
            rules = parsed
        }
        return rules.allows(path: path)
    }

    func throttle() async throws {
        if let last = lastRequestAt {
            let elapsed = Date().timeIntervalSince(last)
            let remaining = 1.0 - elapsed
            if remaining > 0 {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }
        lastRequestAt = Date()
    }
}

struct RobotsRules: Sendable {
    /// Disallow prefixes for User-agent: * (and bare rules when no UA section matched).
    private let disallows: [String]

    init(robotsTxt: String) {
        var starDisallows: [String] = []
        var currentIsStar = false
        var seenStar = false

        for rawLine in robotsTxt.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let lower = line.lowercased()
            if lower.hasPrefix("user-agent:") {
                let agent = String(line.dropFirst("user-agent:".count)).trimmingCharacters(in: .whitespaces)
                currentIsStar = (agent == "*")
                if currentIsStar { seenStar = true }
                continue
            }
            if currentIsStar, lower.hasPrefix("disallow:") {
                let path = String(line.dropFirst("disallow:".count)).trimmingCharacters(in: .whitespaces)
                starDisallows.append(path)
            }
        }

        // If no User-agent sections, treat top-level Disallow as applying to *
        if !seenStar {
            for rawLine in robotsTxt.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                let lower = line.lowercased()
                if lower.hasPrefix("disallow:") {
                    let path = String(line.dropFirst("disallow:".count)).trimmingCharacters(in: .whitespaces)
                    starDisallows.append(path)
                }
            }
        }
        self.disallows = starDisallows
    }

    func allows(path: String) -> Bool {
        for rule in disallows {
            if rule.isEmpty { continue } // Disallow: with empty path = allow all
            if path.hasPrefix(rule) { return false }
        }
        return true
    }
}

public struct AudibleAdapter: BookAdapter {
    public let config: AdapterConfig
    private let http: any HTTPClient

    public init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.config = AdapterConfig(
            id: "audible-metadata",
            name: "Audible Metadata",
            enabled: true,
            type: "metadata",
            priority: 10,
            config: [:]
        )
        self.http = http
    }

    public func fetch(query: String) async throws -> AdapterResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        // Query may be an ASIN or a full Audible product URL.
        let productURL: URL
        if let asURL = URL(string: trimmed), asURL.host != nil {
            productURL = asURL
        } else {
            let asin = trimmed.uppercased()
            guard let url = URL(string: "https://www.audible.com/pd/\(asin)") else {
                return .none
            }
            productURL = url
        }

        guard let host = productURL.host else { return .none }
        let path = productURL.path.isEmpty ? "/" : productURL.path
        let gate = AudibleRequestGate.shared

        let allowed = try await gate.allow(path: path, host: host) {
            let robotsURL = URL(string: "https://\(host)/robots.txt")!
            let (data, response) = try await self.http.get(robotsURL)
            guard (200 ... 299).contains(response.statusCode) else {
                return Data("User-agent: *\nDisallow:\n".utf8)
            }
            return data
        }
        guard allowed else { return .none }

        try await gate.throttle()
        let (data, response) = try await http.get(productURL)
        guard (200 ... 299).contains(response.statusCode),
              let html = String(data: data, encoding: .utf8)
        else {
            return .none
        }

        guard let book = Self.parseProductHTML(html, fallbackASIN: Self.asinFromURL(productURL)) else {
            return .none
        }
        return .definitive(book)
    }

    static func asinFromURL(_ url: URL) -> String? {
        // /pd/Title/B00EMXBDMA or /pd/B00EMXBDMA
        let parts = url.path.split(separator: "/").map(String.init)
        for part in parts.reversed() {
            if part.range(of: #"^B[0-9A-Z]{9}$"#, options: .regularExpression) != nil {
                return part
            }
        }
        return nil
    }

    static func parseProductHTML(_ html: String, fallbackASIN: String?) -> NormalizedBook? {
        let asin =
            firstMatch(html, pattern: #"data-asin=["']([B][0-9A-Z]{9})["']"#)
            ?? firstMatch(html, pattern: #"asin["']?\s*[:=]\s*["']([B][0-9A-Z]{9})["']"#)
            ?? fallbackASIN
        guard let asin, !asin.isEmpty else { return nil }

        let title =
            firstMatch(html, pattern: #"<meta\s+property=["']og:title["']\s+content=["']([^"']+)["']"#)
            ?? firstMatch(html, pattern: #"data-title=["']([^"']+)["']"#)
            ?? ""
        let author =
            firstMatch(html, pattern: #"data-author=["']([^"']+)["']"#)
            ?? firstMatch(html, pattern: #"<meta\s+name=["']author["']\s+content=["']([^"']+)["']"#)
            ?? ""
        let narrator =
            firstMatch(html, pattern: #"data-narrator=["']([^"']+)["']"#)
            ?? ""
        let durationMin = Int(firstMatch(html, pattern: #"data-duration-min=["'](\d+)["']"#) ?? "") ?? 0

        let cover =
            firstMatch(html, pattern: #"<meta\s+property=["']og:image["']\s+content=["']([^"']+)["']"#)
            ?? firstMatch(html, pattern: #"data-cover-url=["']([^"']+)["']"#)
            ?? ""
        let sample =
            firstMatch(html, pattern: #"data-sample-url=["']([^"']+)["']"#)
            ?? firstMatch(html, pattern: #"(https://[^"' ]+\.mp3)"#)
            ?? ""
        // Public review summary kept for parse completeness (not a NormalizedBook field).
        _ = firstMatch(html, pattern: #"data-review-summary=["']([^"']+)["']"#)

        return NormalizedBook(
            title: title,
            author: author,
            narrator: narrator,
            asin: asin,
            isbn: "",
            duration_min: durationMin,
            cover_url: cover,
            sample_audio_url: sample,
            formats: [],
            metadata_sources: ["audible-metadata"]
        )
    }

    private static func firstMatch(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[r])
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
