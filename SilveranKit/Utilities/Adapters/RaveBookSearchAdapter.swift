import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// High-priority adapter for https://ravebooksearch.com (Cloudflare Worker search).
///
/// Default endpoint: `{baseURL}/search/all?q=…&mode=ebooks` (no API key).
/// Optional config keys: `baseURL`, `mode`, `searchPath`, `apiKey` (for `/api/v1/search`).
public struct RaveBookSearchAdapter: BookAdapter {
    public static let defaultBaseURL = "https://ravebooksearch.cloudflare-s3cvv.workers.dev"
    public static let defaultId = "ravebooksearch"
    public static let siteURL = "https://ravebooksearch.com"

    public let config: AdapterConfig
    private let http: any HTTPClient

    public init(
        http: any HTTPClient = URLSessionHTTPClient(),
        config: AdapterConfig? = nil
    ) {
        self.config = config ?? AdapterConfig(
            id: Self.defaultId,
            name: "RaveBookSearch",
            enabled: true,
            type: "catalog",
            priority: 5,
            config: [
                "baseURL": Self.defaultBaseURL,
                "mode": "ebooks",
                "searchPath": "/search/all",
            ]
        )
        self.http = http
    }

    public func fetch(query: String) async throws -> AdapterResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        let url = try Self.buildSearchURL(query: trimmed, config: config)
        let (data, response) = try await http.get(url)
        guard (200 ... 299).contains(response.statusCode) else { return .none }

        if let book = Self.parseSearchJSON(data, adapterId: config.id) {
            return .definitive(book)
        }
        if let html = String(data: data, encoding: .utf8),
           let book = Self.parseWorkerHTML(html, adapterId: config.id)
        {
            return .definitive(book)
        }
        return .none
    }

    // MARK: - URL building

    public static func buildSearchURL(query: String, config: AdapterConfig) throws -> URL {
        let baseRaw = (config.config["baseURL"] ?? Self.defaultBaseURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseRaw.isEmpty,
              let base = URL(string: baseRaw),
              base.scheme == "http" || base.scheme == "https",
              base.host != nil
        else {
            throw AdapterConfigurationError.malformedURL
        }

        let mode = config.config["mode"] ?? "ebooks"
        let path = config.config["searchPath"] ?? "/search/all"

        if config.config["apiKey"]?.isEmpty == false {
            // Optional mirror path; callers that need the key send it via config
            // for documentation — the public Worker uses /search/all without auth.
            var components = URLComponents(
                url: base.appendingPathComponent("api/v1/search"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [URLQueryItem(name: "q", value: query)]
            guard let url = components.url else { throw AdapterConfigurationError.malformedURL }
            return url
        }

        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        let normalizedPath: String
        if path.hasPrefix("/") {
            normalizedPath = path
        } else {
            normalizedPath = "/" + path
        }
        components.path = normalizedPath
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "mode", value: mode),
        ]
        guard let url = components.url else { throw AdapterConfigurationError.malformedURL }
        return url
    }

    // MARK: - JSON

    /// Parses Worker `{ results: [ … ] }` payloads into one NormalizedBook.
    public static func parseSearchJSON(_ data: Data, adapterId: String = defaultId) -> NormalizedBook? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let rows: [[String: Any]]
        if let results = obj["results"] as? [[String: Any]] {
            rows = results
        } else if let results = obj["results"] as? [Any] {
            rows = results.compactMap { $0 as? [String: Any] }
        } else {
            return nil
        }
        guard !rows.isEmpty else { return nil }

        let primary = rows[0]
        let title = stringValue(primary["title"])
        let author = stringValue(primary["author"])
            .trimmingCharacters(in: CharacterSet(charactersIn: ",").union(.whitespaces))
        let isbn = stringValue(primary["isbn"])
        let cover = stringValue(primary["coverUrl"])

        var formats: [BookFormat] = []
        var seen = Set<String>()
        for row in rows.prefix(25) {
            for format in formatsFromRow(row) {
                if seen.insert(format.url).inserted {
                    formats.append(format)
                }
            }
        }
        guard !title.isEmpty || !formats.isEmpty else { return nil }

        return NormalizedBook(
            title: title,
            author: author,
            narrator: "",
            asin: "",
            isbn: isbn,
            duration_min: 0,
            cover_url: cover,
            sample_audio_url: "",
            formats: formats,
            metadata_sources: [adapterId]
        )
    }

    private static func formatsFromRow(_ row: [String: Any]) -> [BookFormat] {
        let format = stringValue(row["format"]).lowercased()
        let source = stringValue(row["source"]).isEmpty ? "ravebooksearch" : stringValue(row["source"])
        let sizeBytes = doubleValue(row["filesize"])
        let sizeMB = sizeBytes > 0 ? sizeBytes / 1_000_000.0 : 0
        let magnet = stringValue(row["magnet"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let fmt = format.isEmpty ? "unknown" : format

        // Magnet-first: AudiobookBay results carry a magnet + infoHash but no direct
        // file. Emit a magnet-backed format so the ingest layer can resolve it via
        // a debrid service instead of trying (and failing) to fetch an HTML page.
        if !magnet.isEmpty {
            return [BookFormat(source: source, format: fmt, url: "", size_mb: sizeMB, magnet: magnet)]
        }

        // Direct-download sources (Internet Archive et al.) expose a real file URL.
        let direct = stringValue(row["directUrl"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !direct.isEmpty {
            return [BookFormat(source: source, format: fmt, url: direct, size_mb: sizeMB)]
        }

        // Fall back to `downloadUrl` only when it looks like a direct media file
        // (recognized extension). Forum-thread / ad-wall / detail pages
        // (viewtopic.php, ads.php, /abss/…) carry no usable extension and are dropped.
        let download = stringValue(row["downloadUrl"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !download.isEmpty, looksLikeMediaFile(download) {
            return [BookFormat(source: source, format: fmt, url: download, size_mb: sizeMB)]
        }
        return []
    }

    /// True when the URL's last path component ends in a recognized ebook/audio
    /// extension (a direct file), false for pages/forums/redirects.
    private static func looksLikeMediaFile(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        let ext = url.pathExtension.lowercased()
        let mediaExtensions: Set<String> = [
            "epub", "pdf", "mobi", "azw3", "azw", "cbz", "cbr", "fb2", "txt", "html",
            "m4b", "mp3", "m4a", "aac", "ogg", "opus", "wav", "flac", "mp4", "mka",
        ]
        return mediaExtensions.contains(ext)
    }

    // MARK: - HTML (.worker-item)

    /// Parses rendered Direct-results HTML (`a.worker-item` cards).
    public static func parseWorkerHTML(_ html: String, adapterId: String = defaultId) -> NormalizedBook? {
        guard let itemRegex = try? NSRegularExpression(
            pattern: #"<a[^>]*class="[^"]*worker-item[^"]*"[^>]*>([\s\S]*?)</a>"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = itemRegex.matches(in: html, options: [], range: range)
        guard !matches.isEmpty else { return nil }

        var formats: [BookFormat] = []
        var title = ""
        var author = ""
        var isbn = ""
        var cover = ""
        var seen = Set<String>()

        for match in matches.prefix(25) {
            guard let full = Range(match.range, in: html) else { continue }
            let chunk = String(html[full])
            let href = attr(chunk, "href")?.replacingOccurrences(of: "&amp;", with: "&") ?? ""
            let format = (attr(chunk, "data-format") ?? "unknown").lowercased()
            let sizeBytes = Double(attr(chunk, "data-size") ?? "") ?? 0
            let source = attr(chunk, "data-source") ?? "ravebooksearch"
            if let t = firstMatch(chunk, pattern: #"class="[^"]*worker-title[^"]*"[^>]*>([^<]+)"#),
               title.isEmpty
            {
                title = decodeEntities(t)
            }
            if let meta = firstMatch(chunk, pattern: #"class="[^"]*worker-meta[^"]*"[^>]*>([^<]+)"#),
               author.isEmpty
            {
                let parts = meta.split(separator: "·").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let first = parts.first { author = decodeEntities(first) }
                if let isbnPart = parts.first(where: { $0.uppercased().hasPrefix("ISBN") }) {
                    isbn = isbnPart.replacingOccurrences(of: "ISBN", with: "", options: .caseInsensitive)
                        .trimmingCharacters(in: .whitespaces)
                }
            }
            if cover.isEmpty,
               let img = firstMatch(chunk, pattern: #"<img[^>]*class="[^"]*worker-cover[^"]*"[^>]*src="([^"]+)""#)
            {
                cover = decodeEntities(img)
            }
            guard !href.isEmpty, seen.insert(href).inserted else { continue }
            formats.append(
                BookFormat(
                    source: source,
                    format: format,
                    url: href,
                    size_mb: sizeBytes > 0 ? sizeBytes / 1_000_000.0 : 0
                )
            )
        }

        guard !title.isEmpty || !formats.isEmpty else { return nil }
        return NormalizedBook(
            title: title,
            author: author.trimmingCharacters(in: CharacterSet(charactersIn: ",").union(.whitespaces)),
            narrator: "",
            asin: "",
            isbn: isbn,
            duration_min: 0,
            cover_url: cover,
            sample_audio_url: "",
            formats: formats,
            metadata_sources: [adapterId]
        )
    }

    // MARK: - helpers

    private static func stringValue(_ any: Any?) -> String {
        switch any {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return ""
        }
    }

    private static func doubleValue(_ any: Any?) -> Double {
        switch any {
        case let n as Double: return n
        case let n as Int: return Double(n)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s) ?? 0
        default: return 0
        }
    }

    private static func attr(_ html: String, _ name: String) -> String? {
        firstMatch(html, pattern: #"\#(name)=["']([^"']+)["']"#)
    }

    private static func firstMatch(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[r])
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}

/// User-defined / custom search source. Validates `baseURL` and optionally
/// reuses Rave HTML/JSON parsers when `type` or id indicates ravebooksearch.
public struct ConfigurableSearchAdapter: BookAdapter {
    public let config: AdapterConfig
    private let http: any HTTPClient

    public init(config: AdapterConfig, http: any HTTPClient = URLSessionHTTPClient()) throws {
        let base = (config.config["baseURL"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty {
            throw AdapterConfigurationError.malformedURL
        }
        guard let url = URL(string: base),
              url.scheme == "http" || url.scheme == "https",
              url.host != nil
        else {
            throw AdapterConfigurationError.malformedURL
        }
        // Soft-validate config JSON map already decoded; empty is fine.
        self.config = config
        self.http = http
    }

    public func fetch(query: String) async throws -> AdapterResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        let lowered = (config.type + " " + config.id).lowercased()
        if lowered.contains("rave") {
            return try await RaveBookSearchAdapter(http: http, config: config).fetch(query: trimmed)
        }

        // Generic: GET `{baseURL}` with `q` query (or append path from searchPath).
        let url = try RaveBookSearchAdapter.buildSearchURL(query: trimmed, config: config)
        let (data, response) = try await http.get(url)
        guard (200 ... 299).contains(response.statusCode) else { return .none }

        if let book = RaveBookSearchAdapter.parseSearchJSON(data, adapterId: config.id) {
            return .definitive(book)
        }
        if let html = String(data: data, encoding: .utf8) {
            if let book = RaveBookSearchAdapter.parseWorkerHTML(html, adapterId: config.id) {
                return .definitive(book)
            }
            let formats = LibGenAdapter.parseSearchHTML(html)
            if !formats.isEmpty {
                return .enrichment(
                    formats: formats,
                    cover_url: nil,
                    sample_audio_url: nil,
                    adapterId: config.id
                )
            }
        }
        return .none
    }
}

public enum AdapterConfigurationError: Error, LocalizedError, Sendable {
    case malformedURL
    case invalidJSONConfig

    public var errorDescription: String? {
        "Source configuration error"
    }
}
