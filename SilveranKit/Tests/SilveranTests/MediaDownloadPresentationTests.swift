import Foundation
import Testing

@testable import SilveranAppleKit
@testable import SilveranKit

@Suite("Media download presentation")
struct MediaDownloadPresentationTests {

    // MARK: - Progress fraction

    @Test func progressFractionNilWhenExpectedMissingOrZero() {
        #expect(MediaDownloadPresentation.progressFraction(received: 10, expected: nil) == nil)
        #expect(MediaDownloadPresentation.progressFraction(received: 10, expected: 0) == nil)
        #expect(MediaDownloadPresentation.progressFraction(received: 10, expected: -1) == nil)
    }

    @Test func progressFractionClampsToUnitInterval() {
        #expect(MediaDownloadPresentation.progressFraction(received: 50, expected: 100) == 0.5)
        #expect(MediaDownloadPresentation.progressFraction(received: -10, expected: 100) == 0)
        #expect(MediaDownloadPresentation.progressFraction(received: 150, expected: 100) == 1)
    }

    // MARK: - Category / aggregate activity

    @Test func categoryActiveIgnoresFailedFlag() {
        // Quirk: paused maps to isFailed+!isFinished; isActive still true.
        #expect(MediaDownloadPresentation.isCategoryActive(isFinished: false, wasSkipped: false))
        #expect(!MediaDownloadPresentation.isCategoryActive(isFinished: true, wasSkipped: false))
        #expect(!MediaDownloadPresentation.isCategoryActive(isFinished: false, wasSkipped: true))
        #expect(!MediaDownloadPresentation.isCategoryActive(isFinished: true, wasSkipped: true))
    }

    @Test func downloadCompletedRequiresNonEmptyAllTerminal() {
        var empty = MediaViewModel.DownloadProgressState()
        #expect(!MediaDownloadPresentation.isDownloadCompleted(categories: empty.categories.values))

        var state = MediaViewModel.DownloadProgressState()
        state.categories[.ebook] = finishedCategory()
        state.categories[.audio] = skippedCategory()
        #expect(MediaDownloadPresentation.isDownloadCompleted(categories: state.categories.values))

        state.categories[.synced] = activeCategory()
        #expect(!MediaDownloadPresentation.isDownloadCompleted(categories: state.categories.values))
    }

    @Test func aggregateProgressSumsOnlyWhenAllExpectedKnown() {
        var state = MediaViewModel.DownloadProgressState()
        state.categories[.ebook] = category(received: 25, expected: 50)
        state.categories[.audio] = category(received: 25, expected: 50)
        #expect(MediaDownloadPresentation.totalReceived(categories: state.categories.values) == 50)
        #expect(MediaDownloadPresentation.totalExpected(categories: state.categories.values) == 100)
        #expect(MediaDownloadPresentation.progressFraction(categories: state.categories.values) == 0.5)

        state.categories[.synced] = category(received: 10, expected: nil)
        #expect(MediaDownloadPresentation.totalExpected(categories: state.categories.values) == nil)
        #expect(MediaDownloadPresentation.progressFraction(categories: state.categories.values) == nil)
    }

    @Test func downloadProgressStateComputedPropertiesDelegate() {
        var state = MediaViewModel.DownloadProgressState()
        state.categories[.ebook] = category(received: 10, expected: 20)
        #expect(state.progressFraction == 0.5)
        #expect(state.isActive)
        #expect(!state.isCompleted)

        state.categories[.ebook]?.isFinished = true
        #expect(!state.isActive)
        #expect(state.isCompleted)
    }

    // MARK: - Paths + preferred category

    @Test func hasLocalPathAndLocalPathUseMediaPaths() {
        let paths = MediaPaths(
            ebookPath: URL(fileURLWithPath: "/tmp/a.epub"),
            audioPath: nil,
            syncedPath: URL(fileURLWithPath: "/tmp/a.readaloud"),
        )
        #expect(MediaDownloadPresentation.hasLocalPath(paths, category: .ebook))
        #expect(!MediaDownloadPresentation.hasLocalPath(paths, category: .audio))
        #expect(MediaDownloadPresentation.hasLocalPath(paths, category: .synced))
        #expect(MediaDownloadPresentation.localPath(from: paths, category: .ebook)?.path == "/tmp/a.epub")
        #expect(MediaDownloadPresentation.localPath(from: nil, category: .ebook) == nil)
        #expect(!MediaDownloadPresentation.hasLocalPath(nil, category: .ebook))
    }

    @Test func preferredDownloadedCategorySyncedWins() {
        #expect(
            MediaDownloadPresentation.preferredDownloadedCategory(
                hasSynced: true,
                hasAudio: true,
                hasEbook: true,
                preferAudioOverEbook: false,
            ) == .synced
        )
    }

    @Test func preferredDownloadedCategoryHonorsAudioEbookPreference() {
        #expect(
            MediaDownloadPresentation.preferredDownloadedCategory(
                hasSynced: false,
                hasAudio: true,
                hasEbook: true,
                preferAudioOverEbook: true,
            ) == .audio
        )
        #expect(
            MediaDownloadPresentation.preferredDownloadedCategory(
                hasSynced: false,
                hasAudio: true,
                hasEbook: true,
                preferAudioOverEbook: false,
            ) == .ebook
        )
        #expect(
            MediaDownloadPresentation.preferredDownloadedCategory(
                hasSynced: false,
                hasAudio: true,
                hasEbook: false,
                preferAudioOverEbook: false,
            ) == .audio
        )
        #expect(
            MediaDownloadPresentation.preferredDownloadedCategory(
                hasSynced: false,
                hasAudio: false,
                hasEbook: true,
                preferAudioOverEbook: true,
            ) == .ebook
        )
        #expect(
            MediaDownloadPresentation.preferredDownloadedCategory(
                hasSynced: false,
                hasAudio: false,
                hasEbook: false,
                preferAudioOverEbook: true,
            ) == nil
        )
    }

    @MainActor
    @Test func mediaViewModelPreferredDownloadedCategoryDelegates() {
        let viewModel = MediaViewModel(
            injectLibrary: BookLibrary(
                bookMetaData: [],
                ebookCoverCache: [:],
                audiobookCoverCache: [:],
            )
        )
        // No path cache → nil preferred (ownership of maps stays on MVM).
        let book = BookMetadata(
            bookID: BookID(sourceID: "server", uuid: "dddddddd-eeee-ffff-aaaa-bbbbbbbbbbbb"),
            title: "DL",
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
            ebook: nil,
            audiobook: nil,
            readaloud: nil,
            status: nil,
            position: nil,
            rating: nil,
        )
        #expect(viewModel.preferredDownloadedCategory(for: book) == nil)
        #expect(!viewModel.isCategoryDownloaded(.ebook, for: book))
    }

    // MARK: - Fixtures

    private func category(received: Int64, expected: Int64?) -> MediaViewModel.DownloadProgressState.CategoryState {
        var state = MediaViewModel.DownloadProgressState.CategoryState()
        state.latestReceived = received
        state.expected = expected
        return state
    }

    private func finishedCategory() -> MediaViewModel.DownloadProgressState.CategoryState {
        var state = category(received: 1, expected: 1)
        state.isFinished = true
        return state
    }

    private func skippedCategory() -> MediaViewModel.DownloadProgressState.CategoryState {
        var state = category(received: 0, expected: 1)
        state.wasSkipped = true
        return state
    }

    private func activeCategory() -> MediaViewModel.DownloadProgressState.CategoryState {
        category(received: 1, expected: 10)
    }
}
