#if os(iOS)
import Foundation
import SilveranKit
import SwiftUI

/// Orchestrates in-player Ebook / Audiobook / Readaloud switches without a Home detour.
///
/// Reuses Storyteller progress + ProgressSyncActor (no second sync architecture).
/// Widget launch paths are intentionally untouched — callers are player chrome only.
@MainActor
public enum FormatSwitchCoordinator {
    /// Downloaded formats on this book (and linked format-group members when present).
    public static func availableFormats(
        for book: BookMetadata,
        mediaViewModel: MediaViewModel,
    ) -> [(book: BookMetadata, category: LocalMediaCategory)] {
        let members = BookFormatGrouping.members(
            of: book.id,
            in: mediaViewModel.library.bookMetaData,
            links: mediaViewModel.formatLinks,
        )
        let books = members.isEmpty ? [book] : members
        var result: [(book: BookMetadata, category: LocalMediaCategory)] = []
        for member in books {
            for category in downloadedCategories(for: member, mediaViewModel: mediaViewModel) {
                // Prefer the primary/current book when multiple members expose the same category.
                if result.contains(where: { $0.category == category }) { continue }
                result.append((member, category))
            }
        }
        // Stable UX order: Readaloud, Audiobook, Ebook (matches Home medium picker).
        let order: [LocalMediaCategory] = [.synced, .audio, .ebook]
        return result.sorted {
            (order.firstIndex(of: $0.category) ?? 99) < (order.firstIndex(of: $1.category) ?? 99)
        }
    }

    public static func canSwitchFormat(
        from book: BookMetadata,
        current: LocalMediaCategory,
        mediaViewModel: MediaViewModel,
    ) -> Bool {
        availableFormats(for: book, mediaViewModel: mediaViewModel)
            .contains { $0.category != current }
    }

    /// Capture → translate → stop prior playback → seed when needed → present destination.
    public static func switchFormat(
        from sourceBook: BookMetadata,
        sourceCategory: LocalMediaCategory,
        toDestinationBook destinationBook: BookMetadata,
        destinationCategory: LocalMediaCategory,
        mediaViewModel: MediaViewModel,
    ) async {
        guard sourceCategory != destinationCategory
            || sourceBook.id != destinationBook.id
        else { return }

        guard
            await BookServiceActor.shared.resolveLocalMedia(
                for: destinationBook.id,
                category: destinationCategory,
            ) != nil
        else {
            NotificationCenter.default.post(name: .punkRallyOpenPlayerFailed, object: nil)
            return
        }

        let captured = await captureSourcePosition(bookID: sourceBook.id)
        let destRestore = await ProgressSyncActor.shared.bestRestorePosition(
            for: destinationBook.id,
            bookMetadataPosition: destinationBook.position,
        )
        let hasOverlay =
            destinationCategory == .synced
            || sourceCategory == .synced
            || destinationBook.hasAvailableReadaloud
            || sourceBook.hasAvailableReadaloud

        let translation = StoryPositionTranslator.translate(
            StoryPositionTranslationInput(
                sourceBookID: sourceBook.id,
                destinationBookID: destinationBook.id,
                sourceCategory: sourceCategory,
                destinationCategory: destinationCategory,
                sourceLocator: captured.locator,
                sourceProgression: captured.progression,
                sourceTimestamp: captured.timestamp,
                destinationChapters: [],
                destinationSavedProgression: destRestore?.progression,
                destinationSavedTimestamp: destRestore?.timestamp,
                destinationSavedLocator: destRestore?.locator,
                hasMediaOverlayAlignment: hasOverlay,
            )
        )

        debugLog(
            "[FormatSwitch] \(sourceCategory.rawValue)→\(destinationCategory.rawValue) precision=\(translation.precision.rawValue) prog=\(translation.progression) seed=\(translation.shouldSeedDestination)"
        )

        await endSourcePlayback(
            bookID: sourceBook.id,
            category: sourceCategory,
        )

        // Same-book: endSourcePlayback already flushed into PSA — no extra Storyteller write.
        // Cross-book (format links): seed the destination so restore lands on the intentional place.
        if translation.shouldSeedDestination, let locator = translation.locator {
            _ = await ProgressSyncActor.shared.syncProgress(
                bookID: destinationBook.id,
                locator: locator,
                timestamp: floor(Date().timeIntervalSince1970 * 1000),
                reason: .userSwitchedFormat,
                sourceIdentifier: "Format Switch",
                locationDescription: "Switched from \(FormatSwitchLabels.title(for: sourceCategory))",
                playheadInitialized: true,
                isExplicitUserAction: true,
            )
        }

        let bookData = mediaViewModel.makePlayerBookData(
            for: destinationBook,
            category: destinationCategory,
        )
        PlayerPresenter.shared.present(bookData)
    }

    public static func switchFormat(
        from sourceBook: BookMetadata,
        sourceCategory: LocalMediaCategory,
        to destinationCategory: LocalMediaCategory,
        mediaViewModel: MediaViewModel,
    ) async {
        let options = availableFormats(for: sourceBook, mediaViewModel: mediaViewModel)
        guard let match = options.first(where: { $0.category == destinationCategory }) else {
            NotificationCenter.default.post(name: .punkRallyOpenPlayerFailed, object: nil)
            return
        }
        await switchFormat(
            from: sourceBook,
            sourceCategory: sourceCategory,
            toDestinationBook: match.book,
            destinationCategory: match.category,
            mediaViewModel: mediaViewModel,
        )
    }

    // MARK: - Private

    private static func downloadedCategories(
        for book: BookMetadata,
        mediaViewModel: MediaViewModel,
    ) -> [LocalMediaCategory] {
        var categories: [LocalMediaCategory] = []
        if book.hasAvailableReadaloud, mediaViewModel.isCategoryDownloaded(.synced, for: book) {
            categories.append(.synced)
        }
        if book.hasAvailableAudiobook, mediaViewModel.isCategoryDownloaded(.audio, for: book) {
            categories.append(.audio)
        }
        if book.hasAvailableEbook, mediaViewModel.isCategoryDownloaded(.ebook, for: book) {
            categories.append(.ebook)
        }
        return categories
    }

    private static func captureSourcePosition(bookID: BookID) async -> (
        progression: Double,
        locator: BookLocator?,
        timestamp: Double?
    ) {
        if let snapshot = await AudioSessionActor.shared.currentSnapshot(),
            snapshot.kind.bookID == bookID
        {
            let prog = snapshot.bookProgress
            let category: LocalMediaCategory =
                switch snapshot.kind {
                    case .readaloud: .synced
                    case .audiobook, .podcast: .audio
                }
            let locator = StoryPositionTranslator.locatorForDestination(
                category: category,
                progression: prog,
                chapterTitle: snapshot.chapterLabel,
            )
            return (prog, locator, floor(Date().timeIntervalSince1970 * 1000))
        }

        if let progress = await ProgressSyncActor.shared.getBookProgress(for: bookID) {
            let prog = progress.progressFraction
            return (prog, progress.locator, progress.timestamp)
        }

        let restore = await ProgressSyncActor.shared.bestRestorePosition(
            for: bookID,
            bookMetadataPosition: nil,
        )
        return (
            restore?.progression ?? 0,
            restore?.locator,
            restore?.timestamp
        )
    }

    private static func endSourcePlayback(
        bookID: BookID,
        category: LocalMediaCategory,
    ) async {
        // Stop audio first so we never leave two engines live across the card swap.
        if let kind = await AudioSessionActor.shared.currentSessionKind(),
            kind.bookID == bookID
        {
            try? await AudioSessionActor.shared.transport(.pause)
            switch kind {
                case .audiobook:
                    await AudioSessionActor.shared.flushLifecycleProgress(reason: .userSwitchedFormat)
                    await AudioSessionActor.shared.close(ifOwnedBy: bookID)
                case .readaloud:
                    await ReadingSessionStore.shared.activeSession(for: bookID)?
                        .close(.endSession)
                    await AudioSessionActor.shared.close(ifOwnedBy: bookID)
                case .podcast:
                    break
            }
        }

        switch category {
            case .ebook, .synced:
                if let session = ReadingSessionStore.shared.activeSession(for: bookID) {
                    await session.close(.endSession)
                }
            case .audio:
                await AudioSessionActor.shared.close(ifOwnedBy: bookID)
        }
    }
}

/// Compact confirmation dialog content for switching formats from player chrome.
public struct FormatSwitchMenuButtons: View {
    let current: LocalMediaCategory
    let options: [(book: BookMetadata, category: LocalMediaCategory)]
    let onSelect: (BookMetadata, LocalMediaCategory) -> Void

    public init(
        current: LocalMediaCategory,
        options: [(book: BookMetadata, category: LocalMediaCategory)],
        onSelect: @escaping (BookMetadata, LocalMediaCategory) -> Void,
    ) {
        self.current = current
        self.options = options
        self.onSelect = onSelect
    }

    public var body: some View {
        let others = options.filter { $0.category != current }
        ForEach(others, id: \.category) { option in
            Button {
                onSelect(option.book, option.category)
            } label: {
                Label(
                    FormatSwitchLabels.title(for: option.category),
                    systemImage: FormatSwitchLabels.systemImage(for: option.category),
                )
            }
        }
    }
}
#endif
