#if os(iOS)
import Foundation
import SilveranKit
import SwiftUI

/// Planned format switch after capture + translation (before session teardown).
public struct FormatSwitchPlan: Sendable, Equatable {
    public let sourceBook: BookMetadata
    public let sourceCategory: LocalMediaCategory
    public let destinationBook: BookMetadata
    public let destinationCategory: LocalMediaCategory
    public let translation: StoryPositionTranslation
    public let verifiedMediaOverlay: Bool
    public let destinationChapterCount: Int

    public var needsDiscrepancyChoice: Bool {
        translation.conflictingDestinationSaved != nil
    }
}

/// Orchestrates in-player Ebook / Audiobook / Readaloud switches without a Home detour.
///
/// Reuses Storyteller progress + ProgressSyncActor (no second sync architecture).
/// Applies translated locators via `FormatSwitchHandoffStore` (local, one-shot).
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
                if result.contains(where: { $0.category == category }) { continue }
                result.append((member, category))
            }
        }
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

    /// Build translation plan (testable) without mutating sessions.
    public static func planSwitch(
        from sourceBook: BookMetadata,
        sourceCategory: LocalMediaCategory,
        toDestinationBook destinationBook: BookMetadata,
        destinationCategory: LocalMediaCategory,
        mediaViewModel: MediaViewModel,
    ) async -> FormatSwitchPlan? {
        guard
            let media = await BookServiceActor.shared.resolveLocalMedia(
                for: destinationBook.id,
                category: destinationCategory,
            )
        else { return nil }

        let captured = await captureSourcePosition(
            bookID: sourceBook.id,
            category: sourceCategory,
        )
        let destRestore = await ProgressSyncActor.shared.bestRestorePosition(
            for: destinationBook.id,
            bookMetadataPosition: destinationBook.position,
        )
        let probe = await probeDestination(
            book: destinationBook,
            category: destinationCategory,
            localURL: media.url,
        )

        let translation = StoryPositionTranslator.translate(
            StoryPositionTranslationInput(
                sourceBookID: sourceBook.id,
                destinationBookID: destinationBook.id,
                sourceCategory: sourceCategory,
                destinationCategory: destinationCategory,
                sourceLocator: captured.locator,
                sourceProgression: captured.progression,
                sourceTimestamp: captured.timestamp,
                destinationChapters: probe.chapters,
                destinationSavedProgression: destRestore?.progression,
                destinationSavedTimestamp: destRestore?.timestamp,
                destinationSavedLocator: destRestore?.locator,
                hasVerifiedMediaOverlay: probe.hasVerifiedMediaOverlay,
            )
        )

        return FormatSwitchPlan(
            sourceBook: sourceBook,
            sourceCategory: sourceCategory,
            destinationBook: destinationBook,
            destinationCategory: destinationCategory,
            translation: translation,
            verifiedMediaOverlay: probe.hasVerifiedMediaOverlay,
            destinationChapterCount: probe.chapters.count,
        )
    }

    /// Capture → translate → (optional discrepancy choice) → stop prior playback →
    /// handoff locator → present destination.
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
            let plan = await planSwitch(
                from: sourceBook,
                sourceCategory: sourceCategory,
                toDestinationBook: destinationBook,
                destinationCategory: destinationCategory,
                mediaViewModel: mediaViewModel,
            )
        else {
            NotificationCenter.default.post(name: .punkRallyOpenPlayerFailed, object: nil)
            return
        }

        debugLog(
            "[FormatSwitch] \(sourceCategory.rawValue)→\(destinationCategory.rawValue) precision=\(plan.translation.precision.rawValue) prog=\(plan.translation.progression) chapters=\(plan.destinationChapterCount) verifiedMO=\(plan.verifiedMediaOverlay) discrepancy=\(plan.needsDiscrepancyChoice)"
        )

        if let alternate = plan.translation.conflictingDestinationSaved {
            FormatSwitchPromptState.shared.presentDiscrepancy(
                prompt: .init(
                    bookTitle: destinationBook.title,
                    destinationLabel: FormatSwitchLabels.title(for: destinationCategory),
                    mappedPercentLabel: FormatSwitchLabels.progressPercentLabel(
                        plan.translation.progression
                    ),
                    destinationPercentLabel: FormatSwitchLabels.progressPercentLabel(
                        alternate.progression
                    ),
                ),
                onChooseMapped: {
                    await completeSwitch(
                        plan: plan,
                        chosen: plan.translation,
                        mediaViewModel: mediaViewModel,
                    )
                },
                onChooseDestination: {
                    await completeSwitch(
                        plan: plan,
                        chosen: alternate.asTranslation,
                        mediaViewModel: mediaViewModel,
                    )
                },
            )
            return
        }

        await completeSwitch(
            plan: plan,
            chosen: plan.translation,
            mediaViewModel: mediaViewModel,
        )
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

    // MARK: - Complete / apply

    private static func completeSwitch(
        plan: FormatSwitchPlan,
        chosen: StoryPositionTranslation,
        mediaViewModel: MediaViewModel,
    ) async {
        await endSourcePlayback(
            bookID: plan.sourceBook.id,
            category: plan.sourceCategory,
        )

        // Destination reader must open fresh — a leftover readaloud session for the
        // same BookID would join and skip / override the format-switch locator.
        if plan.destinationCategory == .ebook || plan.destinationCategory == .synced {
            if let existing = ReadingSessionStore.shared.activeSession(
                for: plan.destinationBook.id
            ) {
                debugLog(
                    "[FormatSwitch] Ending leftover \(existing.category.rawValue) session before opening \(plan.destinationCategory.rawValue)"
                )
                await existing.close(.endSession)
            }
        }

        if chosen.shouldApplyHandoff, let locator = chosen.locator {
            // Ensure ebook/readaloud handoffs always carry totalProgression so EPM can
            // resolve a spine position even when href is a placeholder ("ebook").
            let handoffLocator: BookLocator = {
                if plan.destinationCategory == .audio { return locator }
                if locator.locations?.totalProgression != nil,
                    !StoryPositionTranslator.isAudioLocator(locator)
                {
                    return locator
                }
                return StoryPositionTranslator.locatorForDestination(
                    category: plan.destinationCategory,
                    progression: chosen.progression,
                    chapterTitle: locator.title,
                    chapterHref: StoryPositionTranslator.isPlaceholderReaderHref(locator.href)
                        ? nil
                        : locator.href,
                    sourceLocator: StoryPositionTranslator.isAudioLocator(locator) ? nil : locator,
                    chapterProgression: locator.locations?.progression,
                )
            }()

            debugLog(
                "[FormatSwitch] Handoff set dest=\(plan.destinationBook.id) category=\(plan.destinationCategory.rawValue) prog=\(chosen.progression) precision=\(chosen.precision.rawValue) href=\(handoffLocator.href) total=\(handoffLocator.locations?.totalProgression?.description ?? "nil")"
            )

            await FormatSwitchHandoffStore.shared.set(
                FormatSwitchHandoff(
                    bookID: plan.destinationBook.id,
                    category: plan.destinationCategory,
                    locator: handoffLocator,
                    progression: chosen.progression,
                    precision: chosen.precision,
                )
            )
        }

        let bookData = mediaViewModel.makePlayerBookData(
            for: plan.destinationBook,
            category: plan.destinationCategory,
        )
        PlayerPresenter.shared.present(bookData)
    }

    // MARK: - Probe / capture

    private struct DestinationProbe: Sendable {
        var chapters: [StoryPositionChapter]
        var hasVerifiedMediaOverlay: Bool
    }

    private static func probeDestination(
        book: BookMetadata,
        category: LocalMediaCategory,
        localURL: URL,
    ) async -> DestinationProbe {
        switch category {
            case .audio:
                if let meta = try? await AudiobookActor.shared.peekAudiobookMetadata(url: localURL) {
                    return DestinationProbe(
                        chapters: StoryPositionChapter.fromAudiobookChapters(
                            meta.chapters,
                            totalDuration: meta.totalDuration,
                        ),
                        hasVerifiedMediaOverlay: false,
                    )
                }
                if let live = await AudioSessionActor.shared.currentAudiobookSessionState(),
                    live.bookID == book.uuid
                {
                    return DestinationProbe(
                        chapters: StoryPositionChapter.fromSessionChapters(
                            live.chapters,
                            totalDuration: live.duration,
                        ),
                        hasVerifiedMediaOverlay: false,
                    )
                }
                return DestinationProbe(chapters: [], hasVerifiedMediaOverlay: false)

            case .ebook, .synced:
                // Prefer live reading session structure (already parsed).
                if let session = ReadingSessionStore.shared.activeSession(for: book.id),
                    !session.bookStructure.isEmpty
                {
                    let hasSMIL = session.bookStructure.contains { !$0.mediaOverlay.isEmpty }
                    return DestinationProbe(
                        chapters: StoryPositionChapter.fromLabeledSections(session.bookStructure),
                        hasVerifiedMediaOverlay: hasSMIL,
                    )
                }
                if let parsed = try? SMILParser.parseEPUB(at: localURL) {
                    let hasSMIL = parsed.sections.contains { !$0.mediaOverlay.isEmpty }
                    return DestinationProbe(
                        chapters: StoryPositionChapter.fromLabeledSections(parsed.sections),
                        hasVerifiedMediaOverlay: hasSMIL,
                    )
                }
                // ALIGNED status alone is not verified local media-overlay.
                return DestinationProbe(chapters: [], hasVerifiedMediaOverlay: false)
        }
    }

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

    private static func captureSourcePosition(
        bookID: BookID,
        category: LocalMediaCategory,
    ) async -> (
        progression: Double,
        locator: BookLocator?,
        timestamp: Double?
    ) {
        let now = floor(Date().timeIntervalSince1970 * 1000)

        // Live audiobook: full locator with chapter href + in-chapter progression.
        if category == .audio,
            let state = await AudioSessionActor.shared.currentAudiobookSessionState(),
            state.bookID == bookID.uuid
        {
            if let locator = await AudioSessionActor.shared.currentAudiobookLocator() {
                return (state.bookProgress, locator, now)
            }
            let locator = StoryPositionTranslator.locatorForDestination(
                category: .audio,
                progression: state.bookProgress,
                chapterTitle: state.currentChapterIndex.flatMap { state.chapters[safe: $0]?.title },
                chapterHref: state.currentChapterID,
                chapterProgression: state.chapterProgress,
            )
            return (state.bookProgress, locator, now)
        }

        // Live readaloud / SMIL: prefer fragment-bearing locator.
        if category == .synced,
            let smil = await SMILPlayerActor.shared.getCurrentState(),
            smil.bookID == bookID
        {
            let prog =
                smil.bookTotal > 0 ? min(max(smil.bookElapsed / smil.bookTotal, 0), 1) : 0
            let fragment = smil.currentFragment
            let href: String
            let textId: String?
            if let hash = fragment.firstIndex(of: "#") {
                href = String(fragment[..<hash])
                textId = String(fragment[fragment.index(after: hash)...])
            } else if !fragment.isEmpty {
                href = fragment
                textId = nil
            } else {
                href = "ebook"
                textId = nil
            }
            let locator = BookLocator(
                href: href.isEmpty ? "ebook" : href,
                type: "application/xhtml+xml",
                title: smil.chapterLabel,
                locations: BookLocator.Locations(
                    fragments: textId.map { [$0] },
                    progression: nil,
                    position: nil,
                    totalProgression: prog,
                    cssSelector: nil,
                    partialCfi: nil,
                    domRange: nil,
                ),
                text: nil,
            )
            return (prog, locator, now)
        }

        // Live ebook / readaloud session managers.
        if let session = ReadingSessionStore.shared.activeSession(for: bookID),
            let fraction = session.progressManager?.bookFraction
        {
            let locator: BookLocator?
            if let mom = session.mediaOverlayManager,
                mom.hasMediaOverlay,
                let fragment = mom.currentFragment
            {
                let href: String
                let textId: String?
                if let hash = fragment.firstIndex(of: "#") {
                    href = String(fragment[..<hash])
                    textId = String(fragment[fragment.index(after: hash)...])
                } else {
                    href = fragment
                    textId = nil
                }
                locator = BookLocator(
                    href: href,
                    type: "application/xhtml+xml",
                    title: nil,
                    locations: BookLocator.Locations(
                        fragments: textId.map { [$0] },
                        progression: nil,
                        position: nil,
                        totalProgression: fraction,
                        cssSelector: nil,
                        partialCfi: nil,
                        domRange: nil,
                    ),
                    text: nil,
                )
            } else {
                locator = StoryPositionTranslator.locatorForDestination(
                    category: category == .audio ? .ebook : category,
                    progression: fraction,
                )
            }
            return (fraction, locator, now)
        }

        if let progress = await ProgressSyncActor.shared.getBookProgress(for: bookID) {
            return (progress.progressFraction, progress.locator, progress.timestamp ?? now)
        }

        let restore = await ProgressSyncActor.shared.bestRestorePosition(
            for: bookID,
            bookMetadataPosition: nil,
        )
        return (
            restore?.progression ?? 0,
            restore?.locator,
            restore?.timestamp ?? now
        )
    }

    private static func endSourcePlayback(
        bookID: BookID,
        category: LocalMediaCategory,
    ) async {
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
