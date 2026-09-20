import Foundation
import Testing

@testable import SilveranKit

@Suite("Request activity")
struct RequestActivityTests {
    private let base = "http://192.168.1.20:5299"
    private let key = "abc123secret"

    // MARK: - Routing

    @Test func automaticChoosesLazyLibrarianWhenReady() {
        #expect(
            BookRequestRouting.choose(
                preference: .automatic,
                lazyLibrarianReady: true,
                shelfarrReady: true,
            ) == .lazyLibrarian
        )
    }

    @Test func automaticFallsBackToShelfarr() {
        #expect(
            BookRequestRouting.choose(
                preference: .automatic,
                lazyLibrarianReady: false,
                shelfarrReady: true,
            ) == .shelfarr
        )
    }

    @Test func explicitLazyLibrarianRespected() {
        #expect(
            BookRequestRouting.choose(
                preference: .lazyLibrarian,
                lazyLibrarianReady: true,
                shelfarrReady: true,
            ) == .lazyLibrarian
        )
        #expect(
            BookRequestRouting.choose(
                preference: .lazyLibrarian,
                lazyLibrarianReady: false,
                shelfarrReady: true,
            ) == nil
        )
    }

    @Test func explicitShelfarrRespected() {
        #expect(
            BookRequestRouting.choose(
                preference: .shelfarr,
                lazyLibrarianReady: true,
                shelfarrReady: true,
            ) == .shelfarr
        )
        #expect(
            BookRequestRouting.choose(
                preference: .shelfarr,
                lazyLibrarianReady: true,
                shelfarrReady: false,
            ) == nil
        )
    }

    @Test func neitherConfiguredReturnsNil() {
        #expect(
            BookRequestRouting.choose(
                preference: .automatic,
                lazyLibrarianReady: false,
                shelfarrReady: false,
            ) == nil
        )
    }

    @Test func legacyPreferenceStringsStillDecode() {
        #expect(BookRequestProviderKind.preference(from: "lazyLibrarian") == .lazyLibrarian)
        #expect(BookRequestProviderKind.preference(from: "shelfarr") == .shelfarr)
        #expect(BookRequestProviderKind.preference(from: "automatic") == .automatic)
        #expect(BookRequestProviderKind.preference(from: "") == .automatic)
    }

    // MARK: - Storage

    @Test func storeSavesAndReloadsWithoutSecrets() throws {
        let defaults = UserDefaults(suiteName: "request-activity-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }
        let store = RequestActivityStore(defaults: defaults)
        let work = CanonicalBookWork(
            workID: "work/1",
            title: "Dune",
            subtitle: nil,
            authors: ["Frank Herbert"],
            language: "en",
            isbn: nil,
            openLibraryWorkID: "/works/OL1W",
            openLibraryEditionID: nil,
            publicationYear: "1965",
        )
        store.recordSubmission(
            work: work,
            provider: .lazyLibrarian,
            outcomes: [
                BookRequestOutcome(
                    format: .audiobook,
                    phase: .searching,
                    detail: "Searching",
                    providerBookID: "OL1W",
                )
            ],
        )
        let loaded = store.item(forWorkID: "/works/OL1W")
        #expect(loaded?.title == "Dune")
        #expect(loaded?.providerBookID == "OL1W")
        #expect(loaded?.status(for: .audiobook)?.status == .searching)
        let data = try #require(defaults.data(forKey: RequestActivityStore.defaultsKey))
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(!text.contains(key))
        #expect(!text.contains("Bearer"))
        #expect(!text.contains("apikey"))
    }

    @Test func formatStatesPersistIndependently() {
        let defaults = UserDefaults(suiteName: "request-activity-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }
        let store = RequestActivityStore(defaults: defaults)
        let work = work(title: "Dune")
        store.recordSubmission(
            work: work,
            provider: .lazyLibrarian,
            outcomes: [
                BookRequestOutcome(
                    format: .ebook,
                    phase: .alreadyAvailable,
                    detail: "Have",
                    providerBookID: "OL1W",
                ),
                BookRequestOutcome(
                    format: .audiobook,
                    phase: .alreadyRequested,
                    detail: "Wanted",
                    providerBookID: "OL1W",
                ),
            ],
        )
        let item = store.item(forWorkID: work.openLibraryWorkID ?? work.workID)
        #expect(item?.status(for: .ebook)?.status == .alreadyAvailable)
        #expect(item?.status(for: .audiobook)?.status == .alreadyRequested)
    }

    // MARK: - LazyLibrarian mapping

    @Test func lazyLibrarianLookupMapsWantedSnatchedHave() async {
        let script = LLScript()
        script.handler = { cmd, _ in
            #expect(cmd == "getBook")
            return LLScript.http(
                #"{"book":[{"BookID":"OL1W","Status":"Wanted","AudioStatus":"Snatched"}]}"#
            )
        }
        let result = await LazyLibrarianClient(transport: script).lookupBook(
            id: "OL1W",
            baseURL: base,
            apiKey: key,
        )
        switch result {
            case .success(let snapshot):
                #expect(snapshot?.ebook == .wanted)
                #expect(snapshot?.audiobook == .snatched)
                #expect(snapshot?.ebook.activityStatus == .wanted)
                #expect(snapshot?.audiobook.activityStatus == .snatched)
            case .failure(let error):
                Issue.record("unexpected failure \(error)")
        }
    }

    @Test func lazyLibrarianLookupHaveAndMissing() async {
        let have = LLScript()
        have.handler = { _, _ in
            LLScript.http(#"{"book":[{"BookID":"OL1W","Status":"Have","BookLibrary":"/books/dune.epub"}]}"#)
        }
        let haveResult = await LazyLibrarianClient(transport: have).lookupBook(
            id: "OL1W",
            baseURL: base,
            apiKey: key,
        )
        switch haveResult {
            case .success(let snapshot):
                #expect(snapshot?.ebook == .available)
            case .failure(let error):
                Issue.record("unexpected failure \(error)")
        }

        let missing = LLScript()
        missing.handler = { _, _ in LLScript.http(#"{"book":[]}"#) }
        let missingResult = await LazyLibrarianClient(transport: missing).lookupBook(
            id: "GONE",
            baseURL: base,
            apiKey: key,
        )
        switch missingResult {
            case .success(let snapshot):
                #expect(snapshot == nil)
            case .failure(let error):
                Issue.record("unexpected failure \(error)")
        }
    }

    @Test func lazyLibrarianLookupAPIFailure() async {
        let down = LLScript()
        down.error = URLError(.cannotConnectToHost)
        let result = await LazyLibrarianClient(transport: down).lookupBook(
            id: "OL1W",
            baseURL: base,
            apiKey: key,
        )
        guard case .failure = result else {
            Issue.record("expected failure")
            return
        }
    }

    @Test func requestOutcomeIncludesProviderBookID() async {
        let script = LLScript()
        script.handler = { cmd, _ in
            if cmd == "findBook" {
                return LLScript.http(
                    #"[{"bookid":"OL1W","bookname":"Pride and Prejudice","authorname":"Jane Austen","bookisbn":"9780141439518","bookpub":"1813"}]"#
                )
            }
            if cmd == "getBook" {
                return LLScript.http(#"{"book":[{"BookID":"OL1W","Status":"Open","AudioStatus":"Open"}]}"#)
            }
            return LLScript.http("OK")
        }
        let outcomes = await LazyLibrarianClient(transport: script).request(
            work: work(title: "Pride and Prejudice", author: "Jane Austen", isbn: "9780141439518"),
            formats: [.ebook],
            baseURL: base,
            apiKey: key,
        )
        #expect(outcomes.first?.providerBookID == "OL1W")
        #expect(outcomes.first?.phase == .searching || outcomes.first?.phase == .requested)
    }

    // MARK: - Duplicate prevention

    @Test func existingWantedIsNotRequeuedLocally() {
        let defaults = UserDefaults(suiteName: "request-activity-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }
        let store = RequestActivityStore(defaults: defaults)
        let work = work(title: "Dune")
        store.recordSubmission(
            work: work,
            provider: .lazyLibrarian,
            outcomes: [
                BookRequestOutcome(
                    format: .ebook,
                    phase: .alreadyRequested,
                    detail: "Wanted",
                    providerBookID: "OL1W",
                )
            ],
        )
        let item = store.item(forWorkID: work.openLibraryWorkID ?? work.workID)
        #expect(item?.status(for: .ebook)?.status == .alreadyRequested)
    }

    @Test func attentionStaleWantedVsFresh() {
        let now = Date()
        var stale = RequestActivityItem(
            canonicalWorkID: "w1",
            title: "Stale",
            author: "A",
            provider: .lazyLibrarian,
            requestedFormats: [.ebook],
            updatedAt: now,
            formatStatuses: [
                RequestFormatStatus(
                    format: .ebook,
                    status: .wanted,
                    updatedAt: now.addingTimeInterval(-25 * 3600),
                )
            ],
        )
        stale = RequestActivityAttention.apply(stale, now: now)
        #expect(stale.formatStatuses[0].status == .needsAttention)
        #expect(stale.attentionReason != nil)

        var fresh = RequestActivityItem(
            canonicalWorkID: "w2",
            title: "Fresh",
            author: "A",
            provider: .lazyLibrarian,
            requestedFormats: [.ebook],
            updatedAt: now,
            formatStatuses: [
                RequestFormatStatus(
                    format: .ebook,
                    status: .wanted,
                    updatedAt: now.addingTimeInterval(-30 * 60),
                )
            ],
        )
        fresh = RequestActivityAttention.apply(fresh, now: now)
        #expect(fresh.formatStatuses[0].status == .wanted)
        #expect(fresh.attentionReason == nil)
    }

    @Test func temporaryLookupFailureNotImmediatelyEscalated() {
        let now = Date()
        var item = RequestActivityItem(
            canonicalWorkID: "w3",
            title: "Temp",
            author: "A",
            provider: .lazyLibrarian,
            requestedFormats: [.ebook],
            formatStatuses: [
                RequestFormatStatus(
                    format: .ebook,
                    status: .wanted,
                    updatedAt: now,
                    consecutiveLookupFailures: 1,
                )
            ],
        )
        item = RequestActivityAttention.apply(item, now: now)
        #expect(item.formatStatuses[0].status == .wanted)

        item.formatStatuses[0].consecutiveLookupFailures = 3
        item = RequestActivityAttention.apply(item, now: now)
        #expect(item.formatStatuses[0].status == .needsAttention)
    }

    // MARK: - Shelfarr

    @Test func shelfarrRequestedStaysRequestedAfterADay() {
        let now = Date()
        let item = RequestActivityAttention.apply(
            shelfarrItem(status: .requested, updatedAt: now.addingTimeInterval(-25 * 3600)),
            now: now,
        )
        #expect(item.formatStatuses[0].status == .requested)
        #expect(item.attentionReason == nil)
        #expect(RequestActivityGrouping.section(for: item, now: now) == .inProgress)
    }

    @Test func shelfarrRequestedStaysRequestedAfterSeveralDays() {
        let now = Date()
        let item = RequestActivityAttention.apply(
            shelfarrItem(status: .requested, updatedAt: now.addingTimeInterval(-5 * 24 * 3600)),
            now: now,
        )
        #expect(item.formatStatuses[0].status == .requested)
        #expect(item.attentionReason == nil)
    }

    @Test func failedShelfarrSubmissionNeedsAttention() {
        let now = Date()
        let item = RequestActivityAttention.apply(
            shelfarrItem(
                status: .failed,
                detail: "Authentication failed. Check your Shelfarr API token.",
                updatedAt: now,
            ),
            now: now,
        )
        #expect(item.formatStatuses[0].status == .needsAttention)
        #expect(item.attentionReason?.contains("token") == true)
        #expect(RequestActivityGrouping.section(for: item, now: now) == .needsAttention)
    }

    @Test func shelfarrAcceptedDoesNotInventLifecycle() {
        let defaults = UserDefaults(suiteName: "request-activity-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }
        let store = RequestActivityStore(defaults: defaults)
        let work = work(title: "Dune")
        store.recordSubmission(
            work: work,
            provider: .shelfarr,
            outcomes: [
                BookRequestOutcome(
                    format: .ebook,
                    phase: .requested,
                    detail: "Shelfarr accepted this request. The file is not downloaded.",
                )
            ],
        )
        let item = store.item(forWorkID: work.openLibraryWorkID ?? work.workID)
        #expect(item?.provider == .shelfarr)
        #expect(item?.status(for: .ebook)?.status == .requested)
        #expect(item?.status(for: .ebook)?.status != .searching)
        #expect(item?.status(for: .ebook)?.status != .snatched)
        #expect(item?.status(for: .ebook)?.status != .available)
    }

    @Test func groupingPutsAttentionAndInProgressCorrectly() {
        let now = Date()
        let attention = RequestActivityItem(
            canonicalWorkID: "a",
            title: "A",
            author: "",
            provider: .lazyLibrarian,
            requestedFormats: [.ebook],
            updatedAt: now,
            formatStatuses: [
                RequestFormatStatus(format: .ebook, status: .needsAttention, updatedAt: now)
            ],
            attentionReason: "failed",
        )
        let progress = RequestActivityItem(
            canonicalWorkID: "b",
            title: "B",
            author: "",
            provider: .lazyLibrarian,
            requestedFormats: [.audiobook],
            updatedAt: now,
            formatStatuses: [
                RequestFormatStatus(format: .audiobook, status: .searching, updatedAt: now)
            ],
        )
        let groups = RequestActivityGrouping.groups([attention, progress], now: now)
        #expect(groups.contains(where: { $0.0 == .needsAttention && $0.1.count == 1 }))
        #expect(groups.contains(where: { $0.0 == .inProgress && $0.1.count == 1 }))
    }

    // MARK: - Library summary

    @Test func librarySummaryHidesWhenNoRequests() {
        let summary = RequestActivityGrouping.librarySummary([], now: Date())
        #expect(summary.hasTrackedRequests == false)
        #expect(summary.subtitle == nil)
        #expect(summary.accessibilityLabel == "Requests")
    }

    @Test func librarySummaryOneInProgress() {
        let now = Date()
        let summary = RequestActivityGrouping.librarySummary(
            [item(id: "1", status: .searching, updatedAt: now)],
            now: now,
        )
        #expect(summary.inProgressCount == 1)
        #expect(summary.needsAttentionCount == 0)
        #expect(summary.subtitle == "1 in progress")
        #expect(summary.accessibilityLabel == "Requests. 1 in progress.")
        #expect(summary.showsAttentionStyling == false)
    }

    @Test func librarySummaryMultipleInProgress() {
        let now = Date()
        let summary = RequestActivityGrouping.librarySummary(
            [
                item(id: "1", status: .searching, updatedAt: now),
                item(id: "2", status: .wanted, updatedAt: now),
                item(id: "3", status: .snatched, updatedAt: now),
            ],
            now: now,
        )
        #expect(summary.inProgressCount == 3)
        #expect(summary.subtitle == "3 in progress")
    }

    @Test func librarySummaryNeedsAttentionPlusInProgress() {
        let now = Date()
        let summary = RequestActivityGrouping.librarySummary(
            [
                item(id: "a", status: .needsAttention, updatedAt: now, attention: "stale"),
                item(id: "b", status: .searching, updatedAt: now),
                item(id: "c", status: .wanted, updatedAt: now),
                item(id: "d", status: .requested, updatedAt: now),
            ],
            now: now,
        )
        #expect(summary.needsAttentionCount == 1)
        #expect(summary.inProgressCount == 3)
        #expect(summary.subtitle == "3 in progress · 1 needs attention")
        #expect(summary.showsAttentionStyling)
        #expect(summary.accessibilityLabel == "Requests. 3 in progress · 1 needs attention.")
    }

    @Test func librarySummaryNeedsAttentionTakesPriorityOverAvailable() {
        let now = Date()
        let summary = RequestActivityGrouping.librarySummary(
            [
                item(id: "a", status: .needsAttention, updatedAt: now, attention: "failed"),
                item(id: "b", status: .available, updatedAt: now),
            ],
            now: now,
        )
        #expect(summary.subtitle == "1 in progress · 1 needs attention")
        // Provider-side Have is still in progress until Storyteller has the book.
        #expect(summary.inProgressCount == 1)
        #expect(summary.recentlyAvailableCount == 0)
    }

    @Test func librarySummaryCompletedOnlyRecent() {
        let now = Date()
        let summary = RequestActivityGrouping.librarySummary(
            [
                item(id: "1", status: .availableInLibrary, updatedAt: now.addingTimeInterval(-2 * 3600)),
                item(id: "2", status: .availableInLibrary, updatedAt: now.addingTimeInterval(-10 * 3600)),
            ],
            now: now,
        )
        #expect(summary.inProgressCount == 0)
        #expect(summary.recentlyAvailableCount == 2)
        #expect(summary.subtitle == "2 recently available")
    }

    @Test func librarySummaryOldCompletedBecomesAllCaughtUp() {
        let now = Date()
        let old = now.addingTimeInterval(
            -(RequestActivityGrouping.recentCompletionWindow + 3600)
        )
        let summary = RequestActivityGrouping.librarySummary(
            [item(id: "1", status: .availableInLibrary, updatedAt: old)],
            now: now,
        )
        #expect(summary.recentlyAvailableCount == 0)
        #expect(summary.subtitle == "All caught up")
    }

    @Test func librarySummaryRecentVsOldCompleted() {
        let now = Date()
        let recent = now.addingTimeInterval(-12 * 3600)
        let old = now.addingTimeInterval(
            -(RequestActivityGrouping.recentCompletionWindow + 24 * 3600)
        )
        let summary = RequestActivityGrouping.librarySummary(
            [
                item(id: "recent", status: .availableInLibrary, updatedAt: recent),
                item(id: "old", status: .availableInLibrary, updatedAt: old),
            ],
            now: now,
        )
        #expect(summary.recentlyAvailableCount == 1)
        #expect(summary.subtitle == "1 recently available")
    }

    @Test func librarySummaryShelfarrRequestedCountsAsInProgress() {
        let now = Date()
        let summary = RequestActivityGrouping.librarySummary(
            [shelfarrItem(status: .requested, updatedAt: now)],
            now: now,
        )
        #expect(summary.inProgressCount == 1)
        #expect(summary.subtitle == "1 in progress")
    }

    @Test func librarySummaryLazyLibrarianWantedCountsAsInProgress() {
        let now = Date()
        let summary = RequestActivityGrouping.librarySummary(
            [item(id: "w", status: .wanted, updatedAt: now)],
            now: now,
        )
        #expect(summary.inProgressCount == 1)
        #expect(RequestActivityStatus.wanted.isInProgress)
    }

    @Test func librarySummaryProviderAvailableIsNotFullyCompleted() {
        let now = Date()
        // Provider Have / Available from LazyLibrarian is not Storyteller completion.
        #expect(RequestActivityStatus.available.isCompleted == false)
        #expect(RequestActivityStatus.available.isInProgress)
        #expect(RequestActivityStatus.availableInLibrary.isCompleted)
        let summary = RequestActivityGrouping.librarySummary(
            [item(id: "a", status: .available, updatedAt: now)],
            now: now,
        )
        #expect(summary.inProgressCount == 1)
        #expect(summary.recentlyAvailableCount == 0)
    }

    @Test func librarySummaryInLibraryCountsAsRecentlyAvailable() {
        let now = Date()
        let summary = RequestActivityGrouping.librarySummary(
            [item(id: "a", status: .availableInLibrary, updatedAt: now)],
            now: now,
        )
        #expect(summary.inProgressCount == 0)
        #expect(summary.recentlyAvailableCount == 1)
    }

    @Test func libraryDetailStatusLineSearching() {
        let line = item(id: "1", status: .searching, updatedAt: Date())
            .libraryDetailStatusLine
        #expect(line == "Ebook · Searching")
    }

    @Test func libraryDetailStatusLineAvailableFromLazyLibrarian() {
        let line = item(id: "1", status: .available, updatedAt: Date())
            .libraryDetailStatusLine
        #expect(line == "Ebook · Available from LazyLibrarian")
    }

    @Test func libraryDetailStatusLineAvailableInLibrary() {
        let line = item(id: "1", status: .availableInLibrary, updatedAt: Date())
            .libraryDetailStatusLine
        #expect(line == "Ebook · Available in Library")
    }

    @Test func libraryDetailStatusLineMixedFormats() {
        let now = Date()
        let mixed = RequestActivityItem(
            id: "mix",
            canonicalWorkID: "mix",
            title: "Mixed",
            author: "A",
            provider: .lazyLibrarian,
            requestedFormats: [.ebook, .audiobook],
            updatedAt: now,
            formatStatuses: [
                RequestFormatStatus(format: .ebook, status: .availableInLibrary, updatedAt: now),
                RequestFormatStatus(format: .audiobook, status: .wanted, updatedAt: now),
            ],
        )
        #expect(RequestActivityGrouping.section(for: mixed, now: now) == .inProgress)
        #expect(mixed.libraryDetailStatusLine.contains("Available in Library"))
        #expect(mixed.libraryDetailStatusLine.contains("Searching"))
    }

    // MARK: - Store observability

    @Test func storePostsChangeNotificationOnRecordAndRemove() {
        let defaults = UserDefaults(suiteName: "request-activity-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }
        let store = RequestActivityStore(defaults: defaults)
        let counter = NotificationCounter(name: .requestActivityStoreDidChange)
        defer { counter.stop() }

        store.recordSubmission(
            work: work(title: "Notify"),
            provider: .lazyLibrarian,
            outcomes: [
                BookRequestOutcome(
                    format: .ebook,
                    phase: .searching,
                    detail: "Searching",
                    providerBookID: "OL9W",
                )
            ],
        )
        #expect(counter.count == 1)

        let id = store.allItems()[0].id
        store.remove(id: id)
        #expect(counter.count == 2)
        #expect(store.allItems().isEmpty)
    }

    @Test func storePostsChangeNotificationOnUpsert() {
        let defaults = UserDefaults(suiteName: "request-activity-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }
        let store = RequestActivityStore(defaults: defaults)
        let counter = NotificationCounter(name: .requestActivityStoreDidChange)
        defer { counter.stop() }

        store.upsert(item(id: "up", status: .wanted, updatedAt: Date()))
        #expect(counter.count == 1)
        #expect(store.librarySummary().inProgressCount == 1)
    }

    @Test func storePostsChangeNotificationOnPruneWhenItemsRemoved() {
        let defaults = UserDefaults(suiteName: "request-activity-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }
        let store = RequestActivityStore(defaults: defaults)
        let now = Date()
        let staleCompleted = now.addingTimeInterval(
            -(RequestActivityGrouping.completedRetentionInterval + 3600)
        )
        store.upsert(item(id: "old", status: .availableInLibrary, updatedAt: staleCompleted))

        let counter = NotificationCounter(name: .requestActivityStoreDidChange)
        defer { counter.stop() }
        store.prune(now: now)
        #expect(counter.count == 1)
        #expect(store.allItems().isEmpty)
    }

    @Test func storeChangeNotificationAllowsReentrantReadsWithoutDeadlock() {
        let defaults = UserDefaults(suiteName: "request-activity-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }
        let store = RequestActivityStore(defaults: defaults)

        var observedCount = 0
        var observedInProgress = 0
        let token = NotificationCenter.default.addObserver(
            forName: .requestActivityStoreDidChange,
            object: nil,
            queue: nil,
        ) { _ in
            // Re-enter the same store while handling the synchronous notification.
            // Must not deadlock on the non-recursive NSLock.
            let items = store.allItems()
            observedCount = items.count
            observedInProgress = store.librarySummary().inProgressCount
        }
        defer { NotificationCenter.default.removeObserver(token) }

        store.upsert(item(id: "reenter", status: .searching, updatedAt: Date()))

        #expect(observedCount == 1)
        #expect(observedInProgress == 1)
        #expect(store.allItems().count == 1)
    }

    // MARK: - Helpers

    private func item(
        id: String,
        status: RequestActivityStatus,
        updatedAt: Date,
        attention: String? = nil,
        format: BookRequestFormat = .ebook,
        provider: BookRequestProviderKind = .lazyLibrarian,
    ) -> RequestActivityItem {
        RequestActivityItem(
            id: id,
            canonicalWorkID: id,
            title: id,
            author: "",
            provider: provider,
            requestedFormats: [format],
            updatedAt: updatedAt,
            formatStatuses: [
                RequestFormatStatus(format: format, status: status, updatedAt: updatedAt)
            ],
            attentionReason: attention,
        )
    }

    private func work(
        title: String = "Pride and Prejudice",
        author: String = "Jane Austen",
        isbn: String? = nil,
    ) -> CanonicalBookWork {
        CanonicalBookWork(
            workID: "work/\(title)",
            title: title,
            subtitle: nil,
            authors: [author],
            language: "en",
            isbn: isbn,
            openLibraryWorkID: "/works/OL1W",
            openLibraryEditionID: nil,
            publicationYear: "1813",
        )
    }

    private func shelfarrItem(
        status: RequestActivityStatus,
        detail: String? = "Shelfarr accepted this request.",
        updatedAt: Date,
    ) -> RequestActivityItem {
        RequestActivityItem(
            canonicalWorkID: "shelfarr-work",
            title: "Dune",
            author: "Frank Herbert",
            provider: .shelfarr,
            requestedFormats: [.ebook],
            updatedAt: updatedAt,
            formatStatuses: [
                RequestFormatStatus(
                    format: .ebook,
                    status: status,
                    detail: detail,
                    updatedAt: updatedAt,
                )
            ],
        )
    }
}

private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var token: NSObjectProtocol?

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }

    init(name: Notification.Name) {
        token = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: nil,
        ) { [weak self] _ in
            self?.lock.lock()
            self?._count += 1
            self?.lock.unlock()
        }
    }

    func stop() {
        if let token {
            NotificationCenter.default.removeObserver(token)
            self.token = nil
        }
    }
}

private final class LLScript: LazyLibrarianTransport, @unchecked Sendable {
    var error: URLError?
    var handler: ((String, [String: String]) -> LazyLibrarianHTTP)?

    func send(_ url: URL, timeout _: TimeInterval) async throws -> LazyLibrarianHTTP {
        if let error { throw error }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let cmd = items.first { $0.name == "cmd" }?.value ?? ""
        var query: [String: String] = [:]
        for item in items where item.name != "apikey" && item.name != "cmd" {
            query[item.name] = item.value ?? ""
        }
        return handler?(cmd, query) ?? Self.http("OK")
    }

    static func http(_ body: String, status: Int = 200) -> LazyLibrarianHTTP {
        LazyLibrarianHTTP(status: status, body: Data(body.utf8))
    }
}
