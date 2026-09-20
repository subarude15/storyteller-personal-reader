import Foundation
import Testing

@testable import SilveranKit

@Suite("Request activity chains")
struct RequestActivityChainsTests {

    // MARK: - Basic grouping

    @Test func groupsParentAndFallbackChildIntoOneChain() {
        let now = Date()
        let root = item(
            id: "ll-1",
            title: "The Reddening",
            author: "Adam Nevill",
            provider: .lazyLibrarian,
            formats: [.audiobook: .needsAttention],
            updatedAt: now.addingTimeInterval(-3600),
        )
        let child = item(
            id: "shelf-1",
            title: "The Reddening",
            author: "Adam Nevill",
            provider: .shelfarr,
            formats: [.audiobook: .requested],
            updatedAt: now,
            fallbackFrom: "ll-1",
            fallbackKind: .automatic,
        )

        let index = RequestActivityChains.build(from: [root, child], now: now)
        #expect(index.chains.count == 1)
        let chain = try #require(index.chains.first)
        #expect(chain.rootRequestID == "ll-1")
        #expect(chain.attemptCount == 2)
        #expect(chain.items.map(\.id) == ["ll-1", "shelf-1"])
        #expect(chain.hasFallback)
        #expect(index.requestIDToChainID["shelf-1"] == "ll-1")
    }

    @Test func unrelatedSameBookStaySeparateWithoutFallbackLink() {
        let now = Date()
        let a = item(
            id: "a",
            title: "Dune",
            author: "Frank Herbert",
            provider: .lazyLibrarian,
            formats: [.ebook: .wanted],
            workID: "work/dune",
            updatedAt: now,
        )
        let b = item(
            id: "b",
            title: "Dune",
            author: "Frank Herbert",
            provider: .shelfarr,
            formats: [.ebook: .requested],
            workID: "work/dune",
            updatedAt: now,
        )

        let index = RequestActivityChains.build(from: [a, b], now: now)
        #expect(index.chains.count == 2)
    }

    // MARK: - Effective status

    @Test func activeFallbackOverridesParentNeedsAttention() {
        let now = Date()
        let root = item(
            id: "ll",
            provider: .lazyLibrarian,
            formats: [.audiobook: .needsAttention],
            updatedAt: now.addingTimeInterval(-100),
        )
        let child = item(
            id: "shelf",
            provider: .shelfarr,
            formats: [.audiobook: .requested],
            updatedAt: now,
            fallbackFrom: "ll",
            fallbackKind: .automatic,
        )
        let chain = RequestActivityChains.build(from: [root, child], now: now).chains[0]
        #expect(RequestActivityChains.section(for: chain, now: now) == .inProgress)
        #expect(chain.currentStatus == .requested)
        #expect(chain.effectiveProviderLabel == "Shelfarr")
        #expect(chain.formatState(for: .audiobook)?.providerLabel == "Shelfarr")
    }

    @Test func fallbackAlsoNeedsAttentionKeepsChainInAttention() {
        let now = Date()
        let root = item(
            id: "ll",
            provider: .lazyLibrarian,
            formats: [.audiobook: .needsAttention],
            updatedAt: now.addingTimeInterval(-100),
        )
        let child = item(
            id: "shelf",
            provider: .shelfarr,
            formats: [.audiobook: .needsAttention],
            updatedAt: now,
            fallbackFrom: "ll",
            fallbackKind: .manual,
        )
        let chain = RequestActivityChains.build(from: [root, child], now: now).chains[0]
        #expect(RequestActivityChains.section(for: chain, now: now) == .needsAttention)
        #expect(chain.effectiveProviderLabel == "Shelfarr")
        #expect(chain.currentStatus == .needsAttention)
    }

    @Test func storytellerPresenceWinsOverProviderStates() {
        let now = Date()
        var root = item(
            id: "ll",
            provider: .lazyLibrarian,
            formats: [.audiobook: .needsAttention],
            updatedAt: now.addingTimeInterval(-200),
        )
        var child = item(
            id: "shelf",
            provider: .shelfarr,
            formats: [.audiobook: .requested],
            updatedAt: now.addingTimeInterval(-100),
            fallbackFrom: "ll",
            fallbackKind: .automatic,
        )
        // Storyteller arrival stamped on the active attempt.
        child.formatStatuses = [
            RequestFormatStatus(
                format: .audiobook,
                status: .availableInLibrary,
                updatedAt: now,
            )
        ]
        child.updatedAt = now
        let chain = RequestActivityChains.build(from: [root, child], now: now).chains[0]
        #expect(chain.formatState(for: .audiobook)?.status == .availableInLibrary)
        #expect(chain.formatState(for: .audiobook)?.providerLabel == "Storyteller")
        #expect(RequestActivityChains.section(for: chain, now: now) == .completed)
        #expect(!chain.needsAttention)
    }

    @Test func mixedFormatsPreservePerFormatState() {
        let now = Date()
        let root = RequestActivityItem(
            id: "ll",
            canonicalWorkID: "work/1",
            title: "Mixed",
            author: "Author",
            provider: .lazyLibrarian,
            requestedFormats: [.ebook, .audiobook],
            createdAt: now.addingTimeInterval(-300),
            updatedAt: now.addingTimeInterval(-200),
            formatStatuses: [
                RequestFormatStatus(
                    format: .ebook,
                    status: .availableInLibrary,
                    updatedAt: now.addingTimeInterval(-50),
                ),
                RequestFormatStatus(
                    format: .audiobook,
                    status: .needsAttention,
                    updatedAt: now.addingTimeInterval(-200),
                ),
            ],
        )
        let child = item(
            id: "shelf",
            title: "Mixed",
            author: "Author",
            provider: .shelfarr,
            formats: [.audiobook: .requested],
            workID: "work/1",
            updatedAt: now,
            fallbackFrom: "ll",
            fallbackKind: .automatic,
        )
        let chain = RequestActivityChains.build(from: [root, child], now: now).chains[0]
        #expect(chain.formatState(for: .ebook)?.status == .availableInLibrary)
        #expect(chain.formatState(for: .ebook)?.providerLabel == "Storyteller")
        #expect(chain.formatState(for: .audiobook)?.status == .requested)
        #expect(chain.formatState(for: .audiobook)?.providerLabel == "Shelfarr")
        #expect(RequestActivityChains.section(for: chain, now: now) == .inProgress)
        #expect(!chain.availableInLibrary)
    }

    // MARK: - Timeline

    @Test func combinedTimelineIsChronologicalWithoutDuplicateFallback() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = t0.addingTimeInterval(60)
        let t2 = t0.addingTimeInterval(120)
        let t3 = t0.addingTimeInterval(180)

        var root = item(
            id: "ll",
            provider: .lazyLibrarian,
            formats: [.audiobook: .needsAttention],
            updatedAt: t1,
        )
        root.createdAt = t0
        root.events = [
            RequestActivityEvent(
                id: "e1",
                date: t0,
                kind: .requested,
                format: .audiobook,
                provider: .lazyLibrarian,
                title: "Requested",
            ),
            RequestActivityEvent(
                id: "e2",
                date: t1,
                kind: .needsAttention,
                format: .audiobook,
                provider: .lazyLibrarian,
                title: "Needs Attention",
            ),
            RequestActivityEvent(
                id: "e3",
                date: t2,
                kind: .automaticFallback,
                format: .audiobook,
                provider: .shelfarr,
                title: "Automatic fallback",
                detail: "Tried Shelfarr",
                relatedRequestID: "shelf",
            ),
        ]

        var child = item(
            id: "shelf",
            provider: .shelfarr,
            formats: [.audiobook: .requested],
            updatedAt: t3,
            fallbackFrom: "ll",
            fallbackKind: .automatic,
        )
        child.createdAt = t2
        child.events = [
            // Same hop described again — must dedupe.
            RequestActivityEvent(
                id: "e4",
                date: t2,
                kind: .automaticFallback,
                format: .audiobook,
                provider: .shelfarr,
                title: "Automatic fallback",
                detail: "Tried Shelfarr",
                relatedRequestID: "shelf",
            ),
            RequestActivityEvent(
                id: "e5",
                date: t3,
                kind: .requested,
                format: .audiobook,
                provider: .shelfarr,
                title: "Requested",
            ),
        ]

        let chain = RequestActivityChains.build(from: [root, child]).chains[0]
        let timeline = RequestActivityChains.combinedTimeline(for: chain)
        #expect(timeline.map(\.event.kind) == [
            .requested,
            .needsAttention,
            .automaticFallback,
            .requested,
        ])
        #expect(timeline.map(\.sourceRequestID) == ["ll", "ll", "ll", "shelf"])
    }

    // MARK: - Deep link

    @Test func deepLinkChildResolvesToParentChain() {
        let now = Date()
        let root = item(id: "ll", provider: .lazyLibrarian, formats: [.ebook: .needsAttention], updatedAt: now)
        let child = item(
            id: "shelf",
            provider: .shelfarr,
            formats: [.ebook: .requested],
            updatedAt: now,
            fallbackFrom: "ll",
            fallbackKind: .manual,
        )
        let index = RequestActivityChains.build(from: [root, child], now: now)
        #expect(RequestActivityChains.resolveChainID(requestID: "shelf", index: index) == "ll")
        let destination = RequestActivityNavigation.resolvedChainDetail(
            requestID: "shelf",
            chainIDForRequest: { index.requestIDToChainID[$0] },
            itemExists: { index.requestIDToChainID[$0] != nil },
        )
        #expect(destination == .detail(requestID: "ll"))
    }

    // MARK: - Counts

    @Test func librarySummaryCountsChainsNotRows() {
        let now = Date()
        let root = item(
            id: "ll",
            provider: .lazyLibrarian,
            formats: [.audiobook: .needsAttention],
            updatedAt: now,
        )
        let child = item(
            id: "shelf",
            provider: .shelfarr,
            formats: [.audiobook: .requested],
            updatedAt: now,
            fallbackFrom: "ll",
            fallbackKind: .automatic,
        )
        let other = item(
            id: "other",
            title: "Other",
            provider: .lazyLibrarian,
            formats: [.ebook: .wanted],
            workID: "work/other",
            updatedAt: now,
        )
        let summary = RequestActivityGrouping.librarySummary([root, child, other], now: now)
        #expect(summary.inProgressCount == 2)
        #expect(summary.needsAttentionCount == 0)
        #expect(summary.hasTrackedRequests)
    }

    @Test func needsAttentionCountUsesEffectiveChainStatus() {
        let now = Date()
        let root = item(
            id: "ll",
            provider: .lazyLibrarian,
            formats: [.audiobook: .needsAttention],
            updatedAt: now,
        )
        let child = item(
            id: "shelf",
            provider: .shelfarr,
            formats: [.audiobook: .needsAttention],
            updatedAt: now,
            fallbackFrom: "ll",
            fallbackKind: .automatic,
        )
        let summary = RequestActivityGrouping.librarySummary([root, child], now: now)
        #expect(summary.needsAttentionCount == 1)
        #expect(summary.inProgressCount == 0)
    }

    // MARK: - Cycle / legacy safety

    @Test func cyclicFallbackLinksDoNotLoopAndAreDeterministic() {
        let now = Date()
        let a = item(
            id: "a",
            provider: .lazyLibrarian,
            formats: [.ebook: .wanted],
            updatedAt: now,
            fallbackFrom: "b",
            fallbackKind: .manual,
        )
        let b = item(
            id: "b",
            provider: .shelfarr,
            formats: [.ebook: .requested],
            updatedAt: now,
            fallbackFrom: "a",
            fallbackKind: .manual,
        )
        let index = RequestActivityChains.build(from: [a, b], now: now)
        #expect(index.chains.count == 1)
        #expect(index.chains[0].id == "a") // lexicographically smaller cycle root
        #expect(index.chains[0].attemptCount == 2)
        #expect(Set(index.chains[0].items.map(\.id)) == Set(["a", "b"]))
    }

    @Test func missingParentBecomesOwnRoot() {
        let now = Date()
        let orphan = item(
            id: "orphan",
            provider: .shelfarr,
            formats: [.ebook: .requested],
            updatedAt: now,
            fallbackFrom: "missing-parent",
            fallbackKind: .automatic,
        )
        let index = RequestActivityChains.build(from: [orphan], now: now)
        #expect(index.chains.count == 1)
        #expect(index.chains[0].id == "orphan")
        #expect(index.chains[0].attemptCount == 1)
    }

    @Test func selfReferentialFallbackIsOwnRoot() {
        let now = Date()
        let row = item(
            id: "self",
            provider: .lazyLibrarian,
            formats: [.ebook: .wanted],
            updatedAt: now,
            fallbackFrom: "self",
            fallbackKind: .manual,
        )
        let index = RequestActivityChains.build(from: [row], now: now)
        #expect(index.chains.count == 1)
        #expect(index.chains[0].id == "self")
    }

    @Test func legacyRowsWithoutFallbackRemainIndividualChains() {
        let now = Date()
        let a = item(id: "1", provider: .lazyLibrarian, formats: [.ebook: .wanted], updatedAt: now)
        let b = item(
            id: "2",
            title: "Other",
            provider: .shelfarr,
            formats: [.audiobook: .requested],
            workID: "work/2",
            updatedAt: now,
        )
        let index = RequestActivityChains.build(from: [a, b], now: now)
        #expect(index.chains.count == 2)
    }

    @Test func libraryIndexDedupesPendingRowsForOneChain() {
        let now = Date()
        let root = item(
            id: "ll",
            title: "The Reddening",
            author: "Adam Nevill",
            provider: .lazyLibrarian,
            formats: [.audiobook: .needsAttention],
            workID: "work/reddening",
            updatedAt: now,
        )
        let child = item(
            id: "shelf",
            title: "The Reddening",
            author: "Adam Nevill",
            provider: .shelfarr,
            formats: [.audiobook: .requested],
            workID: "work/reddening",
            updatedAt: now,
            fallbackFrom: "ll",
            fallbackKind: .automatic,
        )
        let index = RequestLibraryPresentationIndex(items: [root, child], books: [], now: now)
        let pending = index.pendingRows(filter: .requests)
        #expect(pending.count == 1)
        #expect(pending[0].id == "ll")
        #expect(pending[0].badge.kind == .inProgress)
        #expect(index.chip.activeCount == 1)
        #expect(index.chip.attentionCount == 0)
    }

    @Test func actionItemTargetsActiveFallbackAttempt() {
        let now = Date()
        let root = item(
            id: "ll",
            provider: .lazyLibrarian,
            formats: [.audiobook: .needsAttention],
            updatedAt: now.addingTimeInterval(-10),
        )
        let child = item(
            id: "shelf",
            provider: .shelfarr,
            formats: [.audiobook: .needsAttention],
            updatedAt: now,
            fallbackFrom: "ll",
            fallbackKind: .automatic,
        )
        let chain = RequestActivityChains.build(from: [root, child], now: now).chains[0]
        #expect(RequestActivityChains.actionItem(for: chain)?.id == "shelf")
    }

    @Test func multiHopManualFallbackStaysOneChain() {
        let now = Date()
        let root = item(
            id: "ll",
            provider: .lazyLibrarian,
            formats: [.audiobook: .needsAttention],
            updatedAt: now.addingTimeInterval(-300),
        )
        let mid = item(
            id: "shelf-1",
            provider: .shelfarr,
            formats: [.audiobook: .needsAttention],
            updatedAt: now.addingTimeInterval(-200),
            fallbackFrom: "ll",
            fallbackKind: .automatic,
        )
        let leaf = item(
            id: "shelf-2",
            provider: .shelfarr,
            formats: [.audiobook: .requested],
            updatedAt: now,
            fallbackFrom: "shelf-1",
            fallbackKind: .manual,
        )
        let chain = RequestActivityChains.build(from: [root, mid, leaf], now: now).chains[0]
        #expect(chain.attemptCount == 3)
        #expect(chain.rootRequestID == "ll")
        #expect(chain.formatState(for: .audiobook)?.status == .requested)
        #expect(RequestActivityChains.actionItem(for: chain)?.id == "shelf-2")
    }

    // MARK: - Helpers

    private func item(
        id: String,
        title: String = "Book",
        author: String = "Author",
        provider: BookRequestProviderKind,
        formats: [BookRequestFormat: RequestActivityStatus],
        workID: String = "work/1",
        updatedAt: Date,
        fallbackFrom: String? = nil,
        fallbackKind: RequestFallbackKind? = nil,
    ) -> RequestActivityItem {
        RequestActivityItem(
            id: id,
            canonicalWorkID: workID,
            title: title,
            author: author,
            provider: provider,
            requestedFormats: BookRequestFormat.allCases.filter { formats[$0] != nil },
            createdAt: updatedAt,
            updatedAt: updatedAt,
            formatStatuses: formats.map { format, status in
                RequestFormatStatus(format: format, status: status, updatedAt: updatedAt)
            },
            fallbackFromRequestID: fallbackFrom,
            fallbackKind: fallbackKind,
        )
    }
}
