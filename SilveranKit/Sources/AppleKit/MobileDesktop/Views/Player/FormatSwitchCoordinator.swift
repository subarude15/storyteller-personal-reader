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
        let sourceProbe = await probeSourceTimeline(
            book: sourceBook,
            category: sourceCategory,
        )

        // When entering audiobook, peek destination duration for SMIL→audio gate.
        var destinationAudiobookDuration: TimeInterval? = probe.audiobookDuration
        if destinationCategory == .audio, destinationAudiobookDuration == nil {
            if let audioMedia = await BookServiceActor.shared.resolveLocalMedia(
                for: destinationBook.id,
                category: .audio,
            ),
                let meta = try? await AudiobookActor.shared.peekAudiobookMetadata(
                    url: audioMedia.url
                )
            {
                destinationAudiobookDuration = meta.totalDuration
            }
        }

        // When leaving audiobook toward reader, ensure destination SMIL is probed even for ebook.
        var destStructure = probe.bookStructure
        var destSmilTotal = probe.smilTotalDuration
        var destHasSMIL = probe.hasVerifiedMediaOverlay
        if (destinationCategory == .ebook || destinationCategory == .synced),
            !destHasSMIL,
            sourceCategory == .audio,
            let syncedMedia = await BookServiceActor.shared.resolveLocalMedia(
                for: destinationBook.id,
                category: .synced,
            ),
            let parsed = try? SMILParser.parseEPUB(at: syncedMedia.url)
        {
            // Use synced SMIL as alignment bridge into ebook when available.
            destStructure = parsed.sections
            destSmilTotal = StoryPositionChapter.smilTotalDuration(in: parsed.sections)
            destHasSMIL = destSmilTotal > 0
        }

        let translation = StoryPositionTranslator.translate(
            StoryPositionTranslationInput(
                sourceBookID: sourceBook.id,
                destinationBookID: destinationBook.id,
                sourceCategory: sourceCategory,
                destinationCategory: destinationCategory,
                sourceLocator: captured.locator,
                sourceProgression: captured.progression,
                sourceTimestamp: captured.timestamp,
                sourceElapsedSeconds: captured.elapsedSeconds,
                sourceAudiobookDuration: captured.audiobookDuration ?? sourceProbe.audiobookDuration,
                destinationAudiobookDuration: destinationAudiobookDuration,
                destinationChapters: probe.chapters,
                destinationChaptersTimingVerified: probe.chaptersTimingVerified,
                destinationBookStructure: destStructure,
                destinationSmilTotalDuration: destSmilTotal,
                sourceBookStructure: sourceProbe.bookStructure,
                sourceSmilTotalDuration: sourceProbe.smilTotalDuration,
                destinationSavedProgression: destRestore?.progression,
                destinationSavedTimestamp: destRestore?.timestamp,
                destinationSavedLocator: destRestore?.locator,
                hasVerifiedMediaOverlay: destHasSMIL || probe.hasVerifiedMediaOverlay,
            )
        )

        debugLog(
            "[FormatSwitch] plan method=\(translation.mappingMethod) precision=\(translation.precision.rawValue) srcAudioDur=\(captured.audiobookDuration?.description ?? "nil") destSmil=\(destSmilTotal?.description ?? "nil") timingVerified=\(probe.chaptersTimingVerified)"
        )

        return FormatSwitchPlan(
            sourceBook: sourceBook,
            sourceCategory: sourceCategory,
            destinationBook: destinationBook,
            destinationCategory: destinationCategory,
            translation: translation,
            verifiedMediaOverlay: destHasSMIL || probe.hasVerifiedMediaOverlay,
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
            "[FormatSwitch] \(sourceCategory.rawValue)→\(destinationCategory.rawValue) method=\(plan.translation.mappingMethod) precision=\(plan.translation.precision.rawValue) prog=\(plan.translation.progression) chapters=\(plan.destinationChapterCount) verifiedMO=\(plan.verifiedMediaOverlay) discrepancy=\(plan.needsDiscrepancyChoice)"
        )

        if let alternate = plan.translation.conflictingDestinationSaved {
            let approxNote = FormatSwitchLabels.precisionLabel(for: plan.translation.precision)
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
                    mappingQualityLabel: approxNote,
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
        var chaptersTimingVerified: Bool
        var hasVerifiedMediaOverlay: Bool
        var bookStructure: [SectionInfo]
        var smilTotalDuration: TimeInterval?
        var audiobookDuration: TimeInterval?

        static let empty = DestinationProbe(
            chapters: [],
            chaptersTimingVerified: false,
            hasVerifiedMediaOverlay: false,
            bookStructure: [],
            smilTotalDuration: nil,
            audiobookDuration: nil,
        )
    }

    private struct SourceTimelineProbe: Sendable {
        var bookStructure: [SectionInfo]
        var smilTotalDuration: TimeInterval?
        var audiobookDuration: TimeInterval?
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
                        chaptersTimingVerified: meta.totalDuration > 0,
                        hasVerifiedMediaOverlay: false,
                        bookStructure: [],
                        smilTotalDuration: nil,
                        audiobookDuration: meta.totalDuration,
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
                        chaptersTimingVerified: live.duration > 0,
                        hasVerifiedMediaOverlay: false,
                        bookStructure: [],
                        smilTotalDuration: nil,
                        audiobookDuration: live.duration,
                    )
                }
                return .empty

            case .ebook, .synced:
                // Prefer live reading session structure (already parsed).
                if let session = ReadingSessionStore.shared.activeSession(for: book.id),
                    !session.bookStructure.isEmpty
                {
                    return readerProbe(from: session.bookStructure)
                }
                if let parsed = try? SMILParser.parseEPUB(at: localURL) {
                    return readerProbe(from: parsed.sections)
                }
                // ALIGNED status alone is not verified local media-overlay.
                return .empty
        }
    }

    private static func readerProbe(from sections: [SectionInfo]) -> DestinationProbe {
        let hasSMIL = sections.contains { !$0.mediaOverlay.isEmpty }
        let smilTotal = StoryPositionChapter.smilTotalDuration(in: sections)
        let (chapters, timingVerified) = StoryPositionChapter.fromSectionsPreferringSmilTiming(
            sections
        )
        return DestinationProbe(
            chapters: chapters,
            chaptersTimingVerified: timingVerified,
            hasVerifiedMediaOverlay: hasSMIL && smilTotal > 0,
            bookStructure: sections,
            smilTotalDuration: smilTotal > 0 ? smilTotal : nil,
            audiobookDuration: nil,
        )
    }

    /// Source-side timeline metadata for audiobook↔SMIL gates (does not mutate sessions).
    private static func probeSourceTimeline(
        book: BookMetadata,
        category: LocalMediaCategory,
    ) async -> SourceTimelineProbe {
        switch category {
            case .audio:
                if let live = await AudioSessionActor.shared.currentAudiobookSessionState(),
                    live.bookID == book.uuid, live.duration > 0
                {
                    return SourceTimelineProbe(
                        bookStructure: [],
                        smilTotalDuration: nil,
                        audiobookDuration: live.duration,
                    )
                }
                if let media = await BookServiceActor.shared.resolveLocalMedia(
                    for: book.id,
                    category: .audio,
                ),
                    let meta = try? await AudiobookActor.shared.peekAudiobookMetadata(url: media.url)
                {
                    return SourceTimelineProbe(
                        bookStructure: [],
                        smilTotalDuration: nil,
                        audiobookDuration: meta.totalDuration,
                    )
                }
                return SourceTimelineProbe(
                    bookStructure: [],
                    smilTotalDuration: nil,
                    audiobookDuration: nil,
                )

            case .synced, .ebook:
                if let session = ReadingSessionStore.shared.activeSession(for: book.id),
                    !session.bookStructure.isEmpty
                {
                    let total = StoryPositionChapter.smilTotalDuration(in: session.bookStructure)
                    return SourceTimelineProbe(
                        bookStructure: session.bookStructure,
                        smilTotalDuration: total > 0 ? total : nil,
                        audiobookDuration: nil,
                    )
                }
                if let media = await BookServiceActor.shared.resolveLocalMedia(
                    for: book.id,
                    category: category == .ebook ? .synced : category,
                ),
                    let parsed = try? SMILParser.parseEPUB(at: media.url)
                {
                    let total = StoryPositionChapter.smilTotalDuration(in: parsed.sections)
                    return SourceTimelineProbe(
                        bookStructure: parsed.sections,
                        smilTotalDuration: total > 0 ? total : nil,
                        audiobookDuration: nil,
                    )
                }
                if category == .ebook,
                    let media = await BookServiceActor.shared.resolveLocalMedia(
                        for: book.id,
                        category: .ebook,
                    ),
                    let parsed = try? SMILParser.parseEPUB(at: media.url)
                {
                    let total = StoryPositionChapter.smilTotalDuration(in: parsed.sections)
                    return SourceTimelineProbe(
                        bookStructure: parsed.sections,
                        smilTotalDuration: total > 0 ? total : nil,
                        audiobookDuration: nil,
                    )
                }
                return SourceTimelineProbe(
                    bookStructure: [],
                    smilTotalDuration: nil,
                    audiobookDuration: nil,
                )
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
        timestamp: Double?,
        elapsedSeconds: TimeInterval?,
        audiobookDuration: TimeInterval?
    ) {
        let now = floor(Date().timeIntervalSince1970 * 1000)

        // Live audiobook: full locator with chapter href + in-chapter progression.
        if category == .audio,
            let state = await AudioSessionActor.shared.currentAudiobookSessionState(),
            state.bookID == bookID.uuid
        {
            let elapsed = state.currentTime
            let duration = state.duration > 0 ? state.duration : nil
            if let locator = await AudioSessionActor.shared.currentAudiobookLocator() {
                return (state.bookProgress, locator, now, elapsed, duration)
            }
            let locator = StoryPositionTranslator.locatorForDestination(
                category: .audio,
                progression: state.bookProgress,
                chapterTitle: state.currentChapterIndex.flatMap { state.chapters[safe: $0]?.title },
                chapterHref: state.currentChapterID,
                chapterProgression: state.chapterProgress,
            )
            return (state.bookProgress, locator, now, elapsed, duration)
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
            return (prog, locator, now, smil.bookElapsed, smil.bookTotal > 0 ? smil.bookTotal : nil)
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
            return (fraction, locator, now, nil, nil)
        }

        if let progress = await ProgressSyncActor.shared.getBookProgress(for: bookID) {
            return (progress.progressFraction, progress.locator, progress.timestamp ?? now, nil, nil)
        }

        let restore = await ProgressSyncActor.shared.bestRestorePosition(
            for: bookID,
            bookMetadataPosition: nil,
        )
        return (
            restore?.progression ?? 0,
            restore?.locator,
            restore?.timestamp ?? now,
            nil,
            nil
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
