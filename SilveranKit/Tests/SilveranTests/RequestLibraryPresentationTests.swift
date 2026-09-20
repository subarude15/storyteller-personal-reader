import Foundation
import Testing

@testable import SilveranKit

@Suite("Request library presentation")
struct RequestLibraryPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Matching

    @Test func canonicalIDMatch() {
        let book = libraryBook(uuid: "work-1", title: "Other", authors: ["Nobody"], ebook: true)
        let item = requestItem(
            canonicalWorkID: book.id.description,
            title: "Dune",
            author: "Frank Herbert",
            formats: [.ebook],
            status: .wanted,
        )
        let index = RequestLibraryPresentationIndex(items: [item], books: [book], now: now)
        #expect(index.match(book: book)?.id == item.id)
        #expect(index.badge(for: book)?.label == "Wanted")
    }

    @Test func isbnFallbackMatch() {
        let book = libraryBook(
            uuid: "isbn-book",
            title: "Pride",
            authors: ["Jane Austen"],
            description: "ISBN 9780141439518",
            ebook: true,
        )
        let item = requestItem(
            canonicalWorkID: "unrelated",
            title: "Completely Different",
            author: "Nobody",
            formats: [.ebook],
            status: .searching,
            isbn: "978-0-14-143951-8",
        )
        let index = RequestLibraryPresentationIndex(items: [item], books: [book], now: now)
        #expect(index.match(book: book)?.id == item.id)
        #expect(index.badge(for: book)?.label == "Searching")
    }

    @Test func titleAuthorFallbackMatch() {
        let book = libraryBook(uuid: "dune-book", title: "Dune", authors: ["Frank Herbert"], ebook: true)
        let item = requestItem(
            canonicalWorkID: "not-the-book-id",
            title: "Dune",
            author: "Frank Herbert",
            formats: [.audiobook],
            status: .snatched,
        )
        let index = RequestLibraryPresentationIndex(items: [item], books: [book], now: now)
        #expect(index.badge(for: book)?.label == "Snatched")
    }

    @Test func conflictingAuthorDoesNotMatch() {
        let book = libraryBook(uuid: "dune-book", title: "Dune", authors: ["Frank Herbert"], ebook: true)
        let item = requestItem(
            canonicalWorkID: "other",
            title: "Dune",
            author: "Brian Herbert",
            formats: [.ebook],
            status: .wanted,
        )
        let index = RequestLibraryPresentationIndex(items: [item], books: [book], now: now)
        #expect(index.match(book: book) == nil)
        #expect(index.badge(for: book) == nil)
        #expect(index.pendingRows(filter: .requests).map(\.id) == [item.id])
    }

    // MARK: - Badge priority

    @Test func needsAttentionBeatsWanted() {
        let item = requestItem(
            statuses: [.ebook: .needsAttention, .audiobook: .wanted],
            attention: "stale",
        )
        let badge = RequestLibraryPresentationIndex.badge(for: item, now: now, includeStaleReady: false)
        #expect(badge?.label == "Needs Attention")
        #expect(badge?.kind == .needsAttention)
        #expect(badge?.accessibilityLabel == "Request status: Needs Attention")
    }

    @Test func wantedBeatsReady() {
        let item = requestItem(
            statuses: [.ebook: .availableInLibrary, .audiobook: .wanted],
        )
        let badge = RequestLibraryPresentationIndex.badge(for: item, now: now, includeStaleReady: false)
        #expect(badge?.label == "Wanted")
        #expect(badge?.kind == .inProgress)
    }

    @Test func allFormatsInLibraryIsReady() {
        let item = requestItem(
            statuses: [.ebook: .availableInLibrary, .audiobook: .availableInLibrary],
            updatedAt: now,
        )
        let badge = RequestLibraryPresentationIndex.badge(for: item, now: now, includeStaleReady: false)
        #expect(badge?.label == "Ready")
        #expect(badge?.accessibilityLabel == "Request status: Available in Library")
    }

    @Test func providerAvailableOnlyIsNotReady() {
        let item = requestItem(status: .available, formats: [.ebook])
        let badge = RequestLibraryPresentationIndex.badge(for: item, now: now, includeStaleReady: false)
        #expect(badge?.label == "Available")
        #expect(badge?.kind == .inProgress)
        #expect(badge?.label != "Ready")
    }

    // MARK: - Filtering

    @Test func activeRequestIncludedInRequestsFilter() {
        let book = libraryBook(uuid: "b1", title: "Dune", authors: ["Frank Herbert"], ebook: true)
        let item = requestItem(
            canonicalWorkID: book.id.description,
            title: "Dune",
            author: "Frank Herbert",
            formats: [.ebook],
            status: .searching,
        )
        let other = libraryBook(uuid: "b2", title: "Untracked", authors: ["Someone"], ebook: true)
        let index = RequestLibraryPresentationIndex(items: [item], books: [book, other], now: now)
        let filtered = index.filteredBooks([book, other], filter: .requests)
        #expect(filtered.map(\.id) == [book.id])
    }

    @Test func needsAttentionIncludedInNeedsAttentionFilter() {
        let book = libraryBook(uuid: "b1", title: "Dune", authors: ["Frank Herbert"], ebook: true)
        let item = requestItem(
            canonicalWorkID: book.id.description,
            title: "Dune",
            author: "Frank Herbert",
            formats: [.ebook],
            status: .needsAttention,
            attention: "lookup failed",
        )
        let index = RequestLibraryPresentationIndex(items: [item], books: [book], now: now)
        #expect(index.includes(book: book, filter: .needsAttention))
        #expect(index.includes(book: book, filter: .requests))
    }

    @Test func untrackedBookExcludedFromRequestsFilter() {
        let book = libraryBook(uuid: "plain", title: "Plain", authors: ["Author"], ebook: true)
        let index = RequestLibraryPresentationIndex(items: [], books: [book], now: now)
        #expect(index.filteredBooks([book], filter: .requests).isEmpty)
        #expect(index.filteredBooks([book], filter: .all).count == 1)
    }

    @Test func availableInLibraryFilterIncludesCompletedNotProviderOnly() {
        let readyBook = libraryBook(uuid: "ready", title: "Ready Book", authors: ["A"], ebook: true)
        let providerBook = libraryBook(uuid: "prov", title: "Provider Book", authors: ["B"], ebook: true)
        let ready = requestItem(
            canonicalWorkID: readyBook.id.description,
            title: "Ready Book",
            author: "A",
            formats: [.ebook],
            status: .availableInLibrary,
            updatedAt: now,
        )
        let provider = requestItem(
            canonicalWorkID: providerBook.id.description,
            title: "Provider Book",
            author: "B",
            formats: [.ebook],
            status: .available,
            updatedAt: now,
        )
        let index = RequestLibraryPresentationIndex(
            items: [ready, provider],
            books: [readyBook, providerBook],
            now: now,
        )
        let shown = index.filteredBooks([readyBook, providerBook], filter: .availableInLibrary)
        #expect(shown.map(\.id) == [readyBook.id])
        #expect(index.includes(book: providerBook, filter: .requests))
    }

    @Test func shelfarrRequestedStaysActiveButNotNeedsAttentionByAge() {
        let fiveDaysAgo = now.addingTimeInterval(-(5 * 24 * 3600))
        let book = libraryBook(uuid: "shelf", title: "Dune", authors: ["Frank Herbert"], ebook: true)
        let item = requestItem(
            canonicalWorkID: book.id.description,
            title: "Dune",
            author: "Frank Herbert",
            formats: [.ebook],
            status: .requested,
            provider: .shelfarr,
            updatedAt: fiveDaysAgo,
        )
        let index = RequestLibraryPresentationIndex(items: [item], books: [book], now: now)
        #expect(index.includes(book: book, filter: .requests))
        #expect(!index.includes(book: book, filter: .needsAttention))
        #expect(index.badge(for: book)?.label == "Requested")
        #expect(index.chip.attentionCount == 0)
        #expect(index.chip.activeCount == 1)
    }

    // MARK: - Summary

    @Test func chipCountsIgnoreStaleCompleted() {
        let active = requestItem(status: .wanted, formats: [.ebook], updatedAt: now)
        let attention = requestItem(
            id: "attn",
            status: .needsAttention,
            formats: [.ebook],
            attention: "stale",
            updatedAt: now,
        )
        let oldReady = requestItem(
            id: "old",
            status: .availableInLibrary,
            formats: [.ebook],
            updatedAt: now.addingTimeInterval(-(10 * 24 * 3600)),
        )
        let index = RequestLibraryPresentationIndex(
            items: [active, attention, oldReady],
            books: [],
            now: now,
        )
        #expect(index.chip.activeCount == 2)
        #expect(index.chip.attentionCount == 1)
        #expect(index.badge(for: oldReady) == nil)
    }

    // MARK: - Observability

    @Test func storeChangeRefreshesIndex() {
        let defaults = UserDefaults(suiteName: "request-library-index-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.suiteName!) }
        let store = RequestActivityStore(defaults: defaults)
        let book = libraryBook(uuid: "obs", title: "Dune", authors: ["Frank Herbert"], ebook: true)
        let refresher = RequestLibraryIndexRefresher(
            store: store,
            books: { [book] },
            now: { self.now },
        )
        #expect(refresher.currentIndex().badge(for: book) == nil)

        store.upsert(
            requestItem(
                canonicalWorkID: book.id.description,
                title: "Dune",
                author: "Frank Herbert",
                formats: [.ebook],
                status: .searching,
                updatedAt: now,
            )
        )
        #expect(refresher.currentIndex().badge(for: book)?.label == "Searching")
    }

    // MARK: - Helpers

    private func requestItem(
        id: String = UUID().uuidString,
        canonicalWorkID: String = "work",
        title: String = "Dune",
        author: String = "Frank Herbert",
        formats: [BookRequestFormat],
        status: RequestActivityStatus,
        provider: BookRequestProviderKind = .lazyLibrarian,
        attention: String? = nil,
        isbn: String? = nil,
        updatedAt: Date? = nil,
    ) -> RequestActivityItem {
        let stamp = updatedAt ?? now
        return RequestActivityItem(
            id: id,
            canonicalWorkID: canonicalWorkID,
            title: title,
            author: author,
            provider: provider,
            requestedFormats: formats,
            updatedAt: stamp,
            formatStatuses: formats.map {
                RequestFormatStatus(format: $0, status: status, updatedAt: stamp)
            },
            attentionReason: attention,
            isbn: isbn,
        )
    }

    private func requestItem(
        id: String = UUID().uuidString,
        statuses: [BookRequestFormat: RequestActivityStatus],
        attention: String? = nil,
        updatedAt: Date? = nil,
    ) -> RequestActivityItem {
        let stamp = updatedAt ?? now
        let formats = BookRequestFormat.allCases.filter { statuses[$0] != nil }
        return RequestActivityItem(
            id: id,
            canonicalWorkID: id,
            title: "Dune",
            author: "Frank Herbert",
            provider: .lazyLibrarian,
            requestedFormats: formats,
            updatedAt: stamp,
            formatStatuses: formats.map {
                RequestFormatStatus(format: $0, status: statuses[$0]!, updatedAt: stamp)
            },
            attentionReason: attention,
        )
    }

    private func libraryBook(
        uuid: String,
        title: String,
        authors: [String],
        description: String? = nil,
        ebook: Bool = false,
    ) -> BookMetadata {
        BookMetadata(
            bookID: BookID(sourceID: "storyteller", uuid: uuid),
            title: title,
            subtitle: nil,
            description: description,
            language: nil,
            createdAt: nil,
            updatedAt: nil,
            publicationDate: nil,
            authors: authors.map {
                BookCreator(
                    uuid: nil, id: nil, name: $0, fileAs: nil, role: "aut", createdAt: nil,
                    updatedAt: nil,
                )
            },
            narrators: nil,
            creators: nil,
            series: nil,
            tags: nil,
            collections: nil,
            ebook: ebook
                ? BookAsset(
                    uuid: uuid, filepath: "\(uuid).epub", missing: 0, createdAt: nil, updatedAt: nil,
                ) : nil,
            audiobook: nil,
            readaloud: nil,
            status: nil,
            position: nil,
            rating: nil,
        )
    }
}
