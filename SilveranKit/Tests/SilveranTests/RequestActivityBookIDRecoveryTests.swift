import Foundation
import Testing

@testable import SilveranKit

@Suite("Request Activity LazyLibrarian BookID recovery")
struct RequestActivityBookIDRecoveryTests {
    private let base = "http://192.168.1.20:5299"
    private let key = "abc123secret"

    @Test func recoversMissingBookIDByISBNThenContinuesRefresh() async {
        let script = RecoveryScript()
        script.handler = { cmd, query in
            if cmd == "findBook", query["name"] == "9780141439518" {
                return RecoveryScript.http(self.hit(id: "LL-ISBN", isbn: "9780141439518"))
            }
            if cmd == "findBook" {
                return RecoveryScript.http("[]")
            }
            if cmd == "getBook", query["id"] == "LL-ISBN" {
                return RecoveryScript.http(
                    #"{"book":[{"BookID":"LL-ISBN","Status":"Wanted","AudioStatus":"Open"}]}"#
                )
            }
            return RecoveryScript.http("OK")
        }

        let suiteName = "ll-recovery-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RequestActivityStore(defaults: defaults)
        let seed = legacyItem(
            title: "Pride and Prejudice",
            author: "Jane Austen",
            isbn: "9780141439518",
            providerBookID: nil,
        )
        store.upsert(seed)

        let service = RequestActivityRefreshService(
            client: LazyLibrarianClient(transport: script),
            history: store,
            now: { Date() },
        )
        let updated = await service.refreshOne(
            seed,
            force: true,
            lazyReady: true,
            baseURL: base,
            apiKey: key,
        )

        #expect(updated.providerBookID == "LL-ISBN")
        #expect(updated.status(for: .ebook)?.status == .wanted)
        #expect(updated.lastError == nil)
        #expect(updated.attentionReason == nil)
        #expect(store.item(id: seed.id)?.providerBookID == "LL-ISBN")
        #expect(script.commands.first == "findBook")
        #expect(script.commands.contains("getBook"))
        #expect(script.commands.last == "getBook")
        #expect(!script.commands.contains("addBook"))
        #expect(!script.commands.contains("queueBook"))
        #expect(!script.commands.contains("searchBook"))
    }

    @Test func recoversMissingBookIDByTitleAndAuthor() async {
        let script = RecoveryScript()
        script.handler = { cmd, query in
            if cmd == "findBook" {
                return RecoveryScript.http(
                    self.hit(id: "LL-TITLE", title: "The Reddening", author: "Adam Nevill")
                )
            }
            if cmd == "getBook", query["id"] == "LL-TITLE" {
                return RecoveryScript.http(
                    #"{"book":[{"BookID":"LL-TITLE","Status":"Open","AudioStatus":"Wanted"}]}"#
                )
            }
            return RecoveryScript.http("OK")
        }

        let suiteName = "ll-recovery-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RequestActivityStore(defaults: defaults)
        let seed = legacyItem(
            title: "The Reddening",
            author: "Adam Nevill",
            formats: [.audiobook],
            providerBookID: nil,
            lastError: "Missing LazyLibrarian BookID",
            attentionReason: "Missing LazyLibrarian BookID",
            status: .needsAttention,
        )
        store.upsert(seed)

        let service = RequestActivityRefreshService(
            client: LazyLibrarianClient(transport: script),
            history: store,
            now: { Date() },
        )
        let updated = await service.refreshOne(
            seed,
            force: true,
            lazyReady: true,
            baseURL: base,
            apiKey: key,
        )

        #expect(updated.providerBookID == "LL-TITLE")
        #expect(updated.status(for: .audiobook)?.status == .wanted)
        #expect(updated.lastError == nil)
        #expect(updated.attentionReason == nil)
        #expect(!script.commands.contains("addBook"))
        #expect(!script.commands.contains("queueBook"))
        #expect(!script.commands.contains("searchBook"))
    }

    @Test func authorConflictDoesNotPersistBookID() async {
        let script = RecoveryScript()
        script.handler = { cmd, _ in
            if cmd == "findBook" {
                return RecoveryScript.http(
                    self.hit(id: "LL-WRONG", title: "Pride and Prejudice", author: "Charles Dickens")
                )
            }
            Issue.record("unexpected command \(cmd)")
            return RecoveryScript.http("OK")
        }

        let suiteName = "ll-recovery-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RequestActivityStore(defaults: defaults)
        let seed = legacyItem(
            title: "Pride and Prejudice",
            author: "Jane Austen",
            providerBookID: nil,
        )
        store.upsert(seed)

        let service = RequestActivityRefreshService(
            client: LazyLibrarianClient(transport: script),
            history: store,
            now: { Date() },
        )
        let updated = await service.refreshOne(
            seed,
            force: true,
            lazyReady: true,
            baseURL: base,
            apiKey: key,
        )

        #expect(updated.providerBookID == nil)
        #expect(updated.status(for: .ebook)?.status == .needsAttention)
        #expect(updated.attentionReason == "Could not match this request to a LazyLibrarian book.")
        #expect(updated.lastError == updated.attentionReason)
        #expect(script.commands == ["findBook"])
        #expect(!script.commands.contains("getBook"))
        #expect(!script.commands.contains("addBook"))
        #expect(!script.commands.contains("queueBook"))
        #expect(!script.commands.contains("searchBook"))
    }

    @Test func ambiguousMatchesDoNotGuess() async {
        let script = RecoveryScript()
        script.handler = { cmd, _ in
            if cmd == "findBook" {
                return RecoveryScript.http(
                    """
                    [\
                    {"bookid":"A","bookname":"Emma","authorname":"Jane Austen","bookpub":"1815"},\
                    {"bookid":"B","bookname":"Emma","authorname":"Jane Austen","bookpub":"1815"}\
                    ]
                    """
                )
            }
            Issue.record("unexpected command \(cmd)")
            return RecoveryScript.http("OK")
        }

        let suiteName = "ll-recovery-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RequestActivityStore(defaults: defaults)
        let seed = legacyItem(
            title: "Emma",
            author: "Jane Austen",
            providerBookID: nil,
        )
        store.upsert(seed)

        let service = RequestActivityRefreshService(
            client: LazyLibrarianClient(transport: script),
            history: store,
            now: { Date() },
        )
        let updated = await service.refreshOne(
            seed,
            force: true,
            lazyReady: true,
            baseURL: base,
            apiKey: key,
        )

        #expect(updated.providerBookID == nil)
        #expect(updated.status(for: .ebook)?.status == .needsAttention)
        #expect(updated.attentionReason == "Multiple LazyLibrarian matches found.")
        #expect(!script.commands.contains("getBook"))
        #expect(!script.commands.contains("addBook"))
        #expect(!script.commands.contains("queueBook"))
        #expect(!script.commands.contains("searchBook"))
    }

    // MARK: - Attention clock on recovery failure

    @Test func noMatchStartsAttentionClockNowAndBlocksImmediateFallback() async {
        let wantedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let checkedAt = wantedAt.addingTimeInterval(24 * 3600)
        let script = noMatchScript()

        let suiteName = "ll-recovery-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RequestActivityStore(defaults: defaults)
        let seed = legacyItem(
            title: "Pride and Prejudice",
            author: "Jane Austen",
            providerBookID: nil,
            status: .wanted,
            formatUpdatedAt: wantedAt,
        )
        store.upsert(seed)

        let service = RequestActivityRefreshService(
            client: LazyLibrarianClient(transport: script),
            history: store,
            now: { checkedAt },
        )
        let updated = await service.refreshOne(
            seed,
            force: true,
            lazyReady: true,
            baseURL: base,
            apiKey: key,
        )

        #expect(updated.status(for: .ebook)?.status == .needsAttention)
        #expect(updated.status(for: .ebook)?.updatedAt == checkedAt)
        #expect(updated.attentionReason == "Could not match this request to a LazyLibrarian book.")

        let decision = AutomaticFallbackPolicy.decide(
            item: updated,
            history: [updated],
            settings: AutomaticFallbackSettingsSnapshot(enabled: true, delay: .sixHours),
            context: bothProviders,
            now: checkedAt,
        )
        #expect(decision == .none)
    }

    @Test func ambiguousMatchStartsAttentionClockNow() async {
        let wantedAt = Date(timeIntervalSince1970: 1_700_100_000)
        let checkedAt = wantedAt.addingTimeInterval(24 * 3600)
        let script = RecoveryScript()
        script.handler = { cmd, _ in
            if cmd == "findBook" {
                return RecoveryScript.http(
                    """
                    [\
                    {"bookid":"A","bookname":"Emma","authorname":"Jane Austen","bookpub":"1815"},\
                    {"bookid":"B","bookname":"Emma","authorname":"Jane Austen","bookpub":"1815"}\
                    ]
                    """
                )
            }
            return RecoveryScript.http("OK")
        }

        let suiteName = "ll-recovery-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RequestActivityStore(defaults: defaults)
        let seed = legacyItem(
            title: "Emma",
            author: "Jane Austen",
            providerBookID: nil,
            status: .wanted,
            formatUpdatedAt: wantedAt,
        )
        store.upsert(seed)

        let service = RequestActivityRefreshService(
            client: LazyLibrarianClient(transport: script),
            history: store,
            now: { checkedAt },
        )
        let updated = await service.refreshOne(
            seed,
            force: true,
            lazyReady: true,
            baseURL: base,
            apiKey: key,
        )

        #expect(updated.status(for: .ebook)?.status == .needsAttention)
        #expect(updated.status(for: .ebook)?.updatedAt == checkedAt)
        #expect(updated.attentionReason == "Multiple LazyLibrarian matches found.")
    }

    @Test func existingNeedsAttentionDoesNotResetClockOnRecoveryFailure() async {
        let enteredAt = Date(timeIntervalSince1970: 1_700_200_000)
        let checkedAt = enteredAt.addingTimeInterval(5 * 3600)
        let script = noMatchScript()

        let suiteName = "ll-recovery-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RequestActivityStore(defaults: defaults)
        let seed = legacyItem(
            title: "Pride and Prejudice",
            author: "Jane Austen",
            providerBookID: nil,
            lastError: "Could not match this request to a LazyLibrarian book.",
            attentionReason: "Could not match this request to a LazyLibrarian book.",
            status: .needsAttention,
            formatUpdatedAt: enteredAt,
        )
        store.upsert(seed)

        let service = RequestActivityRefreshService(
            client: LazyLibrarianClient(transport: script),
            history: store,
            now: { checkedAt },
        )
        let updated = await service.refreshOne(
            seed,
            force: true,
            lazyReady: true,
            baseURL: base,
            apiKey: key,
        )

        #expect(updated.status(for: .ebook)?.status == .needsAttention)
        #expect(updated.status(for: .ebook)?.updatedAt == enteredAt)
    }

    @Test func needsAttentionTimelineUsesTransitionTimestamp() async {
        let wantedAt = Date(timeIntervalSince1970: 1_700_300_000)
        let checkedAt = wantedAt.addingTimeInterval(24 * 3600)
        let script = noMatchScript()

        let suiteName = "ll-recovery-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RequestActivityStore(defaults: defaults)
        var seed = legacyItem(
            title: "Pride and Prejudice",
            author: "Jane Austen",
            providerBookID: nil,
            status: .wanted,
            formatUpdatedAt: wantedAt,
        )
        seed.events = [
            RequestActivityEvent(
                date: wantedAt,
                kind: .requested,
                format: .ebook,
                provider: .lazyLibrarian,
                title: "Requested",
            )
        ]
        store.upsert(seed)

        let service = RequestActivityRefreshService(
            client: LazyLibrarianClient(transport: script),
            history: store,
            now: { checkedAt },
        )
        _ = await service.refreshOne(
            seed,
            force: true,
            lazyReady: true,
            baseURL: base,
            apiKey: key,
        )

        let loaded = try #require(store.item(id: seed.id))
        let attentionEvents = RequestActivityTimeline.displayEvents(for: loaded).filter {
            $0.kind == .needsAttention && $0.format == .ebook
        }
        #expect(attentionEvents.count == 1)
        #expect(attentionEvents[0].date == checkedAt)
        #expect(attentionEvents[0].date != wantedAt)
    }

    @Test func alreadyInStorytellerSkipsLazyLibrarianRecovery() async {
        let script = RecoveryScript()
        script.handler = { cmd, _ in
            Issue.record("LL should not be contacted when Storyteller already has the format: \(cmd)")
            return RecoveryScript.http("OK")
        }

        let suiteName = "ll-recovery-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RequestActivityStore(defaults: defaults)
        let seed = legacyItem(
            title: "Dune",
            author: "Frank Herbert",
            formats: [.ebook],
            providerBookID: nil,
            status: .wanted,
        )
        store.upsert(seed)

        let libraryBook = BookMetadata(
            bookID: BookID(sourceID: "storyteller", uuid: "dune-ebook"),
            title: "Dune",
            subtitle: nil,
            description: nil,
            language: nil,
            createdAt: nil,
            updatedAt: nil,
            publicationDate: nil,
            authors: [
                BookCreator(
                    uuid: nil, id: nil, name: "Frank Herbert", fileAs: nil, role: "aut",
                    createdAt: nil, updatedAt: nil
                )
            ],
            narrators: nil,
            creators: nil,
            series: nil,
            tags: nil,
            collections: nil,
            ebook: BookAsset(
                uuid: "dune-ebook", filepath: "dune.epub", missing: 0, createdAt: nil, updatedAt: nil
            ),
            audiobook: nil,
            readaloud: nil,
            status: nil,
            position: nil,
            rating: nil,
        )

        let service = RequestActivityRefreshService(
            client: LazyLibrarianClient(transport: script),
            history: store,
            now: { Date() },
        )
        let updated = await service.refreshOne(
            seed,
            force: true,
            lazyReady: true,
            baseURL: base,
            apiKey: key,
            matcher: RequestLibraryMatcher(books: [libraryBook]),
        )

        #expect(updated.status(for: .ebook)?.status == .availableInLibrary)
        #expect(updated.providerBookID == nil)
        #expect(script.commands.isEmpty)
        #expect(updated.allRequestedFormatsInLibrary)
    }

    @Test func resolveBookIDNeverQueuesOrAdds() async {
        let script = RecoveryScript()
        script.handler = { cmd, _ in
            if cmd == "findBook" {
                return RecoveryScript.http(self.hit(id: "LL-ONLY-FIND"))
            }
            Issue.record("resolveBookID must not call \(cmd)")
            return RecoveryScript.http("OK")
        }
        let result = await LazyLibrarianClient(transport: script).resolveBookID(
            work: CanonicalBookWork(
                workID: "work/1",
                title: "Pride and Prejudice",
                subtitle: nil,
                authors: ["Jane Austen"],
                language: "en",
                isbn: "9780141439518",
                openLibraryWorkID: "/works/OL1W",
                openLibraryEditionID: nil,
                publicationYear: "1813",
            ),
            baseURL: base,
            apiKey: key,
        )
        #expect(result == .success("LL-ONLY-FIND"))
        #expect(script.commands == ["findBook"])
        #expect(!script.commands.contains("addBook"))
        #expect(!script.commands.contains("queueBook"))
        #expect(!script.commands.contains("searchBook"))
        #expect(!script.commands.contains("getBook"))
    }

    @Test func legacyRowRecoversWithoutMigration() async {
        // Existing Request Activity row with missing providerBookID (pre-persistence era).
        let suiteName = "ll-recovery-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RequestActivityStore(defaults: defaults)
        let seed = legacyItem(
            id: "legacy-1",
            canonicalWorkID: "legacy-work",
            title: "Pride and Prejudice",
            author: "Jane Austen",
            isbn: "9780141439518",
            providerBookID: nil,
        )
        store.upsert(seed)
        #expect(store.item(id: "legacy-1")?.providerBookID == nil)

        let script = RecoveryScript()
        script.handler = { cmd, query in
            if cmd == "findBook", query["name"] == "9780141439518" {
                return RecoveryScript.http(self.hit(id: "LL-LEGACY", isbn: "9780141439518"))
            }
            if cmd == "findBook" { return RecoveryScript.http("[]") }
            if cmd == "getBook", query["id"] == "LL-LEGACY" {
                return RecoveryScript.http(
                    #"{"book":[{"BookID":"LL-LEGACY","Status":"Snatched","AudioStatus":"Open"}]}"#
                )
            }
            return RecoveryScript.http("OK")
        }

        let service = RequestActivityRefreshService(
            client: LazyLibrarianClient(transport: script),
            history: store,
            now: { Date() },
        )
        let updated = await service.refreshOne(
            seed,
            force: true,
            lazyReady: true,
            baseURL: base,
            apiKey: key,
        )
        #expect(updated.providerBookID == "LL-LEGACY")
        #expect(updated.status(for: .ebook)?.status == .snatched)
        #expect(store.item(id: "legacy-1")?.providerBookID == "LL-LEGACY")
    }

    // MARK: - Helpers

    private var bothProviders: RequestActivityActionContext {
        RequestActivityActionContext(
            lazyLibrarianEnabled: true,
            lazyLibrarianBaseURL: "https://lazy.example",
            shelfarrBaseURL: "https://shelf.example",
            lazyLibrarianHasAPIKey: true,
            shelfarrHasToken: true,
        )
    }

    private func noMatchScript() -> RecoveryScript {
        let script = RecoveryScript()
        script.handler = { cmd, _ in
            if cmd == "findBook" {
                return RecoveryScript.http(
                    self.hit(id: "LL-WRONG", title: "Pride and Prejudice", author: "Charles Dickens")
                )
            }
            Issue.record("unexpected command \(cmd)")
            return RecoveryScript.http("OK")
        }
        return script
    }

    private func legacyItem(
        id: String = UUID().uuidString,
        canonicalWorkID: String? = nil,
        title: String,
        author: String,
        formats: [BookRequestFormat] = [.ebook],
        isbn: String? = nil,
        providerBookID: String?,
        lastError: String? = nil,
        attentionReason: String? = nil,
        status: RequestActivityStatus = .wanted,
        formatUpdatedAt: Date? = nil,
    ) -> RequestActivityItem {
        let now = Date()
        let formatAt = formatUpdatedAt ?? now
        return RequestActivityItem(
            id: id,
            canonicalWorkID: canonicalWorkID ?? id,
            title: title,
            author: author,
            provider: .lazyLibrarian,
            providerBookID: providerBookID,
            requestedFormats: formats,
            createdAt: formatUpdatedAt ?? now,
            updatedAt: formatAt,
            formatStatuses: formats.map {
                RequestFormatStatus(
                    format: $0,
                    status: status,
                    detail: attentionReason,
                    updatedAt: formatAt,
                )
            },
            lastError: lastError,
            attentionReason: attentionReason,
            isbn: isbn,
        )
    }

    private func hit(
        id: String,
        title: String = "Pride and Prejudice",
        author: String = "Jane Austen",
        isbn: String = "9780141439518",
        year: String = "1813",
    ) -> String {
        """
        [{"bookid":"\(id)","bookname":"\(title)","authorname":"\(author)","bookisbn":"\(isbn)","bookpub":"\(year)"}]
        """
    }
}

private final class RecoveryScript: LazyLibrarianTransport, @unchecked Sendable {
    struct Call {
        var cmd: String
        var query: [String: String]
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    var handler: ((String, [String: String]) -> LazyLibrarianHTTP)?

    var commands: [String] {
        lock.lock()
        defer { lock.unlock() }
        return calls.map(\.cmd)
    }

    func send(_ url: URL, timeout _: TimeInterval) async throws -> LazyLibrarianHTTP {
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
