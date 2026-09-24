import Foundation
import Testing

@testable import SilveranAppleKit
@testable import SilveranKit

/// Characterization of cover-variant selection extracted from MediaViewModel (R4).
/// Describes CURRENT behavior; quirks are intentional locks, not fixes.
@Suite("Media cover variant selection")
struct MediaCoverVariantSelectionTests {

    // MARK: - Default (no CoverPreference)

    @Test func defaultPrefersEbookWhenBothFormatsPresent() {
        #expect(MediaCoverVariantSelection.coverVariant(for: coverBook(ebook: true, audiobook: true)) == .standard)
    }

    @Test func defaultUsesAudioSquareForAudiobookOnly() {
        #expect(MediaCoverVariantSelection.coverVariant(for: coverBook(ebook: false, audiobook: true)) == .audioSquare)
    }

    @Test func defaultUsesStandardForEbookOnly() {
        #expect(MediaCoverVariantSelection.coverVariant(for: coverBook(ebook: true, audiobook: false)) == .standard)
    }

    @Test func defaultUsesStandardWhenNoAssets() {
        #expect(MediaCoverVariantSelection.coverVariant(for: coverBook(ebook: false, audiobook: false)) == .standard)
    }

    // MARK: - preferEbook / storytellerDouble (identical today)

    @Test func preferEbookAndStorytellerDoubleShareSelectionRules() {
        let both = coverBook(ebook: true, audiobook: true)
        let audioOnly = coverBook(ebook: false, audiobook: true)
        let none = coverBook(ebook: false, audiobook: false)

        for preference in [CoverPreference.preferEbook, .storytellerDouble] {
            #expect(MediaCoverVariantSelection.coverVariant(for: both, preference: preference) == .standard)
            #expect(
                MediaCoverVariantSelection.coverVariant(for: audioOnly, preference: preference)
                    == .audioSquare
            )
            #expect(MediaCoverVariantSelection.coverVariant(for: none, preference: preference) == .standard)
        }
    }

    // MARK: - preferAudiobook

    @Test func preferAudiobookSelectsAudioSquareWhenAudiobookPresent() {
        #expect(
            MediaCoverVariantSelection.coverVariant(
                for: coverBook(ebook: true, audiobook: true),
                preference: .preferAudiobook,
            ) == .audioSquare
        )
        #expect(
            MediaCoverVariantSelection.coverVariant(
                for: coverBook(ebook: false, audiobook: true),
                preference: .preferAudiobook,
            ) == .audioSquare
        )
    }

    @Test func preferAudiobookFallsBackToStandardWithoutAudiobook() {
        #expect(
            MediaCoverVariantSelection.coverVariant(
                for: coverBook(ebook: true, audiobook: false),
                preference: .preferAudiobook,
            ) == .standard
        )
        #expect(
            MediaCoverVariantSelection.coverVariant(
                for: coverBook(ebook: false, audiobook: false),
                preference: .preferAudiobook,
            ) == .standard
        )
    }

    // MARK: - MediaViewModel still delegates (public API unchanged)

    @MainActor
    @Test func mediaViewModelDelegatesToSelectionHelper() {
        let viewModel = MediaViewModel(
            injectLibrary: BookLibrary(
                bookMetaData: [],
                ebookCoverCache: [:],
                audiobookCoverCache: [:],
            )
        )
        let both = coverBook(ebook: true, audiobook: true)
        let audioOnly = coverBook(ebook: false, audiobook: true)

        #expect(viewModel.coverVariant(for: both) == .standard)
        #expect(viewModel.coverVariant(for: audioOnly) == .audioSquare)
        #expect(viewModel.coverVariant(for: both, preference: .preferAudiobook) == .audioSquare)
        #expect(viewModel.coverVariant(for: both, preference: .storytellerDouble) == .standard)
    }

    // MARK: - CoverVariant display constants (unchanged)

    @Test func coverVariantRequestParametersUnchanged() {
        let standard = MediaViewModel.CoverVariant.standard.requestParameters
        #expect(standard.audio == false)
        #expect(standard.width == 209)
        #expect(standard.height == 320)

        let audio = MediaViewModel.CoverVariant.audioSquare.requestParameters
        #expect(audio.audio == true)
        #expect(audio.width == 209)
        #expect(audio.height == 209)
    }

    @Test func coverVariantPreferredAspectRatiosUnchanged() {
        #expect(MediaViewModel.CoverVariant.standard.preferredAspectRatio == 2.0 / 3.0)
        #expect(MediaViewModel.CoverVariant.audioSquare.preferredAspectRatio == 1.0)
    }

    private func coverBook(ebook: Bool, audiobook: Bool) -> BookMetadata {
        let uuid = "cccccccc-dddd-eeee-ffff-000000000001"
        return BookMetadata(
            bookID: BookID(sourceID: "server", uuid: uuid),
            title: "Cover Fixture",
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
                    uuid: uuid,
                    filepath: "\(uuid).epub",
                    missing: 0,
                    createdAt: nil,
                    updatedAt: nil
                ) : nil,
            audiobook: audiobook
                ? BookAsset(
                    uuid: uuid,
                    filepath: "\(uuid).m4b",
                    missing: 0,
                    createdAt: nil,
                    updatedAt: nil
                ) : nil,
            readaloud: nil,
            status: nil,
            position: nil,
            rating: nil,
        )
    }
}
