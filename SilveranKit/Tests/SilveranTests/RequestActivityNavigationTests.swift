import Foundation
import Testing

@testable import SilveranKit

@Suite("Request activity navigation")
struct RequestActivityNavigationTests {
    // MARK: - Pending state

    @Test func detailPeekThenConsumeOnce() {
        let coordinator = RequestActivityNavigationCoordinator()
        coordinator.set(.detail(requestID: "abc"))
        #expect(coordinator.peek() == .detail(requestID: "abc"))
        #expect(coordinator.consume() == .detail(requestID: "abc"))
        #expect(coordinator.consume() == nil)
        #expect(coordinator.peek() == nil)
    }

    @Test func destinationSetBeforeConsumerIsDeliveredOnce() {
        let coordinator = RequestActivityNavigationCoordinator()
        coordinator.set(.detail(requestID: "cold-start"))
        // UI is not mounted yet. A later consumer still receives the id, then it is cleared.
        let received = coordinator.consume()
        #expect(received == .detail(requestID: "cold-start"))
        #expect(coordinator.consume() == nil)
    }

    // MARK: - List fallback

    @Test func absentRequestIDResolvesToList() {
        let request = RequestActivityNavigation.request(from: ["kind": "available"])
        #expect(request.destination == .list)
        #expect(request.kind == "available")
    }

    @Test func missingHistoryResolvesDetailToList() {
        let resolved = RequestActivityNavigation.resolved(
            .detail(requestID: "gone"),
            itemExists: { _ in false },
        )
        #expect(resolved == .list)
    }

    @Test func existingRequestStaysOnDetail() {
        let resolved = RequestActivityNavigation.resolved(
            .detail(requestID: "abc"),
            itemExists: { $0 == "abc" },
        )
        #expect(resolved == .detail(requestID: "abc"))
    }

    // MARK: - Notification parsing

    @Test func validRequestIDParsesToDetail() {
        let request = RequestActivityNavigation.request(
            from: ["requestID": "req-1", "kind": "needsAttention"]
        )
        #expect(request.destination == .detail(requestID: "req-1"))
        #expect(request.kind == "needsAttention")
        #expect(request.destination.requestID == "req-1")
    }

    @Test func missingRequestIDParsesToList() {
        #expect(RequestActivityNavigation.request(from: nil).destination == .list)
        #expect(RequestActivityNavigation.request(from: [:]).destination == .list)
    }

    @Test func malformedPayloadDoesNotCrashAndFallsBackToList() {
        let request = RequestActivityNavigation.request(
            from: ["requestID": 42, "kind": 7]
        )
        #expect(request.destination == .list)
        #expect(request.kind == nil)
        let blank = RequestActivityNavigation.request(from: ["requestID": "   "])
        #expect(blank.destination == .list)
    }

    // MARK: - Library navigation

    @Test func badgeUsesMatchedRequestID() {
        let book = BookMetadata(
            bookID: BookID(sourceID: "storyteller", uuid: "dune"),
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
                    createdAt: nil, updatedAt: nil,
                )
            ],
            narrators: nil,
            creators: nil,
            series: nil,
            tags: nil,
            collections: nil,
            ebook: BookAsset(
                uuid: "dune", filepath: "dune.epub", missing: 0, createdAt: nil, updatedAt: nil,
            ),
            audiobook: nil,
            readaloud: nil,
            status: nil,
            position: nil,
            rating: nil,
        )
        let item = RequestActivityItem(
            id: "req-dune",
            canonicalWorkID: book.id.description,
            title: "Dune",
            author: "Frank Herbert",
            provider: .lazyLibrarian,
            requestedFormats: [.ebook],
            formatStatuses: [
                RequestFormatStatus(format: .ebook, status: .wanted, updatedAt: Date())
            ],
        )
        let index = RequestLibraryPresentationIndex(items: [item], books: [book])
        #expect(
            RequestActivityLibraryNavigation.badge(book: book, index: index)
                == .detail(requestID: "req-dune")
        )
    }

    @Test func pendingRowUsesItsRequestID() {
        let row = RequestLibraryPendingRow(
            id: "pending-1",
            title: "Dune",
            author: "Frank Herbert",
            formatsLabel: "Ebook",
            badge: RequestLibraryBadgeState(
                label: "Searching",
                systemImage: "clock",
                kind: .inProgress,
                accessibilityLabel: "Request status: Searching",
            ),
        )
        #expect(RequestActivityLibraryNavigation.pendingRow(row) == .detail(requestID: "pending-1"))
    }

    @Test func summaryStaysOnList() {
        #expect(RequestActivityLibraryNavigation.summary == .list)
        #expect(RequestActivityLibraryNavigation.summary.requestID == nil)
    }
}
