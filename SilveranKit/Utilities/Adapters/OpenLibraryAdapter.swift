import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct OpenLibraryAdapter: BookAdapter {
    public let config: AdapterConfig
    private let http: any HTTPClient

    public init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.config = AdapterConfig(
            id: "openlibrary-normalizer",
            name: "OpenLibrary Normalizer",
            enabled: true,
            type: "normalizer",
            priority: 30,
            config: [:]
        )
        self.http = http
    }

    public func fetch(query: String) async throws -> AdapterResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        // Prefer ISBN endpoint when the query looks like an ISBN; otherwise search.
        let digits = trimmed.filter { $0.isNumber || $0 == "X" || $0 == "x" }
        let url: URL
        if digits.count == 10 || digits.count == 13,
           let isbnURL = URL(string: "https://openlibrary.org/isbn/\(digits).json")
        {
            url = isbnURL
        } else if let searchURL = URL(
            string: "https://openlibrary.org/search.json?q=\(trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed)&limit=1"
        ) {
            url = searchURL
        } else {
            return .none
        }

        let (data, response) = try await http.get(url)
        guard (200 ... 299).contains(response.statusCode) else { return .none }

        let cover = Self.parseCoverURL(from: data)
        return .enrichment(
            formats: [],
            cover_url: cover,
            sample_audio_url: nil,
            adapterId: config.id
        )
    }

    /// Resolves a cover URL from OpenLibrary ISBN JSON or search.json payloads.
    static func parseCoverURL(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }

        if let dict = obj as? [String: Any] {
            // ISBN / edition document: {"covers":[123], "works":[{"key":"/works/OL..."}]}
            if let covers = dict["covers"] as? [Int], let first = covers.first {
                return "https://covers.openlibrary.org/b/id/\(first)-L.jpg"
            }
            if let coverI = dict["cover_i"] as? Int {
                return "https://covers.openlibrary.org/b/id/\(coverI)-L.jpg"
            }
            // search.json shape
            if let docs = dict["docs"] as? [[String: Any]], let first = docs.first {
                if let coverI = first["cover_i"] as? Int {
                    return "https://covers.openlibrary.org/b/id/\(coverI)-L.jpg"
                }
                if let isbn = (first["isbn"] as? [String])?.first {
                    return "https://covers.openlibrary.org/b/isbn/\(isbn)-L.jpg"
                }
            }
        }
        return nil
    }
}
