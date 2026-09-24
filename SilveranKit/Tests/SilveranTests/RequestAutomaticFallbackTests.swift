import Foundation
import Testing

@testable import SilveranKit

@Suite("Optional automatic request fallback")
struct RequestAutomaticFallbackTests {

    // MARK: - Feature off / eligibility

    @Test func disabledProducesNoFallback() {
        let decision = AutomaticFallbackPolicy.decide(
            item: attentionItem(provider: .lazyLibrarian, age: 8 * 3600),
            history: [],
            settings: AutomaticFallbackSettingsSnapshot(enabled: false, delay: .immediately),
            context: bothProviders,
        )
        #expect(decision == .none)
    }

    @Test func lazyLibrarianFailedWithShelfarrConfiguredIsEligible() {
        let decision = AutomaticFallbackPolicy.decide(
            item: attentionItem(provider: .lazyLibrarian, age: 0),
            history: [],
            settings: AutomaticFallbackSettingsSnapshot(enabled: true, delay: .immediately),
            context: bothProviders,
        )
        guard case .submit(_, let provider, let formats) = decision else {
            Issue.record("expected submit")
            return
        }
        #expect(provider == .shelfarr)
        #expect(formats == [.audiobook])
    }

    @Test func shelfarrFailedWithLazyLibrarianConfiguredIsEligible() {
        let decision = AutomaticFallbackPolicy.decide(
            item: attentionItem(provider: .shelfarr, age: 0, formats: [.ebook]),
            history: [],
            settings: AutomaticFallbackSettingsSnapshot(enabled: true, delay: .immediately),
            context: bothProviders,
        )
        guard case .submit(_, let provider, let formats) = decision else {
            Issue.record("expected submit")
            return
        }
        #expect(provider == .lazyLibrarian)
        #expect(formats == [.ebook])
    }

    @Test func wantedIsNotEligible() {
        #expect(
            AutomaticFallbackPolicy.decide(
                item: statusItem(provider: .lazyLibrarian, status: .wanted),
                history: [],
                settings: enabledImmediate,
                context: bothProviders,
            ) == .none
        )
    }

    @Test func searchingIsNotEligible() {
        #expect(
            AutomaticFallbackPolicy.decide(
                item: statusItem(provider: .lazyLibrarian, status: .searching),
                history: [],
                settings: enabledImmediate,
                context: bothProviders,
            ) == .none
        )
    }

    @Test func providerAvailableIsNotEligible() {
        #expect(
            AutomaticFallbackPolicy.decide(
                item: statusItem(provider: .lazyLibrarian, status: .available),
                history: [],
                settings: enabledImmediate,
                context: bothProviders,
            ) == .none
        )
    }

    @Test func availableInLibraryIsNotEligible() {
        #expect(
            AutomaticFallbackPolicy.decide(
                item: statusItem(provider: .lazyLibrarian, status: .availableInLibrary),
                history: [],
                settings: enabledImmediate,
                context: bothProviders,
            ) == .none
        )
    }

    @Test func shelfarrRequestedAgeAloneIsNotEligible() {
        let item = statusItem(
            provider: .shelfarr,
            status: .requested,
            age: 48 * 3600,
        )
        #expect(
            AutomaticFallbackPolicy.decide(
                item: item,
                history: [],
                settings: enabledImmediate,
                context: bothProviders,
            ) == .none
        )
    }

    @Test func missingAlternateConfigurationIsNotEligible() {
        let context = RequestActivityActionContext(
            lazyLibrarianEnabled: true,
            lazyLibrarianBaseURL: "https://lazy.example",
            shelfarrBaseURL: "",
            lazyLibrarianHasAPIKey: true,
            shelfarrHasToken: false,
        )
        #expect(
            AutomaticFallbackPolicy.decide(
                item: attentionItem(provider: .lazyLibrarian, age: 0),
                history: [],
                settings: enabledImmediate,
                context: context,
            ) == .none
        )
    }

    // MARK: - Delay

    @Test func delayBlocksUntilAttentionAgePasses() {
        let item = attentionItem(provider: .lazyLibrarian, age: 2 * 3600)
        let settings = AutomaticFallbackSettingsSnapshot(enabled: true, delay: .sixHours)
        #expect(
            AutomaticFallbackPolicy.decide(
                item: item,
                history: [],
                settings: settings,
                context: bothProviders,
            ) == .none
        )
        let message = AutomaticFallbackPolicy.pendingMessage(
            item: item,
            settings: settings,
            context: bothProviders,
        )
        #expect(message?.contains("Shelfarr") == true)
        #expect(message?.contains("about") == true)
    }

    @Test func delayElapsedAllowsFallback() {
        let decision = AutomaticFallbackPolicy.decide(
            item: attentionItem(provider: .lazyLibrarian, age: 7 * 3600),
            history: [],
            settings: AutomaticFallbackSettingsSnapshot(enabled: true, delay: .sixHours),
            context: bothProviders,
        )
        guard case .submit = decision else {
            Issue.record("expected submit after delay")
            return
        }
    }

    @Test func immediateSettingFallsBackRightAway() {
        let decision = AutomaticFallbackPolicy.decide(
            item: attentionItem(provider: .lazyLibrarian, age: 0),
            history: [],
            settings: enabledImmediate,
            context: bothProviders,
        )
        guard case .submit = decision else {
            Issue.record("expected immediate submit")
            return
        }
    }

    // MARK: - Formats

    @Test func ebookReadyLeavesAudiobookOnly() {
        let item = RequestActivityItem(
            id: "mixed",
            canonicalWorkID: "/works/OLDune",
            title: "Dune",
            author: "Frank Herbert",
            provider: .lazyLibrarian,
            requestedFormats: [.ebook, .audiobook],
            formatStatuses: [
                RequestFormatStatus(
                    format: .ebook,
                    status: .availableInLibrary,
                    updatedAt: Date().addingTimeInterval(-10 * 3600),
                ),
                RequestFormatStatus(
                    format: .audiobook,
                    status: .needsAttention,
                    updatedAt: Date().addingTimeInterval(-10 * 3600),
                ),
            ],
        )
        let decision = AutomaticFallbackPolicy.decide(
            item: item,
            history: [item],
            settings: enabledImmediate,
            context: bothProviders,
        )
        guard case .submit(_, _, let formats) = decision else {
            Issue.record("expected audiobook submit")
            return
        }
        #expect(formats == [.audiobook])
    }

    @Test func bothFailedFormatsStayEligible() {
        let item = RequestActivityItem(
            id: "both",
            canonicalWorkID: "/works/OLDune",
            title: "Dune",
            author: "Frank Herbert",
            provider: .lazyLibrarian,
            requestedFormats: [.ebook, .audiobook],
            formatStatuses: [
                RequestFormatStatus(format: .ebook, status: .failed, updatedAt: Date()),
                RequestFormatStatus(format: .audiobook, status: .needsAttention, updatedAt: Date()),
            ],
        )
        let decision = AutomaticFallbackPolicy.decide(
            item: item,
            history: [item],
            settings: enabledImmediate,
            context: bothProviders,
        )
        guard case .submit(_, _, let formats) = decision else {
            Issue.record("expected both formats")
            return
        }
        #expect(Set(formats) == Set([.ebook, .audiobook]))
    }

    // MARK: - One hop / duplicates / storyteller / health

    @Test func automaticAlternateDoesNotHopBack() {
        let original = attentionItem(id: "ll", provider: .lazyLibrarian, age: 0)
        let alternate = RequestActivityItem(
            id: "shelf",
            canonicalWorkID: original.canonicalWorkID,
            title: "Dune",
            author: "Frank Herbert",
            provider: .shelfarr,
            requestedFormats: [.audiobook],
            formatStatuses: [
                RequestFormatStatus(format: .audiobook, status: .needsAttention, updatedAt: Date())
            ],
            fallbackFromRequestID: original.id,
            fallbackKind: .automatic,
        )
        #expect(
            AutomaticFallbackPolicy.decide(
                item: alternate,
                history: [original, alternate],
                settings: enabledImmediate,
                context: bothProviders,
            ) == .none
        )
    }

    @Test func activeAlternateBlocksAutomaticSubmit() {
        let original = attentionItem(id: "ll", provider: .lazyLibrarian, age: 0)
        let active = RequestActivityItem(
            id: "shelf",
            canonicalWorkID: original.canonicalWorkID,
            title: "Dune",
            author: "Frank Herbert",
            provider: .shelfarr,
            requestedFormats: [.audiobook],
            formatStatuses: [
                RequestFormatStatus(format: .audiobook, status: .requested)
            ],
        )
        #expect(
            AutomaticFallbackPolicy.decide(
                item: original,
                history: [original, active],
                settings: enabledImmediate,
                context: bothProviders,
            ) == .none
        )
    }

    @Test func completedAlternateBlocksAutomaticSubmit() {
        let original = attentionItem(id: "ll", provider: .lazyLibrarian, age: 0)
        let done = RequestActivityItem(
            id: "shelf",
            canonicalWorkID: original.canonicalWorkID,
            title: "Dune",
            author: "Frank Herbert",
            provider: .shelfarr,
            requestedFormats: [.audiobook],
            formatStatuses: [
                RequestFormatStatus(format: .audiobook, status: .availableInLibrary)
            ],
        )
        #expect(
            AutomaticFallbackPolicy.decide(
                item: original,
                history: [original, done],
                settings: enabledImmediate,
                context: bothProviders,
            ) == .none
        )
    }

    @Test func recordedAttemptPreventsRepeat() {
        var original = attentionItem(id: "ll", provider: .lazyLibrarian, age: 0)
        original.automaticFallbackAttempts = [
            AutomaticFallbackAttempt(format: .audiobook, targetProvider: .shelfarr)
        ]
        #expect(
            AutomaticFallbackPolicy.decide(
                item: original,
                history: [original],
                settings: enabledImmediate,
                context: bothProviders,
            ) == .none
        )
    }

    @Test func priorAutomaticHopRowBlocksRepeatEvenIfAttemptMissing() {
        let original = attentionItem(id: "ll", provider: .lazyLibrarian, age: 0)
        let hop = RequestActivityItem(
            id: "shelf",
            canonicalWorkID: original.canonicalWorkID,
            title: "Dune",
            author: "Frank Herbert",
            provider: .shelfarr,
            requestedFormats: [.audiobook],
            formatStatuses: [
                RequestFormatStatus(format: .audiobook, status: .failed)
            ],
            fallbackFromRequestID: original.id,
            fallbackKind: .automatic,
        )
        #expect(
            AutomaticFallbackPolicy.decide(
                item: original,
                history: [original, hop],
                settings: enabledImmediate,
                context: bothProviders,
            ) == .none
        )
    }

    @Test func storytellerPresenceClearsEligibleFormats() {
        let item = statusItem(provider: .lazyLibrarian, status: .availableInLibrary)
        #expect(
            AutomaticFallbackPolicy.decide(
                item: item,
                history: [item],
                settings: enabledImmediate,
                context: bothProviders,
            ) == .none
        )
    }

    @Test func unavailableAlternateSkipsWithoutMarking() {
        let item = attentionItem(provider: .lazyLibrarian, age: 0)
        let decision = AutomaticFallbackPolicy.decide(
            item: item,
            history: [item],
            settings: enabledImmediate,
            context: bothProviders,
            unavailableShelfarr: true,
        )
        #expect(decision == .skipUnavailable(target: .shelfarr))
        #expect(item.automaticFallbackAttempts == nil)
    }

    // MARK: - Attention clock for fallback delay

    @Test func staleWantedEntersAttentionWithNowTimestamp() {
        let wantedAt = Date(timeIntervalSince1970: 1_000_000)
        let attentionAt = wantedAt.addingTimeInterval(25 * 3600)
        var item = RequestActivityItem(
            id: "stale-clock",
            canonicalWorkID: "/works/OLDune",
            title: "Dune",
            author: "Frank Herbert",
            provider: .lazyLibrarian,
            requestedFormats: [.audiobook],
            formatStatuses: [
                RequestFormatStatus(
                    format: .audiobook,
                    status: .wanted,
                    updatedAt: wantedAt,
                )
            ],
        )
        item = RequestActivityAttention.apply(item, now: attentionAt)
        #expect(item.formatStatuses[0].status == .needsAttention)
        #expect(item.formatStatuses[0].updatedAt == attentionAt)

        let settings = AutomaticFallbackSettingsSnapshot(enabled: true, delay: .sixHours)
        #expect(
            AutomaticFallbackPolicy.decide(
                item: item,
                history: [item],
                settings: settings,
                context: bothProviders,
                now: attentionAt,
            ) == .none
        )
        let later = AutomaticFallbackPolicy.decide(
            item: item,
            history: [item],
            settings: settings,
            context: bothProviders,
            now: attentionAt.addingTimeInterval(7 * 3600),
        )
        guard case .submit = later else {
            Issue.record("expected fallback after attention delay, not wanted age")
            return
        }
    }

    @Test func lookupFailureEscalationResetsAttentionClock() {
        let old = Date(timeIntervalSince1970: 2_000_000)
        let now = old.addingTimeInterval(12 * 3600)
        var item = RequestActivityItem(
            id: "lookup-clock",
            canonicalWorkID: "/works/OLDune",
            title: "Dune",
            author: "Frank Herbert",
            provider: .lazyLibrarian,
            requestedFormats: [.ebook],
            formatStatuses: [
                RequestFormatStatus(
                    format: .ebook,
                    status: .wanted,
                    updatedAt: old,
                    consecutiveLookupFailures: 3,
                )
            ],
        )
        item = RequestActivityAttention.apply(item, now: now)
        #expect(item.formatStatuses[0].status == .needsAttention)
        #expect(item.formatStatuses[0].updatedAt == now)
    }

    @Test func existingAttentionDoesNotResetClock() {
        let entered = Date(timeIntervalSince1970: 3_000_000)
        let later = entered.addingTimeInterval(5 * 3600)
        var item = RequestActivityItem(
            id: "keep-clock",
            canonicalWorkID: "/works/OLDune",
            title: "Dune",
            author: "Frank Herbert",
            provider: .lazyLibrarian,
            requestedFormats: [.audiobook],
            formatStatuses: [
                RequestFormatStatus(
                    format: .audiobook,
                    status: .needsAttention,
                    detail: "Still waiting",
                    updatedAt: entered,
                    consecutiveLookupFailures: 3,
                )
            ],
            attentionReason: "Still waiting",
        )
        item = RequestActivityAttention.apply(item, now: later)
        #expect(item.formatStatuses[0].status == .needsAttention)
        #expect(item.formatStatuses[0].updatedAt == entered)
    }

    @Test func failedTransitionUsesCurrentAttentionTimestamp() {
        let ancient = Date(timeIntervalSince1970: 100)
        let now = Date(timeIntervalSince1970: 4_000_000)
        var item = RequestActivityItem(
            id: "failed-clock",
            canonicalWorkID: "/works/OLDune",
            title: "Dune",
            author: "Frank Herbert",
            provider: .lazyLibrarian,
            requestedFormats: [.ebook],
            formatStatuses: [
                RequestFormatStatus(
                    format: .ebook,
                    status: .failed,
                    detail: "down",
                    updatedAt: ancient,
                )
            ],
        )
        item = RequestActivityAttention.apply(item, now: now)
        #expect(item.formatStatuses[0].status == .needsAttention)
        #expect(item.formatStatuses[0].updatedAt == now)
        #expect(
            AutomaticFallbackPolicy.decide(
                item: item,
                history: [item],
                settings: AutomaticFallbackSettingsSnapshot(enabled: true, delay: .sixHours),
                context: bothProviders,
                now: now,
            ) == .none
        )
    }

    // MARK: - Marking / history

    @Test func markAttemptsThenAttachResult() {
        let source = attentionItem(id: "ll", provider: .lazyLibrarian, age: 0)
        let marked = AutomaticFallbackPolicy.markAttempts(
            on: source,
            formats: [.audiobook],
            target: .shelfarr,
            now: Date(timeIntervalSince1970: 100),
        )
        #expect(marked.automaticFallbackAttempts?.count == 1)
        #expect(marked.automaticFallbackAttempts?.first?.resultingRequestID == nil)
        let linked = AutomaticFallbackPolicy.attachResultingID(
            on: marked,
            formats: [.audiobook],
            target: .shelfarr,
            resultingRequestID: "shelf-1",
        )
        #expect(linked.automaticFallbackAttempts?.first?.resultingRequestID == "shelf-1")
    }

    @Test func automaticSubmissionRecordsFallbackKind() {
        let suiteName = "auto-fallback-kind-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RequestActivityStore(defaults: defaults)
        let work = CanonicalBookWork(
            workID: "/works/OLDune",
            title: "Dune",
            subtitle: nil,
            authors: ["Frank Herbert"],
            language: "en",
            isbn: nil,
            openLibraryWorkID: "/works/OLDune",
            openLibraryEditionID: nil,
            publicationYear: "1965",
        )
        store.recordSubmission(
            work: work,
            provider: .lazyLibrarian,
            outcomes: [
                BookRequestOutcome(format: .audiobook, phase: .failed, detail: "down")
            ],
        )
        let original = store.item(forWorkID: "/works/OLDune", provider: .lazyLibrarian)!
        store.recordSubmission(
            work: work,
            provider: .shelfarr,
            outcomes: [
                BookRequestOutcome(format: .audiobook, phase: .requested, detail: "ok")
            ],
            fallbackFromRequestID: original.id,
            fallbackKind: .automatic,
        )
        let shelf = store.item(forWorkID: "/works/OLDune", provider: .shelfarr)
        #expect(store.allItems().count == 2)
        #expect(original.fallbackFromRequestID == nil)
        #expect(original.fallbackKind == nil)
        #expect(shelf?.fallbackFromRequestID == original.id)
        #expect(shelf?.fallbackKind == .automatic)
    }

    @Test func manualFallbackStillRecordsManualKind() {
        let suiteName = "manual-fallback-kind-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RequestActivityStore(defaults: defaults)
        let work = CanonicalBookWork(
            workID: "/works/OLManual",
            title: "Dune",
            subtitle: nil,
            authors: ["Frank Herbert"],
            language: "en",
            isbn: nil,
            openLibraryWorkID: "/works/OLManual",
            openLibraryEditionID: nil,
            publicationYear: "1965",
        )
        store.recordSubmission(
            work: work,
            provider: .shelfarr,
            outcomes: [
                BookRequestOutcome(format: .ebook, phase: .requested, detail: "ok")
            ],
            fallbackFromRequestID: "ll-1",
            fallbackKind: .manual,
        )
        #expect(store.item(forWorkID: "/works/OLManual", provider: .shelfarr)?.fallbackKind == .manual)
    }

    @Test func legacyJSONWithoutAutoMetadataDecodes() throws {
        let item = attentionItem(provider: .lazyLibrarian, age: 0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(item)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "fallbackKind")
        object.removeValue(forKey: "automaticFallbackAttempts")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RequestActivityItem.self, from: stripped)
        #expect(decoded.fallbackKind == nil)
        #expect(decoded.automaticFallbackAttempts == nil)
    }

    // MARK: - Concurrency

    @Test func concurrentEvaluationsSubmitOnce() async {
        let suiteName = "auto-fallback-race-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RequestActivityStore(defaults: defaults)
        let source = attentionItem(id: "ll-race", provider: .lazyLibrarian, age: 0)
        store.upsert(source)
        let fake = CountingFallbackSubmitter()
        let coordinator = RequestAutomaticFallbackCoordinator(
            history: store,
            submitter: fake,
            settings: { AutomaticFallbackSettingsSnapshot(enabled: true, delay: .immediately) },
            health: { (false, false) },
        )
        async let first = coordinator.evaluate(actionContext: bothProviders)
        async let second = coordinator.evaluate(actionContext: bothProviders)
        let counts = await [first, second]
        #expect(await fake.count == 1)
        #expect(counts.reduce(0, +) == 1)
        let marked = store.item(id: source.id)
        #expect(marked?.automaticFallbackAttempts?.count == 1)
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

    private var enabledImmediate: AutomaticFallbackSettingsSnapshot {
        AutomaticFallbackSettingsSnapshot(enabled: true, delay: .immediately)
    }

    private func attentionItem(
        id: String = "req-1",
        provider: BookRequestProviderKind,
        age: TimeInterval,
        formats: [BookRequestFormat] = [.audiobook],
    ) -> RequestActivityItem {
        statusItem(
            id: id,
            provider: provider,
            status: .needsAttention,
            age: age,
            formats: formats,
        )
    }

    private func statusItem(
        id: String = "req-1",
        provider: BookRequestProviderKind,
        status: RequestActivityStatus,
        age: TimeInterval = 0,
        formats: [BookRequestFormat] = [.audiobook],
    ) -> RequestActivityItem {
        RequestActivityItem(
            id: id,
            canonicalWorkID: "/works/OLDune",
            title: "Dune",
            author: "Frank Herbert",
            provider: provider,
            requestedFormats: formats,
            formatStatuses: formats.map {
                RequestFormatStatus(
                    format: $0,
                    status: status,
                    updatedAt: Date().addingTimeInterval(-age),
                )
            },
            openLibraryWorkID: "/works/OLDune",
        )
    }
}

private actor CountingFallbackSubmitter: AutomaticFallbackSubmitting {
    private(set) var count = 0

    func submitFallback(
        work: CanonicalBookWork,
        formats: [BookRequestFormat],
        provider: BookRequestProviderKind,
        fallbackFromRequestID: String,
        history: RequestActivityStore,
        now: Date,
    ) async -> BookRequestSubmission {
        count += 1
        try? await Task.sleep(nanoseconds: 50_000_000)
        history.recordSubmission(
            work: work,
            provider: provider,
            outcomes: formats.map {
                BookRequestOutcome(format: $0, phase: .requested, detail: "fake")
            },
            now: now,
            fallbackFromRequestID: fallbackFromRequestID,
            fallbackKind: .automatic,
        )
        return BookRequestSubmission(
            provider: provider,
            outcomes: formats.map {
                BookRequestOutcome(format: $0, phase: .requested, detail: "fake")
            },
        )
    }
}
