import Foundation
import Testing

@testable import SilveranKit

@Suite("LazyLibrarian match resolution")
struct LazyLibrarianMatchTests {
    private func work(
        title: String = "Last Days",
        author: String = "Adam Nevill",
        isbn: String? = nil,
        isbn10: String? = nil,
        isbn13: String? = nil,
        openLibraryWorkID: String? = nil,
        openLibraryEditionID: String? = nil,
        year: String? = "2012",
    ) -> CanonicalBookWork {
        CanonicalBookWork(
            workID: "library-last-days",
            title: title,
            subtitle: nil,
            authors: [author],
            language: "en",
            isbn: isbn,
            openLibraryWorkID: openLibraryWorkID,
            openLibraryEditionID: openLibraryEditionID,
            publicationYear: year,
            isbn10: isbn10,
            isbn13: isbn13,
        )
    }

    private func candidate(
        id: String,
        title: String = "Last Days",
        author: String = "Adam Nevill",
        isbn: String? = nil,
        year: String? = "2012",
        openLibraryWorkID: String? = nil,
    ) -> LazyLibrarianCandidate {
        LazyLibrarianCandidate(
            bookID: id,
            title: title,
            author: author,
            isbn: isbn,
            year: year,
            openLibraryWorkID: openLibraryWorkID,
        )
    }

    @Test func openLibraryWorkMatchBeatsADifferentTitle() {
        let decision = LazyLibrarianMatcher.resolve(
            work: work(openLibraryWorkID: "/works/OL17356704W"),
            candidates: [
                candidate(id: "OTHER", title: "Last Days"),
                candidate(
                    id: "OL17356704W",
                    title: "Something Else",
                    openLibraryWorkID: "/works/OL17356704W",
                ),
            ],
            preference: .askWhenUncertain,
        )
        guard case .matched(let hit, let reason, let tier) = decision else {
            Issue.record("expected OpenLibrary work match")
            return
        }
        #expect(hit.bookID == "OL17356704W")
        #expect(reason == "Matched by OpenLibrary work")
        #expect(tier == .openLibraryWork)
    }

    @Test func isbnMatchWinsWhenTheTitleDiffers() {
        let decision = LazyLibrarianMatcher.resolve(
            work: work(isbn: "978-0-312-64217-4", isbn13: "9780312642174"),
            candidates: [
                candidate(id: "TITLE", title: "Last Days", isbn: "1111111111"),
                candidate(id: "ISBN", title: "Different Title", isbn: "9780312642174"),
            ],
            preference: .askWhenUncertain,
        )
        guard case .matched(let hit, let reason, _) = decision else {
            Issue.record("expected ISBN match")
            return
        }
        #expect(hit.bookID == "ISBN")
        #expect(reason == "Matched by ISBN")
    }

    @Test func exactNormalizedTitleAndAuthorMatches() {
        let decision = LazyLibrarianMatcher.resolve(
            work: work(),
            candidates: [candidate(id: "LL1")],
            preference: .askWhenUncertain,
        )
        guard case .matched(let hit, let reason, let tier) = decision else {
            Issue.record("expected title + author match")
            return
        }
        #expect(hit.bookID == "LL1")
        #expect(reason == "Matched by title + author")
        #expect(tier == .exactTitleAuthor)
    }

    @Test func punctuationAndCaseStillMatchTitleAndAuthor() {
        let decision = LazyLibrarianMatcher.resolve(
            work: work(title: "LAST DAYS!", author: "Nevill, Adam"),
            candidates: [candidate(id: "LL1", title: "Last Days", author: "Adam Nevill")],
            preference: .askWhenUncertain,
        )
        guard case .matched(let hit, _, let tier) = decision else {
            Issue.record("expected normalized title + author match")
            return
        }
        #expect(hit.bookID == "LL1")
        #expect(tier == .exactTitleAuthor)
    }

    @Test func sameTitleWrongAuthorDoesNotAutoMatch() {
        let decision = LazyLibrarianMatcher.resolve(
            work: work(),
            candidates: [candidate(id: "WRONG", author: "Stephen King")],
            preference: .useBestMatch,
        )
        #expect(decision == .noMatch)
    }

    @Test func multiplePlausibleCandidatesNeedAttention() {
        let candidates = [
            candidate(id: "B", year: "2012"),
            candidate(id: "A", year: "2012"),
        ]
        let ask = LazyLibrarianMatcher.resolve(
            work: work(year: "2012"),
            candidates: candidates,
            preference: .askWhenUncertain,
        )
        guard case .ambiguous(_, let shown) = ask else {
            Issue.record("expected needs-attention ambiguity")
            return
        }
        #expect(Set(shown.map(\.bookID)) == ["A", "B"])

        let auto = LazyLibrarianMatcher.resolve(
            work: work(year: "2012"),
            candidates: candidates,
            preference: .useBestMatch,
        )
        guard case .ambiguous = auto else {
            Issue.record("a tie must stay needs attention even in automatic mode")
            return
        }
        #expect(
            LazyLibrarianMatcher.bestResolvable(
                work: work(year: "2012"),
                candidates: candidates,
            ) == nil
        )
    }

    @Test func tiedTitleAndAuthorStaysAmbiguousWhenBookIDSortsFirst() {
        let candidates = [
            candidate(id: "B", year: nil),
            candidate(id: "A", year: nil),
        ]
        let decision = LazyLibrarianMatcher.resolve(
            work: work(year: nil),
            candidates: candidates,
            preference: .useBestMatch,
        )
        guard case .ambiguous(_, let shown) = decision else {
            Issue.record("equal title and author must not be split by bookID")
            return
        }
        #expect(Set(shown.map(\.bookID)) == Set(["A", "B"]))
        #expect(LazyLibrarianMatcher.bestResolvable(work: work(year: nil), candidates: candidates) == nil)
    }

    @Test func automaticModeSelectsUniquelyStrongerMetadata() {
        let byYear = LazyLibrarianMatcher.resolve(
            work: work(year: "2012"),
            candidates: [
                candidate(id: "A", year: "1999"),
                candidate(id: "B", year: "2012"),
            ],
            preference: .useBestMatch,
        )
        if case .matched(let yearHit, _, let yearTier) = byYear {
            #expect(yearHit.bookID == "B")
            #expect(yearTier == .exactTitleAuthor)
        } else {
            Issue.record("publication year should separate an otherwise equal pair")
        }

        let byISBN = LazyLibrarianMatcher.resolve(
            work: work(isbn13: "9780312642174"),
            candidates: [
                candidate(id: "A", isbn: "1111111111"),
                candidate(id: "Z", title: "Last Days", isbn: "9780312642174"),
            ],
            preference: .useBestMatch,
        )
        if case .matched(let isbnHit, let reason, _) = byISBN {
            #expect(isbnHit.bookID == "Z")
            #expect(reason == "Matched by ISBN")
        } else {
            Issue.record("ISBN should beat a title and author hit")
        }
    }

    @Test func titleOnlyResultsAreNotUsedAutomatically() {
        let only = LazyLibrarianMatcher.resolve(
            work: work(),
            candidates: [candidate(id: "BARE", author: "")],
            preference: .useBestMatch,
        )
        guard case .ambiguous = only else {
            Issue.record("title-only must stay needs attention")
            return
        }
        #expect(
            LazyLibrarianMatcher.bestResolvable(
                work: work(),
                candidates: [candidate(id: "BARE", author: "")],
            ) == nil
        )
    }

    @Test func useBestMatchUpdatesTheExistingRequest() async {
        let defaults = UserDefaults(suiteName: "ll-match-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }
        let store = RequestActivityStore(defaults: defaults)
        let item = attentionItem()
        store.upsert(item)
        let script = MatchScript()
        script.handler = { cmd, _ in
            if cmd == "getBook" {
                return MatchScript.http(#"{"book":[{"BookID":"A","Status":"Open","AudioStatus":"Open"}]}"#)
            }
            return MatchScript.http("OK")
        }
        let outcomes = await LazyLibrarianClient(transport: script).queueResolved(
            bookID: "A",
            formats: [.ebook],
            baseURL: "http://192.168.1.20:5299",
            apiKey: "abc123secret",
            matchReason: "Matched by title + author",
        )
        store.recordSubmission(
            work: item.canonicalWorkForRetry(),
            provider: .lazyLibrarian,
            outcomes: outcomes,
            existingRequestID: item.id,
        )
        let rows = store.allItems()
        #expect(rows.count == 1)
        #expect(rows[0].id == item.id)
        #expect(rows[0].status(for: .ebook)?.status == .searching)
        #expect(rows[0].providerBookID == "A")
        #expect(rows[0].matchReason == "Matched by title + author")
        #expect(rows[0].matchCandidates == nil)
        #expect(!script.commands.contains("findBook"))
        #expect(script.commands.contains("queueBook"))
    }

    @Test func choosingACandidateDoesNotCreateAnotherRequest() async {
        let defaults = UserDefaults(suiteName: "ll-match-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }
        let store = RequestActivityStore(defaults: defaults)
        var item = attentionItem()
        item.matchCandidates = [
            candidate(id: "A"),
            candidate(id: "B", year: "2013"),
        ]
        store.upsert(item)
        let script = MatchScript()
        script.handler = { cmd, _ in
            if cmd == "getBook" {
                return MatchScript.http(#"{"book":[{"BookID":"B","Status":"Open","AudioStatus":"Open"}]}"#)
            }
            return MatchScript.http("OK")
        }
        let outcomes = await LazyLibrarianClient(transport: script).queueResolved(
            bookID: "B",
            formats: [.ebook],
            baseURL: "http://192.168.1.20:5299",
            apiKey: "abc123secret",
            matchReason: "Chosen LazyLibrarian match",
        )
        store.recordSubmission(
            work: item.canonicalWorkForRetry(),
            provider: .lazyLibrarian,
            outcomes: outcomes,
            existingRequestID: item.id,
        )
        store.recordSubmission(
            work: item.canonicalWorkForRetry(),
            provider: .lazyLibrarian,
            outcomes: outcomes,
            existingRequestID: item.id,
        )
        let rows = store.allItems()
        #expect(rows.count == 1)
        #expect(rows[0].id == item.id)
        #expect(rows[0].providerBookID == "B")
        #expect(script.calls.filter { $0.cmd == "queueBook" }.map { $0.query["id"] } == ["B"])
        #expect(script.calls.filter { $0.cmd == "queueBook" }.map { $0.query["type"] } == ["eBook"])
    }

    @Test func resolvingSkipsTheFormatAlreadyInTheLibrary() {
        var item = attentionItem()
        item.requestedFormats = [.ebook, .audiobook]
        item.formatStatuses.append(
            RequestFormatStatus(format: .audiobook, status: .availableInLibrary, detail: "Available in Library")
        )
        #expect(RequestActivityRetryPolicy.retryableFormats(for: item) == [.ebook])
    }

    @Test func audiobookInLibrarySuppliesEbookLookupMetadata() {
        let book = libraryBook(
            ebookMissing: true,
            audiobookMissing: false,
            description: "Adam Nevill. ISBN 9780312642174. https://openlibrary.org/works/OL17356704W",
        )
        let work = CanonicalBookWork.library(book)
        #expect(work.title == "Last Days")
        #expect(work.authors == ["Adam Nevill"])
        #expect(work.isbn13 == "9780312642174")
        #expect(work.openLibraryWorkID == "/works/OL17356704W")
        #expect(BookRequestLibrary.ownedFormats([book]) == [.audiobook])
        let decision = LazyLibrarianMatcher.resolve(
            work: work,
            candidates: [candidate(id: "OL17356704W", openLibraryWorkID: "/works/OL17356704W")],
            preference: .askWhenUncertain,
        )
        guard case .matched(let hit, let reason, _) = decision else {
            Issue.record("ebook request should reuse audiobook metadata")
            return
        }
        #expect(hit.bookID == "OL17356704W")
        #expect(reason == "Matched by OpenLibrary work")
    }

    @Test func ebookInLibrarySuppliesAudiobookLookupMetadata() {
        let book = libraryBook(
            ebookMissing: false,
            audiobookMissing: true,
            description: "ISBN 9780312642174",
        )
        let work = CanonicalBookWork.library(book)
        #expect(work.authors == ["Adam Nevill"])
        #expect(work.isbn == "9780312642174")
        #expect(BookRequestLibrary.ownedFormats([book]) == [.ebook])
        let decision = LazyLibrarianMatcher.resolve(
            work: work,
            candidates: [candidate(id: "LL1", title: "Last Days!", author: "Nevill, Adam")],
            preference: .askWhenUncertain,
        )
        guard case .matched(let hit, let reason, _) = decision else {
            Issue.record("audiobook request should reuse ebook metadata")
            return
        }
        #expect(hit.bookID == "LL1")
        #expect(reason == "Matched by title + author")
    }

    @Test func automaticMatchingPreferencePersists() {
        let previous = UserDefaults.standard.string(forKey: LazyLibrarianMatchingSettings.key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: LazyLibrarianMatchingSettings.key)
            } else {
                UserDefaults.standard.removeObject(forKey: LazyLibrarianMatchingSettings.key)
            }
        }
        UserDefaults.standard.removeObject(forKey: LazyLibrarianMatchingSettings.key)
        #expect(LazyLibrarianMatchingSettings.preference == .askWhenUncertain)
        LazyLibrarianMatchingSettings.preference = .useBestMatch
        #expect(LazyLibrarianMatchingSettings.preference == .useBestMatch)
        #expect(
            LazyLibrarianAutomaticMatching.preference(
                from: UserDefaults.standard.string(forKey: LazyLibrarianMatchingSettings.key)
            ) == .useBestMatch
        )
    }

    @Test func providerFailureStaysDistinctFromAnAmbiguousMatch() async {
        let down = MatchScript()
        down.error = URLError(.timedOut)
        let failed = await LazyLibrarianClient(transport: down).request(
            work: work(),
            formats: [.ebook],
            baseURL: "http://192.168.1.20:5299",
            apiKey: "abc123secret",
        )
        #expect(failed[0].phase == .failed)
        #expect(failed[0].matchAttention == .providerFailure)
        #expect(failed[0].detail.contains("timed out"))
        #expect(!failed[0].detail.contains("couldn’t confidently choose"))
        #expect(!failed[0].detail.contains("No LazyLibrarian candidates"))

        let ambiguous = MatchScript()
        ambiguous.handler = { cmd, _ in
            if cmd == "findBook" {
                return MatchScript.http(
                    """
                    [{"bookid":"A","bookname":"Last Days","authorname":"Adam Nevill","bookpub":"2012"},\
                    {"bookid":"B","bookname":"Last Days","authorname":"Adam Nevill","bookpub":"2012"}]
                    """
                )
            }
            return MatchScript.http("OK")
        }
        let unsure = await LazyLibrarianClient(transport: ambiguous).request(
            work: work(),
            formats: [.ebook],
            baseURL: "http://192.168.1.20:5299",
            apiKey: "abc123secret",
        )
        #expect(unsure[0].phase == .needsAttention)
        #expect(unsure[0].matchAttention == .ambiguous)
        #expect(unsure[0].detail == LazyLibrarianMatchCopy.ambiguous)
        #expect(unsure[0].matchCandidates.map(\.bookID) == ["A", "B"])
        #expect(!ambiguous.commands.contains("queueBook"))
    }

    private func attentionItem() -> RequestActivityItem {
        RequestActivityItem(
            id: "existing-request",
            canonicalWorkID: "library-last-days",
            title: "Last Days",
            author: "Adam Nevill",
            provider: .lazyLibrarian,
            requestedFormats: [.ebook],
            formatStatuses: [
                RequestFormatStatus(
                    format: .ebook,
                    status: .needsAttention,
                    detail: LazyLibrarianMatchCopy.ambiguous,
                )
            ],
            attentionReason: LazyLibrarianMatchCopy.ambiguous,
            openLibraryWorkID: "/works/OL17356704W",
            matchAttention: .ambiguous,
        )
    }

    private func libraryBook(
        ebookMissing: Bool,
        audiobookMissing: Bool,
        description: String,
    ) -> BookMetadata {
        BookMetadata(
            bookID: BookID(sourceID: "storyteller", uuid: "last-days"),
            title: "Last Days",
            subtitle: nil,
            description: description,
            language: "en",
            createdAt: nil,
            updatedAt: nil,
            publicationDate: "2012-09-01",
            authors: [
                BookCreator(
                    uuid: nil,
                    id: nil,
                    name: "Adam Nevill",
                    fileAs: nil,
                    role: "aut",
                    createdAt: nil,
                    updatedAt: nil,
                )
            ],
            narrators: nil,
            creators: nil,
            series: nil,
            tags: nil,
            collections: nil,
            ebook: BookAsset(
                uuid: "ebook",
                filepath: "last-days.epub",
                missing: ebookMissing ? 1 : 0,
                createdAt: nil,
                updatedAt: nil,
            ),
            audiobook: BookAsset(
                uuid: "audio",
                filepath: "last-days.m4b",
                missing: audiobookMissing ? 1 : 0,
                createdAt: nil,
                updatedAt: nil,
            ),
            readaloud: nil,
            status: nil,
            position: nil,
            rating: nil,
        )
    }
}

private final class MatchScript: LazyLibrarianTransport, @unchecked Sendable {
    struct Call {
        var cmd: String
        var query: [String: String]
    }

    var calls: [Call] = []
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
        lock.lock()
        calls.append(Call(cmd: cmd, query: query))
        lock.unlock()
        return handler?(cmd, query) ?? Self.http("OK")
    }

    static func http(_ body: String, status: Int = 200) -> LazyLibrarianHTTP {
        LazyLibrarianHTTP(status: status, body: Data(body.utf8))
    }
}
