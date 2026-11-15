#if os(iOS) || os(macOS)
import SwiftUI
import WebKit

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
@Observable
class EbookPlayerViewModel {
    let bookData: PlayerBookData?
    var settingsVM: SettingsViewModel

    private(set) var session: ReadingSession? = nil
    private var userSelectedTocId: String? = nil
    private var comicBookStructure: [SectionInfo] = []
    private var comicProgressManager: EphemeralProgressManager? = nil
    private var bridgeInitialColorScheme: ColorScheme = .light
    var styleManager: ReaderStyleManager? = nil
    var searchManager: EbookSearchManager? = nil
    var comicPageURLs: [URL] = []
    #if os(iOS)
    private(set) var recoveryManager: WebViewRecoveryManager?
    #endif

    var bookStructure: [SectionInfo] {
        if !comicBookStructure.isEmpty {
            return comicBookStructure
        }
        return session?.bookStructure ?? []
    }

    var tocEntries: [TocEntry] {
        session?.tocEntries ?? []
    }

    var mediaOverlayManager: MediaOverlayManager? {
        session?.mediaOverlayManager
    }

    var progressManager: EphemeralProgressManager? {
        comicProgressManager ?? session?.progressManager
    }

    var extractedEbookPath: URL? {
        get { session?.extractedEbookPath }
        set { session?.extractedEbookPath = newValue }
    }

    var ebookFileFormat: EbookFileFormat {
        session?.ebookFileFormat ?? .epub
    }

    var hasAudioNarration: Bool {
        session?.hasAudioNarration ?? false
    }

    var isJoiningExistingSession: Bool {
        session?.isJoiningExistingSession ?? false
    }

    var chapterList: [ChapterItem] {
        if !tocEntries.isEmpty {
            return tocEntries.enumerated().map { idx, entry in
                ChapterItem(
                    id: "toc-\(idx)",
                    label: entry.label,
                    href: entry.href,
                    level: entry.level,
                )
            }
        }
        return bookStructure.filter { $0.label != nil }.map {
            ChapterItem(
                id: $0.id,
                label: $0.label ?? "Untitled",
                href: $0.id,
                level: $0.level ?? 0,
            )
        }
    }

    var isComicBook: Bool {
        ebookFileFormat == .cbz
    }

    private var _sidebarInitialized = false
    #if os(macOS)
    var showChapterSidebar: Bool = false {
        didSet {
            if _sidebarInitialized && oldValue != showChapterSidebar {
                debugLog(
                    "[EbookPlayerViewModel] Chapter sidebar changed: \(oldValue) -> \(showChapterSidebar), saving..."
                )
                UserDefaults.standard.set(
                    showChapterSidebar,
                    forKey: "EbookPlayerShowChapterSidebar",
                )
            }
        }
    }
    var showAudioSidebar: Bool = false {
        didSet {
            if _sidebarInitialized && oldValue != showAudioSidebar {
                debugLog(
                    "[EbookPlayerViewModel] Sidebar changed: \(oldValue) -> \(showAudioSidebar), saving..."
                )
                UserDefaults.standard.set(showAudioSidebar, forKey: "EbookPlayerShowAudioSidebar")
            }
        }
    }
    var isTitleBarHovered = false
    #else
    /// Immersive never auto-opens the iPad sidebar on entry; the stored
    /// preference belongs to Classic and is only read/written there.
    var showAudioSidebar: Bool = false {
        didSet {
            if _sidebarInitialized && oldValue != showAudioSidebar
                && chrome.state.mode == .classic
            {
                UserDefaults.standard.set(
                    showAudioSidebar,
                    forKey: "EbookPlayerShowAudioSidebarIOS",
                )
            }
        }
    }
    var showAudioSheet = false
    /// Single owner of iOS ebook/readaloud chrome visibility (`ReaderChromePolicy`).
    let chrome: ReaderChromeController
    var isReadingBarVisible: Bool { chrome.state.isBottomVisible }
    var isTopBarVisible: Bool { chrome.state.isTopVisible }
    /// True while a page-curl gesture/overlay is active. Masks floating chrome
    /// for the curl lifetime without changing chrome state.
    var isPageCurlActive: Bool { chrome.state.isCurlActive }
    var isSelectTextMode: Bool { chrome.state.isSelectionMode }
    var collapseCardTrigger = 0
    /// Section content is laid out (the first-run hint waits for this).
    var isReaderContentReady = false
    private var presentedChromeSheets: Set<UUID> = []
    @ObservationIgnored private var lastAppliedControlsMode: ReaderControlsMode?
    /// iPad landscape two-page spread, measured by the view (`ReaderSpreadPolicy`).
    var isSpreadLayout = false {
        didSet { styleManager?.setSpreadMode(isSpreadLayout) }
    }
    #endif
    var showCustomizePopover = false
    var commsBridge: ReaderCommsBridge? = nil
    var playbackProgressMessage: Any? = nil

    var chapterProgressBinding: Binding<Double> {
        Binding(
            get: {
                if self.isComicBook {
                    return self.progressManager?.bookFraction ?? 0.0
                }
                return self.progressManager?.chapterSeekBarValue ?? 0.0
            },
            set: { newValue in
                if self.isComicBook {
                    self.progressManager?.handleNativeProgressSeek(newValue)
                } else {
                    self.progressManager?.handleUserProgressSeek(newValue)
                }
            },
        )
    }

    var selectedChapterHref: String? {
        guard let index = progressManager?.selectedChapterId else { return nil }
        if !tocEntries.isEmpty {
            // If user explicitly clicked a toc entry, and it still matches the current section, use it
            if let userSelected = userSelectedTocId,
                userSelected.hasPrefix("toc-"),
                let idx = Int(userSelected.dropFirst(4)),
                idx < tocEntries.count,
                tocEntries[idx].sectionIndex == index
            {
                return userSelected
            }
            // Otherwise find the first toc entry that matches this section index
            for (offset, entry) in tocEntries.enumerated() {
                if entry.sectionIndex == index {
                    return "toc-\(offset)"
                }
            }
            // No exact match - find the last entry with a lower section index
            var lastOffset: Int? = nil
            for (offset, entry) in tocEntries.enumerated() {
                if entry.sectionIndex < index {
                    lastOffset = offset
                }
            }
            if let offset = lastOffset {
                return "toc-\(offset)"
            }
            return nil
        }
        return bookStructure[safe: index]?.id
    }

    var sleepTimerActive = false
    var sleepTimerRemaining: TimeInterval? = nil
    var sleepTimerType: Any? = nil
    var lastRestartTime: Date? = nil
    var showKeybindingsPopover = false
    var showSearchPanel = false
    var pendingSearchReveal = false
    var showTranslation = false
    var translationText = ""
    var showBookmarksPanel = false
    var bookmarksPanelInitialTab: BookmarksPanel.Tab = .bookmarks
    var highlights: [Highlight] = []
    var pendingSelection: TextSelectionMessage? = nil
    var pendingEditHighlight: Highlight? = nil

    var showServerPositionDialog = false
    var pendingServerPosition: IncomingServerPosition? = nil

    var serverPositionDescription: String {
        guard let position = pendingServerPosition else {
            return "Another device has synced a more recent reading position."
        }
        let locator = position.locator
        var details: [String] = []
        if let title = locator.title {
            details.append(title)
        }
        if let prog = locator.locations?.totalProgression {
            details.append("\(Int(prog * 100))%")
        }
        let locationStr = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
        return
            "Another device has synced a more recent reading position\(locationStr). Would you like to go to that location?"
    }

    var bookmarks: [Highlight] {
        highlights.filter { $0.isBookmark }.sorted { $0.createdAt > $1.createdAt }
    }

    var coloredHighlights: [Highlight] {
        highlights.filter { !$0.isBookmark }.sorted { $0.createdAt > $1.createdAt }
    }

    var chapterTicks: [ReaderScrubberPolicy.ChapterTick] {
        ReaderScrubberPolicy.buildChapterTicks(
            tocEntries: tocEntries,
            sections: bookStructure,
            sectionFractions: session?.sectionFractions
        )
    }

    var currentPageBookmark: Highlight? {
        ReaderScrubberPolicy.matchingBookmark(
            in: bookmarks,
            sectionIndex: progressManager?.selectedChapterId,
            cfi: progressManager?.currentCfi,
            href: progressManager?.currentHref,
            bookFraction: progressManager?.bookFraction,
            totalPagesInSection: progressManager?.chapterTotalPages,
            sections: bookStructure
        )
    }

    var isCurrentPageBookmarked: Bool {
        currentPageBookmark != nil
    }

    private(set) var jumpSnapshot: ReaderScrubberPolicy.JumpSnapshot? = nil
    @ObservationIgnored private var isScrubJumpSessionActive = false
    @ObservationIgnored private var jumpPillAutoDismissTask: Task<Void, Never>? = nil
    @ObservationIgnored private var userFlipsSinceJump = 0

    init(bookData: PlayerBookData?, settingsVM: SettingsViewModel = SettingsViewModel()) {
        self.bookData = bookData
        self.settingsVM = settingsVM
        #if os(macOS)
        let savedAudioSidebarState =
            UserDefaults.standard.object(forKey: "EbookPlayerShowAudioSidebar") as? Bool
        self.showAudioSidebar = savedAudioSidebarState ?? true
        let savedChapterSidebarState =
            UserDefaults.standard.object(forKey: "EbookPlayerShowChapterSidebar") as? Bool
        self.showChapterSidebar = savedChapterSidebarState ?? false
        debugLog(
            "[EbookPlayerViewModel] Init - audio sidebar: \(self.showAudioSidebar), chapter sidebar: \(self.showChapterSidebar)"
        )
        #else
        self.chrome = ReaderChromeController()
        #endif
        self._sidebarInitialized = true
    }

    func handleChapterSelection(_ chapter: ChapterItem) {
        recordJumpSnapshotBeforeNavigation()
        userSelectedTocId = chapter.id
        if isComicBook, let index = Int(chapter.href) ?? Int(chapter.id) {
            progressManager?.handleNativePageSelected(index)
            return
        }
        if !tocEntries.isEmpty, chapter.id.hasPrefix("toc-"),
            let idx = Int(chapter.id.dropFirst(4)), idx < tocEntries.count
        {
            let entry = tocEntries[idx]
            let fragment = entry.href.components(separatedBy: "#").dropFirst().first

            if let fragment, let sectionId = bookStructure[safe: entry.sectionIndex]?.id {
                let fullHref = "\(sectionId)#\(fragment)"
                progressManager?.handleUserChapterSelectedWithHref(
                    entry.sectionIndex,
                    href: fullHref,
                )
            } else {
                progressManager?.handleUserChapterSelected(entry.sectionIndex)
            }
            return
        }
        handleChapterSelectionByHref(chapter.href)
    }

    func handleChapterSelectionByHref(_ href: String) {
        debugLog("[EbookPlayerViewModel] Chapter selected by href: \(href)")

        guard let chapterIndex = findSectionIndex(for: href, in: bookStructure) else {
            debugLog("[EbookPlayerViewModel] Chapter not found for href: \(href)")
            return
        }

        debugLog("[EbookPlayerViewModel] Found chapter at index: \(chapterIndex)")
        progressManager?.handleUserChapterSelected(chapterIndex)
    }

    func handlePrevChapter() {
        recordJumpSnapshotBeforeNavigation()
        userSelectedTocId = nil
        if isComicBook {
            progressManager?.handleNativeNavLeft()
            return
        }
        guard let currentIndex = progressManager?.selectedChapterId else {
            debugLog("[EbookPlayerViewModel] Cannot navigate - no chapter selected")
            return
        }

        let currentChapter = bookStructure[safe: currentIndex]
        let currentProgress = progressManager?.chapterSeekBarValue ?? 0.0
        let now = Date()

        let justRestarted =
            if let lastRestart = lastRestartTime {
                now.timeIntervalSince(lastRestart) < 2.0
            } else {
                false
            }

        if currentProgress > 0.01 && !justRestarted {
            debugLog(
                "[EbookPlayerViewModel] Restarting current chapter: \(currentChapter?.label ?? "nil") (was at \(Int(currentProgress * 100))%)"
            )
            handleProgressSeek(0.0)
            lastRestartTime = now
        } else if currentIndex > 0 {
            let prevChapter = bookStructure[safe: currentIndex - 1]
            debugLog(
                "[EbookPlayerViewModel] Navigating to previous chapter: \(prevChapter?.label ?? "nil")"
            )
            progressManager?.handleUserChapterSelected(currentIndex - 1)
            lastRestartTime = nil
        } else {
            debugLog("[EbookPlayerViewModel] Already at beginning of first chapter")
            handleProgressSeek(0.0)
            lastRestartTime = now
        }
    }

    func handleNextChapter() {
        recordJumpSnapshotBeforeNavigation()
        userSelectedTocId = nil
        if isComicBook {
            progressManager?.handleNativeNavRight()
            return
        }
        guard let currentIndex = progressManager?.selectedChapterId,
            currentIndex < bookStructure.count - 1
        else {
            debugLog(
                "[EbookPlayerViewModel] Cannot go to next chapter - at last chapter or no selection"
            )
            return
        }

        let nextChapter = bookStructure[safe: currentIndex + 1]
        debugLog(
            "[EbookPlayerViewModel] Navigating to next chapter: \(nextChapter?.label ?? "nil")"
        )
        progressManager?.handleUserChapterSelected(currentIndex + 1)
    }

    func handlePlaybackRateChange(_ rate: Double) {
        debugLog("[EbookPlayerViewModel] Received playback rate change to \(rate)")
        settingsVM.defaultPlaybackSpeed = rate
        mediaOverlayManager?.setPlaybackRate(rate)

        Task { @MainActor in
            do {
                try await settingsVM.save()
            } catch {
                debugLog("[EbookPlayerViewModel] Failed to save playback rate: \(error)")
            }
        }
    }

    func handleVolumeChange(_ newVolume: Double) {
        debugLog("[EbookPlayerViewModel] Received volume change to \(newVolume)")
        settingsVM.defaultVolume = newVolume
        mediaOverlayManager?.setVolume(newVolume)

        Task { @MainActor in
            do {
                try await settingsVM.save()
            } catch {
                debugLog("[EbookPlayerViewModel] Failed to save volume: \(error)")
            }
        }
    }

    func handleSleepTimerStart(_ duration: TimeInterval?, _ type: SleepTimerType) {
        debugLog(
            "[EbookPlayerViewModel] Starting sleep timer - type: \(type), duration: \(duration?.description ?? "N/A")"
        )
        mediaOverlayManager?.startSleepTimer(duration: duration, type: type)
    }

    func handleSleepTimerCancel() {
        debugLog("[EbookPlayerViewModel] Cancelling sleep timer")
        mediaOverlayManager?.cancelSleepTimer()
    }

    func handleToggleOverlay() {
        #if os(iOS)
        sendChrome(.centerTap(alwaysShowMiniPlayer: settingsVM.alwaysShowMiniPlayer))
        debugLog(
            "[EbookPlayerViewModel] Center tap - top: \(isTopBarVisible), bottom: \(isReadingBarVisible)"
        )
        #endif
    }

    #if os(iOS)
    /// Comics keep the legacy tap-toggle chrome.
    var effectiveControlsMode: ReaderControlsMode {
        isComicBook ? .classic : settingsVM.readerControlsMode
    }

    var isChromeModalPresented: Bool {
        showCustomizePopover || showSearchPanel || showBookmarksPanel || showTranslation
            || showServerPositionDialog || pendingSelection != nil || pendingEditHighlight != nil
            || !presentedChromeSheets.isEmpty
    }

    func sendChrome(_ event: ReaderChromeEvent) {
        let before = chrome.state
        chrome.send(event)
        let after = chrome.state
        // Legacy Always Show: hiding the toolbar also collapses the pinned card.
        if before.isTopVisible && !after.isTopVisible
            && after.cardAlwaysShows(
                alwaysShowMiniPlayer: settingsVM.alwaysShowMiniPlayer,
                hasAudioNarration: hasAudioNarration
            )
        {
            collapseCardTrigger += 1
        }
        if before.mode != after.mode || before.isSelectionMode != after.isSelectionMode {
            pushReaderControlsToJS()
        }
    }

    func noteChromeActivity() {
        sendChrome(.userActivity)
    }

    /// Applies the persisted mode once settings load, and again when it changes.
    func applyControlsMode() {
        guard settingsVM.isLoaded else { return }
        let mode = effectiveControlsMode
        sendChrome(.setMode(mode))
        // Also covers the first load: an unchanged default mode sends no event.
        pushReaderControlsToJS()
        let previous = lastAppliedControlsMode
        lastAppliedControlsMode = mode
        if let open = ReaderSidebarPolicy.sidebarOnModeChange(
            from: previous,
            to: mode,
            storedPreference: UserDefaults.standard.object(
                forKey: "EbookPlayerShowAudioSidebarIOS"
            ) as? Bool
        ) {
            showAudioSidebar = open
        }
    }

    func toggleSelectTextMode() {
        sendChrome(.setBlocker(.selectionMode, !isSelectTextMode))
    }

    func reportChromeSheet(_ id: UUID, presented: Bool) {
        if presented {
            presentedChromeSheets.insert(id)
        } else {
            presentedChromeSheets.remove(id)
        }
    }

    func setCardChromeBlockers(_ blockers: Set<ReaderChromeBlocker>) {
        for blocker in [ReaderChromeBlocker.cardExpanded, .cardDrag, .scrubbing] {
            sendChrome(.setBlocker(blocker, blockers.contains(blocker)))
        }
    }

    /// Before settings load nothing is sent, so JS stays on legacy behavior
    /// (Classic readers never get a stray selection lock); `applyControlsMode`
    /// pushes as soon as they load.
    private func pushReaderControlsToJS(to target: ReaderCommsBridge? = nil) {
        guard settingsVM.isLoaded, !isComicBook, let bridge = target ?? commsBridge else { return }
        let state = chrome.state
        let immersive = state.mode == .immersive
        bridge.setReaderControlsForPageLoads(immersive: immersive)
        Task { @MainActor in
            do {
                let result = try await bridge.sendJsSetReaderControls(
                    immersive: immersive,
                    selectionMode: state.isSelectionMode
                )
                debugLog("[EbookPlayerViewModel] Reader controls pushed: \(result ?? "nil")")
            } catch {
                debugLog("[EbookPlayerViewModel] Reader controls push failed: \(error)")
            }
        }
    }
    #endif

    func handleNextSentence() {
        mediaOverlayManager?.nextSentence()
    }

    func handlePrevSentence() {
        mediaOverlayManager?.prevSentence()
    }

    func beginScrubSession() {
        if !isScrubJumpSessionActive {
            recordJumpSnapshotBeforeNavigation()
            isScrubJumpSessionActive = true
        }
        jumpPillAutoDismissTask?.cancel()
    }

    func handleProgressSeek(_ fraction: Double) {
        if !isScrubJumpSessionActive {
            recordJumpSnapshotBeforeNavigation()
        }
        isScrubJumpSessionActive = false
        scheduleJumpPillAutoDismiss()
        if isComicBook {
            progressManager?.handleNativeProgressSeek(fraction)
        } else {
            progressManager?.handleUserProgressSeek(fraction)
        }
    }

    func handleBookProgressSeek(_ fraction: Double) {
        if !isScrubJumpSessionActive {
            recordJumpSnapshotBeforeNavigation()
        }
        isScrubJumpSessionActive = false
        scheduleJumpPillAutoDismiss()
        if isComicBook {
            progressManager?.handleNativeProgressSeek(fraction)
        } else {
            progressManager?.handleUserBookProgressSeek(fraction)
        }
    }

    func recordJumpSnapshotBeforeNavigation(isForwardTarget: Bool = false) {
        guard let pm = progressManager else { return }
        let sectionIndex = pm.selectedChapterId
        let chapterTitle = sectionIndex.flatMap { bookStructure[safe: $0]?.label }
        let candidate = ReaderScrubberPolicy.JumpSnapshot(
            sectionIndex: sectionIndex,
            cfi: pm.currentCfi,
            href: pm.currentHref ?? sectionIndex.flatMap { bookStructure[safe: $0]?.id },
            chapterFraction: pm.chapterSeekBarValue,
            bookFraction: pm.bookFraction,
            pageNumber: pm.chapterCurrentPage,
            totalPages: pm.chapterTotalPages,
            chapterTitle: chapterTitle,
            isForwardTarget: isForwardTarget
        )
        guard candidate.sectionIndex != nil || candidate.bookFraction != nil || candidate.cfi != nil
        else {
            return
        }
        userFlipsSinceJump = 0
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            jumpSnapshot = candidate
        }
        scheduleJumpPillAutoDismiss()
    }

    func dismissJumpSnapshot() {
        jumpPillAutoDismissTask?.cancel()
        jumpPillAutoDismissTask = nil
        isScrubJumpSessionActive = false
        userFlipsSinceJump = 0
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            jumpSnapshot = nil
        }
    }

    func returnToJumpSnapshot() {
        guard let target = jumpSnapshot else { return }
        ReaderHaptics.jumpNavigation()

        // Capture the current position as the opposite direction so the user can bounce back if desired.
        recordJumpSnapshotBeforeNavigation(isForwardTarget: !target.isForwardTarget)

        if isComicBook, let page = target.pageNumber, page > 0 {
            progressManager?.handleNativePageSelected(page - 1)
            return
        }

        Task { @MainActor in
            progressManager?.prepareForDirectJump(targetSection: target.sectionIndex)
            if let cfi = target.cfi, !cfi.isEmpty, let bridge = commsBridge {
                do {
                    try await bridge.sendJsGoToCFICommand(cfi: cfi)
                    return
                } catch {
                    debugLog("[EbookPlayerViewModel] Jump-back CFI failed, falling back: \(error)")
                }
            }
            if let section = target.sectionIndex, let bridge = commsBridge {
                do {
                    try await bridge.sendJsGoToFractionInSectionCommand(
                        sectionIndex: section,
                        fraction: target.chapterFraction
                    )
                    return
                } catch {
                    debugLog(
                        "[EbookPlayerViewModel] Jump-back section fraction failed, falling back: \(error)"
                    )
                }
            }
            if let bookFrac = target.bookFraction {
                progressManager?.handleUserBookProgressSeek(bookFrac)
            }
        }
    }

    private func scheduleJumpPillAutoDismiss() {
        jumpPillAutoDismissTask?.cancel()
        jumpPillAutoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self else { return }
            self.dismissJumpSnapshot()
        }
    }

    func handleColorSchemeChange(_ colorScheme: ColorScheme) {
        settingsVM.applyActiveTheme(for: colorScheme)
        styleManager?.handleDarkModeChange(colorScheme == .dark)
    }

    func handleAppBackgrounding() async {
        debugLog(
            "[EbookPlayerViewModel] App backgrounding - syncing progress (audio continues in background)"
        )

        await progressManager?.syncProgressToServer(reason: .appBackgrounding)

        debugLog("[EbookPlayerViewModel] Background sync complete")
    }

    func handleOnAppear() {
        #if os(iOS)
        recoveryManager = WebViewRecoveryManager(viewModel: self)
        // Re-arm the idle window cancelled by a previous disappear.
        noteChromeActivity()
        #endif

        if let data = bookData {
            let session = ReadingSessionStore.shared.obtain(
                metadata: data.metadata,
                category: data.category,
                localMediaPath: data.localMediaPath,
                settings: settingsVM,
            )
            self.session = session
            configureSessionHooks(session)
            session.prepare()
        }
    }

    private func configureSessionHooks(_ session: ReadingSession) {
        session.onComicPrepared = { [weak self] url in
            self?.prepareComicPages(from: url)
        }
        session.onUserNavigation = { [weak self] in
            guard let self else { return }
            self.userSelectedTocId = nil
            if self.jumpSnapshot != nil && !self.isScrubJumpSessionActive {
                self.userFlipsSinceJump += 1
                if self.userFlipsSinceJump >= 2 {
                    self.dismissJumpSnapshot()
                }
            }
        }
        #if os(iOS)
        session.isViewRecovering = { [weak self] in
            self?.recoveryManager?.isInRecovery == true
        }
        session.onRecoveryStructureReady = { [weak self] in
            _ = self?.recoveryManager?.handleBookStructureReadyIfRecovering()
        }
        #endif
        session.configureMediaOverlayManager = { [weak self] manager in
            guard let self else { return }
            manager.setWakeLock = { ScreenWakeLock.shared.set($0) }
            manager.setPlaybackRate(self.settingsVM.defaultPlaybackSpeed)
        }
        session.onReadaloudAvailabilityChanged = { [weak self] available in
            self?.styleManager?.setReadaloudModeAvailable(available)
        }
        session.onViewStructureReady = { [weak self] in
            guard let self else { return }
            self.progressManager?.onChapterBoundaryCrossed = { _, _ in
                Task { @MainActor in
                    ReaderHaptics.chapterBoundaryCrossed()
                }
            }
            self.settingsVM.applyActiveTheme(for: self.bridgeInitialColorScheme)
            self.styleManager?.sendInitialStyles(
                isDarkMode: self.bridgeInitialColorScheme == .dark
            )
            await self.loadHighlights()
            #if os(iOS)
            self.pushReaderControlsToJS()
            self.isReaderContentReady = true
            #endif
        }
        session.onIncomingServerPosition = { [weak self] position in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.settingsVM.autoSyncToNewerServerPosition {
                    await self.navigateToServerPosition(position.locator)
                } else {
                    self.pendingServerPosition = position
                    self.showServerPositionDialog = true
                }
            }
        }
    }

    private func prepareComicPages(from extractedDirectory: URL) {
        let urls = Self.comicImageURLs(in: extractedDirectory)
        comicPageURLs = urls
        comicBookStructure = urls.enumerated().map { index, url in
            SectionInfo(
                index: index,
                id: "\(index)",
                label: "Page \(index + 1)",
                level: 0,
                mediaOverlay: [],
            )
        }
        session?.hasAudioNarration = false
        searchManager = nil
        styleManager = nil
        let pinned = session?.pinnedFormatSwitchHandoff
        let manager = EphemeralProgressManager(
            bridge: nil,
            settingsVM: settingsVM,
            bookID: bookData?.metadata.id,
            initialLocator: pinned?.locator ?? bookData?.metadata.position?.locator,
            formatSwitchHandoff: pinned,
        )
        manager.bookStructure = comicBookStructure
        manager.bookTitle = bookData?.metadata.title
        manager.bookAuthor = bookData?.metadata.authors?.first?.name
        manager.handleNativeBookStructureReady(pageCount: urls.count)
        comicProgressManager = manager
        session?.clearPinnedFormatSwitchHandoff()

        Task { @MainActor in
            let syncInterval = await SettingsActor.shared.config.sync.progressSyncIntervalSeconds
            self.comicProgressManager?.startPeriodicSync(syncInterval: syncInterval)
        }
    }

    private static func comicImageURLs(in directory: URL) -> [URL] {
        let allowedExtensions: Set<String> = [
            "jpg", "jpeg", "png", "gif", "bmp", "webp", "svg", "jxl", "avif",
        ]
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
            )
        else {
            return []
        }

        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL else { return nil }
            let ext = url.pathExtension.lowercased()
            guard allowedExtensions.contains(ext) else { return nil }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == false ? nil : url
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func handleComicPageSelected(_ index: Int) {
        userSelectedTocId = nil
        progressManager?.handleNativePageSelected(index)
    }

    func navigateToServerPosition(_ locator: BookLocator) async {
        debugLog("[EbookPlayerViewModel] Navigating to server position: \(locator.href)")
        progressManager?.handleServerPositionUpdate(locator)
    }

    func acceptServerPosition() {
        guard let position = pendingServerPosition else { return }
        Task {
            await navigateToServerPosition(position.locator)
        }
        pendingServerPosition = nil
        showServerPositionDialog = false
    }

    func declineServerPosition() {
        pendingServerPosition = nil
        showServerPositionDialog = false
    }

    func handleOnDisappear(close policy: ReadingSessionClosePolicy? = .endSession) {
        debugLog("[EbookPlayerViewModel] View disappearing (policy: \(String(describing: policy)))")
        #if os(iOS)
        chrome.invalidate()
        #endif

        session?.removeIncomingPositionObserver()

        guard let policy else {
            debugLog("[EbookPlayerViewModel] Background disappear - preserving SMIL playback")
            return
        }

        Task { @MainActor in
            if policy == .endSession {
                await comicProgressManager?.cleanup()
            }
            await session?.close(policy)
        }
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
            case .active:
                #if os(iOS)
                sendChrome(.setForeground(true))
                #endif
                Task { @MainActor in
                    await progressManager?.handleResume()
                    await session?.handleSceneBecameActive()
                }
            case .background:
                #if os(iOS)
                sendChrome(.setForeground(false))
                #endif
                debugLog("[EbookPlayerViewModel] Entering background - audio continues natively")
                Task { @MainActor in
                    await session?.handleSceneEnteredBackground()
                }
            case .inactive:
                break
            @unknown default:
                break
        }
    }

    func installBridgeHandlers(_ bridge: ReaderCommsBridge, initialColorScheme: ColorScheme) {
        debugLog("[EbookPlayerViewModel] Installing bridge handlers")
        bridgeInitialColorScheme = initialColorScheme

        #if os(iOS)
        recoveryManager?.setBridge(bridge)

        if recoveryManager?.isInRecovery == true {
            debugLog(
                "[EbookPlayerViewModel] Recovery mode - updating existing managers with new bridge"
            )
            session?.attachBridge(bridge, isRecovery: true)
            styleManager?.updateBridge(bridge)
            searchManager = EbookSearchManager(bridge: bridge)
            setupBridgeCallbacks(bridge)
            return
        }
        #endif

        session?.attachBridge(bridge, isRecovery: false)

        searchManager = EbookSearchManager(bridge: bridge)
        debugLog("[EbookPlayerViewModel] SearchManager initialized")

        styleManager = ReaderStyleManager(
            settingsVM: settingsVM,
            bridge: bridge,
        )
        #if os(iOS)
        styleManager?.setSpreadMode(isSpreadLayout)
        #endif

        setupBridgeCallbacks(bridge)
    }

    private func setupBridgeCallbacks(_ bridge: ReaderCommsBridge) {

        bridge.onOverlayToggled = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.handleToggleOverlay()
            }
        }

        bridge.onPageCurlChrome = { [weak self] active in
            guard let self else { return }
            Task { @MainActor in
                #if os(iOS)
                if self.isPageCurlActive != active {
                    self.sendChrome(.setCurlActive(active))
                    debugLog(
                        "[EbookPlayerViewModel] Page curl chrome suppress active=\(active)"
                    )
                }
                #endif
            }
        }

        #if os(iOS)
        // A recovered WebView never sends the curl-ended message for the old page.
        if isPageCurlActive {
            sendChrome(.setCurlActive(false))
        }

        // Before the reader HTML loads (first open and recovery alike), so the
        // first section attaches with the current controls state.
        pushReaderControlsToJS(to: bridge)

        bridge.onReaderChromeReveal = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.sendChrome(.reveal)
            }
        }

        // Session owns margin navigation; immersive chrome also dismisses on it.
        let sessionMarginClickNav = bridge.onMarginClickNav
        bridge.onMarginClickNav = { [weak self] message in
            sessionMarginClickNav?(message)
            guard let self else { return }
            Task { @MainActor in
                self.sendChrome(.marginTap)
            }
        }
        #endif

        bridge.onTextSelected = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                self.handleTextSelectionComplete(message)
            }
        }

        bridge.onSelectionHighlight = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                let color = HighlightColor(rawValue: message.colorId)
                await self.addHighlight(from: message.selection, color: color)
                self.rememberLastUsedColor(message.colorId)
            }
        }

        bridge.onHighlightSetColor = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                await self.handleHighlightSetColor(id: message.id, colorId: message.colorId)
                self.rememberLastUsedColor(message.colorId)
            }
        }

        bridge.onHighlightDelete = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                await self.handleHighlightDelete(id: message.id)
            }
        }

        bridge.onHighlightEdit = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in
                self.handleHighlightEdit(id: message.id)
            }
        }

        bridge.onSelectionTranslate = { [weak self] text in
            guard let self else { return }
            Task { @MainActor in
                self.translationText = text
                self.showTranslation = true
            }
        }

        bridge.onSelectionSearch = { [weak self] text in
            guard let self else { return }
            Task { @MainActor in
                self.searchManager?.searchQuery = text
                #if os(macOS)
                // The search popover anchors to the toolbar magnifier, which is
                // hidden until the title bar reveals. Reveal it first; the panel
                // is presented once the toolbar is on-screen (handleTitleBarApplied).
                self.pendingSearchReveal = true
                #else
                self.showSearchPanel = true
                await self.searchManager?.startSearch(query: text)
                #endif
            }
        }
    }

    #if os(macOS)
    /// Defers the search popover until the toolbar anchor is on-screen, avoiding a flicker.
    func handleTitleBarApplied() {
        guard pendingSearchReveal, !showSearchPanel else { return }
        pendingSearchReveal = false
        showSearchPanel = true
        let query = searchManager?.searchQuery ?? ""
        Task { await searchManager?.startSearch(query: query) }
    }
    #endif

    /// Navigate to search result - view only, no audio sync
    func handleSearchResultNavigation(_ result: SearchResult) {
        recordJumpSnapshotBeforeNavigation()
        Task { @MainActor in
            await searchManager?.navigateToResult(result)
        }
    }

    func loadHighlights() async {
        guard let bookID = bookData?.metadata.id else { return }

        highlights = await BookmarkActor.shared.getHighlights(bookID: bookID)
        debugLog("[EbookPlayerViewModel] Loaded \(highlights.count) highlights for book \(bookID)")

        await sendHighlightsToJS()
    }

    func addHighlight(
        from selection: TextSelectionMessage,
        color: HighlightColor?,
        note: String? = nil,
    ) async {
        guard let bookID = bookData?.metadata.id else { return }

        let locator = BookLocator(
            href: selection.href,
            type: "application/xhtml+xml",
            title: selection.title,
            locations: BookLocator.Locations(
                fragments: [selection.cfi],
                progression: progressManager?.chapterSeekBarValue,
                position: nil,
                totalProgression: progressManager?.bookFraction,
                cssSelector: selection.startCssSelector,
                partialCfi: selection.cfi,
                domRange: BookLocator.Locations.DomRange(
                    start: BookLocator.Locations.DomRangeBoundary(
                        cssSelector: selection.startCssSelector,
                        textNodeIndex: selection.startTextNodeIndex,
                        charOffset: selection.startCharOffset,
                    ),
                    end: BookLocator.Locations.DomRangeBoundary(
                        cssSelector: selection.endCssSelector,
                        textNodeIndex: selection.endTextNodeIndex,
                        charOffset: selection.endCharOffset,
                    ),
                ),
            ),
            text: BookLocator.Text(
                after: nil,
                before: nil,
                highlight: selection.text,
            ),
        )

        let highlight = Highlight(
            bookID: bookID,
            locator: locator,
            text: selection.text,
            color: color,
            note: note,
        )

        await BookmarkActor.shared.addHighlight(highlight)
        highlights = await BookmarkActor.shared.getHighlights(bookID: bookID)

        pendingSelection = nil

        await sendHighlightsToJS()

        debugLog("[EbookPlayerViewModel] Added highlight: isBookmark=\(highlight.isBookmark)")
    }

    func deleteHighlight(_ highlight: Highlight) async {
        guard let bookID = bookData?.metadata.id else { return }

        await BookmarkActor.shared.deleteHighlight(id: highlight.id, bookID: bookID)
        highlights = await BookmarkActor.shared.getHighlights(bookID: bookID)

        if let bridge = commsBridge {
            do {
                try await bridge.sendJsRemoveHighlight(id: highlight.id.uuidString)
            } catch {
                debugLog("[EbookPlayerViewModel] Failed to remove highlight from JS: \(error)")
            }
        }

        debugLog("[EbookPlayerViewModel] Deleted highlight: \(highlight.id)")
    }

    func navigateToHighlight(_ highlight: Highlight) async {
        guard let bridge = commsBridge else { return }
        recordJumpSnapshotBeforeNavigation()
        progressManager?.prepareForDirectJump(
            targetSection: findSectionIndex(for: highlight.locator.href, in: bookStructure)
        )

        if let cfi = highlight.locator.locations?.partialCfi {
            do {
                try await bridge.sendJsGoToCFICommand(cfi: cfi)
                debugLog("[EbookPlayerViewModel] Navigated to highlight CFI: \(cfi)")
            } catch {
                debugLog("[EbookPlayerViewModel] Failed to navigate to highlight: \(error)")
            }
        } else {
            var href = highlight.locator.href
            if let fragment = highlight.locator.locations?.fragments?.first {
                href = "\(href)#\(fragment)"
            }
            do {
                try await bridge.sendJsGoToHrefCommand(href: href)
                debugLog("[EbookPlayerViewModel] Navigated to highlight href: \(href)")
            } catch {
                debugLog("[EbookPlayerViewModel] Failed to navigate to highlight: \(error)")
            }
        }
    }

    func refreshHighlightColors() async {
        await sendHighlightsToJS()
    }

    private func sendHighlightPaletteToJS() async {
        guard let bridge = commsBridge else { return }

        let entries = HighlightColor.allCases.map { color in
            HighlightPaletteEntry(
                id: color.rawValue,
                color: settingsVM.hexColor(for: color),
                label: settingsVM.label(for: color),
            )
        }

        let translateAvailable: Bool
        if #available(iOS 17.4, macOS 14.4, *) {
            translateAvailable = true
        } else {
            translateAvailable = false
        }

        do {
            try await bridge.sendJsSetHighlightPalette(entries)
            try await bridge.sendJsSetTranslateAvailable(translateAvailable)
            try await bridge.sendJsSetDefaultHighlightColor(lastUsedHighlightColorId)
        } catch {
            debugLog("[EbookPlayerViewModel] Failed to send highlight palette to JS: \(error)")
        }
    }

    private static let lastUsedHighlightColorKey = "lastUsedHighlightColorId"

    var lastUsedHighlightColorId: String {
        get {
            UserDefaults.standard.string(forKey: Self.lastUsedHighlightColorKey)
                ?? HighlightColor.allCases.first!.rawValue
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastUsedHighlightColorKey) }
    }

    private func rememberLastUsedColor(_ colorId: String) {
        guard HighlightColor(rawValue: colorId) != nil else { return }
        guard colorId != lastUsedHighlightColorId else { return }
        lastUsedHighlightColorId = colorId
        Task { try? await commsBridge?.sendJsSetDefaultHighlightColor(colorId) }
    }

    private func sendHighlightsToJS() async {
        guard let bridge = commsBridge else { return }

        await sendHighlightPaletteToJS()

        let coloredOnly = highlights.filter { !$0.isBookmark }
        let renderData = coloredOnly.compactMap { highlight -> HighlightRenderData? in
            guard let cfi = highlight.locator.locations?.partialCfi,
                let color = highlight.color
            else { return nil }

            guard
                let sectionIndex = findSectionIndex(
                    for: highlight.locator.href,
                    in: bookStructure,
                )
            else { return nil }

            return HighlightRenderData(
                id: highlight.id.uuidString,
                sectionIndex: sectionIndex,
                cfi: cfi,
                color: settingsVM.hexColor(for: color),
            )
        }

        do {
            try await bridge.sendJsRenderHighlights(renderData)
            debugLog("[EbookPlayerViewModel] Sent \(renderData.count) highlights to JS")
        } catch {
            debugLog("[EbookPlayerViewModel] Failed to send highlights to JS: \(error)")
        }
    }

    func handleTextSelectionComplete(_ message: TextSelectionMessage) {
        debugLog("[EbookPlayerViewModel] Text selection complete: \(message.text.prefix(50))...")
        pendingSelection = message
    }

    func handleHighlightSetColor(id: String, colorId: String) async {
        guard let bookID = bookData?.metadata.id,
            let uuid = UUID(uuidString: id),
            let existing = highlights.first(where: { $0.id == uuid }),
            let color = HighlightColor(rawValue: colorId)
        else { return }

        let updated = Highlight(
            id: existing.id,
            bookID: existing.bookID,
            locator: existing.locator,
            text: existing.text,
            color: color,
            note: existing.note,
            createdAt: existing.createdAt,
        )

        await BookmarkActor.shared.updateHighlight(updated)
        highlights = await BookmarkActor.shared.getHighlights(bookID: bookID)
        await sendHighlightsToJS()
        rememberLastUsedColor(colorId)
    }

    func handleHighlightDelete(id: String) async {
        guard let uuid = UUID(uuidString: id),
            let existing = highlights.first(where: { $0.id == uuid })
        else { return }
        await deleteHighlight(existing)
    }

    func handleHighlightEdit(id: String) {
        guard let uuid = UUID(uuidString: id),
            let existing = highlights.first(where: { $0.id == uuid })
        else { return }
        pendingEditHighlight = existing
    }

    func saveEditedHighlight(_ original: Highlight, color: HighlightColor?, note: String?) async {
        guard let bookID = bookData?.metadata.id else { return }
        let updated = Highlight(
            id: original.id,
            bookID: original.bookID,
            locator: original.locator,
            text: original.text,
            color: color,
            note: note,
            createdAt: original.createdAt,
        )
        await BookmarkActor.shared.updateHighlight(updated)
        highlights = await BookmarkActor.shared.getHighlights(bookID: bookID)
        await sendHighlightsToJS()
        pendingEditHighlight = nil
    }

    func cancelPendingSelection() {
        pendingSelection = nil
    }

    func cancelPendingEdit() {
        pendingEditHighlight = nil
    }

    func addBookmarkAtCurrentPage() async {
        guard let bookID = bookData?.metadata.id else {
            debugLog("[EbookPlayerViewModel] Cannot add bookmark - missing book ID")
            return
        }

        guard let position = try? await commsBridge?.sendJsGetFirstVisiblePosition() else {
            debugLog(
                "[EbookPlayerViewModel] Cannot add bookmark - failed to get visible position from JS"
            )
            return
        }

        let locator = BookLocator(
            href: position.href,
            type: "application/xhtml+xml",
            title: position.title,
            locations: BookLocator.Locations(
                fragments: position.elementId.map { [$0] },
                progression: progressManager?.chapterSeekBarValue,
                position: nil,
                totalProgression: progressManager?.bookFraction,
                cssSelector: nil,
                partialCfi: position.cfi,
                domRange: nil,
            ),
            text: nil,
        )

        let highlight = Highlight(
            bookID: bookID,
            locator: locator,
            text: position.text,
            color: nil,
            note: nil,
        )

        await BookmarkActor.shared.addHighlight(highlight)
        highlights = await BookmarkActor.shared.getHighlights(bookID: bookID)

        debugLog("[EbookPlayerViewModel] Added bookmark: \(position.text.prefix(50))...")
    }

    func toggleBookmarkAtCurrentPage() async {
        if let existing = currentPageBookmark {
            ReaderHaptics.bookmarkToggled(added: false)
            await deleteHighlight(existing)
        } else {
            ReaderHaptics.bookmarkToggled(added: true)
            await addBookmarkAtCurrentPage()
        }
    }
}

#endif
