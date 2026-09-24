import Foundation
import Testing

@testable import SilveranKit

@Suite("Request activity recovery actions")
struct RequestActivityActionsTests {

    // MARK: - Action visibility

    @Test func failedLazyLibrarianShowsCheckRetryAndOpenLL() {
        let item = makeItem(
            provider: .lazyLibrarian,
            providerBookID: "OL1W",
            statuses: [.ebook: .failed],
        )
        let availability = RequestActivityActions.availability(
            for: item,
            context: llContext,
        )
        #expect(availability.canCheckStatus)
        #expect(availability.canRetry)
        #expect(availability.canOpenLazyLibrarian)
        #expect(!availability.canOpenShelfarr)
        #expect(availability.retryFormats == [.ebook])
    }

    @Test func lazyLibrarianWantedShowsCheckAndOpenLLNoRetry() {
        let item = makeItem(
            provider: .lazyLibrarian,
            providerBookID: "OL1W",
            statuses: [.ebook: .wanted],
        )
        let availability = RequestActivityActions.availability(for: item, context: llContext)
        #expect(availability.canCheckStatus)
        #expect(!availability.canRetry)
        #expect(availability.canOpenLazyLibrarian)
        #expect(availability.retryFormats.isEmpty)
    }

    @Test func lazyLibrarianProviderAvailableShowsCheckAndOpenLLNoRetry() {
        let item = makeItem(
            provider: .lazyLibrarian,
            providerBookID: "OL1W",
            statuses: [.ebook: .available],
        )
        let availability = RequestActivityActions.availability(for: item, context: llContext)
        #expect(availability.canCheckStatus)
        #expect(!availability.canRetry)
        #expect(availability.canOpenLazyLibrarian)
    }

    @Test func availableInLibraryHidesRetry() {
        let item = makeItem(
            provider: .lazyLibrarian,
            providerBookID: "OL1W",
            statuses: [.ebook: .availableInLibrary],
        )
        let availability = RequestActivityActions.availability(for: item, context: llContext)
        #expect(availability.canCheckStatus)
        #expect(!availability.canRetry)
        #expect(availability.canOpenLazyLibrarian)
    }

    @Test func shelfarrRequestedShowsCheckAndOpenShelfarrNoRetry() {
        let item = makeItem(
            provider: .shelfarr,
            statuses: [.ebook: .requested],
        )
        let availability = RequestActivityActions.availability(for: item, context: shelfContext)
        #expect(availability.canCheckStatus)
        #expect(!availability.canRetry)
        #expect(availability.canOpenShelfarr)
        #expect(!availability.canOpenLazyLibrarian)
    }

    @Test func failedShelfarrSubmissionAllowsRetry() {
        let item = makeItem(
            provider: .shelfarr,
            statuses: [.ebook: .failed],
        )
        let availability = RequestActivityActions.availability(for: item, context: shelfContext)
        #expect(availability.canRetry)
        #expect(availability.canOpenShelfarr)
        #expect(availability.retryFormats == [.ebook])
    }

    @Test func needsAttentionAllowsRetry() {
        let item = makeItem(
            provider: .lazyLibrarian,
            providerBookID: nil,
            statuses: [.ebook: .needsAttention],
            attention: "Missing LazyLibrarian BookID",
        )
        let availability = RequestActivityActions.availability(for: item, context: llContext)
        #expect(availability.canRetry)
    }

    @Test func bookSearchLANEnabledShowsAlternateAction() {
        let item = makeItem(
            provider: .lazyLibrarian,
            providerBookID: "OL1W",
            statuses: [.ebook: .failed],
        )
        let availability = RequestActivityActions.availability(
            for: item,
            context: RequestActivityActionContext(
                lazyLibrarianEnabled: true,
                lazyLibrarianBaseURL: "https://lazy.punkandrally.com",
                bookSearchLANEnabled: true,
                bookSearchLANBaseURL: "http://192.168.1.2:3010",
            ),
        )
        #expect(availability.canOpenAlternateSearch)
    }

    @Test func bookSearchLANDisabledHidesAlternateAction() {
        let item = makeItem(
            provider: .lazyLibrarian,
            providerBookID: "OL1W",
            statuses: [.ebook: .failed],
        )
        let availability = RequestActivityActions.availability(
            for: item,
            context: RequestActivityActionContext(
                lazyLibrarianEnabled: true,
                lazyLibrarianBaseURL: "https://lazy.punkandrally.com",
                bookSearchLANEnabled: false,
                bookSearchLANBaseURL: "http://192.168.1.2:3010",
            ),
        )
        #expect(!availability.canOpenAlternateSearch)
    }

    @Test func searchingWantedSnatchedNotRetryable() {
        for status: RequestActivityStatus in [.searching, .wanted, .snatched, .requested, .alreadyRequested] {
            #expect(!RequestActivityRetryPolicy.isRetryable(status))
        }
    }

    // MARK: - Per-format retry

    @Test func failedEbookRetriesEbookOnly() {
        let item = makeItem(
            provider: .lazyLibrarian,
            statuses: [.ebook: .failed, .audiobook: .wanted],
            formats: [.ebook, .audiobook],
        )
        #expect(RequestActivityRetryPolicy.retryableFormats(for: item) == [.ebook])
    }

    @Test func failedAudiobookRetriesAudiobookOnly() {
        let item = makeItem(
            provider: .lazyLibrarian,
            statuses: [.ebook: .wanted, .audiobook: .failed],
            formats: [.ebook, .audiobook],
        )
        #expect(RequestActivityRetryPolicy.retryableFormats(for: item) == [.audiobook])
    }

    @Test func mixedRequestRetriesOnlyFailedFormat() {
        let item = makeItem(
            provider: .lazyLibrarian,
            statuses: [
                .ebook: .availableInLibrary,
                .audiobook: .needsAttention,
            ],
            formats: [.ebook, .audiobook],
        )
        #expect(RequestActivityRetryPolicy.retryableFormats(for: item) == [.audiobook])
        #expect(RequestActivityRetryPolicy.canRetry(item))
    }

    @Test func completedFormatNeverInRetrySet() {
        let item = makeItem(
            provider: .lazyLibrarian,
            statuses: [
                .ebook: .availableInLibrary,
                .audiobook: .availableInLibrary,
            ],
            formats: [.ebook, .audiobook],
        )
        #expect(RequestActivityRetryPolicy.retryableFormats(for: item).isEmpty)
        #expect(!RequestActivityRetryPolicy.canRetry(item))
    }

    @Test func temporaryUnknownStatusIsNotRetryable() {
        #expect(!RequestActivityRetryPolicy.isRetryable(.unknown))
        let item = makeItem(provider: .lazyLibrarian, statuses: [.ebook: .unknown])
        #expect(!RequestActivityRetryPolicy.canRetry(item))
    }

    @Test func retryWithNoTargetsReturnsMessage() async {
        let suiteName = "request-retry-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RequestActivityStore(defaults: defaults)
        let item = makeItem(
            provider: .lazyLibrarian,
            providerBookID: "OL1W",
            statuses: [.ebook: .wanted],
        )
        store.upsert(item)
        let result = await BookRequests.retry(item: item, history: store)
        #expect(result.message == "Nothing to retry.")
        #expect(result.outcomes.isEmpty)
        #expect(store.allItems().count == 1)
    }

    @Test func recordSubmissionUpdatesExistingRowRatherThanDuplicating() {
        let suiteName = "request-retry-dup-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
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
                    format: .ebook,
                    phase: .failed,
                    detail: "down",
                    providerBookID: "OL1W",
                )
            ],
        )
        store.recordSubmission(
            work: work,
            provider: .lazyLibrarian,
            outcomes: [
                BookRequestOutcome(
                    format: .ebook,
                    phase: .searching,
                    detail: "retry",
                    providerBookID: "OL1W",
                )
            ],
        )
        #expect(store.allItems().count == 1)
        #expect(store.item(forWorkID: "/works/OL1W")?.status(for: .ebook)?.status == .searching)
    }

    @Test func successfulRetryClearsStaleLastError() {
        let suiteName = "request-retry-clear-err-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RequestActivityStore(defaults: defaults)
        let work = CanonicalBookWork(
            workID: "work/clear-err",
            title: "Dune",
            subtitle: nil,
            authors: ["Frank Herbert"],
            language: "en",
            isbn: nil,
            openLibraryWorkID: "/works/OLClear",
            openLibraryEditionID: nil,
            publicationYear: "1965",
        )
        store.recordSubmission(
            work: work,
            provider: .lazyLibrarian,
            outcomes: [
                BookRequestOutcome(
                    format: .ebook,
                    phase: .failed,
                    detail: "Could not reach LazyLibrarian",
                    providerBookID: nil,
                )
            ],
        )
        let failed = store.item(forWorkID: "/works/OLClear")
        #expect(failed?.lastError == "Could not reach LazyLibrarian")
        #expect(failed?.attentionReason != nil)
        #expect(failed?.status(for: .ebook)?.status == .needsAttention)

        store.recordSubmission(
            work: work,
            provider: .lazyLibrarian,
            outcomes: [
                BookRequestOutcome(
                    format: .ebook,
                    phase: .searching,
                    detail: "Searching",
                    providerBookID: "OLClear",
                )
            ],
        )
        let recovered = store.item(forWorkID: "/works/OLClear")
        #expect(recovered?.status(for: .ebook)?.status == .searching)
        #expect(recovered?.attentionReason == nil)
        #expect(recovered?.lastError == nil)
    }

    @Test func successfulAudiobookRetryClearsErrorWhenEbookAlreadyInLibrary() {
        let suiteName = "request-retry-mixed-ok-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RequestActivityStore(defaults: defaults)
        let work = CanonicalBookWork(
            workID: "work/mixed-ok",
            title: "Dune",
            subtitle: nil,
            authors: ["Frank Herbert"],
            language: "en",
            isbn: nil,
            openLibraryWorkID: "/works/OLMixedOk",
            openLibraryEditionID: nil,
            publicationYear: "1965",
        )
        // Seed: ebook already in library, audiobook failed.
        var seeded = RequestActivityItem(
            canonicalWorkID: "/works/OLMixedOk",
            title: "Dune",
            author: "Frank Herbert",
            provider: .lazyLibrarian,
            providerBookID: "OLMixedOk",
            requestedFormats: [.ebook, .audiobook],
            formatStatuses: [
                RequestFormatStatus(format: .ebook, status: .availableInLibrary),
                RequestFormatStatus(
                    format: .audiobook,
                    status: .failed,
                    detail: "Audio queue failed",
                ),
            ],
            lastError: "Audio queue failed",
            attentionReason: "Audio queue failed",
            openLibraryWorkID: "/works/OLMixedOk",
        )
        seeded = RequestActivityAttention.apply(seeded)
        store.upsert(seeded)
        #expect(store.item(forWorkID: "/works/OLMixedOk")?.lastError == "Audio queue failed")

        store.recordSubmission(
            work: work,
            provider: .lazyLibrarian,
            outcomes: [
                BookRequestOutcome(
                    format: .audiobook,
                    phase: .searching,
                    detail: "Searching",
                    providerBookID: "OLMixedOk",
                )
            ],
        )
        let recovered = store.item(forWorkID: "/works/OLMixedOk")
        #expect(recovered?.status(for: .ebook)?.status == .availableInLibrary)
        #expect(recovered?.status(for: .audiobook)?.status == .searching)
        #expect(recovered?.attentionReason == nil)
        #expect(recovered?.lastError == nil)
    }

    @Test func partialRetryKeepsLastErrorWhenSiblingStillNeedsAttention() {
        let suiteName = "request-retry-partial-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RequestActivityStore(defaults: defaults)
        let work = CanonicalBookWork(
            workID: "work/partial",
            title: "Dune",
            subtitle: nil,
            authors: ["Frank Herbert"],
            language: "en",
            isbn: nil,
            openLibraryWorkID: "/works/OLPartial",
            openLibraryEditionID: nil,
            publicationYear: "1965",
        )
        store.recordSubmission(
            work: work,
            provider: .lazyLibrarian,
            outcomes: [
                BookRequestOutcome(
                    format: .ebook,
                    phase: .failed,
                    detail: "Ebook failed",
                    providerBookID: "OLPartial",
                ),
                BookRequestOutcome(
                    format: .audiobook,
                    phase: .failed,
                    detail: "Audiobook failed",
                    providerBookID: "OLPartial",
                ),
            ],
        )
        let bothFailed = store.item(forWorkID: "/works/OLPartial")
        #expect(bothFailed?.lastError == "Audiobook failed")
        #expect(bothFailed?.formatStatuses.filter { $0.status.needsAttentionBucket }.count == 2)

        // Retry only ebook successfully; audiobook still needs attention.
        store.recordSubmission(
            work: work,
            provider: .lazyLibrarian,
            outcomes: [
                BookRequestOutcome(
                    format: .ebook,
                    phase: .searching,
                    detail: "Searching",
                    providerBookID: "OLPartial",
                )
            ],
        )
        let partial = store.item(forWorkID: "/works/OLPartial")
        #expect(partial?.status(for: .ebook)?.status == .searching)
        #expect(partial?.status(for: .audiobook)?.status == .needsAttention)
        #expect(partial?.attentionReason != nil)
        #expect(partial?.lastError == "Audiobook failed")
    }

    @Test func failedResubmissionKeepsLastError() {
        let suiteName = "request-retry-fail-again-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RequestActivityStore(defaults: defaults)
        let work = CanonicalBookWork(
            workID: "work/fail-again",
            title: "Dune",
            subtitle: nil,
            authors: ["Frank Herbert"],
            language: "en",
            isbn: nil,
            openLibraryWorkID: "/works/OLFailAgain",
            openLibraryEditionID: nil,
            publicationYear: "1965",
        )
        store.recordSubmission(
            work: work,
            provider: .lazyLibrarian,
            outcomes: [
                BookRequestOutcome(
                    format: .ebook,
                    phase: .failed,
                    detail: "First failure",
                )
            ],
        )
        store.recordSubmission(
            work: work,
            provider: .lazyLibrarian,
            outcomes: [
                BookRequestOutcome(
                    format: .ebook,
                    phase: .failed,
                    detail: "Second failure",
                )
            ],
        )
        let item = store.item(forWorkID: "/works/OLFailAgain")
        #expect(item?.lastError == "Second failure")
        #expect(item?.status(for: .ebook)?.status == .needsAttention)
    }

    @Test func localDuplicateShortCircuitSkipsWantedAndHave() {
        let suiteName = "request-retry-skip-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RequestActivityStore(defaults: defaults)
        let work = CanonicalBookWork(
            workID: "work/2",
            title: "Dune",
            subtitle: nil,
            authors: ["Frank Herbert"],
            language: "en",
            isbn: nil,
            openLibraryWorkID: "/works/OL2W",
            openLibraryEditionID: nil,
            publicationYear: "1965",
        )
        store.recordSubmission(
            work: work,
            provider: .lazyLibrarian,
            outcomes: [
                BookRequestOutcome(
                    format: .ebook,
                    phase: .alreadyRequested,
                    detail: "Wanted",
                    providerBookID: "OL2W",
                ),
                BookRequestOutcome(
                    format: .audiobook,
                    phase: .alreadyAvailable,
                    detail: "Have",
                    providerBookID: "OL2W",
                ),
            ],
        )
        let item = store.item(forWorkID: "/works/OL2W")!
        #expect(item.status(for: .ebook)?.status == .alreadyRequested)
        #expect(item.status(for: .audiobook)?.status == .alreadyAvailable)
        #expect(RequestActivityRetryPolicy.retryableFormats(for: item).isEmpty)
    }

    // MARK: - URL safety

    @Test func httpsLazyLibrarianURLAccepted() {
        let url = RequestActivityExternalLinks.browseURL(from: "https://lazy.punkandrally.com")
        #expect(url?.absoluteString == "https://lazy.punkandrally.com")
    }

    @Test func httpLANURLAccepted() {
        let url = RequestActivityExternalLinks.browseURL(from: "http://192.168.1.2:3010")
        #expect(url?.absoluteString == "http://192.168.1.2:3010")
    }

    @Test func malformedURLRejected() {
        #expect(RequestActivityExternalLinks.browseURL(from: "") == nil)
        #expect(RequestActivityExternalLinks.browseURL(from: "ftp://lazy.punkandrally.com") == nil)
        #expect(RequestActivityExternalLinks.browseURL(from: "not a url") == nil)
        #expect(RequestActivityExternalLinks.browseURL(from: "javascript:alert(1)") == nil)
    }

    @Test func secretsStrippedFromBrowseURL() {
        let url = RequestActivityExternalLinks.browseURL(
            from: "https://user:secret@lazy.punkandrally.com/path?apikey=abc123&token=xyz"
        )
        #expect(url != nil)
        let text = url!.absoluteString
        #expect(!text.contains("secret"))
        #expect(!text.contains("apikey"))
        #expect(!text.contains("abc123"))
        #expect(!text.contains("token="))
        #expect(!text.contains("user"))
        #expect(text.hasPrefix("https://lazy.punkandrally.com"))
    }

    @Test func sanitizedDescriptionNeverIncludesCredentials() {
        let url = URL(string: "https://user:pass@lazy.punkandrally.com/books?apikey=abc")!
        let sanitized = RequestActivityExternalLinks.sanitizedDescription(of: url)
        #expect(!sanitized.contains("pass"))
        #expect(!sanitized.contains("apikey"))
        #expect(!sanitized.contains("abc"))
    }

    @Test func trailingSlashNormalized() {
        let url = RequestActivityExternalLinks.browseURL(from: "https://lazy.punkandrally.com/")
        #expect(url?.absoluteString == "https://lazy.punkandrally.com")
    }

    // MARK: - Helpers

    private var llContext: RequestActivityActionContext {
        RequestActivityActionContext(
            lazyLibrarianEnabled: true,
            lazyLibrarianBaseURL: "https://lazy.punkandrally.com",
        )
    }

    private var shelfContext: RequestActivityActionContext {
        RequestActivityActionContext(
            shelfarrBaseURL: "https://shelfarr.example.com",
        )
    }

    private func makeItem(
        provider: BookRequestProviderKind,
        providerBookID: String? = nil,
        statuses: [BookRequestFormat: RequestActivityStatus],
        formats: [BookRequestFormat]? = nil,
        attention: String? = nil,
    ) -> RequestActivityItem {
        let requested = formats ?? Array(statuses.keys).sorted { $0.rawValue < $1.rawValue }
        return RequestActivityItem(
            canonicalWorkID: "/works/OLTEST",
            title: "Test Book",
            author: "Author",
            provider: provider,
            providerBookID: providerBookID,
            requestedFormats: requested,
            formatStatuses: requested.map { format in
                RequestFormatStatus(
                    format: format,
                    status: statuses[format] ?? .unknown,
                )
            },
            attentionReason: attention,
        )
    }
}
