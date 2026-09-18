import Foundation

/// Asks the user's Shelfarr server to fetch a title. Credentials live on
/// `SilveranGlobalConfig` (Settings), not a second store.
public enum ShelfarrRequestManager {
    public static func request(_ idea: ReadingIdea, mediums: [ShelfarrMedium]) async -> Bool {
        let settings = await SettingsActor.shared.config
        let base = settings.shelfarrBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = settings.shelfarrAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !token.isEmpty, !mediums.isEmpty else { return false }
        let urlString = base.hasSuffix("/") ? base + "api/v1/requests" : base + "/api/v1/requests"
        guard let url = URL(string: urlString) else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

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
        if idea.id.hasPrefix("ol:") || idea.id.contains("/works/") {
            body["ol_work_key"] = idea.id
        }
        if let coverURL = idea.coverURL {
            body["cover_url"] = coverURL.absoluteString
        }

        let mediumStrings = mediums.map(\.rawValue)
        if mediumStrings.count == 1 {
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
                (200...299).contains(httpResponse.statusCode)
            {
                return true
            }
        } catch {
            return false
        }
        return false
    }
}

public enum ShelfarrMedium: String, CaseIterable, Sendable {
    case ebook
    case audiobook
}
