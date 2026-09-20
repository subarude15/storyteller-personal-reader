import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// LazyLibrarian HTTP API: /api?apikey=&cmd=
// BookIDs come from findBook/addBook. Open Library IDs are not assumed to be those IDs.
// addBookByISBN is not used: it inserts the highest fuzz hit without our match check.

public enum LazyLibrarianConnection: Equatable, Sendable {
    case ok
    case cannotReachServer
    case unauthorized
    case invalidResponse
    case timeout

    public var message: String {
        switch self {
            case .ok: "Connected"
            case .cannotReachServer: "Cannot reach server"
            case .unauthorized: "Unauthorized / invalid API key"
            case .invalidResponse: "Invalid server response"
            case .timeout: "Timed out"
        }
    }
}

public struct LazyLibrarianHTTP: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public protocol LazyLibrarianTransport: Sendable {
    func send(_ url: URL, timeout: TimeInterval) async throws -> LazyLibrarianHTTP
}

public struct LiveLazyLibrarianTransport: LazyLibrarianTransport {
    public init() {}

    public func send(_ url: URL, timeout: TimeInterval) async throws -> LazyLibrarianHTTP {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("inkamp/lazylibrarian", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return LazyLibrarianHTTP(status: status, body: data)
    }
}

public enum LazyLibrarianEndpoint {
    public static func url(
        base: String,
        apiKey: String,
        command: String,
        parameters: [String: String] = [:],
    ) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard var components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            components.host?.isEmpty == false
        else { return nil }
        if components.path.isEmpty || components.path == "/" {
            components.path = "/api"
        } else if !components.path.hasSuffix("/api") {
            components.path += "/api"
        }
        var items = [
            URLQueryItem(name: "apikey", value: apiKey),
            URLQueryItem(name: "cmd", value: command),
        ]
        for key in parameters.keys.sorted() {
            items.append(URLQueryItem(name: key, value: parameters[key]))
        }
        components.queryItems = items
        return components.url
    }

    public static func redact(_ text: String, apiKey: String) -> String {
        var result = text
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 4 {
            result = result.replacingOccurrences(of: trimmed, with: "••••")
            if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                encoded != trimmed
            {
                result = result.replacingOccurrences(of: encoded, with: "••••")
            }
        }
        guard let regex = try? NSRegularExpression(pattern: "apikey=[^&\\s]+", options: [.caseInsensitive])
        else { return result }
        let range = NSRange(result.startIndex..., in: result)
        return regex.stringByReplacingMatches(in: result, range: range, withTemplate: "apikey=••••")
    }
}

public struct LazyLibrarianCandidate: Equatable, Sendable {
    public var bookID: String
    public var title: String
    public var author: String
    public var isbn: String?
    public var year: String?

    public init(bookID: String, title: String, author: String, isbn: String?, year: String?) {
        self.bookID = bookID
        self.title = title
        self.author = author
        self.isbn = isbn
        self.year = year
    }
}

public enum LazyLibrarianMatchFailure: Error, Equatable, Sendable {
    case noMatch
    case ambiguous
}

public enum LazyLibrarianMatcher {
    public static func choose(
        work: CanonicalBookWork,
        candidates: [LazyLibrarianCandidate],
    ) -> Result<LazyLibrarianCandidate, LazyLibrarianMatchFailure> {
        let strong = candidates.filter { isHighConfidence(work, $0) }
        let isbnHits = strong.filter { isbnMatch(work.isbn, $0.isbn) }
        var pool = isbnHits.isEmpty ? strong : isbnHits
        if let year = publicationYear(work.publicationYear) {
            let dated = pool.filter { $0.year == year }
            if Set(dated.map(\.bookID)).count == 1, let only = dated.first {
                return .success(only)
            }
            if Set(dated.map(\.bookID)).count > 1 {
                pool = dated
            }
        }
        let ids = Set(pool.map(\.bookID))
        if ids.count == 1, let chosen = pool.first(where: { $0.bookID == ids.first }) {
            return .success(chosen)
        }
        if ids.isEmpty { return .failure(.noMatch) }
        return .failure(.ambiguous)
    }

    private static func isHighConfidence(
        _ work: CanonicalBookWork,
        _ candidate: LazyLibrarianCandidate,
    ) -> Bool {
        guard !candidate.bookID.isEmpty else { return false }
        let author = authorRelation(work.authors, candidate.author)
        if isbnMatch(work.isbn, candidate.isbn) {
            return author != .conflict
        }
        return titlesMatch(work, candidate) && author == .compatible
    }

    private static func titlesMatch(_ work: CanonicalBookWork, _ candidate: LazyLibrarianCandidate) -> Bool {
        let left = AudiobookText.normalizedTitle(work.title, subtitle: work.subtitle)
        let right = AudiobookText.normalizedTitle(candidate.title)
        return !left.isEmpty && left == right
    }

    private enum AuthorRelation {
        case compatible
        case missing
        case conflict
    }

    private static func authorRelation(_ authors: [String], _ candidate: String) -> AuthorRelation {
        let left = authors.map(AudiobookText.normalizedAuthor).filter { !$0.isEmpty }
        let right = AudiobookText.normalizedAuthor(candidate)
        if left.isEmpty || right.isEmpty { return .missing }
        let rightParts = parts(right)
        for author in left {
            let leftParts = parts(author)
            guard leftParts.last == rightParts.last, leftParts.last.count >= 2 else { continue }
            if leftParts.first.isEmpty || rightParts.first.isEmpty { return .compatible }
            if givenNamesCompatible(leftParts.first, rightParts.first) { return .compatible }
        }
        return .conflict
    }

    private static func publicationYear(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let digits = raw.filter(\.isNumber)
        guard digits.count >= 4 else { return nil }
        return String(digits.prefix(4))
    }

    private static func parts(_ name: String) -> (first: String, last: String) {
        let tokens = name.split(separator: " ").map(String.init)
        guard let last = tokens.last else { return ("", "") }
        return (tokens.dropLast().joined(separator: " "), last)
    }

    private static func givenNamesCompatible(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let left = lhs.split(separator: " ").map(String.init)
        let right = rhs.split(separator: " ").map(String.init)
        if left.count == right.count {
            return zip(left, right).allSatisfy { tokenCompatible($0, $1) }
        }
        guard let firstLeft = left.first, let firstRight = right.first else { return false }
        return (left.count == 1 || right.count == 1) && tokenCompatible(firstLeft, firstRight)
    }

    private static func tokenCompatible(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        if lhs.count == 1, rhs.hasPrefix(lhs) { return true }
        if rhs.count == 1, lhs.hasPrefix(rhs) { return true }
        return false
    }

    static func isbnMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let left = isbnDigits(lhs), let right = isbnDigits(rhs) else { return false }
        if left == right { return true }
        let short = left.count == 10 ? left : right
        let long = left.count == 13 ? left : right
        guard short.count == 10, long.count == 13, long.hasPrefix("978") else { return false }
        return long.dropFirst(3).prefix(9) == short.prefix(9)
    }

    static func isbnDigits(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let digits = raw.filter(\.isNumber)
        guard digits.count == 10 || digits.count == 13 else { return nil }
        return digits
    }
}

public struct LazyLibrarianClient: Sendable {
    private let transport: any LazyLibrarianTransport

    public init(transport: any LazyLibrarianTransport = LiveLazyLibrarianTransport()) {
        self.transport = transport
    }

    public func testConnection(baseURL: String, apiKey: String) async -> LazyLibrarianConnection {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .unauthorized }
        guard let url = LazyLibrarianEndpoint.url(base: baseURL, apiKey: key, command: "getVersion")
        else { return .cannotReachServer }
        switch await call(url, timeout: 8, apiKey: key) {
            case .failure(let failure):
                return connection(failure)
            case .success(let body):
                guard let object = jsonObject(body) as? [String: Any],
                    bool(object["Success"]) == true,
                    let version = string(object, ["current_version"]),
                    !version.isEmpty
                else { return .invalidResponse }
                return .ok
        }
    }

    public func request(
        work: CanonicalBookWork,
        formats: [BookRequestFormat],
        baseURL: String,
        apiKey: String,
    ) async -> [BookRequestOutcome] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !formats.isEmpty else { return [] }
        guard !key.isEmpty else {
            return failed(formats, "Unauthorized. Check the API key.", apiKey: key)
        }
        guard LazyLibrarianEndpoint.url(base: baseURL, apiKey: key, command: "getVersion") != nil
        else {
            return failed(formats, "The server URL is not valid.", apiKey: key)
        }

        let found: [LazyLibrarianCandidate]
        switch await candidates(work: work, baseURL: baseURL, apiKey: key) {
            case .failure(let message):
                return failed(formats, message.text, apiKey: key)
            case .success(let rows):
                found = rows
        }
        let chosen: LazyLibrarianCandidate
        switch LazyLibrarianMatcher.choose(work: work, candidates: found) {
            case .failure(.noMatch):
                return failed(
                    formats,
                    "No confident match in LazyLibrarian. Nothing was queued.",
                    apiKey: key,
                )
            case .failure(.ambiguous):
                return failed(
                    formats,
                    "Several books matched. Nothing was queued.",
                    apiKey: key,
                )
            case .success(let candidate):
                chosen = candidate
        }

        let record: OwnedBook
        switch await ensureBook(id: chosen.bookID, baseURL: baseURL, apiKey: key) {
            case .failure(let message):
                return failed(formats, message.text, apiKey: key)
            case .success(let owned):
                record = owned
        }

        var outcomes: [BookRequestOutcome] = []
        for format in formats {
            outcomes.append(
                await queue(
                    format: format,
                    bookID: chosen.bookID,
                    record: record,
                    baseURL: baseURL,
                    apiKey: key,
                )
            )
        }
        return outcomes
    }

    private func candidates(
        work: CanonicalBookWork,
        baseURL: String,
        apiKey: String,
    ) async -> Result<[LazyLibrarianCandidate], Note> {
        var rows: [LazyLibrarianCandidate] = []
        var seen = Set<String>()
        func absorb(_ hits: [LazyLibrarianCandidate]) {
            for hit in hits where seen.insert(hit.bookID).inserted {
                rows.append(hit)
            }
        }
        if let isbn = LazyLibrarianMatcher.isbnDigits(work.isbn) {
            switch await findBook(name: isbn, baseURL: baseURL, apiKey: apiKey) {
                case .failure(let message): return .failure(message)
                case .success(let hits): absorb(hits)
            }
        }
        let author = work.authors.first(where: { !$0.isEmpty }) ?? ""
        let name = [work.title, author].filter { !$0.isEmpty }.joined(separator: " ")
        if !name.isEmpty, name != LazyLibrarianMatcher.isbnDigits(work.isbn) {
            switch await findBook(name: name, baseURL: baseURL, apiKey: apiKey) {
                case .failure(let message): return .failure(message)
                case .success(let hits): absorb(hits)
            }
        }
        return .success(rows)
    }

    private func ensureBook(
        id: String,
        baseURL: String,
        apiKey: String,
    ) async -> Result<OwnedBook, Note> {
        switch await getBook(id: id, baseURL: baseURL, apiKey: apiKey) {
            case .failure(let message): return .failure(message)
            case .success(let existing?): return .success(existing)
            case .success(nil): break
        }
        switch await command(
            "addBook",
            parameters: ["id": id, "wait": "1"],
            baseURL: baseURL,
            apiKey: apiKey,
            timeout: 45,
        ) {
            case .failure(let message): return .failure(message)
            case .success(let body):
                if let object = jsonObject(body) as? Bool, object == false {
                    return .failure(note("LazyLibrarian did not add this book."))
                }
                if let text = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                    text == "false"
                {
                    return .failure(note("LazyLibrarian did not add this book."))
                }
        }
        switch await getBook(id: id, baseURL: baseURL, apiKey: apiKey) {
            case .failure(let message): return .failure(message)
            case .success(let owned?): return .success(owned)
            case .success(nil):
                return .failure(note("LazyLibrarian did not add this book."))
        }
    }

    private func queue(
        format: BookRequestFormat,
        bookID: String,
        record: OwnedBook,
        baseURL: String,
        apiKey: String,
    ) async -> BookRequestOutcome {
        switch record.state(format) {
            case .available:
                return BookRequestOutcome(
                    format: format,
                    phase: .alreadyAvailable,
                    detail: "Already available in LazyLibrarian. Not downloaded into this library yet.",
                )
            case .wanted:
                return BookRequestOutcome(
                    format: format,
                    phase: .alreadyRequested,
                    detail: "Already requested. LazyLibrarian has not finished downloading it.",
                )
            case .ignored:
                return BookRequestOutcome(
                    format: format,
                    phase: .failed,
                    detail: "LazyLibrarian has this \(format.label) marked ignored. Nothing was queued.",
                )
            case .open:
                break
        }
        let type = format.lazyLibrarianType
        switch await command(
            "queueBook",
            parameters: ["id": bookID, "type": type],
            baseURL: baseURL,
            apiKey: apiKey,
            timeout: 20,
        ) {
            case .failure(let message):
                return BookRequestOutcome(format: format, phase: .failed, detail: message.text)
            case .success(let body):
                if !accepted(body) {
                    return BookRequestOutcome(
                        format: format,
                        phase: .failed,
                        detail: textDetail(body, apiKey: apiKey, fallback: "LazyLibrarian did not queue this book."),
                    )
                }
        }
        switch await command(
            "searchBook",
            parameters: ["id": bookID, "type": type],
            baseURL: baseURL,
            apiKey: apiKey,
            timeout: 20,
        ) {
            case .failure:
                return BookRequestOutcome(
                    format: format,
                    phase: .requested,
                    detail: "Request accepted. Search did not start. The file is not downloaded.",
                )
            case .success(let body):
                if searchStarted(body) {
                    return BookRequestOutcome(
                        format: format,
                        phase: .searching,
                        detail: "Request accepted. LazyLibrarian is searching. The file is not downloaded.",
                    )
                }
                return BookRequestOutcome(
                    format: format,
                    phase: .requested,
                    detail: "Request accepted. Search did not start. The file is not downloaded.",
                )
        }
    }

    private func findBook(
        name: String,
        baseURL: String,
        apiKey: String,
    ) async -> Result<[LazyLibrarianCandidate], Note> {
        switch await command(
            "findBook",
            parameters: ["name": name],
            baseURL: baseURL,
            apiKey: apiKey,
            timeout: 30,
        ) {
            case .failure(let message): return .failure(message)
            case .success(let body):
                guard let object = jsonObject(body) else {
                    return .failure(note(textDetail(body, apiKey: apiKey, fallback: "Invalid server response.")))
                }
                if let error = apiError(object) {
                    return .failure(note(LazyLibrarianEndpoint.redact(error, apiKey: apiKey)))
                }
                guard let rows = object as? [Any] else {
                    return .failure(note("Invalid server response."))
                }
                return .success(rows.compactMap(candidate(from:)))
        }
    }

    private func getBook(
        id: String,
        baseURL: String,
        apiKey: String,
    ) async -> Result<OwnedBook?, Note> {
        switch await command(
            "getBook",
            parameters: ["id": id],
            baseURL: baseURL,
            apiKey: apiKey,
            timeout: 20,
        ) {
            case .failure(let message): return .failure(message)
            case .success(let body):
                guard let object = jsonObject(body) as? [String: Any] else {
                    return .failure(note(textDetail(body, apiKey: apiKey, fallback: "Invalid server response.")))
                }
                if let error = apiError(object) {
                    return .failure(note(LazyLibrarianEndpoint.redact(error, apiKey: apiKey)))
                }
                guard let books = object["book"] as? [Any] else {
                    return .failure(note("Invalid server response."))
                }
                guard let first = books.first else { return .success(nil) }
                guard let parsed = owned(from: first) else {
                    return .failure(note("Invalid server response."))
                }
                return .success(parsed)
        }
    }

    private func command(
        _ command: String,
        parameters: [String: String],
        baseURL: String,
        apiKey: String,
        timeout: TimeInterval,
    ) async -> Result<Data, Note> {
        guard let url = LazyLibrarianEndpoint.url(
            base: baseURL,
            apiKey: apiKey,
            command: command,
            parameters: parameters,
        ) else { return .failure(note("The server URL is not valid.")) }
        switch await call(url, timeout: timeout, apiKey: apiKey) {
            case .failure(let failure):
                return .failure(note(failure.message(apiKey: apiKey)))
            case .success(let body):
                return .success(body)
        }
    }

    private struct Note: Error, Sendable {
        var text: String
    }

    private enum CallFailure: Error, Sendable {
        case cannotReachServer
        case unauthorized
        case invalidResponse
        case timeout
        case message(String)

        func message(apiKey: String) -> String {
            switch self {
                case .cannotReachServer: "Cannot reach the LazyLibrarian server."
                case .unauthorized: "Unauthorized. Check the API key."
                case .invalidResponse: "Invalid server response."
                case .timeout: "The LazyLibrarian server timed out."
                case .message(let text): LazyLibrarianEndpoint.redact(text, apiKey: apiKey)
            }
        }
    }

    private func call(_ url: URL, timeout: TimeInterval, apiKey: String) async -> Result<Data, CallFailure> {
        let http: LazyLibrarianHTTP
        do {
            http = try await transport.send(url, timeout: timeout)
        } catch let error as URLError {
            switch error.code {
                case .timedOut: return .failure(.timeout)
                default: return .failure(.cannotReachServer)
            }
        } catch {
            return .failure(.cannotReachServer)
        }
        if http.status == 401 || http.status == 403 { return .failure(.unauthorized) }
        if !(200..<300).contains(http.status) { return .failure(.invalidResponse) }
        if let object = jsonObject(http.body), let error = apiError(object) {
            if unauthorizedText(error) { return .failure(.unauthorized) }
            return .failure(.message(error))
        }
        return .success(http.body)
    }

    private func connection(_ failure: CallFailure) -> LazyLibrarianConnection {
        switch failure {
            case .cannotReachServer: .cannotReachServer
            case .unauthorized: .unauthorized
            case .invalidResponse: .invalidResponse
            case .timeout: .timeout
            case .message: .invalidResponse
        }
    }

    private func failed(
        _ formats: [BookRequestFormat],
        _ detail: String,
        apiKey: String,
    ) -> [BookRequestOutcome] {
        let safe = LazyLibrarianEndpoint.redact(detail, apiKey: apiKey)
        return formats.map {
            BookRequestOutcome(format: $0, phase: .failed, detail: safe)
        }
    }

    private func note(_ text: String) -> Note {
        Note(text: text)
    }

    private func accepted(_ body: Data) -> Bool {
        let text = String(data: body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if text == "ok" { return true }
        if let object = jsonObject(body) as? [String: Any], bool(object["Success"]) == true {
            return true
        }
        return false
    }

    private func searchStarted(_ body: Data) -> Bool {
        let text = String(data: body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if text.contains("no search methods") { return false }
        if text.contains("missing parameter") { return false }
        if text.contains("invalid id") { return false }
        return accepted(body) || text.isEmpty
    }

    private func textDetail(_ body: Data, apiKey: String, fallback: String) -> String {
        let text = String(data: body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let raw = text.isEmpty ? fallback : text
        return LazyLibrarianEndpoint.redact(raw, apiKey: apiKey)
    }

    private struct OwnedBook {
        var ebook: Holding
        var audiobook: Holding

        func state(_ format: BookRequestFormat) -> Holding {
            switch format {
                case .ebook: ebook
                case .audiobook: audiobook
            }
        }
    }

    private enum Holding {
        case open
        case wanted
        case available
        case ignored
    }

    private func owned(from value: Any) -> OwnedBook? {
        guard let row = value as? [String: Any] else { return nil }
        return OwnedBook(
            ebook: holding(string(row, ["Status", "status"]), library: string(row, ["BookLibrary", "booklibrary"])),
            audiobook: holding(
                string(row, ["AudioStatus", "audiostatus"]),
                library: string(row, ["AudioLibrary", "audiolibrary"]),
            ),
        )
    }

    private func holding(_ status: String?, library: String?) -> Holding {
        if let library, !library.isEmpty { return .available }
        switch status?.lowercased() {
            case "have": return .available
            case "wanted", "snatched": return .wanted
            case "ignored": return .ignored
            default: return .open
        }
    }

    private func candidate(from value: Any) -> LazyLibrarianCandidate? {
        guard let row = value as? [String: Any],
            let id = string(row, ["bookid", "BookID"])
        else { return nil }
        let year = string(row, ["bookpub", "bookdate", "BookDate"])
        return LazyLibrarianCandidate(
            bookID: id,
            title: string(row, ["bookname", "BookName"]) ?? "",
            author: string(row, ["authorname", "AuthorName"]) ?? "",
            isbn: string(row, ["bookisbn", "BookIsbn"]),
            year: year.flatMap { token in
                let digits = token.filter(\.isNumber)
                return digits.count >= 4 ? String(digits.prefix(4)) : nil
            },
        )
    }

    private func jsonObject(_ data: Data) -> Any? {
        guard !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func apiError(_ object: Any) -> String? {
        guard let row = object as? [String: Any], bool(row["Success"]) == false else { return nil }
        if let error = row["Error"] as? [String: Any], let message = string(error, ["Message", "message"]) {
            return message
        }
        return "Invalid server response."
    }

    private func unauthorizedText(_ message: String) -> Bool {
        let folded = message.lowercased()
        return folded.contains("api key") || folded.contains("unauthorized")
    }

    private func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    private func string(_ row: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = row[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let value = row[key] as? NSNumber {
                return value.stringValue
            }
        }
        for (key, value) in row {
            guard keys.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) else { continue }
            if let text = value as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let number = value as? NSNumber { return number.stringValue }
        }
        return nil
    }
}
