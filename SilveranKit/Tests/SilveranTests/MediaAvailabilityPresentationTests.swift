import Foundation
import Testing

@testable import SilveranAppleKit
@testable import SilveranKit

/// Characterization of library media-kind / narration availability matching (R5).
/// Locks CURRENT quirks; does not redesign shelf semantics.
@Suite("Media availability presentation")
struct MediaAvailabilityPresentationTests {

    // MARK: - matchesKind

    @Test func ebookKindIncludesEbookAndReadaloud() {
        #expect(MediaAvailabilityPresentation.matchesKind(book(ebook: true), kind: .ebook))
        #expect(MediaAvailabilityPresentation.matchesKind(book(readaloudAligned: true), kind: .ebook))
        #expect(
            MediaAvailabilityPresentation.matchesKind(
                book(ebook: true, audiobook: true),
                kind: .ebook,
            )
        )
    }

    @Test func ebookKindExcludesAudiobookOnly() {
        #expect(!MediaAvailabilityPresentation.matchesKind(book(audiobook: true), kind: .ebook))
        #expect(!MediaAvailabilityPresentation.matchesKind(book(), kind: .ebook))
    }

    @Test func audiobookKindRequiresAudiobookWithoutEbookOrReadaloud() {
        #expect(MediaAvailabilityPresentation.matchesKind(book(audiobook: true), kind: .audiobook))
        #expect(
            !MediaAvailabilityPresentation.matchesKind(
                book(ebook: true, audiobook: true),
                kind: .audiobook,
            )
        )
        #expect(
            !MediaAvailabilityPresentation.matchesKind(
                book(audiobook: true, readaloudAligned: true),
                kind: .audiobook,
            )
        )
        #expect(!MediaAvailabilityPresentation.matchesKind(book(ebook: true), kind: .audiobook))
    }

    // MARK: - items narration (hasAnyAudiobookAsset)

    @Test func itemsNarrationWithAudioUsesAnyAudiobookAsset() {
        #expect(
            MediaAvailabilityPresentation.matchesItemsNarrationFilter(
                book(audiobook: true),
                filter: .withAudio,
            )
        )
        #expect(
            MediaAvailabilityPresentation.matchesItemsNarrationFilter(
                book(readaloudAligned: true),
                filter: .withAudio,
            )
        )
        #expect(
            !MediaAvailabilityPresentation.matchesItemsNarrationFilter(
                book(ebook: true),
                filter: .withAudio,
            )
        )
    }

    @Test func itemsNarrationWithoutAudioNegatesAnyAudiobookAsset() {
        #expect(
            MediaAvailabilityPresentation.matchesItemsNarrationFilter(
                book(ebook: true),
                filter: .withoutAudio,
            )
        )
        // Readaloud-only has hasAnyAudiobookAsset → excluded from withoutAudio items path
        #expect(
            !MediaAvailabilityPresentation.matchesItemsNarrationFilter(
                book(readaloudAligned: true),
                filter: .withoutAudio,
            )
        )
    }

    // MARK: - stricter narration (grid count path)

    @Test func strictNarrationWithoutAudioRequiresEbookOnly() {
        #expect(
            MediaAvailabilityPresentation.matchesNarrationFilter(
                book(ebook: true),
                filter: .withoutAudio,
            )
        )
        // Readaloud-only is NOT isEbookOnly → fails strict withoutAudio (quirk vs items path)
        #expect(
            !MediaAvailabilityPresentation.matchesNarrationFilter(
                book(readaloudAligned: true),
                filter: .withoutAudio,
            )
        )
        #expect(
            !MediaAvailabilityPresentation.matchesNarrationFilter(
                book(ebook: true, audiobook: true),
                filter: .withoutAudio,
            )
        )
    }

    @Test func strictNarrationWithAudioUsesAudiobookOrReadaloud() {
        #expect(
            MediaAvailabilityPresentation.matchesNarrationFilter(
                book(audiobook: true),
                filter: .withAudio,
            )
        )
        #expect(
            MediaAvailabilityPresentation.matchesNarrationFilter(
                book(readaloudAligned: true),
                filter: .withAudio,
            )
        )
        #expect(
            !MediaAvailabilityPresentation.matchesNarrationFilter(
                book(ebook: true),
                filter: .withAudio,
            )
        )
    }

    // MARK: - audiobook-only shelf union + merge

    @Test func shouldIncludeAudiobookOnlyExceptWithoutAudio() {
        #expect(MediaAvailabilityPresentation.shouldIncludeAudiobookOnlyItems(for: .both))
        #expect(MediaAvailabilityPresentation.shouldIncludeAudiobookOnlyItems(for: .withAudio))
        #expect(!MediaAvailabilityPresentation.shouldIncludeAudiobookOnlyItems(for: .withoutAudio))
    }

    @Test func mergeItemsAppendsUniqueIDsPreservingOrder() {
        let a = book(id: "a", ebook: true)
        let b = book(id: "b", audiobook: true)
        let bDup = book(id: "b", title: "Dup", audiobook: true)
        let c = book(id: "c", ebook: true)

        let merged = MediaAvailabilityPresentation.mergeItems([a, b], with: [bDup, c])
        #expect(merged.map(\.id.uuid) == ["a", "b", "c"])
        #expect(merged[1].title == "B")  // first wins
    #expect(MediaAvailabilityPresentation.mergeItems([a], with: []).map(\.id.uuid) == ["a"])
    }

    // MARK: - Fixtures

    private func book(
        id: String = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        title: String? = nil,
        ebook: Bool = false,
        audiobook: Bool = false,
        readaloudAligned: Bool = false,
    ) -> BookMetadata {
        BookMetadata(
            bookID: BookID(sourceID: "server", uuid: id),
            title: title ?? id.uppercased(),
            subtitle: nil,
            description: nil,
            language: nil,
            createdAt: nil,
            updatedAt: nil,
            publicationDate: nil,
            authors: nil,
            narrators: nil,
            creators: nil,
            series: nil,
            tags: nil,
            collections: nil,
            ebook: ebook
                ? BookAsset(
                    uuid: id,
                    filepath: "\(id).epub",
                    missing: 0,
                    createdAt: nil,
                    updatedAt: nil
                ) : nil,
            audiobook: audiobook
                ? BookAsset(
                    uuid: id,
                    filepath: "\(id).m4b",
                    missing: 0,
                    createdAt: nil,
                    updatedAt: nil
                ) : nil,
            readaloud: readaloudAligned
                ? BookReadaloud(
                    uuid: id,
                    filepath: "\(id).epub",
                    missing: 0,
                    status: "ALIGNED",
                    currentStage: nil,
                    stageProgress: nil,
                    queuePosition: nil,
                    restartPending: nil,
                    createdAt: nil,
                    updatedAt: nil,
                ) : nil,
            status: nil,
            position: nil,
            rating: nil,
        )
    }
}
