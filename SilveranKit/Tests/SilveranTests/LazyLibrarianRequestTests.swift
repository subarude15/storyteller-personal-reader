import Foundation
import Testing

@testable import SilveranKit

@Suite("LazyLibrarian requests")
struct LazyLibrarianRequestTests {
    private let base = "http://192.168.1.20:5299"
    private let key = "abc123secret"

    private func work(
        title: String = "Pride and Prejudice",
        author: String = "Jane Austen",
        isbn: String? = nil,
        year: String? = "1813",
    ) -> CanonicalBookWork {
        CanonicalBookWork(
            workID: "work/1",
            title: title,
            subtitle: nil,
            authors: [author],
            language: "en",
            isbn: isbn,
            openLibraryWorkID: "/works/OL1W",
            openLibraryEditionID: nil,
            publicationYear: year,
        )
    }

    private func hit(
        id: String = "OL1W",
        title: String = "Pride and Prejudice",
        author: String = "Jane Austen",
        isbn: String = "9780141439518",
        year: String = "1813",
    ) -> String {
        """
        [{"bookid":"\(id)","bookname":"\(title)","authorname":"\(author)","bookisbn":"\(isbn)","bookpub":"\(year)"}]
        """
    }

    private func owned(ebook: String, audio: String) -> String {
        #"{"book":[{"BookID":"OL1W","Status":"\#(ebook)","AudioStatus":"\#(audio)"}]}"#
    }

    @Test func urlUsesAPICommandAndDropsTrailingSlash() throws {
        let url = try #require(
            LazyLibrarianEndpoint.url(
                base: "http://192.168.1.20:5299/",
                apiKey: key,
                command: "queueBook",
                parameters: ["type": "eBook", "id": "OL1W"],
            )
        )
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(url.path == "/api")
        #expect(items.first { $0.name == "cmd" }?.value == "queueBook")
        #expect(items.first { $0.name == "apikey" }?.value == key)
        #expect(items.first { $0.name == "type" }?.value == "eBook")
        #expect(items.first { $0.name == "id" }?.value == "OL1W")
        #expect(!url.path.contains("//api"))

        let already = try #require(
            LazyLibrarianEndpoint.url(base: "http://192.168.1.20:5299/api", apiKey: key, command: "getVersion")
        )
        #expect(already.path == "/api")
        #expect(LazyLibrarianEndpoint.url(base: "ftp://192.168.1.20", apiKey: key, command: "getVersion") == nil)
    }

    @Test func redactsAPIKeyFromTextAndQuery() throws {
        let url = try #require(
            LazyLibrarianEndpoint.url(base: base, apiKey: key, command: "getVersion")
        )
        let redacted = LazyLibrarianEndpoint.redact(
            "rejected \(key) at \(url.absoluteString)",
            apiKey: key,
        )
        #expect(!redacted.contains(key))
        #expect(redacted.contains("apikey=••••"))
    }

    @Test func connectionTestRecognizesLazyLibrarian() async {
        let script = Script()
        script.handler = { _, _ in
            Script.http(
                #"{"Success":true,"current_version":"v1","latest_version":"v1","commits_behind":0,"install_type":"git"}"#
            )
        }
        let client = LazyLibrarianClient(transport: script)
        #expect(await client.testConnection(baseURL: base, apiKey: key) == .ok)
        #expect(script.commands == ["getVersion"])
        #expect(await client.testConnection(baseURL: base, apiKey: "  ") == .unauthorized)
        #expect(script.commands == ["getVersion"])
    }

    @Test func connectionTestReportsAuthReachTimeoutAndGarbage() async {
        let unauthorized = Script()
        unauthorized.handler = { _, _ in
            Script.http(
                #"{"Success":false,"Error":{"Code":401,"Message":"Incorrect API key"}}"#,
                status: 200,
            )
        }
        let client = LazyLibrarianClient(transport: unauthorized)
        #expect(await client.testConnection(baseURL: base, apiKey: key) == .unauthorized)

        let down = Script()
        down.error = URLError(.cannotConnectToHost)
        #expect(
            await LazyLibrarianClient(transport: down).testConnection(baseURL: base, apiKey: key)
                == .cannotReachServer
        )

        let slow = Script()
        slow.error = URLError(.timedOut)
        #expect(
            await LazyLibrarianClient(transport: slow).testConnection(baseURL: base, apiKey: key) == .timeout
        )

        let garbage = Script()
        garbage.handler = { _, _ in Script.http("<html>not the api</html>") }
        #expect(
            await LazyLibrarianClient(transport: garbage).testConnection(baseURL: base, apiKey: key)
                == .invalidResponse
        )
    }

    @Test func titleAuthorLookupQueuesEbookOnly() async {
        let script = readyScript(owned: owned(ebook: "Open", audio: "Open"))
        let outcomes = await LazyLibrarianClient(transport: script).request(
            work: work(),
            formats: [.ebook],
            baseURL: base,
            apiKey: key,
        )
        #expect(script.calls.contains { $0.cmd == "findBook" && $0.query["name"] == "Pride and Prejudice Jane Austen" })
        #expect(outcomes.map(\.phase) == [.searching])
        #expect(script.calls.filter { $0.cmd == "queueBook" }.map { $0.query["type"] } == ["eBook"])
        #expect(script.calls.filter { $0.cmd == "searchBook" }.map { $0.query["type"] } == ["eBook"])
        #expect(!script.commands.contains("addBookByISBN"))
    }

    @Test func isbnLookupPrefersTheMatchingEdition() async {
        let script = Script()
        script.handler = { cmd, query in
            if cmd == "findBook", query["name"] == "9780141439518" {
                return Script.http(self.hit())
            }
            if cmd == "findBook" {
                return Script.http(self.hit(id: "OTHER", title: "Pride and Prejudice", author: "Jane Austen", isbn: "1111111111"))
            }
            if cmd == "getBook" {
                return Script.http(self.owned(ebook: "Open", audio: "Open"))
            }
            return Script.http("OK")
        }
        let outcomes = await LazyLibrarianClient(transport: script).request(
            work: work(isbn: "978-0-14-143951-8"),
            formats: [.audiobook],
            baseURL: base,
            apiKey: key,
        )
        #expect(outcomes.map(\.phase) == [.searching])
        let queued = script.calls.filter { $0.cmd == "queueBook" }
        #expect(queued.map { $0.query["id"] } == ["OL1W"])
        #expect(queued.map { $0.query["type"] } == ["AudioBook"])
        #expect(script.calls.contains { $0.cmd == "findBook" && $0.query["name"] == "9780141439518" })
    }

    @Test func isbnNormalizationKeepsISBN10CheckX() {
        #expect(LazyLibrarianMatcher.isbnDigits("080442957X") == "080442957X")
        #expect(LazyLibrarianMatcher.isbnDigits("080442957x") == "080442957X")
        #expect(LazyLibrarianMatcher.isbnDigits("0-8044-2957-X") == "080442957X")
        #expect(LazyLibrarianMatcher.isbnDigits("0 8044 2957 x") == "080442957X")
        #expect(LazyLibrarianMatcher.isbnDigits("0306406152") == "0306406152")
        #expect(LazyLibrarianMatcher.isbnDigits("978-0-306-40615-7") == "9780306406157")
        #expect(LazyLibrarianMatcher.isbnDigits("9780306406157") == "9780306406157")
        #expect(LazyLibrarianMatcher.isbnDigits("08044A2957") == nil)
        #expect(LazyLibrarianMatcher.isbnDigits("X804429570") == nil)
        #expect(LazyLibrarianMatcher.isbnDigits("978030640615X") == nil)
        #expect(LazyLibrarianMatcher.isbnDigits("080442957") == nil)
        #expect(LazyLibrarianMatcher.isbnDigits("isbn") == nil)
    }

    @Test func isbn10EndingInXMatchesCandidatesAndISBN13Payload() {
        #expect(LazyLibrarianMatcher.isbnMatch("080442957X", "080442957x"))
        #expect(LazyLibrarianMatcher.isbnMatch("0-8044-2957-X", "080442957X"))
        #expect(LazyLibrarianMatcher.isbnMatch("080442957X", "9780804429573"))
        #expect(!LazyLibrarianMatcher.isbnMatch("080442957X", "9780804429580"))
        #expect(!LazyLibrarianMatcher.isbnMatch("080442957X", "1111111111"))

        let chosen = LazyLibrarianMatcher.choose(
            work: work(
                title: "The Great Gatsby",
                author: "F. Scott Fitzgerald",
                isbn: "0-8044-2957-X",
                year: "1925",
            ),
            candidates: [
                LazyLibrarianCandidate(
                    bookID: "OLX",
                    title: "Different Title",
                    author: "F. Scott Fitzgerald",
                    isbn: "080442957X",
                    year: "1925",
                ),
                LazyLibrarianCandidate(
                    bookID: "OTHER",
                    title: "The Great Gatsby",
                    author: "F. Scott Fitzgerald",
                    isbn: "1111111111",
                    year: "1925",
                ),
            ],
        )
        guard case .success(let hit) = chosen else {
            Issue.record("expected ISBN-10 X match")
            return
        }
        #expect(hit.bookID == "OLX")
    }

    @Test func isbn10EndingInXIsUsedForFindBookLookup() async {
        let script = Script()
        script.handler = { cmd, query in
            if cmd == "findBook", query["name"] == "080442957X" {
                return Script.http(
                    self.hit(
                        id: "OLX",
                        title: "The Great Gatsby",
                        author: "F. Scott Fitzgerald",
                        isbn: "080442957X",
                        year: "1925",
                    )
                )
            }
            if cmd == "findBook" {
                return Script.http("[]")
            }
            if cmd == "getBook" {
                return Script.http(
                    #"{"book":[{"BookID":"OLX","Status":"Open","AudioStatus":"Open"}]}"#
                )
            }
            return Script.http("OK")
        }
        let outcomes = await LazyLibrarianClient(transport: script).request(
            work: work(
                title: "The Great Gatsby",
                author: "F. Scott Fitzgerald",
                isbn: "080442957x",
                year: "1925",
            ),
            formats: [.ebook],
            baseURL: base,
            apiKey: key,
        )
        #expect(outcomes.map(\.phase) == [.searching])
        #expect(script.calls.contains { $0.cmd == "findBook" && $0.query["name"] == "080442957X" })
        #expect(script.calls.filter { $0.cmd == "queueBook" }.map { $0.query["id"] } == ["OLX"])
    }

    @Test func ambiguousMatchDoesNotQueue() async {
        let script = Script()
        script.handler = { cmd, _ in
            if cmd == "findBook" {
                return Script.http(
                    """
                    [\
                    {"bookid":"A","bookname":"Emma","authorname":"Jane Austen","bookpub":"1815"},\
                    {"bookid":"B","bookname":"Emma","authorname":"Jane Austen","bookpub":"1815"}\
                    ]
                    """
                )
            }
            return Script.http("OK")
        }
        let outcomes = await LazyLibrarianClient(transport: script).request(
            work: work(title: "Emma", year: "1815"),
            formats: [.ebook, .audiobook],
            baseURL: base,
            apiKey: key,
        )
        #expect(outcomes.allSatisfy { $0.phase == .needsAttention })
        #expect(outcomes.allSatisfy { $0.detail.contains("couldn’t confidently choose") })
        #expect(outcomes[0].matchAttention == .ambiguous)
        #expect(outcomes[0].matchCandidates.count == 2)
        #expect(!script.commands.contains("queueBook"))
        #expect(!script.commands.contains("addBook"))
    }

    @Test func rejectsADifferentAuthor() async {
        let script = Script()
        script.handler = { cmd, _ in
            if cmd == "findBook" {
                return Script.http(self.hit(id: "DICKENS", author: "Charles Dickens"))
            }
            return Script.http("OK")
        }
        let outcomes = await LazyLibrarianClient(transport: script).request(
            work: work(),
            formats: [.ebook],
            baseURL: base,
            apiKey: key,
        )
        #expect(outcomes.map(\.phase) == [.failed])
        #expect(outcomes[0].detail.contains("No LazyLibrarian candidates were found"))
        #expect(outcomes[0].matchAttention == .noMatch)
        #expect(outcomes[0].matchCandidates.isEmpty)
        #expect(!script.commands.contains("queueBook"))
    }

    @Test func queuesBothFormatsOnce() async throws {
        let script = Script()
        script.handler = { cmd, _ in
            switch cmd {
                case "findBook":
                    return Script.http(self.hit())
                case "getBook":
                    script.gets += 1
                    if script.gets == 1 { return Script.http(#"{"book":[]}"#) }
                    return Script.http(self.owned(ebook: "Open", audio: "Open"))
                case "addBook":
                    return Script.http("Added")
                default:
                    return Script.http("OK")
            }
        }
        let outcomes = await LazyLibrarianClient(transport: script).request(
            work: work(),
            formats: [.ebook, .audiobook],
            baseURL: base,
            apiKey: key,
        )
        #expect(outcomes.map(\.phase) == [.searching, .searching])
        #expect(script.calls.filter { $0.cmd == "addBook" }.count == 1)
        #expect(script.calls.filter { $0.cmd == "addBook" }.allSatisfy { $0.query["wait"] == "1" })
        #expect(script.calls.filter { $0.cmd == "queueBook" }.map { $0.query["type"] } == ["eBook", "AudioBook"])
        #expect(script.calls.filter { $0.cmd == "searchBook" }.map { $0.query["type"] } == ["eBook", "AudioBook"])
        #expect(Set(script.calls.filter { $0.cmd == "queueBook" }.map { $0.query["id"] }) == ["OL1W"])
    }

    @Test func alreadyWantedDoesNotQueueAgain() async {
        let script = readyScript(owned: owned(ebook: "Wanted", audio: "Have"))
        let outcomes = await LazyLibrarianClient(transport: script).request(
            work: work(),
            formats: [.ebook, .audiobook],
            baseURL: base,
            apiKey: key,
        )
        #expect(outcomes.map(\.phase) == [.alreadyRequested, .alreadyAvailable])
        #expect(!script.commands.contains("queueBook"))
        #expect(!script.commands.contains("searchBook"))
        #expect(!script.commands.contains("addBook"))
    }

    @Test func queueFailureDoesNotClaimASearch() async {
        let script = readyScript(owned: owned(ebook: "Open", audio: "Open"))
        script.handler = { cmd, query in
            if cmd == "queueBook" { return Script.http("Invalid id: OL1W") }
            return self.readyHandler(owned: self.owned(ebook: "Open", audio: "Open"))(cmd, query)
        }
        let outcomes = await LazyLibrarianClient(transport: script).request(
            work: work(),
            formats: [.ebook],
            baseURL: base,
            apiKey: key,
        )
        #expect(outcomes.map(\.phase) == [.failed])
        #expect(!script.commands.contains("searchBook"))
    }

    @Test func serverTextDoesNotKeepTheAPIKey() async {
        let script = readyScript(owned: owned(ebook: "Open", audio: "Open"))
        script.handler = { cmd, query in
            if cmd == "queueBook" { return Script.http("rejected \(self.key)") }
            return self.readyHandler(owned: self.owned(ebook: "Open", audio: "Open"))(cmd, query)
        }
        let outcomes = await LazyLibrarianClient(transport: script).request(
            work: work(),
            formats: [.ebook],
            baseURL: base,
            apiKey: key,
        )
        #expect(outcomes.map(\.phase) == [.failed])
        #expect(!outcomes[0].detail.contains(key))
    }

    @Test func malformedFindResultFailsClosed() async {
        let script = Script()
        script.handler = { _, _ in Script.http("not-json") }
        let outcomes = await LazyLibrarianClient(transport: script).request(
            work: work(),
            formats: [.ebook],
            baseURL: base,
            apiKey: key,
        )
        #expect(outcomes.map(\.phase) == [.failed])
        #expect(!script.commands.contains("queueBook"))
    }

    @Test func requestTimeoutDoesNotEchoTheKey() async {
        let script = Script()
        script.error = URLError(.timedOut)
        let outcomes = await LazyLibrarianClient(transport: script).request(
            work: work(),
            formats: [.ebook],
            baseURL: base,
            apiKey: key,
        )
        #expect(outcomes.map(\.phase) == [.failed])
        #expect(outcomes[0].detail.contains("timed out"))
        #expect(!outcomes[0].detail.contains(key))
        #expect(!outcomes[0].detail.contains("192.168"))
    }

    @Test func providerPreferenceUsesTheConfiguredOne() {
        #expect(
            BookRequestRouting.choose(
                preference: .automatic,
                lazyLibrarianReady: true,
                shelfarrReady: true,
            ) == .lazyLibrarian
        )
        #expect(
            BookRequestRouting.choose(
                preference: .automatic,
                lazyLibrarianReady: false,
                shelfarrReady: true,
            ) == .shelfarr
        )
        #expect(
            BookRequestRouting.choose(
                preference: .lazyLibrarian,
                lazyLibrarianReady: true,
                shelfarrReady: true,
            ) == .lazyLibrarian
        )
        #expect(
            BookRequestRouting.choose(
                preference: .shelfarr,
                lazyLibrarianReady: true,
                shelfarrReady: false,
            ) == nil
        )
        #expect(
            BookRequestRouting.choose(
                preference: .lazyLibrarian,
                lazyLibrarianReady: false,
                shelfarrReady: false,
            ) == nil
        )
    }

    private func readyScript(owned: String) -> Script {
        let script = Script()
        script.handler = readyHandler(owned: owned)
        return script
    }

    private func readyHandler(owned: String) -> (String, [String: String]) -> LazyLibrarianHTTP {
        { cmd, _ in
            if cmd == "findBook" { return Script.http(self.hit()) }
            if cmd == "getBook" { return Script.http(owned) }
            return Script.http("OK")
        }
    }
}

private final class Script: LazyLibrarianTransport, @unchecked Sendable {
    struct Call {
        var cmd: String
        var query: [String: String]
    }

    var calls: [Call] = []
    var gets = 0
    var error: URLError?
    var handler: ((String, [String: String]) -> LazyLibrarianHTTP)?
    private let lock = NSLock()

    var commands: [String] {
        lock.lock()
        defer { lock.unlock() }
        return calls.map(\.cmd)
    }

    func send(_ url: URL, timeout _: TimeInterval) async throws -> LazyLibrarianHTTP {
        if let error { throw error }
        let parts = Self.parts(url)
        lock.lock()
        calls.append(parts)
        lock.unlock()
        return handler?(parts.cmd, parts.query) ?? Self.http("OK")
    }

    static func http(_ body: String, status: Int = 200) -> LazyLibrarianHTTP {
        LazyLibrarianHTTP(status: status, body: Data(body.utf8))
    }

    private static func parts(_ url: URL) -> Call {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var query: [String: String] = [:]
        var cmd = ""
        for item in items {
            if item.name == "cmd" {
                cmd = item.value ?? ""
            } else if item.name != "apikey" {
                query[item.name] = item.value ?? ""
            }
        }
        return Call(cmd: cmd, query: query)
    }
}
