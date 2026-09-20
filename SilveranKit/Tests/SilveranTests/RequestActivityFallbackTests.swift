import Foundation
import Testing

@testable import SilveranKit

@Suite("Manual alternate-source fallback")
struct RequestActivityFallbackTests {

    // MARK: - Options

    @Test func lazyLibrarianFailedWithShelfarrConfiguredOffersShelfarr() {
        let offer = RequestActivityFallbackPolicy.offer(
            for: failedItem(provider: .lazyLibrarian, statuses: [.audiobook: .failed]),
            context: bothProviders(lan: false),
        )
        #expect(offer.canOffer)
        #expect(offer.options == [.provider(.shelfarr)])
        #expect(offer.eligibleFormats == [.audiobook])
    }

    @Test func lazyLibrarianFailedWithoutShelfarrHidesShelfarr() {
        let offer = RequestActivityFallbackPolicy.offer(
            for: failedItem(provider: .lazyLibrarian, statuses: [.ebook: .needsAttention]),
            context: RequestActivityActionContext(
                lazyLibrarianEnabled: true,
                lazyLibrarianBaseURL: "https://lazy.example",
                shelfarrBaseURL: "",
                lazyLibrarianHasAPIKey: true,
                shelfarrHasToken: false,
            ),
        )
        #expect(!offer.options.contains(.provider(.shelfarr)))
        #expect(!offer.canOffer)
    }

    @Test func shelfarrFailedWithLazyLibrarianConfiguredOffersLazyLibrarian() {
        let offer = RequestActivityFallbackPolicy.offer(
            for: failedItem(provider: .shelfarr, statuses: [.ebook: .failed]),
            context: bothProviders(lan: false),
        )
        #expect(offer.options == [.provider(.lazyLibrarian)])
        #expect(!offer.options.contains(.provider(.shelfarr)))
    }

    @Test func shelfarrWithoutTokenIsNotAnOption() {
        var context = bothProviders(lan: false)
        context.shelfarrHasToken = false
        let offer = RequestActivityFallbackPolicy.offer(
            for: failedItem(provider: .lazyLibrarian, statuses: [.ebook: .failed]),
            context: context,
        )
        #expect(!offer.options.contains(.provider(.shelfarr)))
    }

    @Test func lazyLibrarianWithoutKeyIsNotAnOption() {
        var context = bothProviders(lan: false)
        context.lazyLibrarianHasAPIKey = false
        let offer = RequestActivityFallbackPolicy.offer(
            for: failedItem(provider: .shelfarr, statuses: [.ebook: .failed]),
            context: context,
        )
        #expect(!offer.options.contains(.provider(.lazyLibrarian)))
    }

    @Test func activeWantedDoesNotOfferAnotherSource() {
        let item = failedItem(provider: .lazyLibrarian, statuses: [.ebook: .wanted])
        let offer = RequestActivityFallbackPolicy.offer(for: item, context: bothProviders(lan: true))
        #expect(offer.eligibleFormats.isEmpty)
        #expect(!offer.canOffer)
        let availability = RequestActivityActions.availability(for: item, context: bothProviders(lan: true))
        #expect(!availability.canTryAnotherSource)
    }

    @Test func availableInLibraryDoesNotOfferProviderFallback() {
        let offer = RequestActivityFallbackPolicy.offer(
            for: failedItem(provider: .lazyLibrarian, statuses: [.ebook: .availableInLibrary]),
            context: bothProviders(lan: true),
        )
        #expect(offer.eligibleFormats.isEmpty)
        #expect(offer.options.isEmpty)
        #expect(!offer.canOffer)
    }

    @Test func searchingWantedSnatchedAndRequestedAreNotEligible() {
        for status: RequestActivityStatus in [.searching, .wanted, .snatched, .requested, .available] {
            let offer = RequestActivityFallbackPolicy.offer(
                for: failedItem(provider: .lazyLibrarian, statuses: [.ebook: status]),
                context: bothProviders(lan: true),
            )
            #expect(!offer.canOffer)
        }
    }

    @Test func bookSearchLANEnabledAddsManualOptionLast() {
        let offer = RequestActivityFallbackPolicy.offer(
            for: failedItem(provider: .lazyLibrarian, statuses: [.ebook: .failed]),
            context: bothProviders(lan: true),
        )
        #expect(offer.options == [.provider(.shelfarr), .alternateSearch])
    }

    @Test func bookSearchLANDisabledOmitsManualOption() {
        let offer = RequestActivityFallbackPolicy.offer(
            for: failedItem(provider: .shelfarr, statuses: [.ebook: .needsAttention]),
            context: bothProviders(lan: false),
        )
        #expect(!offer.options.contains(.alternateSearch))
    }

    @Test func invalidLANURLIsNotAnOption() {
        let offer = RequestActivityFallbackPolicy.offer(
            for: failedItem(provider: .lazyLibrarian, statuses: [.ebook: .failed]),
            context: RequestActivityActionContext(
                shelfarrBaseURL: "https://shelf.example",
                bookSearchLANEnabled: true,
                bookSearchLANBaseURL: "not a url",
                shelfarrHasToken: true,
            ),
        )
        #expect(!offer.options.contains(.alternateSearch))
        #expect(offer.options == [.provider(.shelfarr)])
    }

    @Test func automaticWithBookIDUsesLazyLibrarianAsCurrentProvider() {
        let item = failedItem(
            provider: .automatic,
            providerBookID: "OL1W",
            statuses: [.ebook: .failed],
        )
        #expect(RequestActivityFallbackPolicy.resolvedProvider(item) == .lazyLibrarian)
        let offer = RequestActivityFallbackPolicy.offer(for: item, context: bothProviders(lan: false))
        #expect(offer.options == [.provider(.shelfarr)])
    }

    @Test func unresolvedAutomaticCanChooseEitherConfiguredProvider() {
        let item = failedItem(provider: .automatic, statuses: [.ebook: .failed])
        #expect(RequestActivityFallbackPolicy.resolvedProvider(item) == nil)
        let offer = RequestActivityFallbackPolicy.offer(for: item, context: bothProviders(lan: false))
        #expect(offer.options == [.provider(.shelfarr), .provider(.lazyLibrarian)])
    }

    // MARK: - Formats

    @Test func ebookInLibraryLeavesAudiobookOnly() {
        let item = failedItem(
            provider: .lazyLibrarian,
            statuses: [.ebook: .availableInLibrary, .audiobook: .needsAttention],
            formats: [.ebook, .audiobook],
        )
        let offer = RequestActivityFallbackPolicy.offer(for: item, context: bothProviders(lan: false))
        #expect(offer.eligibleFormats == [.audiobook])
        let decision = RequestActivityFallbackPolicy.decision(
            item: item,
            provider: .shelfarr,
            formats: [.ebook, .audiobook],
            history: [item],
        )
        #expect(decision.formats == [.audiobook])
        #expect(decision.providerOverride == .shelfarr)
    }

    @Test func bothFailedFormatsStayEligible() {
        let item = failedItem(
            provider: .lazyLibrarian,
            statuses: [.ebook: .failed, .audiobook: .needsAttention],
            formats: [.ebook, .audiobook],
        )
        let offer = RequestActivityFallbackPolicy.offer(for: item, context: bothProviders(lan: false))
        #expect(offer.eligibleFormats == [.ebook, .audiobook])
    }

    @Test func completedFormatIsNeverResent() {
        let item = failedItem(
            provider: .shelfarr,
            statuses: [.ebook: .availableInLibrary, .audiobook: .availableInLibrary],
            formats: [.ebook, .audiobook],
        )
        let decision = RequestActivityFallbackPolicy.decision(
            item: item,
            provider: .lazyLibrarian,
            formats: [.ebook, .audiobook],
            history: [],
        )
        #expect(decision.formats.isEmpty)
        #expect(decision.message == RequestActivityFallbackPolicy.alreadyInLibraryMessage)
    }

    // MARK: - Duplicates and history

    @Test func activeAlternateBlocksResubmit() {
        let original = failedItem(provider: .lazyLibrarian, statuses: [.audiobook: .failed])
        let existing = failedItem(
            id: "shelf-active",
            provider: .shelfarr,
            statuses: [.audiobook: .requested],
        )
        let decision = RequestActivityFallbackPolicy.decision(
            item: original,
            provider: .shelfarr,
            formats: [.audiobook],
            history: [original, existing],
        )
        #expect(decision.formats.isEmpty)
        #expect(decision.message == "Already requested with Shelfarr.")
    }

    @Test func completedAlternateBlocksResubmit() {
        let original = failedItem(provider: .lazyLibrarian, statuses: [.ebook: .failed])
        let existing = failedItem(
            id: "shelf-done",
            provider: .shelfarr,
            statuses: [.ebook: .availableInLibrary],
        )
        let decision = RequestActivityFallbackPolicy.decision(
            item: original,
            provider: .shelfarr,
            formats: [.ebook],
            history: [original, existing],
        )
        #expect(decision.formats.isEmpty)
        #expect(decision.message == RequestActivityFallbackPolicy.alreadyInLibraryMessage)
    }

    @Test func failedAlternateDoesNotBlockUpdate() {
        let original = failedItem(provider: .lazyLibrarian, statuses: [.ebook: .failed])
        let existing = failedItem(
            id: "shelf-failed",
            provider: .shelfarr,
            statuses: [.ebook: .needsAttention],
        )
        let decision = RequestActivityFallbackPolicy.decision(
            item: original,
            provider: .shelfarr,
            formats: [.ebook],
            history: [original, existing],
        )
        #expect(decision.formats == [.ebook])
    }

    @Test func separateProviderRowsStaySeparate() {
        let defaults = UserDefaults(suiteName: "fallback-rows-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }
        let store = RequestActivityStore(defaults: defaults)
        let work = duneWork(id: "/works/OLDune")
        store.recordSubmission(
            work: work,
            provider: .lazyLibrarian,
            outcomes: [
                BookRequestOutcome(format: .audiobook, phase: .failed, detail: "down")
            ],
        )
        let original = store.item(forWorkID: "/works/OLDune", provider: .lazyLibrarian)
        store.recordSubmission(
            work: work,
            provider: .shelfarr,
            outcomes: [
                BookRequestOutcome(format: .audiobook, phase: .requested, detail: "accepted")
            ],
            fallbackFromRequestID: original?.id,
        )
        #expect(store.allItems().count == 2)
        let lazy = store.item(forWorkID: "/works/OLDune", provider: .lazyLibrarian)
        let shelf = store.item(forWorkID: "/works/OLDune", provider: .shelfarr)
        #expect(lazy?.status(for: .audiobook)?.status.needsAttentionBucket == true)
        #expect(lazy?.provider == .lazyLibrarian)
        #expect(lazy?.fallbackFromRequestID == nil)
        #expect(shelf?.status(for: .audiobook)?.status == .requested)
        #expect(shelf?.fallbackFromRequestID == original?.id)
        #expect(shelf?.id != lazy?.id)
    }

    @Test func laterUpdateDoesNotReplaceFallbackLink() {
        let defaults = UserDefaults(suiteName: "fallback-link-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }
        let store = RequestActivityStore(defaults: defaults)
        let work = duneWork(id: "/works/OLLink")
        store.recordSubmission(
            work: work,
            provider: .shelfarr,
            outcomes: [
                BookRequestOutcome(format: .ebook, phase: .requested, detail: "accepted")
            ],
            fallbackFromRequestID: "original-ll",
        )
        store.recordSubmission(
            work: work,
            provider: .shelfarr,
            outcomes: [
                BookRequestOutcome(format: .ebook, phase: .requested, detail: "still requested")
            ],
            fallbackFromRequestID: "someone-else",
        )
        let shelf = store.item(forWorkID: "/works/OLLink", provider: .shelfarr)
        #expect(store.allItems().count == 1)
        #expect(shelf?.fallbackFromRequestID == "original-ll")
    }

    // MARK: - Submission choice

    @Test func manualShelfarrFallbackUsesShelfarrOverride() {
        let item = failedItem(provider: .lazyLibrarian, statuses: [.audiobook: .failed])
        let before = item
        let decision = RequestActivityFallbackPolicy.decision(
            item: item,
            provider: .shelfarr,
            formats: [.audiobook],
            history: [item],
        )
        #expect(decision.providerOverride == .shelfarr)
        #expect(decision.providerOverride != .automatic)
        #expect(decision.formats == [.audiobook])
        #expect(item == before)
    }

    @Test func manualLazyLibrarianFallbackUsesLazyLibrarianOverride() {
        let item = failedItem(provider: .shelfarr, statuses: [.ebook: .needsAttention])
        let decision = RequestActivityFallbackPolicy.decision(
            item: item,
            provider: .lazyLibrarian,
            formats: [.ebook],
            history: [item],
        )
        #expect(decision.providerOverride == .lazyLibrarian)
        #expect(decision.formats == [.ebook])
    }

    @Test func automaticOverrideIsNotAFallbackSubmit() {
        let item = failedItem(provider: .lazyLibrarian, statuses: [.ebook: .failed])
        let decision = RequestActivityFallbackPolicy.decision(
            item: item,
            provider: .automatic,
            formats: [.ebook],
            history: [],
        )
        #expect(decision.formats.isEmpty)
    }

    @Test func sameProviderIsNotAFallbackSubmit() {
        let item = failedItem(provider: .lazyLibrarian, statuses: [.ebook: .failed])
        let decision = RequestActivityFallbackPolicy.decision(
            item: item,
            provider: .lazyLibrarian,
            formats: [.ebook],
            history: [item],
        )
        #expect(decision.formats.isEmpty)
    }

    // MARK: - Storyteller presence

    @Test func formatArrivingBeforeConfirmSkipsAlternateSubmit() {
        var item = failedItem(provider: .lazyLibrarian, statuses: [.audiobook: .needsAttention])
        item.formatStatuses = [
            RequestFormatStatus(format: .audiobook, status: .availableInLibrary, detail: "Available in Library")
        ]
        let decision = RequestActivityFallbackPolicy.decision(
            item: item,
            provider: .shelfarr,
            formats: [.audiobook],
            history: [item],
        )
        #expect(decision.formats.isEmpty)
        #expect(decision.message == "This format is already available in your library.")
    }

    // MARK: - Copy and legacy decode

    @Test func confirmationNamesTheAlternateAndKeepsTheOriginal() {
        let copy = RequestActivityFallbackPolicy.confirmation(
            bookTitle: "Dune",
            formats: [.audiobook],
            alternate: .shelfarr,
            currentProviderName: "LazyLibrarian",
        )
        #expect(copy.prompt == "Try Shelfarr for Dune audiobook?")
        #expect(copy.confirmTitle == "Try Shelfarr")
        #expect(
            copy.footer
                == "This will create a new request with Shelfarr. Your existing LazyLibrarian request will not be deleted."
        )
    }

    // MARK: - Cross-provider duplicate gate

    @Test func normalSubmitKeepsAnActiveRequestOnTheOriginalProvider() {
        let existing = failedItem(
            provider: .lazyLibrarian,
            statuses: [.audiobook: .wanted],
        )
        // providerOverride without a fallback id is a normal request, including retry.
        let result = BookRequestDuplicates.evaluate(
            workID: existing.canonicalWorkID,
            formats: [.audiobook],
            provider: .shelfarr,
            items: [existing],
            fallbackFromRequestID: nil,
        )
        #expect(result.toSend.isEmpty)
        #expect(result.persistedOutcomes.isEmpty)
        #expect(result.callerOutcomes.map(\.phase) == [.alreadyRequested])
    }

    @Test func manualFallbackIsNotBlockedByTheOriginalProvider() {
        let original = failedItem(
            id: "ll-attention",
            provider: .lazyLibrarian,
            statuses: [.audiobook: .needsAttention],
        )
        let result = BookRequestDuplicates.evaluate(
            workID: original.canonicalWorkID,
            formats: [.audiobook],
            provider: .shelfarr,
            items: [original],
            fallbackFromRequestID: original.id,
        )
        #expect(result.toSend == [.audiobook])
        #expect(result.callerOutcomes.isEmpty)
    }

    @Test func activeShelfarrRowBlocksAnotherShelfarrFallback() {
        let original = failedItem(
            id: "ll-attention",
            provider: .lazyLibrarian,
            statuses: [.audiobook: .needsAttention],
        )
        let shelfarr = failedItem(
            id: "shelf-active",
            provider: .shelfarr,
            statuses: [.audiobook: .requested],
        )
        let result = BookRequestDuplicates.evaluate(
            workID: original.canonicalWorkID,
            formats: [.audiobook],
            provider: .shelfarr,
            items: [original, shelfarr],
            fallbackFromRequestID: original.id,
        )
        #expect(result.toSend.isEmpty)
        #expect(result.callerOutcomes.map(\.phase) == [.alreadyRequested])
        #expect(result.persistedOutcomes.map(\.phase) == [.alreadyRequested])
    }

    @Test func sameProviderFailureStillSendsOnRetry() {
        let failed = failedItem(
            provider: .lazyLibrarian,
            statuses: [.audiobook: .failed],
        )
        let result = BookRequestDuplicates.evaluate(
            workID: failed.canonicalWorkID,
            formats: [.audiobook],
            provider: .lazyLibrarian,
            items: [failed],
            fallbackFromRequestID: nil,
        )
        #expect(result.toSend == [.audiobook])
        #expect(result.callerOutcomes.isEmpty)
    }

    @Test func legacyItemWithoutFallbackIDDecodes() throws {
        let item = failedItem(provider: .lazyLibrarian, statuses: [.ebook: .failed])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(item)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "fallbackFromRequestID")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RequestActivityItem.self, from: stripped)
        #expect(decoded.fallbackFromRequestID == nil)
        #expect(decoded.title == "Dune")
        #expect(decoded.provider == .lazyLibrarian)
    }

    private func bothProviders(lan: Bool) -> RequestActivityActionContext {
        RequestActivityActionContext(
            lazyLibrarianEnabled: true,
            lazyLibrarianBaseURL: "https://lazy.example",
            shelfarrBaseURL: "https://shelf.example",
            bookSearchLANEnabled: lan,
            bookSearchLANBaseURL: "http://192.168.1.2:3010",
            lazyLibrarianHasAPIKey: true,
            shelfarrHasToken: true,
        )
    }

    private func failedItem(
        id: String = "req-1",
        provider: BookRequestProviderKind,
        providerBookID: String? = nil,
        statuses: [BookRequestFormat: RequestActivityStatus],
        formats: [BookRequestFormat]? = nil,
    ) -> RequestActivityItem {
        let requested = formats ?? BookRequestFormat.allCases.filter { statuses[$0] != nil }
        return RequestActivityItem(
            id: id,
            canonicalWorkID: "/works/OLDune",
            title: "Dune",
            author: "Frank Herbert",
            provider: provider,
            providerBookID: providerBookID,
            requestedFormats: requested,
            formatStatuses: requested.map { format in
                RequestFormatStatus(format: format, status: statuses[format] ?? .unknown)
            },
            openLibraryWorkID: "/works/OLDune",
        )
    }

    private func duneWork(id: String) -> CanonicalBookWork {
        CanonicalBookWork(
            workID: id,
            title: "Dune",
            subtitle: nil,
            authors: ["Frank Herbert"],
            language: "en",
            isbn: nil,
            openLibraryWorkID: id,
            openLibraryEditionID: nil,
            publicationYear: "1965",
        )
    }
}
