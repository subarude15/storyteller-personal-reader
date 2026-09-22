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

public enum LazyLibrarianFormatState: String, Equatable, Sendable {
    case open
    case wanted
    case snatched
    case available
    case ignored

    public var activityStatus: RequestActivityStatus {
        switch self {
            case .open: .requested
            case .wanted: .wanted
            case .snatched: .snatched
            case .available: .available
            case .ignored: .needsAttention
        }
    }

    public var rawLabel: String {
        rawValue
    }
}

public struct LazyLibrarianBookSnapshot: Equatable, Sendable {
    public var bookID: String
    public var ebook: LazyLibrarianFormatState
    public var audiobook: LazyLibrarianFormatState

    public init(bookID: String, ebook: LazyLibrarianFormatState, audiobook: LazyLibrarianFormatState) {
        self.bookID = bookID
        self.ebook = ebook
        self.audiobook = audiobook
    }

    public func state(for format: BookRequestFormat) -> LazyLibrarianFormatState {
        switch format {
            case .ebook: ebook
            case .audiobook: audiobook
        }
    }
}

public enum LazyLibrarianLookupFailure: Error, Equatable, Sendable {
    case unauthorized
    case unreachable
    case timeout
    case missingBook
    case message(String)

    public var detail: String {
        switch self {
            case .unauthorized: "Unauthorized. Check the API key."
            case .unreachable: "Cannot reach the LazyLibrarian server."
            case .timeout: "The LazyLibrarian server timed out."
            case .missingBook: "Book no longer exists in LazyLibrarian."
            case .message(let text): text
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

public struct LazyLibrarianCandidate: Equatable, Sendable, Codable {
    public var bookID: String
    public var title: String
    public var author: String
    public var isbn: String?
    public var year: String?
    public var openLibraryWorkID: String?

    public init(
        bookID: String,
        title: String,
        author: String,
        isbn: String?,
        year: String?,
        openLibraryWorkID: String? = nil,
    ) {
        self.bookID = bookID
        self.title = title
        self.author = author
        self.isbn = isbn
        self.year = year
        self.openLibraryWorkID = openLibraryWorkID
    }
}

public enum LazyLibrarianMatchFailure: Error, Equatable, Sendable {
    case noMatch
    case ambiguous
}

/// Failure from read-only BookID resolution (findBook + matcher only).
public enum LazyLibrarianResolveFailure: Error, Equatable, Sendable {
    case noMatch
    case ambiguous
    case message(String)

    public var detail: String {
        switch self {
            case .noMatch: "Could not match this request to a LazyLibrarian book."
            case .ambiguous: "Multiple LazyLibrarian matches found."
            case .message(let text): text
        }
    }
}

public enum LazyLibrarianMatcher {
    public static func choose(
        work: CanonicalBookWork,
        candidates: [LazyLibrarianCandidate],
    ) -> Result<LazyLibrarianCandidate, LazyLibrarianMatchFailure> {
        switch resolve(work: work, candidates: candidates, preference: .askWhenUncertain) {
            case .matched(let candidate, _, _):
                return .success(candidate)
            case .ambiguous:
                return .failure(.ambiguous)
            case .noMatch:
                return .failure(.noMatch)
        }
    }

    static func ranked(
        work: CanonicalBookWork,
        candidates: [LazyLibrarianCandidate],
    ) -> [(candidate: LazyLibrarianCandidate, tier: LazyLibrarianMatchTier)] {
        let year = publicationYear(work.publicationYear)
        var rows: [(candidate: LazyLibrarianCandidate, tier: LazyLibrarianMatchTier)] = []
        var seen = Set<String>()
        for candidate in candidates {
            guard seen.insert(candidate.bookID).inserted else { continue }
            guard let tier = tier(work: work, candidate: candidate) else { continue }
            rows.append((candidate, tier))
        }
        rows.sort { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier > rhs.tier }
            let leftYear = year != nil && lhs.candidate.year == year
            let rightYear = year != nil && rhs.candidate.year == year
            if leftYear != rightYear { return leftYear }
            return lhs.candidate.bookID < rhs.candidate.bookID
        }
        return rows
    }

    static func lookupISBNs(_ work: CanonicalBookWork) -> [String] {
        var queries: [String] = []
        for raw in [work.isbn13, work.isbn10, work.isbn] {
            guard let digits = isbnDigits(raw), !queries.contains(digits) else { continue }
            queries.append(digits)
        }
        return queries
    }

    static func openLibraryWorkKey(_ raw: String?) -> String? {
        identifierKey(raw, pattern: "OL\\d+W")
    }

    static func openLibraryEditionKey(_ raw: String?) -> String? {
        identifierKey(raw, pattern: "OL\\d+M")
    }

    /// Token passed to findBook. Bare OpenLibrary ids, not a URL.
    static func openLibrarySearchToken(_ raw: String?) -> String? {
        openLibraryWorkKey(raw) ?? openLibraryEditionKey(raw)
    }

    private static func identifierKey(_ raw: String?, pattern: String) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let upper = raw.uppercased()
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(upper.startIndex..., in: upper)
        guard let match = regex.firstMatch(in: upper, range: range),
            let swiftRange = Range(match.range, in: upper)
        else { return nil }
        return String(upper[swiftRange])
    }

    private static func tier(
        work: CanonicalBookWork,
        candidate: LazyLibrarianCandidate,
    ) -> LazyLibrarianMatchTier? {
        guard !candidate.bookID.isEmpty else { return nil }
        if openLibraryWorkMatch(work, candidate) { return .openLibraryWork }
        if openLibraryEditionMatch(work, candidate) { return .openLibraryEdition }
        let author = authorRelation(work.authors, candidate.author)
        if author == .conflict { return nil }
        if lookupISBNs(work).contains(where: { isbnMatch($0, candidate.isbn) }) {
            return .isbn
        }
        let title = titleRelation(work, candidate)
        let exactAuthor = author == .compatible && authorsEqual(work.authors, candidate.author)
        if title == .exact, exactAuthor { return .exactTitleAuthor }
        if (title == .exact || title == .strong), author == .compatible { return .strongTitleAuthor }
        if (title == .exact || title == .strong), author == .missing { return .titleOnly }
        return nil
    }

    private static func openLibraryWorkMatch(
        _ work: CanonicalBookWork,
        _ candidate: LazyLibrarianCandidate,
    ) -> Bool {
        guard let wanted = openLibraryWorkKey(work.openLibraryWorkID) else { return false }
        let found = openLibraryWorkKey(candidate.openLibraryWorkID) ?? openLibraryWorkKey(candidate.bookID)
        return found == wanted
    }

    private static func openLibraryEditionMatch(
        _ work: CanonicalBookWork,
        _ candidate: LazyLibrarianCandidate,
    ) -> Bool {
        guard let wanted = openLibraryEditionKey(work.openLibraryEditionID) else { return false }
        return openLibraryEditionKey(candidate.bookID) == wanted
    }

    private enum TitleRelation {
        case exact
        case strong
        case none
    }

    private static func titleRelation(
        _ work: CanonicalBookWork,
        _ candidate: LazyLibrarianCandidate,
    ) -> TitleRelation {
        let left = AudiobookText.normalizedTitle(work.title, subtitle: work.subtitle)
        let right = AudiobookText.normalizedTitle(candidate.title)
        if left.isEmpty || right.isEmpty { return .none }
        if left == right { return .exact }
        let leftTokens = left.split(separator: " ").map(String.init)
        let rightTokens = right.split(separator: " ").map(String.init)
        // Two-word titles only. "Dune" must not swallow "Dune Messiah".
        if leftTokens.count >= 2, rightTokens.starts(with: leftTokens) { return .strong }
        if rightTokens.count >= 2, leftTokens.starts(with: rightTokens) { return .strong }
        return .none
    }

    private static func authorsEqual(_ authors: [String], _ candidate: String) -> Bool {
        let right = AudiobookText.normalizedAuthor(candidate)
        guard !right.isEmpty else { return false }
        return authors.map(AudiobookText.normalizedAuthor).contains(right)
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

    static func publicationYear(_ raw: String?) -> String? {
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

    /// Normalize a single ISBN string to ISBN-10 or ISBN-13 shape.
    /// Spaces, hyphens, and other punctuation are ignored. Digits are kept.
    /// `X`/`x` is kept only as the final ISBN-10 check digit (normalized to `X`).
    static func isbnDigits(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var out = ""
        var sawCheckX = false
        for character in raw {
            if character.isWhitespace || character == "-" {
                continue
            }
            if !character.isLetter, !character.isNumber {
                continue
            }
            if sawCheckX { return nil }
            if character.isNumber {
                out.append(character)
                continue
            }
            if character == "X" || character == "x" {
                guard out.count == 9 else { return nil }
                out.append("X")
                sawCheckX = true
                continue
            }
            return nil
        }
        guard out.count == 10 || out.count == 13 else { return nil }
        if out.count == 13, sawCheckX { return nil }
        return out
    }
}

public struct LazyLibrarianClient: Sendable {
    private let transport: any LazyLibrarianTransport

    public init(transport: any LazyLibrarianTransport = LiveLazyLibrarianTransport()) {
        self.transport = transport
    }

    public func testConnection(baseURL: String, apiKey: String) async -> LazyLibrarianConnection {
        await probeHealth(baseURL: baseURL, apiKey: apiKey).connection
    }

    /// Read-only health probe. Uses getVersion only — no library mutations or searches.
    public func probeHealth(baseURL: String, apiKey: String) async -> LazyLibrarianHealthProbe {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return LazyLibrarianHealthProbe(connection: .unauthorized, version: nil)
        }
        guard let url = LazyLibrarianEndpoint.url(base: baseURL, apiKey: key, command: "getVersion")
        else {
            return LazyLibrarianHealthProbe(connection: .cannotReachServer, version: nil)
        }
        switch await call(url, timeout: 8, apiKey: key) {
            case .failure(let failure):
                return LazyLibrarianHealthProbe(connection: connection(failure), version: nil)
            case .success(let body):
                guard let object = jsonObject(body) as? [String: Any],
                    bool(object["Success"]) == true,
                    let version = string(object, ["current_version"]),
                    !version.isEmpty
                else {
                    return LazyLibrarianHealthProbe(connection: .invalidResponse, version: nil)
                }
                return LazyLibrarianHealthProbe(connection: .ok, version: version)
        }
    }

    public func request(
        work: CanonicalBookWork,
        formats: [BookRequestFormat],
        baseURL: String,
        apiKey: String,
        matching: LazyLibrarianAutomaticMatching = .askWhenUncertain,
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

        let bookID: String
        let matchReason: String
        switch await resolveMatch(work: work, baseURL: baseURL, apiKey: key, matching: matching) {
            case .failure(.noMatch):
                return unmatched(
                    formats,
                    detail: LazyLibrarianMatchCopy.noCandidates,
                    attention: .noMatch,
                    candidates: [],
                )
            case .failure(.ambiguous(let candidates)):
                return unmatched(
                    formats,
                    detail: LazyLibrarianMatchCopy.ambiguous,
                    attention: .ambiguous,
                    candidates: candidates,
                )
            case .failure(.message(let text)):
                return failed(formats, text, apiKey: key)
            case .success(let resolved):
                bookID = resolved.bookID
                matchReason = resolved.reason
        }

        let record: OwnedBook
        switch await ensureBook(id: bookID, baseURL: baseURL, apiKey: key) {
            case .failure(let message):
                return failed(formats, message.text, apiKey: key)
            case .success(let owned):
                record = owned
        }

        var outcomes: [BookRequestOutcome] = []
        for format in formats {
            var outcome = await queue(
                format: format,
                bookID: bookID,
                record: record,
                baseURL: baseURL,
                apiKey: key,
            )
            if outcome.phase != .failed {
                outcome.matchReason = matchReason
            }
            outcomes.append(outcome)
        }
        return outcomes
    }

    /// Queue a candidate the user (or automatic matching) already chose.
    /// Does not search again, so a second request row is not implied by a new lookup.
    public func queueResolved(
        bookID: String,
        formats: [BookRequestFormat],
        baseURL: String,
        apiKey: String,
        matchReason: String,
    ) async -> [BookRequestOutcome] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !formats.isEmpty else { return [] }
        guard !bookID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return failed(formats, "LazyLibrarian did not return a book id.", apiKey: key)
        }
        guard !key.isEmpty else {
            return failed(formats, "Unauthorized. Check the API key.", apiKey: key)
        }
        guard LazyLibrarianEndpoint.url(base: baseURL, apiKey: key, command: "getVersion") != nil
        else {
            return failed(formats, "The server URL is not valid.", apiKey: key)
        }
        let record: OwnedBook
        switch await ensureBook(id: bookID, baseURL: baseURL, apiKey: key) {
            case .failure(let message):
                return failed(formats, message.text, apiKey: key)
            case .success(let owned):
                record = owned
        }
        var outcomes: [BookRequestOutcome] = []
        for format in formats {
            var outcome = await queue(
                format: format,
                bookID: bookID,
                record: record,
                baseURL: baseURL,
                apiKey: key,
            )
            if outcome.phase != .failed {
                outcome.matchReason = matchReason
            }
            outcomes.append(outcome)
        }
        return outcomes
    }

    private struct ChosenMatch: Sendable {
        var bookID: String
        var reason: String
    }

    private enum MatchLookupFailure: Sendable {
        case noMatch
        case ambiguous([LazyLibrarianCandidate])
        case message(String)
    }

    private func resolveMatch(
        work: CanonicalBookWork,
        baseURL: String,
        apiKey: String,
        matching: LazyLibrarianAutomaticMatching,
    ) async -> Result<ChosenMatch, MatchLookupFailure> {
        let found: [LazyLibrarianCandidate]
        switch await candidates(work: work, baseURL: baseURL, apiKey: apiKey) {
            case .failure(let message):
                return .failure(.message(message.text))
            case .success(let rows):
                found = rows
        }
        switch LazyLibrarianMatcher.resolve(work: work, candidates: found, preference: matching) {
            case .matched(let candidate, let reason, _):
                return .success(ChosenMatch(bookID: candidate.bookID, reason: reason))
            case .ambiguous(_, let candidates):
                return .failure(.ambiguous(candidates))
            case .noMatch:
                return .failure(.noMatch)
        }
    }

    /// Resolve a LazyLibrarian BookID with the same high-confidence matcher as submission.
    /// Read-only: findBook only — never addBook, queueBook, or searchBook.
    public func resolveBookID(
        work: CanonicalBookWork,
        baseURL: String,
        apiKey: String,
    ) async -> Result<String, LazyLibrarianResolveFailure> {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return .failure(.message("Unauthorized. Check the API key."))
        }
        guard LazyLibrarianEndpoint.url(base: baseURL, apiKey: key, command: "getVersion") != nil
        else {
            return .failure(.message("The server URL is not valid."))
        }
        let found: [LazyLibrarianCandidate]
        switch await candidates(work: work, baseURL: baseURL, apiKey: key) {
            case .failure(let message):
                return .failure(.message(message.text))
            case .success(let rows):
                found = rows
        }
        switch LazyLibrarianMatcher.choose(work: work, candidates: found) {
            case .failure(.noMatch):
                return .failure(.noMatch)
            case .failure(.ambiguous):
                return .failure(.ambiguous)
            case .success(let candidate):
                return .success(candidate.bookID)
        }
    }

    /// Read-only status for a previously resolved LazyLibrarian BookID.
    public func lookupBook(
        id: String,
        baseURL: String,
        apiKey: String,
    ) async -> Result<LazyLibrarianBookSnapshot?, LazyLibrarianLookupFailure> {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .failure(.unauthorized) }
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.missingBook)
        }
        switch await getBook(id: id, baseURL: baseURL, apiKey: key) {
            case .failure(let message):
                if message.text.localizedCaseInsensitiveContains("timed out") {
                    return .failure(.timeout)
                }
                if message.text.localizedCaseInsensitiveContains("unauthorized") {
                    return .failure(.unauthorized)
                }
                if message.text.localizedCaseInsensitiveContains("cannot reach") {
                    return .failure(.unreachable)
                }
                return .failure(.message(message.text))
            case .success(nil):
                return .success(nil)
            case .success(let owned?):
                return .success(
                    LazyLibrarianBookSnapshot(
                        bookID: id,
                        ebook: owned.ebook.publicState,
                        audiobook: owned.audiobook.publicState,
                    )
                )
        }
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
        var queries: [String] = []
        if let workID = LazyLibrarianMatcher.openLibrarySearchToken(work.openLibraryWorkID) {
            queries.append(workID)
        }
        if let edition = LazyLibrarianMatcher.openLibrarySearchToken(work.openLibraryEditionID),
            !queries.contains(edition)
        {
            queries.append(edition)
        }
        for isbn in LazyLibrarianMatcher.lookupISBNs(work) where !queries.contains(isbn) {
            queries.append(isbn)
        }
        let author = work.authors.first(where: { !$0.isEmpty }) ?? ""
        let titled = [work.title, author].filter { !$0.isEmpty }.joined(separator: " ")
        if !titled.isEmpty, !queries.contains(titled) {
            queries.append(titled)
        }
        var lookupFailure: Note?
        var anySuccess = false
        func run(_ query: String) async {
            switch await findBook(name: query, baseURL: baseURL, apiKey: apiKey) {
                case .failure(let message):
                    lookupFailure = message
                case .success(let hits):
                    anySuccess = true
                    absorb(hits)
            }
        }
        for query in queries {
            await run(query)
        }
        let titleOnly = work.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if rows.isEmpty, !titleOnly.isEmpty, titleOnly != titled {
            await run(titleOnly)
        }
        // A dead identifier query must not hide a later title hit, and a total
        // outage must stay a provider failure rather than "no candidates".
        if rows.isEmpty, !anySuccess, let lookupFailure {
            return .failure(lookupFailure)
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
                    providerBookID: bookID,
                )
            case .wanted, .snatched:
                return BookRequestOutcome(
                    format: format,
                    phase: .alreadyRequested,
                    detail: "Already requested. LazyLibrarian has not finished downloading it.",
                    providerBookID: bookID,
                )
            case .ignored:
                return BookRequestOutcome(
                    format: format,
                    phase: .failed,
                    detail: "LazyLibrarian has this \(format.label) marked ignored. Nothing was queued.",
                    providerBookID: bookID,
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
                return BookRequestOutcome(
                    format: format,
                    phase: .failed,
                    detail: message.text,
                    providerBookID: bookID,
                    matchAttention: .providerFailure,
                )
            case .success(let body):
                if !accepted(body) {
                    return BookRequestOutcome(
                        format: format,
                        phase: .failed,
                        detail: textDetail(body, apiKey: apiKey, fallback: "LazyLibrarian did not queue this book."),
                        providerBookID: bookID,
                        matchAttention: .providerFailure,
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
                    providerBookID: bookID,
                )
            case .success(let body):
                if searchStarted(body) {
                    return BookRequestOutcome(
                        format: format,
                        phase: .searching,
                        detail: "Request accepted. LazyLibrarian is searching. The file is not downloaded.",
                        providerBookID: bookID,
                    )
                }
                return BookRequestOutcome(
                    format: format,
                    phase: .requested,
                    detail: "Request accepted. Search did not start. The file is not downloaded.",
                    providerBookID: bookID,
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
            BookRequestOutcome(
                format: $0,
                phase: .failed,
                detail: safe,
                matchAttention: .providerFailure,
            )
        }
    }

    private func unmatched(
        _ formats: [BookRequestFormat],
        detail: String,
        attention: LazyLibrarianMatchAttention,
        candidates: [LazyLibrarianCandidate],
    ) -> [BookRequestOutcome] {
        let phase: BookRequestPhase = attention == .ambiguous ? .needsAttention : .failed
        return formats.map {
            BookRequestOutcome(
                format: $0,
                phase: phase,
                detail: detail,
                matchCandidates: candidates,
                matchAttention: attention,
            )
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
        case snatched
        case available
        case ignored

        var publicState: LazyLibrarianFormatState {
            switch self {
                case .open: .open
                case .wanted: .wanted
                case .snatched: .snatched
                case .available: .available
                case .ignored: .ignored
            }
        }
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
            case "wanted": return .wanted
            case "snatched": return .snatched
            case "ignored": return .ignored
            default: return .open
        }
    }

    private func candidate(from value: Any) -> LazyLibrarianCandidate? {
        guard let row = value as? [String: Any],
            let id = string(row, ["bookid", "BookID"])
        else { return nil }
        let year = string(row, ["bookpub", "bookdate", "BookDate"])
        let workID =
            LazyLibrarianMatcher.openLibraryWorkKey(id)
            ?? LazyLibrarianMatcher.openLibraryWorkKey(string(row, ["workid", "ol_work", "openlibrary_work"]))
        return LazyLibrarianCandidate(
            bookID: id,
            title: string(row, ["bookname", "BookName"]) ?? "",
            author: string(row, ["authorname", "AuthorName", "author", "Author"]) ?? "",
            isbn: string(row, ["bookisbn", "BookIsbn"]),
            year: year.flatMap { token in
                let digits = token.filter(\.isNumber)
                return digits.count >= 4 ? String(digits.prefix(4)) : nil
            },
            openLibraryWorkID: workID.map { "/works/\($0)" },
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
