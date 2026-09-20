import Foundation
import Testing

@testable import SilveranKit

@Suite("Request library matcher")
struct RequestLibraryMatcherTests {
    // MARK: - Matching

    @Test func matchesSameCanonicalWorkID() {
        let book = libraryBook(uuid: "work-1", title: "Dune", authors: ["Frank Herbert"], ebook: true)
        let matcher = RequestLibraryMatcher(books: [book])
        let item = requestItem(
            canonicalWorkID: book.id.description,
            title: "Other Title",
            author: "Someone Else",
            formats: [.ebook],
            status: .wanted,
        )
        #expect(matcher.hasFormat(.ebook, for: item))
        #expect(matcher.hasFormat(.audiobook, for: item) == false)
    }

    @Test func matchesISBN() {
        let book = libraryBook(
            uuid: "isbn-book",
            title: "Pride",
            authors: ["Jane Austen"],
            description: "ISBN 9780141439518",
            ebook: true,
        )
        let matcher = RequestLibraryMatcher(books: [book])
        let item = requestItem(
            canonicalWorkID: "unrelated",
            title: "Completely Different",
            author: "Nobody",
            formats: [.ebook],
            status: .wanted,
            isbn: "978-0-14-143951-8",
        )
        #expect(matcher.hasFormat(.ebook, for: item))
    }

    @Test func matchesTitleAndCompatibleAuthor() {
        let book = libraryBook(
            uuid: "title-book",
            title: "The Left Hand of Darkness",
            authors: ["Ursula K. Le Guin"],
            ebook: true,
            audiobook: true,
        )
        let matcher = RequestLibraryMatcher(books: [book])
        let item = requestItem(
            canonicalWorkID: "ol-unknown",
            title: "Left Hand of Darkness",
            author: "Le Guin, Ursula K.",
            formats: [.ebook, .audiobook],
            status: .searching,
        )
        #expect(matcher.availability(for: item)?.hasEbook == true)
        #expect(matcher.availability(for: item)?.hasAudiobook == true)
    }

    @Test func sameTitleConflictingAuthorDoesNotMatch() {
        let book = libraryBook(
            uuid: "conflict",
            title: "Dune",
            authors: ["Frank Herbert"],
            ebook: true,
        )
        let matcher = RequestLibraryMatcher(books: [book])
        let item = requestItem(
            canonicalWorkID: "other",
            title: "Dune",
            author: "Brian Herbert",
            formats: [.ebook],
            status: .wanted,
        )
        #expect(matcher.availability(for: item) == nil)
    }

    @Test func unrelatedTitleDoesNotMatch() {
        let book = libraryBook(uuid: "a", title: "Dune", authors: ["Frank Herbert"], ebook: true)
        let matcher = RequestLibraryMatcher(books: [book])
        let item = requestItem(
            canonicalWorkID: "x",
            title: "Hyperion",
            author: "Frank Herbert",
            formats: [.ebook],
            status: .wanted,
        )
        #expect(matcher.availability(for: item) == nil)
    }

    @Test func titleOnlyWithoutAuthorDoesNotMatch() {
        let book = libraryBook(uuid: "a", title: "Dune", authors: ["Frank Herbert"], ebook: true)
        let matcher = RequestLibraryMatcher(books: [book])
        let item = requestItem(
            canonicalWorkID: "x",
            title: "Dune",
            author: "",
            formats: [.ebook],
            status: .wanted,
        )
        #expect(matcher.availability(for: item) == nil)
    }

    // MARK: - Format availability

    @Test func formatAvailabilityEbookOnly() {
        let book = libraryBook(uuid: "e", title: "Dune", authors: ["Frank Herbert"], ebook: true)
        let availability = RequestLibraryFormatAvailability.from(book: book)
        #expect(availability.hasEbook)
        #expect(availability.hasAudiobook == false)
    }

    @Test func formatAvailabilityAudiobookOnly() {
        let book = libraryBook(
            uuid: "a",
            title: "Dune",
            authors: ["Frank Herbert"],
            audiobook: true,
        )
        let availability = RequestLibraryFormatAvailability.from(book: book)
        #expect(availability.hasEbook == false)
        #expect(availability.hasAudiobook)
    }

    @Test func formatAvailabilityBoth() {
        let book = libraryBook(
            uuid: "b",
            title: "Dune",
            authors: ["Frank Herbert"],
            ebook: true,
            audiobook: true,
        )
        let availability = RequestLibraryFormatAvailability.from(book: book)
        #expect(availability.hasEbook && availability.hasAudiobook)
    }

    @Test func formatAvailabilityNeitherWhenMissing() {
        let book = BookMetadata(
            bookID: BookID(sourceID: "s", uuid: "m"),
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
                uuid: "m", filepath: "x.epub", missing: 1, createdAt: nil, updatedAt: nil
            ),
            audiobook: nil,
            readaloud: nil,
            status: nil,
            position: nil,
            rating: nil,
        )
        #expect(RequestLibraryFormatAvailability.from(book: book).isEmpty)
    }

    @Test func readaloudDoesNotCountAsAudiobook() {
        let book = libraryBook(
            uuid: "r",
            title: "Dune",
            authors: ["Frank Herbert"],
            readaloud: "READY",
        )
        #expect(RequestLibraryFormatAvailability.from(book: book).hasAudiobook == false)
    }

    // MARK: - Status precedence

    @Test func storytellerEbookOverridesLazyLibrarianWanted() {
        let now = Date()
        let book = libraryBook(uuid: "w1", title: "Dune", authors: ["Frank Herbert"], ebook: true)
        var item = requestItem(
            canonicalWorkID: book.id.description,
            title: "Dune",
            author: "Frank Herbert",
            formats: [.ebook],
            status: .wanted,
        )
        let matcher = RequestLibraryMatcher(books: [book])
        item = RequestLibraryPresence.apply(item, matcher: matcher, now: now)
        #expect(item.status(for: .ebook)?.status == .availableInLibrary)
        #expect(item.status(for: .ebook)?.detail == "Available in Library")
    }

    @Test func storytellerAudiobookOverridesSnatched() {
        let now = Date()
        let book = libraryBook(
            uuid: "w2",
            title: "Dune",
            authors: ["Frank Herbert"],
            audiobook: true,
        )
        var item = requestItem(
            canonicalWorkID: book.id.description,
            title: "Dune",
            author: "Frank Herbert",
            formats: [.audiobook],
            status: .snatched,
        )
        item = RequestLibraryPresence.apply(
            item,
            matcher: RequestLibraryMatcher(books: [book]),
            now: now,
        )
        #expect(item.status(for: .audiobook)?.status == .availableInLibrary)
    }

    @Test func providerHaveWithoutStorytellerStaysProviderAvailable() {
        let item = requestItem(
            canonicalWorkID: "missing",
            title: "Ghost Book",
            author: "Nobody",
            formats: [.ebook],
            status: .available,
        )
        let updated = RequestLibraryPresence.apply(
            item,
            matcher: RequestLibraryMatcher(books: []),
            now: Date(),
        )
        #expect(updated.status(for: .ebook)?.status == .available)
        #expect(updated.status(for: .ebook)?.status.isCompleted == false)
        #expect(updated.status(for: .ebook)?.status.isInProgress == true)
    }

    @Test func mixedFormatsRemainInProgress() {
        let now = Date()
        let book = libraryBook(uuid: "mix", title: "Dune", authors: ["Frank Herbert"], ebook: true)
        var item = RequestActivityItem(
            id: "mix",
            canonicalWorkID: book.id.description,
            title: "Dune",
            author: "Frank Herbert",
            provider: .lazyLibrarian,
            requestedFormats: [.ebook, .audiobook],
            updatedAt: now,
            formatStatuses: [
                RequestFormatStatus(format: .ebook, status: .wanted, updatedAt: now),
                RequestFormatStatus(format: .audiobook, status: .wanted, updatedAt: now),
            ],
        )
        item = RequestLibraryPresence.apply(
            item,
            matcher: RequestLibraryMatcher(books: [book]),
            now: now,
        )
        #expect(item.status(for: .ebook)?.status == .availableInLibrary)
        #expect(item.status(for: .audiobook)?.status == .wanted)
        #expect(RequestActivityGrouping.section(for: item, now: now) == .inProgress)
        #expect(item.allRequestedFormatsInLibrary == false)
    }

    @Test func allFormatsInLibraryIsCompleted() {
        let now = Date()
        let book = libraryBook(
            uuid: "both",
            title: "Dune",
            authors: ["Frank Herbert"],
            ebook: true,
            audiobook: true,
        )
        var item = RequestActivityItem(
            id: "both",
            canonicalWorkID: book.id.description,
            title: "Dune",
            author: "Frank Herbert",
            provider: .lazyLibrarian,
            requestedFormats: [.ebook, .audiobook],
            updatedAt: now,
            formatStatuses: [
                RequestFormatStatus(format: .ebook, status: .available, updatedAt: now),
                RequestFormatStatus(format: .audiobook, status: .snatched, updatedAt: now),
            ],
        )
        item = RequestLibraryPresence.apply(
            item,
            matcher: RequestLibraryMatcher(books: [book]),
            now: now,
        )
        #expect(item.allRequestedFormatsInLibrary)
        #expect(RequestActivityGrouping.section(for: item, now: now) == .completed)
        let summary = RequestActivityGrouping.librarySummary([item], now: now)
        #expect(summary.recentlyAvailableCount == 1)
        #expect(summary.inProgressCount == 0)
    }

    @Test func doesNotDowngradeAvailableInLibrary() {
        let now = Date()
        var item = requestItem(
            canonicalWorkID: "gone",
            title: "Dune",
            author: "Frank Herbert",
            formats: [.ebook],
            status: .availableInLibrary,
        )
        // Empty library — presence apply must not clear Available in Library.
        item = RequestLibraryPresence.apply(
            item,
            matcher: RequestLibraryMatcher(books: []),
            now: now,
        )
        #expect(item.status(for: .ebook)?.status == .availableInLibrary)
    }

    // MARK: - Backward compatibility

    @Test func decodesLegacyRequestActivityItemJSONWithoutNewIdentifiers() throws {
        let json = """
            {
              "id": "legacy-1",
              "canonicalWorkID": "/works/OL1W",
              "title": "Dune",
              "author": "Frank Herbert",
              "provider": "lazyLibrarian",
              "requestedFormats": ["ebook"],
              "createdAt": "2024-01-01T00:00:00Z",
              "updatedAt": "2024-01-02T00:00:00Z",
              "formatStatuses": [
                {
                  "format": "ebook",
                  "status": "wanted",
                  "updatedAt": "2024-01-02T00:00:00Z",
                  "consecutiveLookupFailures": 0
                }
              ]
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let item = try decoder.decode(RequestActivityItem.self, from: Data(json.utf8))
        #expect(item.openLibraryWorkID == nil)
        #expect(item.isbn == nil)
        #expect(item.status(for: .ebook)?.status == .wanted)

        let book = libraryBook(
            uuid: "legacy-match",
            title: "Dune",
            authors: ["Frank Herbert"],
            ebook: true,
        )
        let updated = RequestLibraryPresence.apply(
            item,
            matcher: RequestLibraryMatcher(books: [book]),
            now: Date(),
        )
        #expect(updated.status(for: .ebook)?.status == .availableInLibrary)
    }

    // MARK: - Helpers

    private func requestItem(
        canonicalWorkID: String,
        title: String,
        author: String,
        formats: [BookRequestFormat],
        status: RequestActivityStatus,
        isbn: String? = nil,
    ) -> RequestActivityItem {
        let now = Date()
        return RequestActivityItem(
            canonicalWorkID: canonicalWorkID,
            title: title,
            author: author,
            provider: .lazyLibrarian,
            requestedFormats: formats,
            updatedAt: now,
            formatStatuses: formats.map {
                RequestFormatStatus(format: $0, status: status, updatedAt: now)
            },
            isbn: isbn,
        )
    }

    private func libraryBook(
        uuid: String,
        title: String,
        authors: [String],
        description: String? = nil,
        ebook: Bool = false,
        audiobook: Bool = false,
        readaloud: String? = nil,
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
                    updatedAt: nil
                )
            },
            narrators: nil,
            creators: nil,
            series: nil,
            tags: nil,
            collections: nil,
            ebook: ebook
                ? BookAsset(
                    uuid: uuid, filepath: "\(uuid).epub", missing: 0, createdAt: nil, updatedAt: nil
                ) : nil,
            audiobook: audiobook
                ? BookAsset(
                    uuid: uuid, filepath: "\(uuid).m4b", missing: 0, createdAt: nil, updatedAt: nil
                ) : nil,
            readaloud: readaloud == nil
                ? nil
                : BookReadaloud(
                    uuid: uuid,
                    filepath: "\(uuid)-read.epub",
                    missing: 0,
                    status: readaloud,
                    currentStage: nil,
                    stageProgress: nil,
                    queuePosition: nil,
                    restartPending: nil,
                    createdAt: nil,
                    updatedAt: nil,
                ),
            status: nil,
            position: nil,
            rating: nil,
        )
    }
}
