import Foundation
import Observation

/// EbookProgressManager - Tracks reading progress (non-audio)
///
/// Responsibilities:
/// - Track current position in book (chapter, page)
/// - Calculate fractional progress (chapter and book level)
/// - Sync progress to server (when implemented)
/// - Handle initial navigation to saved reading position
@SilveranUIActor
@Observable
public final class EphemeralProgressManager {

    public var chapterSeekBarValue: Double = 0.0
    public var bookFraction: Double? = nil
    public var chapterCurrentPage: Int? = nil
    public var chapterTotalPages: Int? = nil

    /// Current chapter index (source of truth, typically from JS progress events)
    /// Reflects JS reader reality but may need sync with Swift value (below).
    public var selectedChapterId: Int? = nil {
        didSet {
            guard selectedChapterId != oldValue else { return }
            debugLog(
                "[EPM] selectedChapterId changed: \(oldValue?.description ?? "nil") -> \(selectedChapterId?.description ?? "nil")"
            )
            uiSelectedChapterId = selectedChapterId
        }
    }

    /// UI-selected chapter index (what SwiftUI binds to)
    public var uiSelectedChapterId: Int? = nil {
        didSet {
            debugLog(
                "[EPM] uiSelectedChapterId changed: \(oldValue?.description ?? "nil") -> \(uiSelectedChapterId?.description ?? "nil")"
            )
            debugLog(
                "[EPM] selectedChapterId is currently: \(selectedChapterId?.description ?? "nil")"
            )
            if let newId = uiSelectedChapterId, newId != selectedChapterId {
                debugLog("[EPM] Triggering handleUserChapterSelected(\(newId))")
                handleUserChapterSelected(newId)
            } else {
                debugLog("[EPM] Skipping navigation - already at this chapter or newId is nil")
            }
        }
    }

    public var bookStructure: [SectionInfo] = []

    public weak var commsBridge: ReaderCommsBridge?
    public weak var mediaOverlayManager: MediaOverlayManager?
    private let settingsVM: any ReaderSettingsReading

    /// When true, user is browsing freely without syncing progress (lockViewToAudio == false)
    private var isFreeBrowseMode: Bool { !settingsVM.lockViewToAudio }
    private var isScrollingMode: Bool { settingsVM.scrollingMode }

    /// Initial reading position (typ. from server sync)
    private var initialLocator: BookLocator?

    /// Intentional format-switch target; wins over PSA / metadata for this open.
    private var formatSwitchHandoff: FormatSwitchHandoff?

    /// Track whether we've performed initial seek to server location.
    /// This happens when the book is first opened and has been
    /// read in a previous session.
    public var hasPerformedInitialSeek = false

    private enum UserNavDirection: String {
        case left
        case right
    }

    private struct PendingPageNav {
        var sectionIndex: Int
        var expectedPage: Int
        var totalPages: Int?
    }

    private struct PendingSeekNav {
        var sectionIndex: Int
    }

    private var pendingPageNav: PendingPageNav? = nil
    private var pendingSeekNav: PendingSeekNav? = nil
    private var pendingChapterTransition: Int? = nil
    private var pendingSwiftCommandFlipEchoes = 0
    private var userNavFallbackTask: Task<Void, Never>? = nil

    /// Timestamp of last user activity (navigation or audio playback)
    private var lastActivityTimestamp: TimeInterval? = nil

    /// Timestamp of last successful sync to server
    private var lastSyncedTimestamp: TimeInterval? = nil

    /// Pending user nav sync reason (set when nav queued, used when nav confirmed in handleRelocated)
    private var pendingUserNavSyncReason: SyncReason? = nil

    /// Task for periodic progress syncs to server
    private var syncTask: Task<Void, Never>? = nil
    private var bookID: BookID? = nil

    /// Debounced sync task - cancelled and recreated on each page flip to avoid sync spam
    private var debouncedSyncTask: Task<Void, Never>? = nil
    private let syncDebounceDelay: Duration = .seconds(1)

    /// Wake-from-sleep handling
    private var lastResumeTime: Date?
    private let resumeSuppressionDuration: TimeInterval = 30

    /// Book metadata for lockscreen display
    public var bookTitle: String? = nil
    public var bookAuthor: String? = nil
    public var bookCoverUrl: String? = nil

    public init(
        bridge: ReaderCommsBridge?,
        settingsVM: any ReaderSettingsReading,
        bookID: BookID? = nil,
        initialLocator: BookLocator? = nil,
        formatSwitchHandoff: FormatSwitchHandoff? = nil,
    ) {
        self.commsBridge = bridge
        self.settingsVM = settingsVM
        self.bookID = bookID
        self.formatSwitchHandoff = formatSwitchHandoff
        self.initialLocator = formatSwitchHandoff?.locator ?? initialLocator
        debugLog(
            "[EPM] EbookProgressManager initialized with bookID: \(bookID?.description ?? "none"), locator: \(self.initialLocator?.href ?? "none"), formatSwitch=\(formatSwitchHandoff?.precision.rawValue ?? "nil")"
        )

        installRelocateHandler(on: bridge)
    }

    /// Apply / refresh a pinned format-switch target (survives late claim after init).
    public func applyFormatSwitchHandoff(_ handoff: FormatSwitchHandoff) {
        formatSwitchHandoff = handoff
        initialLocator = handoff.locator
        debugLog(
            "[EPM] Applied format-switch handoff prog=\(handoff.progression) precision=\(handoff.precision.rawValue) href=\(handoff.locator.href)"
        )
    }

    /// Webview recovery: the fresh bridge needs the relocate handler reinstalled.
    public func rebindBridge(_ bridge: ReaderCommsBridge?) {
        commsBridge = bridge
        installRelocateHandler(on: bridge)
    }

    private func installRelocateHandler(on bridge: ReaderCommsBridge?) {
        bridge?.onRelocated = { [weak self] message in
            Task { @SilveranUIActor in
                self?.handleRelocated(message)
            }
        }
    }

    public func handleNativeBookStructureReady(pageCount: Int) {
        guard !hasPerformedInitialSeek else { return }
        hasPerformedInitialSeek = true

        Task { @SilveranUIActor in
            await self.claimFormatSwitchHandoffFromStoreIfNeeded()
            let restoredIndex = self.nativeInitialSectionIndex(pageCount: pageCount) ?? 0
            debugLog(
                "[EPM] Native initial page index=\(restoredIndex)/\(pageCount) formatSwitch=\(self.formatSwitchHandoff != nil) href=\(self.initialLocator?.href ?? "nil")"
            )
            self.applyNativePageSelection(restoredIndex, syncReason: nil)
            if self.formatSwitchHandoff != nil {
                self.formatSwitchHandoff = nil
            }
        }
    }

    public func handleNativePageSelected(_ index: Int) {
        applyNativePageSelection(index, syncReason: .userSelectedChapter)
    }

    public func handleNativeNavLeft() {
        guard let current = selectedChapterId, current > 0 else { return }
        applyNativePageSelection(current - 1, syncReason: .userFlippedPage)
    }

    public func handleNativeNavRight() {
        guard let current = selectedChapterId, current < bookStructure.count - 1 else { return }
        applyNativePageSelection(current + 1, syncReason: .userFlippedPage)
    }

    public func handleNativeProgressSeek(_ progress: Double) {
        guard !bookStructure.isEmpty else { return }
        let clamped = max(0.0, min(1.0, progress))
        let index = min(
            max(Int((clamped * Double(bookStructure.count)).rounded(.down)), 0),
            bookStructure.count - 1,
        )
        applyNativePageSelection(index, syncReason: .userDraggedSeekBar)
    }

    private func nativeInitialSectionIndex(pageCount: Int) -> Int? {
        guard pageCount > 0 else { return nil }
        let progression =
            formatSwitchHandoff?.progression
            ?? initialLocator?.locations?.totalProgression
            ?? initialLocator?.locations?.progression

        if let locator = initialLocator,
            !StoryPositionTranslator.isPlaceholderReaderHref(locator.href),
            let sectionIndex = findSectionIndex(for: locator.href, in: bookStructure)
        {
            return sectionIndex
        }

        if let progression {
            let clamped = max(0.0, min(1.0, progression))
            return min(max(Int((clamped * Double(pageCount)).rounded(.down)), 0), pageCount - 1)
        }

        return nil
    }

    private func claimFormatSwitchHandoffFromStoreIfNeeded() async {
        guard formatSwitchHandoff == nil, let bookID else { return }
        if let handoff = await FormatSwitchHandoffStore.shared.consumeReaderHandoff(bookID: bookID) {
            applyFormatSwitchHandoff(handoff)
        }
    }

    private func applyNativePageSelection(_ index: Int, syncReason: SyncReason?) {
        guard index >= 0 && index < bookStructure.count else { return }

        selectedChapterId = index
        chapterCurrentPage = index + 1
        chapterTotalPages = bookStructure.count
        chapterSeekBarValue = 0
        let denominator = max(bookStructure.count - 1, 1)
        bookFraction = Double(index) / Double(denominator)

        guard let syncReason else { return }
        recordActivity()
        scheduleDebouncedSync(reason: syncReason, useFragment: false)
    }

    public func updateChapterProgress(currentPage: Int?, totalPages: Int?) {
        guard let current = currentPage, let total = totalPages, total > 0 else {
            chapterSeekBarValue = 0.0
            return
        }

        chapterSeekBarValue = Double(current - 1) / Double(total)
        debugLog(
            "[EPM] Chapter progress updated: \(String(format: "%.1f%%", chapterSeekBarValue * 100))"
        )
    }

    /// Update book progress (fractional position in entire book)
    public func updateBookProgress(fraction: Double?) {
        bookFraction = fraction
        if let fraction = fraction {
            debugLog("[EPM] Book progress updated: \(String(format: "%.1f%%", fraction * 100))")
        }
    }

    /// Find the SMIL entry corresponding to a fraction (0-1) within a specific section.
    private func findSmilEntryBySectionFraction(_ sectionIndex: Int, fraction: Double) -> String? {
        guard sectionIndex >= 0 && sectionIndex < bookStructure.count else { return nil }

        let section = bookStructure[sectionIndex]
        guard let lastEntry = section.mediaOverlay.last else { return nil }

        // Calculate the cumulative sum at the START of this section
        var sectionStartCumSum: Double = 0
        for prevIdx in (0..<sectionIndex).reversed() {
            if let prevLastEntry = bookStructure[prevIdx].mediaOverlay.last {
                sectionStartCumSum = prevLastEntry.cumSumAtEnd
                break
            }
        }

        // Calculate actual section duration (not book-level cumSum)
        let sectionDuration = lastEntry.cumSumAtEnd - sectionStartCumSum
        guard sectionDuration > 0 else { return nil }

        // Calculate target time in book-level cumSum
        let targetSeconds = sectionStartCumSum + (fraction * sectionDuration)

        for entry in section.mediaOverlay {
            if entry.cumSumAtEnd >= targetSeconds {
                return entry.textId
            }
        }

        return nil
    }

    /// Find the SMIL entry corresponding to a book fraction (0-1).
    /// Delegates to SMILPlayerActor for consistent behavior across CarPlay and iOS app.
    private func findSmilEntryByBookFraction(_ fraction: Double) async -> (
        sectionIndex: Int, anchor: String
    )? {
        guard let result = await SMILPlayerActor.shared.findPositionByTotalProgression(fraction)
        else {
            return nil
        }
        return (sectionIndex: result.sectionIndex, anchor: result.textId)
    }

    /// Called when book structure is ready-- performs initial navigation
    /// Handles both text (ebook) and audio (audiobook) locators.
    /// Audio locators are detected via type.contains("audio") to match server behavior:
    /// storyteller/web/src/components/reader/BookService.ts:892 (translateLocator)
    public func handleBookStructureReady() {
        guard !hasPerformedInitialSeek else {
            debugLog("[EPM] Initial seek already performed, skipping")
            return
        }

        guard let bridge = commsBridge else {
            debugLog("[EPM] Bridge not available for initial seek")
            return
        }

        hasPerformedInitialSeek = true

        Task { @SilveranUIActor in
            do {
                await self.claimFormatSwitchHandoffFromStoreIfNeeded()

                let usingFormatSwitch = self.formatSwitchHandoff != nil
                var locatorToUse = self.formatSwitchHandoff?.locator ?? self.initialLocator
                var progressionHint =
                    self.formatSwitchHandoff?.progression
                    ?? locatorToUse?.locations?.totalProgression
                    ?? locatorToUse?.locations?.progression
                    ?? 0

                // Intentional format switch must never fall through to stale PSA / metadata.
                if !usingFormatSwitch, let bookID = self.bookID {
                    if let psaProgress = await ProgressSyncActor.shared.getBookProgress(
                        for: bookID
                    ),
                        let psaLocator = psaProgress.locator
                    {
                        debugLog("[EPM] Got locator from PSA (source: \(psaProgress.source))")
                        locatorToUse = psaLocator
                        progressionHint =
                            psaLocator.locations?.totalProgression
                            ?? psaLocator.locations?.progression
                            ?? progressionHint
                    }
                }

                debugLog(
                    "[EPM] Initial seek incoming formatSwitch=\(usingFormatSwitch) precision=\(self.formatSwitchHandoff?.precision.rawValue ?? "n/a") href=\(locatorToUse?.href ?? "nil") prog=\(progressionHint) sections=\(self.bookStructure.count)"
                )

                if let locator = locatorToUse {
                    let resolved = StoryPositionTranslator.resolveReaderNavigationTarget(
                        locator: locator,
                        progression: progressionHint,
                        bookStructure: self.bookStructure,
                    )
                    let navLocator = resolved.locator
                    let strategy = resolved.navigation
                    let totalProg =
                        navLocator.locations?.totalProgression
                        ?? progressionHint

                    debugLog(
                        "[EPM] Resolved EPUB nav strategy=\(strategy.rawValue) href=\(navLocator.href) total=\(totalProg) sectionProg=\(navLocator.locations?.progression?.description ?? "nil") fragment=\(navLocator.locations?.fragments?.first ?? "nil")"
                    )

                    let hasSMIL = self.mediaOverlayManager?.hasMediaOverlay == true
                    var navigated = false

                    switch strategy {
                        case .fragment:
                            if let fragment = navLocator.locations?.fragments?.first {
                                try await bridge.sendJsGoToLocatorCommand(locator: navLocator)
                                navigated = true
                                if hasSMIL,
                                    let mom = self.mediaOverlayManager,
                                    let sectionIndex = findSectionIndex(
                                        for: navLocator.href,
                                        in: self.bookStructure,
                                    )
                                {
                                    await mom.handleSeekEvent(
                                        sectionIndex: sectionIndex,
                                        anchor: fragment,
                                    )
                                }
                            }
                        case .sectionFraction:
                            if let progression = navLocator.locations?.progression,
                                let sectionIndex = findSectionIndex(
                                    for: navLocator.href,
                                    in: self.bookStructure,
                                )
                            {
                                try await bridge.sendJsGoToFractionInSectionCommand(
                                    sectionIndex: sectionIndex,
                                    fraction: progression,
                                )
                                navigated = true
                                if hasSMIL,
                                    let mom = self.mediaOverlayManager,
                                    let anchor = self.findSmilEntryBySectionFraction(
                                        sectionIndex,
                                        fraction: progression,
                                    )
                                {
                                    await mom.handleSeekEvent(
                                        sectionIndex: sectionIndex,
                                        anchor: anchor,
                                    )
                                }
                            }
                        case .bookFraction:
                            try await bridge.sendJsGoToBookFractionCommand(fraction: totalProg)
                            navigated = true
                            if hasSMIL,
                                let mom = self.mediaOverlayManager,
                                let (smilSection, anchor) = await self.findSmilEntryByBookFraction(
                                    totalProg
                                )
                            {
                                await mom.handleSeekEvent(
                                    sectionIndex: smilSection,
                                    anchor: anchor,
                                )
                            }
                        case .href:
                            try await bridge.sendJsGoToHrefCommand(href: navLocator.href)
                            navigated = true
                    }

                    if !navigated {
                        debugLog(
                            "[EPM] Primary nav strategy \(strategy.rawValue) failed; falling back to book fraction \(totalProg)"
                        )
                        try await bridge.sendJsGoToBookFractionCommand(fraction: totalProg)
                        navigated = true
                    }

                    debugLog(
                        "[EPM] Initial seek completed navigated=\(navigated) finalHref=\(navLocator.href) finalProg=\(totalProg)"
                    )
                } else {
                    debugLog("[EPM] No saved position, navigating to first page")
                    try await bridge.sendJsGoRightCommand()
                }

                self.formatSwitchHandoff = nil
            } catch {
                debugLog("[EPM] Failed to perform initial seek: \(error)")
                // Last-resort percentage navigation when Foliate rejects the primary target.
                if let prog = self.formatSwitchHandoff?.progression ?? self.initialLocator?
                    .locations?.totalProgression,
                    prog > 0
                {
                    do {
                        try await bridge.sendJsGoToBookFractionCommand(fraction: prog)
                        debugLog("[EPM] Fallback book-fraction seek after error → \(prog)")
                    } catch {
                        debugLog("[EPM] Fallback book-fraction seek also failed: \(error)")
                    }
                }
                self.formatSwitchHandoff = nil
            }
        }
    }

    public func handleServerPositionUpdate(_ locator: BookLocator) {
        guard let bridge = commsBridge else {
            debugLog("[EPM] Bridge not available for server position update")
            return
        }

        debugLog("[EPM] Navigating to server position: \(locator.href)")

        Task { @SilveranUIActor in
            do {
                let hasSMIL = mediaOverlayManager?.hasMediaOverlay == true
                let isAudioLocator = locator.type.contains("audio")
                let totalProgression = locator.locations?.totalProgression

                if isAudioLocator, totalProgression == nil {
                    debugLog("[EPM] Audio locator missing totalProgression; skipping server nav")
                    return
                }

                if let fragment = locator.locations?.fragments?.first, hasSMIL, !isAudioLocator {
                    debugLog("[EPM] Using fragment navigation: \(locator.href)#\(fragment)")
                    try await bridge.sendJsGoToLocatorCommand(locator: locator)

                    if let mom = mediaOverlayManager,
                        let sectionIndex = findSectionIndex(for: locator.href, in: bookStructure)
                    {
                        await mom.handleSeekEvent(sectionIndex: sectionIndex, anchor: fragment)
                    }
                } else if let progression = locator.locations?.progression,
                    let sectionIndex = findSectionIndex(for: locator.href, in: bookStructure)
                {
                    debugLog(
                        "[EPM] Using section progression: section=\(sectionIndex), prog=\(progression)"
                    )
                    try await bridge.sendJsGoToFractionInSectionCommand(
                        sectionIndex: sectionIndex,
                        fraction: progression,
                    )

                    if hasSMIL,
                        let mom = mediaOverlayManager,
                        let anchor = findSmilEntryBySectionFraction(
                            sectionIndex,
                            fraction: progression,
                        )
                    {
                        await mom.handleSeekEvent(sectionIndex: sectionIndex, anchor: anchor)
                    }
                } else if let totalProg = totalProgression, totalProg > 0 {
                    debugLog("[EPM] Using book fraction: \(totalProg)")
                    try await bridge.sendJsGoToBookFractionCommand(fraction: totalProg)

                    if hasSMIL,
                        let mom = mediaOverlayManager,
                        let (smilSection, anchor) = await findSmilEntryByBookFraction(totalProg)
                    {
                        await mom.handleSeekEvent(sectionIndex: smilSection, anchor: anchor)
                    }
                } else {
                    debugLog("[EPM] Using href fallback: \(locator.href)")
                    try await bridge.sendJsGoToHrefCommand(href: locator.href)
                }
            } catch {
                debugLog("[EPM] Failed to navigate to server position: \(error)")
            }
        }
    }

    /*
     Navigation flow (page flips + relocates):
     - Swipes are handled in JS, which emits PageFlipped with from/to/direction. We queue an
       expected page for the current section and wait for the matching relocate before syncing
       readaloud (MOM).
     - Button/margin nav is Swift-triggered (sendJsGoLeft/Right). We queue the expected page
       immediately because JS doesn't reliably emit PageFlipped in all environments. If a
       PageFlipped echo does arrive, we suppress it to avoid double-queueing.
     - If multiple swipes arrive before relocates settle, we advance the expected page each time.
     - If the expected page crosses the chapter boundary (page < 1 or > totalPages), we set up
       a pendingChapterTransition and let the original goLeft/goRight command execute. Foliate
       handles landing on the correct page (first page going right, last page going left). MOM
       syncs after the relocate confirms the new position.
     - If a pending page nav never resolves (e.g., Foliate drops a goLeft/goRight), a 700ms
       fallback fires MOM using the latest known page so readaloud can catch up.
     - Relocate events do the final arbitration: they resolve pending expectations and determine
       whether MOM gets a user-nav event or a natural-nav event.
     */
    /// JS sent relocate (position or chapter changed during playback)
    private func handleRelocated(_ message: RelocatedMessage) {
        debugLog(
            "[EPM] Received relocate event from JS: sectionIndex=\(message.sectionIndex?.description ?? "nil")"
        )

        if message.flow == "scrolled" {
            handleScrollingRelocated(message)
            return
        }

        var chapterTransitionResolved = false

        if let pendingChapter = pendingChapterTransition {
            if message.sectionIndex != pendingChapter {
                debugLog(
                    "[EPM] Ignoring relocate while awaiting chapter \(pendingChapter) (got \(message.sectionIndex?.description ?? "nil"))"
                )
                return
            }

            debugLog("[EPM] Chapter transition settled at section \(pendingChapter)")
            pendingChapterTransition = nil
            pendingPageNav = nil
            pendingSeekNav = nil
            pendingSwiftCommandFlipEchoes = 0
            cancelUserNavFallback()
            chapterTransitionResolved = true
        }

        let shouldNotifyUserNavForChapterTransition = chapterTransitionResolved

        if let pending = pendingPageNav,
            let section = message.sectionIndex,
            section != pending.sectionIndex
        {
            debugLog(
                "[EPM] Pending page nav invalidated by section change (expected \(pending.sectionIndex), got \(section))"
            )
            pendingPageNav = nil
            pendingSwiftCommandFlipEchoes = 0
            cancelUserNavFallback()
        }

        if let pending = pendingSeekNav,
            let section = message.sectionIndex,
            section != pending.sectionIndex
        {
            debugLog(
                "[EPM] Pending seek nav invalidated by section change (expected \(pending.sectionIndex), got \(section))"
            )
            pendingSeekNav = nil
            cancelUserNavFallback()
        }

        var shouldNotifyUserNav = false
        let canNotifyNaturalNav = !chapterTransitionResolved

        if let pending = pendingPageNav,
            let section = message.sectionIndex,
            let page = message.pageIndex,
            section == pending.sectionIndex,
            page == pending.expectedPage
        {
            debugLog("[EPM] Matched pending page nav: section \(section), page \(page)")
            pendingPageNav = nil
            pendingSwiftCommandFlipEchoes = 0
            cancelUserNavFallback()
            shouldNotifyUserNav = true
        } else if let pending = pendingSeekNav,
            let section = message.sectionIndex,
            section == pending.sectionIndex
        {
            debugLog("[EPM] Seek nav settled at section \(section)")
            pendingSeekNav = nil
            cancelUserNavFallback()
            shouldNotifyUserNav = true
        }

        selectedChapterId = message.sectionIndex
        updateBookProgress(fraction: message.fraction)
        chapterCurrentPage = message.pageIndex
        chapterTotalPages = message.totalPages
        updateChapterProgress(currentPage: message.pageIndex, totalPages: message.totalPages)

        let isUserNav = shouldNotifyUserNav || shouldNotifyUserNavForChapterTransition

        if isUserNav, let reason = pendingUserNavSyncReason {
            pendingUserNavSyncReason = nil

            if let section = message.sectionIndex,
                let page = message.pageIndex,
                let total = message.totalPages,
                let mom = mediaOverlayManager
            {
                Task { @SilveranUIActor in
                    let foundSMILMatch = await mom.handleUserNavEvent(
                        section: section,
                        page: page,
                        totalPages: total,
                    )
                    self.recordActivity()
                    self.scheduleDebouncedSync(reason: reason, useFragment: foundSMILMatch)
                }
            } else {
                recordActivity()
                scheduleDebouncedSync(reason: reason, useFragment: false)
            }
        } else if let section = message.sectionIndex,
            let page = message.pageIndex,
            let total = message.totalPages,
            let mom = mediaOverlayManager,
            canNotifyNaturalNav && pendingPageNav == nil && pendingSeekNav == nil
        {
            Task { @SilveranUIActor in
                await mom.handleNaturalNavEvent(section: section, page: page, totalPages: total)
            }
        }
    }

    private func handleScrollingRelocated(_ message: RelocatedMessage) {
        pendingPageNav = nil
        pendingSeekNav = nil
        pendingChapterTransition = nil
        pendingSwiftCommandFlipEchoes = 0
        cancelUserNavFallback()

        selectedChapterId = message.sectionIndex
        updateBookProgress(fraction: message.fraction)
        chapterCurrentPage = nil
        chapterTotalPages = nil

        if let chapterFraction = message.chapterFraction {
            chapterSeekBarValue = max(0.0, min(1.0, chapterFraction))
        } else {
            updateChapterProgress(currentPage: nil, totalPages: nil)
        }

        let pendingReason = pendingUserNavSyncReason
        let isUserScroll = message.reason == "scroll"

        if isUserScroll || pendingReason != nil {
            pendingUserNavSyncReason = nil
            recordActivity()
            scheduleDebouncedSync(
                reason: pendingReason ?? .userDraggedSeekBar,
                useFragment: false,
            )
        }
    }

    @discardableResult
    private func queuePageNav(
        direction: UserNavDirection,
        delta: Int = 1,
        fromPage: Int? = nil,
        totalPages: Int? = nil,
        source: String,
    ) -> Bool {
        guard pendingChapterTransition == nil else {
            debugLog("[EPM] Ignoring page nav (\(direction.rawValue)) - chapter transition pending")
            return false
        }

        guard let sectionIndex = selectedChapterId else {
            debugLog("[EPM] Cannot queue page nav - no current section")
            return false
        }

        let stepMagnitude = max(1, abs(delta))
        let step = direction == .right ? stepMagnitude : -stepMagnitude

        let resolvedTotalPages = totalPages ?? pendingPageNav?.totalPages ?? chapterTotalPages
        let basePage: Int?

        if let pending = pendingPageNav, pending.sectionIndex == sectionIndex {
            basePage = pending.expectedPage
        } else if let fromPage = fromPage {
            basePage = fromPage
        } else {
            basePage = chapterCurrentPage
        }

        guard let basePage else {
            debugLog("[EPM] Cannot queue page nav - no current page")
            return false
        }

        let expectedPage = basePage + step

        if let total = resolvedTotalPages, expectedPage < 1 || expectedPage > total {
            let targetSection =
                direction == .right
                ? sectionIndex + 1
                : sectionIndex - 1

            guard targetSection >= 0 && targetSection < bookStructure.count else {
                debugLog(
                    "[EPM] Page nav crossed boundary but no adjacent chapter (section \(sectionIndex), page \(basePage)/\(total))"
                )
                return false
            }

            debugLog(
                "[EPM] Page nav crossed chapter boundary at \(basePage)/\(total), awaiting section \(targetSection)"
            )

            pendingPageNav = nil
            pendingSeekNav = nil
            cancelUserNavFallback()
            pendingChapterTransition = targetSection

            if !isFreeBrowseMode {
                pendingUserNavSyncReason = .userFlippedPage
            }

            return false
        }

        pendingSeekNav = nil
        pendingPageNav = PendingPageNav(
            sectionIndex: sectionIndex,
            expectedPage: expectedPage,
            totalPages: resolvedTotalPages,
        )

        if !isFreeBrowseMode {
            pendingUserNavSyncReason = .userFlippedPage
        }

        scheduleUserNavFallback(source: source)

        debugLog(
            "[EPM] Queued page nav (\(source)): section \(sectionIndex), expecting page \(expectedPage)/\(resolvedTotalPages?.description ?? "nil")"
        )

        resolvePendingPageNavIfAlreadyAtExpected()
        return true
    }

    private func resolvePendingPageNavIfAlreadyAtExpected() {
        guard let pending = pendingPageNav else { return }
        guard let section = selectedChapterId,
            let page = chapterCurrentPage,
            let total = chapterTotalPages,
            section == pending.sectionIndex,
            page == pending.expectedPage
        else {
            return
        }

        debugLog("[EPM] Pending page nav already satisfied - dispatching")
        pendingPageNav = nil
        cancelUserNavFallback()

        if let mom = mediaOverlayManager {
            Task { @SilveranUIActor in
                _ = await mom.handleUserNavEvent(section: section, page: page, totalPages: total)
            }
        }
    }

    private func scheduleUserNavFallback(source: String) {
        userNavFallbackTask?.cancel()
        userNavFallbackTask = Task { @SilveranUIActor in
            do {
                try await Task.sleep(for: .milliseconds(700))
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            guard pendingChapterTransition == nil,
                pendingPageNav != nil || pendingSeekNav != nil
            else { return }
            guard let section = selectedChapterId,
                let page = chapterCurrentPage,
                let total = chapterTotalPages
            else {
                return
            }

            debugLog(
                "[EPM] User nav fallback fired (\(source)): section \(section), page \(page)/\(total)"
            )
            pendingPageNav = nil
            pendingSeekNav = nil
            pendingSwiftCommandFlipEchoes = 0

            if let reason = pendingUserNavSyncReason {
                pendingUserNavSyncReason = nil

                if let mom = mediaOverlayManager {
                    let foundSMILMatch = await mom.handleUserNavEvent(
                        section: section,
                        page: page,
                        totalPages: total,
                    )
                    recordActivity()
                    scheduleDebouncedSync(reason: reason, useFragment: foundSMILMatch)
                } else {
                    recordActivity()
                    scheduleDebouncedSync(reason: reason, useFragment: false)
                }
            }
        }
    }

    private func cancelUserNavFallback() {
        userNavFallbackTask?.cancel()
        userNavFallbackTask = nil
    }

    private func queueSeekNav(sectionIndex: Int) {
        guard pendingChapterTransition == nil else {
            debugLog("[EPM] Ignoring seek nav - chapter transition pending")
            return
        }

        cancelUserNavFallback()
        pendingPageNav = nil
        pendingSeekNav = PendingSeekNav(sectionIndex: sectionIndex)

        if !isFreeBrowseMode {
            pendingUserNavSyncReason = .userDraggedSeekBar
        }

        scheduleUserNavFallback(source: "seek-nav")

        debugLog("[EPM] Queued seek nav for section \(sectionIndex)")
    }

    private func performChapterNavigation(
        to newId: Int,
        reason: String,
        syncReason: SyncReason,
    ) {
        guard newId != selectedChapterId else {
            debugLog("[EPM] UI selection matches current chapter, ignoring")
            return
        }

        guard let chapter = bookStructure[safe: newId],
            let bridge = commsBridge
        else {
            debugLog("[EPM] Cannot navigate - invalid chapter index or no bridge")
            return
        }

        pendingPageNav = nil
        pendingSeekNav = nil
        cancelUserNavFallback()
        pendingChapterTransition = newId

        debugLog("[EPM] Chapter transition pending → Section.\(newId) (\(reason))")
        debugLog("[EPM] User selected chapter \(newId): \(chapter.label ?? "nil")")

        let previousChapterId = selectedChapterId

        if !isFreeBrowseMode || isScrollingMode {
            pendingUserNavSyncReason = syncReason
        }

        selectedChapterId = newId

        Task { @SilveranUIActor in
            do {
                try await bridge.sendJsGoToFractionInSectionCommand(
                    sectionIndex: newId,
                    fraction: 0,
                )

                if let mom = mediaOverlayManager {
                    await mom.handleUserChapterNavigation(sectionIndex: newId)
                }
            } catch {
                debugLog("[EPM] Failed to navigate to chapter: \(error)")
                pendingChapterTransition = nil
                selectedChapterId = previousChapterId
            }
        }
    }

    /// User pressed left arrow or swiped right (previous page)
    public func handleUserNavLeft() {
        if isScrollingMode {
            pendingUserNavSyncReason = .userFlippedPage
            Task { @SilveranUIActor in
                do {
                    try await commsBridge?.sendJsGoLeftCommand()
                } catch {
                    debugLog("[EPM] Failed to send scrolling left nav: \(error)")
                    pendingUserNavSyncReason = nil
                }
            }
            return
        }

        // Swift-triggered nav queues immediately; a PageFlipped echo may follow.
        if queuePageNav(direction: .left, source: "left-nav") {
            pendingSwiftCommandFlipEchoes += 1
        }
        Task { @SilveranUIActor in
            do {
                try await commsBridge?.sendJsGoLeftCommand()
            } catch {
                debugLog("[EPM] Failed to send left nav: \(error)")
                pendingPageNav = nil
                pendingSwiftCommandFlipEchoes = 0
                cancelUserNavFallback()
            }
        }
    }

    /// User pressed right arrow or swiped left (next page)
    public func handleUserNavRight() {
        if isScrollingMode {
            pendingUserNavSyncReason = .userFlippedPage
            Task { @SilveranUIActor in
                do {
                    try await commsBridge?.sendJsGoRightCommand()
                } catch {
                    debugLog("[EPM] Failed to send scrolling right nav: \(error)")
                    pendingUserNavSyncReason = nil
                }
            }
            return
        }

        // Swift-triggered nav queues immediately; a PageFlipped echo may follow.
        if queuePageNav(direction: .right, source: "right-nav") {
            pendingSwiftCommandFlipEchoes += 1
        }
        Task { @SilveranUIActor in
            do {
                try await commsBridge?.sendJsGoRightCommand()
            } catch {
                debugLog("[EPM] Failed to send right nav: \(error)")
                pendingPageNav = nil
                pendingSwiftCommandFlipEchoes = 0
                cancelUserNavFallback()
            }
        }
    }

    /// User performed touch swipe on webview (JS already handled navigation)
    public func handleUserNavSwipeDetected(_ message: PageFlippedMessage) {
        // PageFlipped is the single source of truth for swipe gestures.
        // Swift-triggered goLeft/goRight can emit a PageFlipped echo; suppress those.
        if pendingSwiftCommandFlipEchoes > 0 {
            pendingSwiftCommandFlipEchoes -= 1
            debugLog("[EPM] Ignoring PageFlipped echo from Swift-triggered nav")
            return
        }

        guard let direction = UserNavDirection(rawValue: message.direction) else {
            debugLog("[EPM] Unrecognized page flip direction: \(message.direction)")
            return
        }

        let delta = message.delta ?? 1

        queuePageNav(
            direction: direction,
            delta: delta,
            fromPage: message.fromPage,
            totalPages: chapterTotalPages,
            source: "page-flip",
        )
    }

    /// User clicked on a chapter in sidebar to navigate
    public func handleUserChapterSelected(_ newId: Int) {
        performChapterNavigation(
            to: newId,
            reason: "user selection",
            syncReason: .userSelectedChapter,
        )
    }

    /// User clicked on a TOC entry that has a specific href (with fragment anchor)
    public func handleUserChapterSelectedWithHref(_ newId: Int, href: String) {
        guard let bridge = commsBridge else {
            debugLog("[EPM] Cannot navigate - no bridge")
            return
        }

        let isSameSection = newId == selectedChapterId

        pendingPageNav = nil
        pendingSeekNav = nil
        cancelUserNavFallback()

        if !isSameSection {
            pendingChapterTransition = newId
            debugLog(
                "[EPM] Chapter transition pending → Section.\(newId) (user selection with href)"
            )
        }

        if !isFreeBrowseMode || isScrollingMode {
            pendingUserNavSyncReason = .userSelectedChapter
        }

        let previousChapterId = selectedChapterId
        selectedChapterId = newId

        debugLog("[EPM] Navigating to href: \(href) (sameSection=\(isSameSection))")

        Task { @SilveranUIActor in
            do {
                try await bridge.sendJsGoToHrefCommand(href: href)

                if !isSameSection, let mom = mediaOverlayManager {
                    await mom.handleUserChapterNavigation(sectionIndex: newId)
                }
            } catch {
                debugLog("[EPM] Failed to navigate to href: \(error)")
                pendingChapterTransition = nil
                selectedChapterId = previousChapterId
            }
        }
    }

    /// User dragged progress bar to seek within chapter (0.0 - 1.0)
    public func handleUserProgressSeek(_ progress: Double) {
        let clampedProgress = max(0.0, min(1.0, progress))
        chapterSeekBarValue = clampedProgress

        debugLog(
            "[EPM] User seeking to chapter progress: \(String(format: "%.1f%%", clampedProgress * 100))"
        )

        guard let currentChapterIndex = selectedChapterId,
            let bridge = commsBridge
        else {
            debugLog("[EPM] Cannot seek - no chapter selected or bridge unavailable")
            return
        }

        if isScrollingMode {
            pendingUserNavSyncReason = .userDraggedSeekBar
        } else {
            queueSeekNav(sectionIndex: currentChapterIndex)
        }

        Task { @SilveranUIActor in
            do {
                try await bridge.sendJsGoToFractionInSectionCommand(
                    sectionIndex: currentChapterIndex,
                    fraction: clampedProgress,
                )
            } catch {
                debugLog("[EPM] Failed to send seek command: \(error)")
                pendingSeekNav = nil
            }
        }
    }

    /// Handle position handoff from SMILPlayerActor after returning from background
    /// Syncs the view to current audio position and updates server
    public func handleBackgroundSyncHandoff(_ syncData: AudioPositionSyncData) async {
        debugLog(
            "[EPM] Background sync handoff: section=\(syncData.sectionIndex), fragment=\(syncData.fragment)"
        )

        selectedChapterId = syncData.sectionIndex
        recordActivity()

        let fullHref =
            syncData.fragment.isEmpty
            ? syncData.href
            : "\(syncData.href)#\(syncData.fragment)"

        do {
            try await commsBridge?.sendJsGoToHrefCommand(href: fullHref)
            debugLog("[EPM] Navigated view to background sync position: \(fullHref)")
        } catch {
            debugLog("[EPM] Failed to navigate to background sync position: \(error)")
        }

        await syncProgressToServer(reason: .periodicDuringActivePlayback)
    }

    /// Toggle audio playback (records activity and delegates to MOM)
    public func togglePlaying() async {
        recordActivity()

        let wasPlaying = mediaOverlayManager?.isPlaying ?? false

        debugLog(
            "[EPM] togglePlaying - activity recorded, delegating to MOM (wasPlaying: \(wasPlaying))"
        )
        await mediaOverlayManager?.togglePlaying()

        let isNowPlaying = mediaOverlayManager?.isPlaying ?? false

        if wasPlaying && !isNowPlaying {
            debugLog("[EPM] Playback stopped - syncing immediately")
            await syncProgressToServer(reason: .userPausedPlayback)
        }
    }

    //
    // Sync Strategy - Progress is synced to the server in multiple scenarios:
    //
    // 1. Periodic Sync (startPeriodicSync):
    //    - Fires every N seconds while app is active (configurable interval)
    //    - Continues running while audio plays in background (iOS/macOS)
    //    - Use case: User on macOS leaves app open but switches to another device
    //    - Use case: Long background audio sessions on iOS
    //
    // 2. Backgrounding (handleAppBackgrounding):
    //    - iOS only: Triggered when app enters background via scenePhase change
    //    - Syncs immediately using UIApplication.beginBackgroundTask for extra time
    //    - Use case: User reading on iOS switches to another app
    //    - Note: Does NOT pause audio - audio continues in background
    //
    // 3. Playback Stop (togglePlaying):
    //    - Triggers when audio playback stops (user pause, sleep timer, etc.)
    //    - Critical for iOS: Captures state before iOS suspends app (~5-10s after audio stops)
    //    - Use case: User listening in background, stops playback, iOS will suspend shortly
    //    - Routes through EPM so all pause events (UI, sleep timer) trigger sync
    //
    // 4. App Termination (cleanup):
    //    - Called on view disappear (window close on macOS, app termination)
    //    - Final safeguard to capture state before app exits
    //    - Force syncs even if no recent activity changes
    //
    // Activity Tracking:
    //   - recordActivity() updates lastActivityTimestamp on every user interaction
    //   - Navigation (page turns, chapter selection, progress seek)
    //   - Playback control (play/pause)
    //   - syncProgressToServer() only uploads if timestamp changed (avoids duplicate syncs)
    //   - If audio is playing during sync check, activity is refreshed automatically

    private func recordActivity() {
        lastActivityTimestamp = floor(Date().timeIntervalSince1970 * 1000) / 1000
        let timestampMs = lastActivityTimestamp! * 1000
        debugLog("[EPM] Activity recorded at \(timestampMs) ms (unix epoch)")
    }

    /// Called by MOM before pause-triggered syncs; without it a headless
    /// session with no navigation would skip the sync for lack of activity.
    public func recordPlaybackActivity() {
        recordActivity()
    }

    /// Schedule a debounced sync - cancels any pending sync and schedules a new one.
    /// This prevents lag from rapid page flips by only syncing after user settles.
    private func scheduleDebouncedSync(reason: SyncReason, useFragment: Bool) {
        debouncedSyncTask?.cancel()
        debouncedSyncTask = Task { @SilveranUIActor in
            do {
                try await Task.sleep(for: syncDebounceDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await syncProgressToServer(reason: reason, useFragment: useFragment)
        }
    }

    public func startPeriodicSync(syncInterval: TimeInterval) {
        stopPeriodicSync()
        debugLog("[EPM] Starting periodic sync with interval \(syncInterval)s")

        syncTask = Task { @SilveranUIActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(syncInterval))
                guard !Task.isCancelled, let self else { return }
                let isPlaying = self.mediaOverlayManager?.isPlaying ?? false

                if isPlaying {
                    await self.syncProgressToServer(reason: .periodicDuringActivePlayback)
                }
            }
        }
    }

    public func stopPeriodicSync() {
        syncTask?.cancel()
        syncTask = nil
        debugLog("[EPM] Stopped periodic sync")
    }

    /// Sync progress to server via ProgressSyncActor
    /// - Parameters:
    ///   - reason: Why this sync is occurring
    ///   - useFragment: If true and MOM has a current fragment, use it. If false, use totalProgression.
    public func syncProgressToServer(reason: SyncReason, useFragment: Bool = true) async {
        guard let bookID else {
            debugLog("[EPM] Cannot sync: no book identity")
            return
        }

        if let mom = mediaOverlayManager, mom.isPlaying {
            recordActivity()
        }

        guard let lastActivity = lastActivityTimestamp else {
            debugLog("[EPM] Cannot sync: no activity recorded yet")
            return
        }

        let now = Date().timeIntervalSince1970
        let timeSinceActivity = now - lastActivity
        debugLog(
            "[EPM] Syncing progress (reason: \(reason.rawValue), useFragment: \(useFragment), activity \(String(format: "%.1f", timeSinceActivity))s ago)"
        )

        let locator: BookLocator?

        if useFragment,
            let mom = mediaOverlayManager,
            mom.hasMediaOverlay,
            let fragment = mom.currentFragment
        {
            debugLog("[EPM] Using audio fragment for sync: \(fragment)")
            locator = buildLocatorFromFragment(fragment)
        } else if let fraction = bookFraction {
            debugLog("[EPM] Using book fraction for sync: \(fraction)")
            locator = buildLocatorFromFraction(fraction)
        } else {
            debugLog("[EPM] No valid progress to sync")
            return
        }

        guard let finalLocator = locator else {
            debugLog("[EPM] Failed to build locator")
            return
        }

        let timestampMs = lastActivity * 1000
        debugLog("[EPM] Sending timestamp: \(timestampMs) ms")

        let hasMediaOverlay = mediaOverlayManager?.hasMediaOverlay ?? false
        let sourceIdentifier = hasMediaOverlay ? "Readaloud Player" : "Ebook Player"

        let locationDescription: String
        if let chapterIdx = selectedChapterId,
            chapterIdx < bookStructure.count
        {
            let chapterName = bookStructure[chapterIdx].label ?? "Chapter \(chapterIdx + 1)"
            locationDescription = "\(chapterName), \(Int(chapterSeekBarValue * 100))%"
        } else if let fraction = bookFraction {
            locationDescription = "\(Int(fraction * 100))% of book"
        } else {
            locationDescription = ""
        }

        let result = await ProgressSyncActor.shared.syncProgress(
            bookID: bookID,
            locator: finalLocator,
            timestamp: timestampMs,
            reason: reason,
            sourceIdentifier: sourceIdentifier,
            locationDescription: locationDescription,
        )

        debugLog("[EPM] Sync result: \(result)")

        if result == .success {
            lastSyncedTimestamp = lastActivity
            debugLog("[EPM] Updated lastSyncedTimestamp to \(lastActivity)")
        }
    }

    /// Fallback for headless sessions, where no relocate ever sets bookFraction.
    private var audioBookFraction: Double? {
        guard let mom = mediaOverlayManager,
            let elapsed = mom.bookElapsedSeconds,
            let total = mom.bookTotalSeconds,
            total > 0
        else { return nil }
        return elapsed / total
    }

    /// Build BookLocator from fragment (href#anchor format)
    private func buildLocatorFromFragment(_ fragment: String) -> BookLocator? {
        let parts = fragment.split(separator: "#", maxSplits: 1)
        guard let href = parts.first else { return nil }

        let anchor = parts.count > 1 ? String(parts[1]) : nil
        let fragments = anchor.map { [$0] }

        return BookLocator(
            href: String(href),
            type: "application/xhtml+xml",
            title: nil as String?,
            locations: BookLocator.Locations(
                fragments: fragments,
                progression: chapterSeekBarValue,
                position: nil,
                totalProgression: bookFraction ?? audioBookFraction,
                cssSelector: nil as String?,
                partialCfi: nil as String?,
                domRange: nil as BookLocator.Locations.DomRange?,
            ),
            text: nil as BookLocator.Text?,
        )
    }

    private func buildLocatorFromFraction(_ fraction: Double) -> BookLocator? {
        guard let section = selectedChapterId,
            section >= 0 && section < bookStructure.count
        else {
            return nil
        }

        let sectionInfo = bookStructure[section]

        return BookLocator(
            href: sectionInfo.id,
            type: "application/xhtml+xml",
            title: sectionInfo.label,
            locations: BookLocator.Locations(
                fragments: nil as [String]?,
                progression: chapterSeekBarValue,
                position: nil,
                totalProgression: fraction,
                cssSelector: nil as String?,
                partialCfi: nil as String?,
                domRange: nil as BookLocator.Locations.DomRange?,
            ),
            text: nil as BookLocator.Text?,
        )
    }

    /// Handle app resume - check PSA for newer position and suppress nav actions
    public func handleResume() async {
        lastResumeTime = Date()
        debugLog(
            "[EPM] Resume detected - suppressing nav actions for \(resumeSuppressionDuration)s"
        )

        guard let bookID else {
            debugLog("[EPM] No bookID, skipping position check")
            return
        }

        guard let psaProgress = await ProgressSyncActor.shared.getBookProgress(for: bookID),
            let psaTimestamp = psaProgress.timestamp
        else {
            debugLog("[EPM] No position from PSA for book \(bookID)")
            return
        }

        let localTimestampMs = (lastActivityTimestamp ?? 0) * 1000
        guard psaTimestamp > localTimestampMs else {
            debugLog(
                "[EPM] PSA position not newer (psa=\(psaTimestamp) <= local=\(localTimestampMs))"
            )
            return
        }

        debugLog(
            "[EPM] PSA has newer position (psa=\(psaTimestamp) > local=\(localTimestampMs)), navigating"
        )
        if let locator = psaProgress.locator {
            do {
                try await commsBridge?.sendJsGoToLocatorCommand(locator: locator)
                debugLog("[EPM] Navigated to PSA position: \(locator.href)")
            } catch {
                debugLog("[EPM] Failed to navigate to PSA position: \(error)")
            }
        }
    }

    /// Cleanup and perform final sync (call on deinit or window close)
    public func cleanup() async {
        debugLog("[EPM] Cleanup: performing final sync")
        stopPeriodicSync()
        debouncedSyncTask?.cancel()
        debouncedSyncTask = nil
        await syncProgressToServer(reason: .userClosedBook)
    }
}
