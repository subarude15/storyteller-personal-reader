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
        let defaults = UserDefaults(suiteName: "request-retry-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }
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
        let defaults = UserDefaults(suiteName: "request-retry-dup-\(UUID().uuidString)")!
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

    @Test func localDuplicateShortCircuitSkipsWantedAndHave() {
        let defaults = UserDefaults(suiteName: "request-retry-skip-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }
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
