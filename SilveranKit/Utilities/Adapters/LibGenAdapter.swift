import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct LibGenAdapter: BookAdapter {
    public let config: AdapterConfig
    private let http: any HTTPClient

    public init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.config = AdapterConfig(
            id: "libgen-catalog",
            name: "LibGen Catalog",
            enabled: true,
            type: "catalog",
            priority: 20,
            config: [:]
        )
        self.http = http
    }

    public func fetch(query: String) async throws -> AdapterResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        var components = URLComponents(string: "https://libgen.is/search.php")!
        components.queryItems = [
            URLQueryItem(name: "req", value: trimmed),
            URLQueryItem(name: "lg_topic", value: "libgen"),
            URLQueryItem(name: "open", value: "0"),
            URLQueryItem(name: "view", value: "simple"),
        ]
        guard let url = components.url else { return .none }

        let (data, response) = try await http.get(url)
        guard (200 ... 299).contains(response.statusCode),
              let html = String(data: data, encoding: .utf8)
        else {
            return .none
        }

        let formats = Self.parseSearchHTML(html)
        guard !formats.isEmpty else { return .none }
        return .enrichment(
            formats: formats,
            cover_url: nil,
            sample_audio_url: nil,
            adapterId: config.id
        )
    }

    /// Parses rows marked with data-libgen-format / data-libgen-url / data-libgen-size-mb.
    static func parseSearchHTML(_ html: String) -> [BookFormat] {
        guard let regex = try? NSRegularExpression(
            pattern: #"data-libgen-format=["']([^"']+)["'][^>]*data-libgen-url=["']([^"']+)["'][^>]*data-libgen-size-mb=["']([^"']+)["']"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, options: [], range: range)
        var formats: [BookFormat] = []
        for match in matches {
            guard match.numberOfRanges == 4,
                  let fr = Range(match.range(at: 1), in: html),
                  let ur = Range(match.range(at: 2), in: html),
                  let sr = Range(match.range(at: 3), in: html)
            else { continue }
            let format = String(html[fr])
            let url = String(html[ur]).replacingOccurrences(of: "&amp;", with: "&")
            let size = Double(String(html[sr])) ?? 0
            formats.append(
                BookFormat(source: "libgen", format: format, url: url, size_mb: size)
            )
        }
        return formats
    }
}
