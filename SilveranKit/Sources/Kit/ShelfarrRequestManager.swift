import Foundation

/// Manages requests to Shelfarr API.
final class ShelfarrRequestManager {
    static let shared = ShelfarrRequestManager()
    private init() {}
    
    /// Sends a request to Shelfarr for the given idea and medium(s).
    /// - Parameters:
    ///   - idea: The ReadingIdea to request.
    ///   - mediums: Array of mediums to request (e.g., [.ebook], [.audiobook], or both).
    /// - Returns: True if the request was sent successfully (HTTP 2xx), false otherwise.
    func request(_ idea: ReadingIdea, mediums: [ShelfarrMedium]) async -> Bool {
        guard let settings = try? ShelfarrSettings(), settings.isConfigured,
              let url = URL(string: "\(settings.baseURL)/api/v1/requests") else {
            return false
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(settings.apiToken)", forHTTPHeaderField: "Authorization")
        
        // Build the request body according to Shelfarr's API.
        var body: [String: Any] = [
            "title": idea.title,
            "author": idea.author,
            "external_source": "inkamp",
        ]
        if let year = idea.year, year > 0 {
            body["year"] = year
        }
        if let isbn = idea.isbn, !isbn.isEmpty {
            body["isbn"] = isbn
        }
        if let workKey = idea.workKey, !workKey.isEmpty {
            body["ol_work_key"] = workKey
        }
        if let coverURL = idea.coverURL {
            body["cover_url"] = coverURL.absoluteString
        }
        
        // Medium: Shelfarr expects either a single `book_type` or an array `book_types`.
        // We'll follow the API: if both ebook and audiobook, use book_types; otherwise book_type.
        let mediumStrings = mediums.map { $0.rawValue }
        if mediums.count == 1 {
            body["book_type"] = mediumStrings[0]
        } else {
            body["book_types"] = mediumStrings
        }
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            return false
        }
        request.httpBody = jsonData
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               (200...299).contains(httpResponse.statusCode) {
                return true
            }
        } catch {
            return false
        }
        return false
    }
}

/// Mediums that can be requested from Shelfarr.
enum ShelfarrMedium: String, CaseIterable {
    case ebook = "ebook"
    case audiobook = "audiobook"
}