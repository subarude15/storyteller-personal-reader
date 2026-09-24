import Foundation
import Testing

@testable import SilveranKit

@Suite("Book-first audiobook resolution")
struct AudiobookResolutionTests {
    private func work(
        title: String = "Pride and Prejudice",
        subtitle: String? = nil,
        authors: [String] = ["Jane Austen"],
        language: String? = "en",
        isbn: String? = nil,
        openLibraryWorkID: String? = "/works/OL1W",
    ) -> CanonicalBookWork {
        CanonicalBookWork(
            workID: "work-1",
            title: title,
            subtitle: subtitle,
            authors: authors,
            language: language,
            isbn: isbn,
            openLibraryWorkID: openLibraryWorkID,
            openLibraryEditionID: nil,
            publicationYear: "1813",
        )
    }

    private func item(
        id: String = "52",
        title: String = "Pride and Prejudice",
        authors: [String] = ["Jane Austen"],
        language: String? = "English",
        isbn: String? = nil,
        openLibraryWorkID: String? = nil,
        chapters: [ResolvedAudiobookChapter]? = nil,
    ) -> AudiobookProviderItem {
        AudiobookProviderItem(
            provider: .librivox,
            providerItemID: id,
            title: title,
            authors: authors,
            narrator: "Jane Smith",
            language: language,
            duration: 320,
            artworkURL: nil,
            description: nil,
            sourceURL: nil,
            chapters: chapters ?? [
                ResolvedAudiobookChapter(
                    id: "1",
                    title: "Chapter 01",
                    order: 1,
                    playbackURL: URL(string: "https://archive.org/1.mp3")!,
                    duration: 180,
                )
            ],
            isbn: isbn,
            openLibraryWorkID: openLibraryWorkID,
        )
    }

    @Test func normalizesTitles() {
        #expect(AudiobookText.normalizedTitle("The Hobbit!") == "hobbit")
        #expect(AudiobookText.normalizedTitle("Pride and Prejudice (version 2)") == "pride and prejudice")
        #expect(
            AudiobookText.normalizedTitle("The Hobbit: An Unexpected Journey") == "hobbit"
        )
        #expect(AudiobookText.normalizedTitle("Dune", subtitle: "Illustrated") == "dune")
        #expect(AudiobookText.searchTitle("  Pride and Prejudice  ", subtitle: nil) == "Pride and Prejudice")
    }

    @Test func normalizesAuthors() {
        #expect(AudiobookText.normalizedAuthor("Austen, Jane") == "jane austen")
        #expect(AudiobookText.normalizedAuthor("J.R.R. Tolkien") == "jrr tolkien")
        #expect(AudiobookText.authorSurname("Herbert, Frank") == "Herbert")
        #expect(AudiobookText.authorSurname("Honoré de Balzac") == "Balzac")
        #expect(AudiobookText.languageCode("English") == "en")
        #expect(AudiobookText.languageCode("fra") == "fr")
    }

    @Test func matchesExactTitleAndAuthor() {
        let matched = AudiobookMatcher.match(
            work(),
            item: item(title: "Pride and Prejudice (version 2)", authors: ["Austen, Jane"]),
        )
        #expect(matched?.match.confidence == .exact)
        #expect(matched?.provider == .librivox)
        #expect(matched?.narrator == "Jane Smith")
    }

    @Test func matchesInitialsToExpandedGivenNames() {
        let pairs = [
            ("J. R. R. Tolkien", "John Ronald Reuel Tolkien"),
            ("J.R.R. Tolkien", "John Ronald Reuel Tolkien"),
            ("Tolkien, J. R. R.", "John Ronald Reuel Tolkien"),
            ("C. S. Lewis", "Clive Staples Lewis"),
            ("J. Austen", "Jane Austen"),
        ]
        for (left, right) in pairs {
            let forward = AudiobookMatcher.match(
                work(title: "The Hobbit", authors: [left]),
                item: item(title: "The Hobbit", authors: [right]),
            )
            let backward = AudiobookMatcher.match(
                work(title: "The Hobbit", authors: [right]),
                item: item(title: "The Hobbit", authors: [left]),
            )
            #expect(forward?.match.confidence == .exact, "\(left) should match \(right)")
            #expect(backward?.match.confidence == .exact, "\(right) should match \(left)")
        }
    }

    @Test func rejectsContradictoryAuthorComponents() {
        #expect(
            AudiobookMatcher.match(
                work(title: "The Hobbit", authors: ["J. R. R. Tolkien"]),
                item: item(title: "The Hobbit", authors: ["John Tolkien"]),
            ) == nil
        )
        #expect(
            AudiobookMatcher.match(
                work(title: "Pride and Prejudice", authors: ["Jane Austen"]),
                item: item(title: "Pride and Prejudice", authors: ["John Austen"]),
            ) == nil
        )
        #expect(
            AudiobookMatcher.match(
                work(title: "The Hobbit", authors: ["J. R. R. Tolkien"]),
                item: item(title: "The Hobbit", authors: ["C. S. Lewis"]),
            ) == nil
        )
    }

    @Test func rejectsUnrelatedTitlesAndAuthors() {
        #expect(AudiobookMatcher.match(work(title: "Dune", authors: ["Frank Herbert"]), item: item(title: "Dune Messiah")) == nil)
        #expect(AudiobookMatcher.match(work(), item: item(title: "Pride and Prejudice and Zombies")) == nil)
        #expect(AudiobookMatcher.match(work(), item: item(authors: ["Someone Else"])) == nil)
        let ranked = AudiobookMatcher.rank(
            work: work(title: "Dune", authors: ["Frank Herbert"]),
            items: [
                item(id: "messiah", title: "Dune Messiah", authors: ["Frank Herbert"]),
                item(id: "other", title: "Dune", authors: ["Frank Herbert"]),
            ],
        )
        #expect(ranked.map(\.providerItemID) == ["other"])
    }

    @Test func keepsWeakMatchesVisible() {
        let missingAuthor = AudiobookMatcher.match(work(), item: item(authors: []))
        #expect(missingAuthor?.match.confidence == .weak)
        #expect(missingAuthor?.match.reasons.contains("Author wasn't available to confirm") == true)

        let otherLanguage = AudiobookMatcher.match(
            work(language: "en"),
            item: item(language: "French"),
        )
        #expect(otherLanguage?.match.confidence == .weak)
        #expect(otherLanguage?.match.reasons.contains("Language differs from the selected book") == true)
    }

    @Test func identifierCanConfirmWhenTitleDiffers() {
        let matched = AudiobookMatcher.match(
            work(title: "Pride & Prejudice", isbn: "978-0-14-143951-8"),
            item: item(title: "A different catalog label", authors: ["Nope"], isbn: "9780141439518"),
        )
        #expect(matched?.match.confidence == .exact)
    }

    @Test func rejectsDifferentOpenLibraryWork() {
        let matched = AudiobookMatcher.match(
            work(openLibraryWorkID: "/works/OL1W"),
            item: item(openLibraryWorkID: "/works/OL2W"),
        )
        #expect(matched == nil)
    }

    @Test func decodesProviderFixtureAndKeepsChapterOrder() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "librivox-audiobook",
                withExtension: "json",
                subdirectory: "Fixtures",
            )
        )
        let data = try Data(contentsOf: url)
        let items = try LibriVoxAudiobookProvider.decode(data)
        #expect(items.count == 2)
        let pride = try #require(items.first { $0.providerItemID == "52" })
        #expect(pride.provider == .librivox)
        #expect(pride.authors == ["Jane Austen"])
        #expect(pride.narrator == "Jane Smith, John Doe")
        #expect(pride.description == "A novel by Jane Austen.")
        #expect(pride.duration == 500)
        #expect(pride.chapters.map(\.order) == [1, 2])
        #expect(pride.chapters.map(\.title) == ["Chapter 01", "Chapter 02"])
        #expect(pride.chapters[0].duration == 180)
        #expect(pride.chapters[1].duration == 140)
        #expect(pride.chapters[0].playbackURL.absoluteString.contains("01.mp3"))
        let messiah = try #require(items.first { $0.providerItemID == "99" })
        #expect(messiah.duration == 25)
        #expect(messiah.chapters[0].duration == 10)

        let selected = work()
        let ranked = AudiobookMatcher.rank(work: selected, items: items)
        #expect(ranked.map(\.providerItemID) == ["52"])
        let playback = try #require(ranked[0].playbackMetadata())
        #expect(playback.tracks.count == 2)
        #expect(playback.chapters.map(\.title) == ["Chapter 01", "Chapter 02"])
        #expect(playback.tracks[0].startTime == 0)
        #expect(playback.tracks[1].startTime == 180)
        #expect(playback.tracks[0].url != playback.tracks[1].url)
    }

    @Test func emptyProviderResultsStayEmpty() throws {
        let items = try LibriVoxAudiobookProvider.decode(Data("{\"books\":[]}".utf8))
        #expect(items.isEmpty)
    }

    @Test func emptySuccessfulSearchIsNotProviderUnavailable() async {
        let provider = LibriVoxAudiobookProvider { _ in
            Data("{\"books\":[]}".utf8)
        }
        let outcome = await AudiobookResolution.lookup(work: work(), providers: [provider])
        #expect(outcome.results.isEmpty)
        #expect(outcome.failure == nil)
    }

    @Test func validLibriVoxResponseReturnsItems() async throws {
        let payload = try Data(contentsOf: fixtureURL())
        let provider = LibriVoxAudiobookProvider { _ in payload }
        let items = try await provider.search(work())
        #expect(items.contains { $0.providerItemID == "52" })
    }

    @Test func http429IsRateLimited() async {
        let provider = LibriVoxAudiobookProvider { _ in
            throw AudiobookProviderError.rateLimited
        }
        let outcome = await AudiobookResolution.lookup(work: work(), providers: [provider])
        #expect(outcome.results.isEmpty)
        #expect(outcome.failure == .providerIssue(.librivox, .rateLimited))
        #expect(outcome.failure?.message.contains("rate-limiting") == true)
    }

    @Test func http500IsUnexpectedResponse() async {
        let provider = LibriVoxAudiobookProvider { _ in
            throw AudiobookProviderError.httpStatus(500)
        }
        let outcome = await AudiobookResolution.lookup(work: work(), providers: [provider])
        #expect(outcome.failure == .providerIssue(.librivox, .unexpectedResponse))
        #expect(outcome.failure?.message.contains("unexpected response") == true)
    }

    @Test func timeoutAndNetworkErrorsAreDistinct() async {
        let timeout = await AudiobookResolution.lookup(
            work: work(),
            providers: [StubProvider(error: AudiobookProviderError.timeout)],
        )
        #expect(timeout.failure == .providerIssue(.librivox, .timeout))
        #expect(timeout.failure?.message.contains("timed out") == true)

        let unreachable = await AudiobookResolution.lookup(
            work: work(),
            providers: [StubProvider(error: AudiobookProviderError.unreachable)],
        )
        #expect(unreachable.failure == .providerIssue(.librivox, .unreachable))
        #expect(unreachable.failure?.message.contains("couldn't be reached") == true)
    }

    @Test func malformedJSONIsUnexpectedResponse() async {
        let provider = LibriVoxAudiobookProvider { _ in
            Data("not-json".utf8)
        }
        let outcome = await AudiobookResolution.lookup(work: work(), providers: [provider])
        #expect(outcome.results.isEmpty)
        #expect(outcome.failure == .providerIssue(.librivox, .unexpectedResponse))
    }

    @Test func providerFailureDoesNotInventResults() async {
        let provider = StubProvider(error: AudiobookProviderError.unreachable)
        let outcome = await AudiobookResolution.lookup(work: work(), providers: [provider])
        #expect(provider.calls == 1)
        #expect(outcome.results.isEmpty)
        #expect(outcome.failure == .providerIssue(.librivox, .unreachable))
    }

    @Test func insufficientMetadataDoesNotQueryProviders() async {
        let provider = StubProvider(items: [item()])
        let outcome = await AudiobookResolution.lookup(
            work: work(title: " "),
            providers: [provider],
        )
        #expect(provider.calls == 0)
        #expect(outcome.failure == .insufficientMetadata)
    }

    @Test func queryURLsStayOnTheSelectedTitle() {
        let urls = LibriVoxAudiobookProvider.queryURLs(for: work())
        #expect(urls.count == 3)
        for url in urls {
            let query = url.absoluteString
            #expect(!query.contains("offset"))
            #expect(!query.contains("since="))
            #expect(query.contains("limit=15"))
            #expect(query.contains("extended=1"))
            #expect(query.contains("Pride"))
        }
        #expect(urls[0].absoluteString.contains("author=Austen"))
        #expect(!urls[1].absoluteString.contains("author="))
    }

    @Test func stopsAfterTheFirstNonEmptyProviderPage() async throws {
        let payload = try Data(contentsOf: fixtureURL())
        let fetches = FetchCounter()
        let provider = LibriVoxAudiobookProvider { url in
            fetches.count += 1
            if url.absoluteString.contains("author=") {
                return Data("{\"books\":[]}".utf8)
            }
            return payload
        }
        let items = try await provider.search(work())
        #expect(fetches.count == 2)
        #expect(items.contains { $0.providerItemID == "52" })
    }

    @Test func resumeStateRoundTrips() {
        let suite = "inkamp.audiobookResume.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = AudiobookResumeStore(defaults: defaults, key: "test")
        #expect(store.state(workID: "work-1", provider: .librivox, providerItemID: "52") == nil)
        let saved = AudiobookResumeState(
            workID: "work-1",
            provider: .librivox,
            providerItemID: "52",
            chapterIndex: 1,
            chapterPosition: 42,
            completed: false,
            updatedAt: Date(timeIntervalSince1970: 10),
        )
        store.save(saved)
        #expect(store.state(workID: "work-1", provider: .librivox, providerItemID: "52") == saved)
        let finished = AudiobookResumeState(
            workID: "work-1",
            provider: .librivox,
            providerItemID: "52",
            chapterIndex: 2,
            chapterPosition: 0,
            completed: true,
            updatedAt: Date(timeIntervalSince1970: 20),
        )
        store.save(finished)
        let loaded = store.state(workID: "work-1", provider: .librivox, providerItemID: "52")
        #expect(loaded?.completed == true)
        #expect(loaded?.chapterIndex == 2)
        #expect(store.state(workID: "other", provider: .librivox, providerItemID: "52") == nil)
        defaults.removePersistentDomain(forName: suite)
    }

    private func fixtureURL() throws -> URL {
        try #require(
            Bundle.module.url(
                forResource: "librivox-audiobook",
                withExtension: "json",
                subdirectory: "Fixtures",
            )
        )
    }
}

private final class FetchCounter: @unchecked Sendable {
    var count = 0
}

private final class StubProvider: AudiobookCatalogProviding, @unchecked Sendable {
    var kind: AudiobookProviderKind { .librivox }
    var calls = 0
    var items: [AudiobookProviderItem]
    var error: Error?

    init(items: [AudiobookProviderItem] = [], error: Error? = nil) {
        self.items = items
        self.error = error
    }

    func search(_ work: CanonicalBookWork) async throws -> [AudiobookProviderItem] {
        calls += 1
        if let error { throw error }
        return items
    }
}
