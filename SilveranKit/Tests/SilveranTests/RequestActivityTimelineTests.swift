import Foundation
import Testing

@testable import SilveranKit

@Suite("Request activity timeline")
struct RequestActivityTimelineTests {

    // MARK: - Recording

    @Test func newRequestRecordsRequestedEvent() {
        let incoming = item(
            provider: .lazyLibrarian,
            statuses: [.audiobook: .requested],
        )
        let recorded = RequestActivityTimeline.recordingTransitions(
            previous: nil,
            incoming: incoming,
        )
        let events = recorded.events ?? []
        #expect(events.count == 1)
        #expect(events[0].kind == .requested)
        #expect(events[0].format == .audiobook)
        #expect(events[0].provider == .lazyLibrarian)
    }

    @Test func searchingToWantedAppendsOnce() {
        var current = item(provider: .lazyLibrarian, statuses: [.ebook: .searching])
        current = RequestActivityTimeline.recordingTransitions(previous: nil, incoming: current)
        var next = current
        next.formatStatuses = [
            RequestFormatStatus(format: .ebook, status: .wanted, detail: "Wanted")
        ]
        next = RequestActivityTimeline.recordingTransitions(previous: current, incoming: next)
        #expect(next.events?.map(\.kind) == [.requested, .wanted] || next.events?.map(\.kind) == [
            .searching, .wanted,
        ])
        // Initial was searching (not requested) when previous was nil.
        #expect(next.events?.filter { $0.kind == .wanted }.count == 1)

        let refreshed = RequestActivityTimeline.recordingTransitions(previous: next, incoming: next)
        #expect(refreshed.events?.filter { $0.kind == .wanted }.count == 1)
    }

    @Test func repeatedWantedRefreshDoesNotDuplicate() {
        var current = item(provider: .lazyLibrarian, statuses: [.ebook: .wanted])
        current = RequestActivityTimeline.recordingTransitions(previous: nil, incoming: current)
        let count = current.events?.count
        var refreshed = current
        refreshed.lastCheckedAt = Date()
        refreshed = RequestActivityTimeline.recordingTransitions(
            previous: current,
            incoming: refreshed,
        )
        #expect(refreshed.events?.count == count)
        #expect(refreshed.events?.filter { $0.kind == .wanted }.count == 1)
    }

    @Test func attentionTransitionAppendsOnceWithReason() {
        let before = item(provider: .lazyLibrarian, statuses: [.audiobook: .wanted])
        var after = before
        after.formatStatuses = [
            RequestFormatStatus(
                format: .audiobook,
                status: .needsAttention,
                detail: "Status lookup failed repeatedly",
            )
        ]
        after.attentionReason = "Status lookup failed repeatedly"
        after = RequestActivityTimeline.recordingTransitions(previous: before, incoming: after)
        let attention = after.events?.filter { $0.kind == .needsAttention } ?? []
        #expect(attention.count == 1)
        #expect(attention[0].detail == "Status lookup failed repeatedly")

        let again = RequestActivityTimeline.recordingTransitions(previous: after, incoming: after)
        #expect(again.events?.filter { $0.kind == .needsAttention }.count == 1)
    }

    @Test func storytellerArrivalAppendsOnce() {
        let before = item(provider: .lazyLibrarian, statuses: [.ebook: .wanted])
        var after = before
        after.formatStatuses = [
            RequestFormatStatus(
                format: .ebook,
                status: .availableInLibrary,
                detail: "Available in Library",
            )
        ]
        after = RequestActivityTimeline.recordingTransitions(previous: before, incoming: after)
        #expect(after.events?.filter { $0.kind == .availableInLibrary }.count == 1)
        #expect(after.events?.first { $0.kind == .availableInLibrary }?.provider == nil)

        let again = RequestActivityTimeline.recordingTransitions(previous: after, incoming: after)
        #expect(again.events?.filter { $0.kind == .availableInLibrary }.count == 1)
    }

    @Test func retryStartedIsRecorded() {
        let current = item(provider: .lazyLibrarian, statuses: [.ebook: .needsAttention])
        let stamped = RequestActivityTimeline.appendRetryStarted(
            to: current,
            formats: [.ebook],
        )
        #expect(stamped.events?.contains { $0.kind == .retryStarted && $0.format == .ebook } == true)
    }

    // MARK: - Fallback

    @Test func manualFallbackRecordsOnOriginalAndAlternateRequested() {
        let defaults = UserDefaults(suiteName: "timeline-manual-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }
        let store = RequestActivityStore(defaults: defaults)
        let work = duneWork("/works/OLTimelineManual")
        store.recordSubmission(
            work: work,
            provider: .lazyLibrarian,
            outcomes: [
                BookRequestOutcome(format: .audiobook, phase: .failed, detail: "down")
            ],
        )
        let original = store.item(forWorkID: "/works/OLTimelineManual", provider: .lazyLibrarian)!
        store.recordSubmission(
            work: work,
            provider: .shelfarr,
            outcomes: [
                BookRequestOutcome(format: .audiobook, phase: .requested, detail: "accepted")
            ],
            fallbackFromRequestID: original.id,
            fallbackKind: .manual,
        )
        let source = store.item(id: original.id)!
        let alternate = store.item(forWorkID: "/works/OLTimelineManual", provider: .shelfarr)!
        #expect(
            source.events?.contains {
                $0.kind == .manualFallback && $0.detail == "Tried Shelfarr"
                    && $0.relatedRequestID == alternate.id
            } == true
        )
        #expect(alternate.events?.contains { $0.kind == .requested } == true)
        #expect(alternate.fallbackKind == .manual)
    }

    @Test func automaticFallbackRecordsOnce() {
        let defaults = UserDefaults(suiteName: "timeline-auto-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }
        let store = RequestActivityStore(defaults: defaults)
        let work = duneWork("/works/OLTimelineAuto")
        store.recordSubmission(
            work: work,
            provider: .lazyLibrarian,
            outcomes: [
                BookRequestOutcome(format: .audiobook, phase: .failed, detail: "down")
            ],
        )
        let original = store.item(forWorkID: "/works/OLTimelineAuto", provider: .lazyLibrarian)!
        store.recordSubmission(
            work: work,
            provider: .shelfarr,
            outcomes: [
                BookRequestOutcome(format: .audiobook, phase: .requested, detail: "accepted")
            ],
            fallbackFromRequestID: original.id,
            fallbackKind: .automatic,
        )
        let source = store.item(id: original.id)!
        #expect(source.events?.filter { $0.kind == .automaticFallback }.count == 1)

        // Later refresh of the alternate must not duplicate the source fallback event.
        store.recordSubmission(
            work: work,
            provider: .shelfarr,
            outcomes: [
                BookRequestOutcome(format: .audiobook, phase: .requested, detail: "still")
            ],
            fallbackFromRequestID: original.id,
            fallbackKind: .automatic,
        )
        let after = store.item(id: original.id)!
        #expect(after.events?.filter { $0.kind == .automaticFallback }.count == 1)
    }

    // MARK: - Mixed format / legacy / sorting

    @Test func mixedFormatsKeepSeparateEvents() {
        var current = item(
            provider: .lazyLibrarian,
            statuses: [.ebook: .searching, .audiobook: .searching],
            formats: [.ebook, .audiobook],
        )
        current = RequestActivityTimeline.recordingTransitions(previous: nil, incoming: current)
        var next = current
        next.formatStatuses = [
            RequestFormatStatus(format: .ebook, status: .availableInLibrary),
            RequestFormatStatus(
                format: .audiobook,
                status: .needsAttention,
                detail: "Still waiting",
            ),
        ]
        next = RequestActivityTimeline.recordingTransitions(previous: current, incoming: next)
        #expect(
            next.events?.contains { $0.kind == .availableInLibrary && $0.format == .ebook } == true
        )
        #expect(
            next.events?.contains { $0.kind == .needsAttention && $0.format == .audiobook } == true
        )
    }

    @Test func legacyNilEventsSynthesizeWithoutMutation() {
        let legacy = item(provider: .lazyLibrarian, statuses: [.ebook: .wanted])
        #expect(legacy.events == nil)
        let display = RequestActivityTimeline.displayEvents(for: legacy)
        #expect(display.contains { $0.kind == .requested })
        #expect(display.contains { $0.kind == .wanted })
        #expect(legacy.events == nil)
    }

    @Test func eventsSortOldestToNewestWithStableTies() {
        let t = Date(timeIntervalSince1970: 1_000)
        let events = [
            RequestActivityEvent(id: "b", date: t.addingTimeInterval(10), kind: .wanted, format: .ebook),
            RequestActivityEvent(id: "a", date: t, kind: .requested, format: .ebook),
            RequestActivityEvent(id: "c", date: t.addingTimeInterval(10), kind: .needsAttention, format: .ebook),
        ]
        let sorted = RequestActivityTimeline.sorted(events)
        #expect(sorted.map(\.id) == ["a", "b", "c"])
    }

    @Test func legacyJSONWithoutEventsDecodes() throws {
        let current = item(provider: .lazyLibrarian, statuses: [.ebook: .requested])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(current)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "events")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RequestActivityItem.self, from: stripped)
        #expect(decoded.events == nil)
    }

    @Test func storeRecordsTransitionsOnUpsert() {
        let defaults = UserDefaults(suiteName: "timeline-upsert-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }
        let store = RequestActivityStore(defaults: defaults)
        var current = item(provider: .lazyLibrarian, statuses: [.ebook: .searching])
        store.upsert(current)
        current = store.item(id: current.id)!
        #expect(current.events?.contains { $0.kind == .searching } == true)

        var next = current
        next.formatStatuses = [
            RequestFormatStatus(format: .ebook, status: .wanted, updatedAt: Date())
        ]
        store.upsert(next)
        let loaded = store.item(id: current.id)!
        #expect(loaded.events?.map(\.kind).contains(.wanted) == true)
        let wantedCount = loaded.events?.filter { $0.kind == .wanted }.count
        store.upsert(loaded)
        #expect(store.item(id: current.id)!.events?.filter { $0.kind == .wanted }.count == wantedCount)
    }

    private func item(
        provider: BookRequestProviderKind,
        statuses: [BookRequestFormat: RequestActivityStatus],
        formats: [BookRequestFormat]? = nil,
    ) -> RequestActivityItem {
        let requested = formats ?? BookRequestFormat.allCases.filter { statuses[$0] != nil }
        return RequestActivityItem(
            id: "timeline-\(UUID().uuidString)",
            canonicalWorkID: "/works/OLTimeline",
            title: "Dune",
            author: "Frank Herbert",
            provider: provider,
            requestedFormats: requested,
            formatStatuses: requested.map {
                RequestFormatStatus(format: $0, status: statuses[$0] ?? .unknown)
            },
            openLibraryWorkID: "/works/OLTimeline",
        )
    }

    private func duneWork(_ id: String) -> CanonicalBookWork {
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
