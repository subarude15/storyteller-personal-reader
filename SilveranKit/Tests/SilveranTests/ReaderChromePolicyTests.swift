import Foundation
import SilveranKit
import Testing

@Suite("Immersive reader chrome policy")
struct ReaderChromePolicyTests {
    private func immersive() -> ReaderChromeState {
        ReaderChromeState(mode: .immersive)
    }

    @Test func modeDecodingDefaultsToImmersive() {
        #expect(ReaderControlsMode(storedValue: nil) == .immersive)
        #expect(ReaderControlsMode(storedValue: "bogus") == .immersive)
        #expect(ReaderControlsMode(storedValue: "classic") == .classic)
        #expect(ReaderControlsMode(storedValue: "immersive") == .immersive)
    }

    /// Reader settings "Reset to Defaults" assigns `ReaderControlsMode(storedValue: kDefaultReaderControlsMode)`.
    @Test func resetDefaultModeIsImmersive() {
        #expect(ReaderControlsMode(storedValue: kDefaultReaderControlsMode) == .immersive)
        #expect(SilveranGlobalConfig.ReadingBar().controlsMode == kDefaultReaderControlsMode)
    }

    @Test func readingBarPersistsControlsModeBackwardCompatibly() throws {
        let legacy = Data(#"{"alwaysShowMiniPlayer":true}"#.utf8)
        let decoded = try JSONDecoder().decode(SilveranGlobalConfig.ReadingBar.self, from: legacy)
        #expect(decoded.controlsMode == "immersive")
        #expect(decoded.alwaysShowMiniPlayer)

        var bar = SilveranGlobalConfig.ReadingBar()
        bar.controlsMode = ReaderControlsMode.classic.rawValue
        let roundTrip = try JSONDecoder().decode(
            SilveranGlobalConfig.ReadingBar.self, from: JSONEncoder().encode(bar))
        #expect(ReaderControlsMode(storedValue: roundTrip.controlsMode) == .classic)
    }

    @Test func immersiveStartsHiddenClassicStartsVisible() {
        let state = immersive()
        #expect(!state.isTopVisible && !state.isBottomVisible)
        #expect(!state.showsTopBar)
        #expect(!state.showsBottomCard(alwaysShowMiniPlayer: false, hasAudioNarration: true))

        let classic = ReaderChromeState(mode: .classic)
        #expect(classic.isTopVisible && classic.isBottomVisible)
    }

    @Test func holdRevealsBothAndCenterTapHides() {
        var state = immersive()
        state.apply(.reveal)
        #expect(state.isTopVisible && state.isBottomVisible)
        #expect(state.autoHideEligible)
        state.apply(.centerTap(alwaysShowMiniPlayer: false))
        #expect(!state.isTopVisible && !state.isBottomVisible)
        state.apply(.centerTap(alwaysShowMiniPlayer: false))
        #expect(!state.isTopVisible, "center tap never reveals in immersive; hold does")
    }

    @Test func marginTapDismissesInImmersiveOnly() {
        var state = immersive()
        state.apply(.reveal)
        state.apply(.marginTap)
        #expect(!state.isRevealed)

        var classic = ReaderChromeState(mode: .classic)
        classic.apply(.marginTap)
        #expect(classic.isTopVisible && classic.isBottomVisible, "Classic margin taps keep legacy chrome")
    }

    @Test func idleTimeoutHonoursGeneration() {
        var state = immersive()
        state.apply(.reveal)
        let stale = state.idleGeneration
        state.apply(.userActivity)
        state.apply(.idleTimeout(generation: stale))
        #expect(state.isRevealed, "stale timeout cannot hide after fresh activity")
        state.apply(.idleTimeout(generation: state.idleGeneration))
        #expect(!state.isRevealed)
    }

    @Test func blockersPreventAutoHideAndRestartTimerWhenCleared() {
        for blocker in [ReaderChromeBlocker.scrubbing, .cardDrag, .cardExpanded, .modal, .selectionMode] {
            var state = immersive()
            state.apply(.reveal)
            let before = state.idleGeneration
            state.apply(.setBlocker(blocker, true))
            #expect(!state.autoHideEligible, "\(blocker) blocks auto-hide")
            state.apply(.idleTimeout(generation: state.idleGeneration))
            #expect(state.isRevealed, "\(blocker) keeps chrome through a due timeout")
            state.apply(.setBlocker(blocker, false))
            #expect(state.autoHideEligible)
            #expect(state.idleGeneration > before, "fresh timeout after \(blocker) ends")
        }
    }

    @Test func voiceOverAndBackgroundSuspendAutoHide() {
        var state = immersive()
        state.apply(.setVoiceOver(true))
        #expect(state.isRevealed, "VoiceOver gets visible controls without a hold")
        #expect(!state.autoHideEligible)
        state.apply(.hide)
        #expect(!state.isRevealed, "explicit Hide reader controls works under VoiceOver")
        state.apply(.reveal)
        state.apply(.setVoiceOver(false))
        #expect(state.autoHideEligible)
        state.apply(.setForeground(false))
        #expect(!state.autoHideEligible)
        let generation = state.idleGeneration
        state.apply(.setForeground(true))
        #expect(state.autoHideEligible && state.idleGeneration > generation)
    }

    @Test func curlMasksPresentationButNeverResurrectsExpiredChrome() {
        var state = immersive()
        state.apply(.reveal)
        state.apply(.setCurlActive(true))
        #expect(!state.showsTopBar)
        #expect(state.autoHideEligible, "idle clock keeps running under curl")
        state.apply(.idleTimeout(generation: state.idleGeneration))
        state.apply(.setCurlActive(false))
        #expect(!state.showsTopBar, "curl end does not bring back chrome that expired")

        state.apply(.reveal)
        state.apply(.setCurlActive(true))
        state.apply(.setCurlActive(false))
        #expect(state.showsTopBar, "curl end restores still-live chrome")
    }

    @Test func narrationPinOnlyAppliesToReadAlouds() {
        let state = immersive()
        #expect(state.showsBottomCard(alwaysShowMiniPlayer: true, hasAudioNarration: true))
        #expect(!state.showsBottomCard(alwaysShowMiniPlayer: true, hasAudioNarration: false),
                "pure ebook scrubber is never pinned in immersive")
        #expect(!state.showsBottomCard(alwaysShowMiniPlayer: false, hasAudioNarration: true))

        let classic = ReaderChromeState(mode: .classic)
        #expect(classic.cardAlwaysShows(alwaysShowMiniPlayer: true, hasAudioNarration: false),
                "Classic keeps the legacy Always Show behavior")
    }

    @Test func selectionModeIsImmersiveOnlyAndKeepsToolbar() {
        var state = immersive()
        state.apply(.setBlocker(.selectionMode, true))
        #expect(state.isSelectionMode && state.isTopVisible)
        state.apply(.centerTap(alwaysShowMiniPlayer: false))
        state.apply(.marginTap)
        state.apply(.hide)
        #expect(state.isTopVisible, "only Done leaves Select Text")
        state.apply(.setBlocker(.selectionMode, false))
        #expect(state.autoHideEligible)

        var classic = ReaderChromeState(mode: .classic)
        classic.apply(.setBlocker(.selectionMode, true))
        #expect(!classic.isSelectionMode, "Classic uses native long-press selection")
    }

    @Test func classicCenterTapMatchesLegacyToggle() {
        var state = ReaderChromeState(mode: .classic)
        state.apply(.centerTap(alwaysShowMiniPlayer: false))
        #expect(!state.isTopVisible && !state.isBottomVisible)
        state.apply(.centerTap(alwaysShowMiniPlayer: false))
        #expect(state.isTopVisible && state.isBottomVisible)

        state.apply(.centerTap(alwaysShowMiniPlayer: true))
        #expect(!state.isTopVisible && state.isBottomVisible, "Always Show toggles only the top bar")
        #expect(!state.autoHideEligible, "Classic never auto-hides")
    }

    @Test func switchingModes() {
        var state = immersive()
        state.apply(.setBlocker(.selectionMode, true))
        state.apply(.setMode(.classic))
        #expect(state.mode == .classic && !state.isSelectionMode)
        #expect(state.isTopVisible && state.isBottomVisible)
        state.apply(.setMode(.immersive))
        #expect(state.autoHideEligible, "switching back starts a fresh idle window")
    }

    @Test func cardDismissHidesChrome() {
        var state = immersive()
        state.apply(.reveal)
        state.apply(.cardDismissed)
        #expect(!state.isRevealed)

        var classic = ReaderChromeState(mode: .classic)
        classic.apply(.cardDismissed)
        #expect(classic.isTopVisible && !classic.isBottomVisible, "legacy swipe-down hides only the card")
    }

    @Test func hintIsVersionedAndImmersiveOnly() {
        #expect(ReaderControlsHint.shouldShow(mode: .immersive, isReaderReady: true, acknowledgedVersion: 0))
        #expect(!ReaderControlsHint.shouldShow(mode: .immersive, isReaderReady: false, acknowledgedVersion: 0))
        #expect(!ReaderControlsHint.shouldShow(
            mode: .immersive, isReaderReady: true, acknowledgedVersion: ReaderControlsHint.currentVersion))
        #expect(!ReaderControlsHint.shouldShow(mode: .classic, isReaderReady: true, acknowledgedVersion: 0))
    }

    @Test func narrationOverlayIsClassicOnlyAndKeepsLegacyRule() {
        var state = immersive()
        #expect(!state.showsNarrationOverlay(hasAudioNarration: true, isSidebarOpen: false),
                "immersive readaloud: no time/transport overlay while hidden")
        state.apply(.reveal)
        #expect(!state.showsNarrationOverlay(hasAudioNarration: true, isSidebarOpen: false))

        var classic = ReaderChromeState(mode: .classic)
        #expect(!classic.showsNarrationOverlay(hasAudioNarration: true, isSidebarOpen: false),
                "legacy: overlay only while the toolbar is hidden")
        classic.apply(.centerTap(alwaysShowMiniPlayer: false))
        #expect(classic.showsNarrationOverlay(hasAudioNarration: true, isSidebarOpen: false))
        #expect(!classic.showsNarrationOverlay(hasAudioNarration: false, isSidebarOpen: false))
        #expect(!classic.showsNarrationOverlay(hasAudioNarration: true, isSidebarOpen: true))
        classic.apply(.setCurlActive(true))
        #expect(!classic.showsNarrationOverlay(hasAudioNarration: true, isSidebarOpen: false))
    }

    @Test func playbackProgressStripFollowsChromeInImmersive() {
        var state = immersive()
        #expect(!state.showsPlaybackProgressStrip(alwaysShowMiniPlayer: false, hasAudioNarration: true),
                "hidden immersive: no permanent strip")
        #expect(state.showsPlaybackProgressStrip(alwaysShowMiniPlayer: true, hasAudioNarration: true),
                "Always Show pins the compact narration card and its strip")
        state.apply(.reveal)
        #expect(state.showsPlaybackProgressStrip(alwaysShowMiniPlayer: false, hasAudioNarration: true))
        #expect(!state.showsPlaybackProgressStrip(alwaysShowMiniPlayer: true, hasAudioNarration: false),
                "pure ebook never gets a strip")
        state.apply(.setCurlActive(true))
        #expect(!state.showsPlaybackProgressStrip(alwaysShowMiniPlayer: true, hasAudioNarration: true))

        var classic = ReaderChromeState(mode: .classic)
        classic.apply(.centerTap(alwaysShowMiniPlayer: false))
        #expect(classic.showsPlaybackProgressStrip(alwaysShowMiniPlayer: false, hasAudioNarration: true),
                "Classic keeps the legacy always-on strip")
        #expect(!classic.showsPlaybackProgressStrip(alwaysShowMiniPlayer: false, hasAudioNarration: false))
    }

    @Test func revealedProgressOverlayAndBookmarkRibbonMatchLegacyInBothModes() {
        for mode in ReaderControlsMode.allCases {
            var state = ReaderChromeState(mode: mode)
            state.apply(.reveal)
            #expect(state.showsRevealedProgressOverlay(isSidebarOpen: false, isBottomCardPresented: false))
            #expect(!state.showsRevealedProgressOverlay(isSidebarOpen: false, isBottomCardPresented: true))
            #expect(!state.showsRevealedProgressOverlay(isSidebarOpen: true, isBottomCardPresented: false))
            #expect(!state.showsBookmarkRibbon(isCurrentPageBookmarked: true), "toolbar shows the bookmark")

            state.apply(.hide)
            #expect(!state.isTopVisible)
            #expect(!state.showsRevealedProgressOverlay(isSidebarOpen: false, isBottomCardPresented: false))
            #expect(state.showsBookmarkRibbon(isCurrentPageBookmarked: true))
            #expect(!state.showsBookmarkRibbon(isCurrentPageBookmarked: false))
            state.apply(.setCurlActive(true))
            #expect(!state.showsBookmarkRibbon(isCurrentPageBookmarked: true))
        }
    }

    @Test func pageTapsAndHideNeverDismissWhileABlockerIsActive() {
        let dismissals: [ReaderChromeEvent] = [
            .centerTap(alwaysShowMiniPlayer: false), .centerTap(alwaysShowMiniPlayer: true),
            .marginTap, .hide,
        ]
        for blocker in ReaderChromeBlocker.allCases {
            for event in dismissals {
                var state = immersive()
                state.apply(.reveal)
                state.apply(.setBlocker(blocker, true))
                state.apply(event)
                #expect(state.isTopVisible && state.isBottomVisible,
                        "\(event) must not dismiss chrome during \(blocker)")

                state.apply(.setBlocker(blocker, false))
                state.apply(event)
                #expect(!state.isRevealed, "\(event) dismisses once \(blocker) has ended")
            }
        }
    }

    @Test func deliberateCardDismissStillWorksUnderEveryBlocker() {
        for blocker in ReaderChromeBlocker.allCases {
            var state = immersive()
            state.apply(.reveal)
            state.apply(.setBlocker(blocker, true))
            state.apply(.cardDismissed)
            #expect(!state.isBottomVisible, "swipe-down closes the card during \(blocker)")
            let keepsToolbar = blocker == .selectionMode || blocker == .modal
            #expect(state.isTopVisible == keepsToolbar,
                    "toolbar stays only for Select Text / sheet presenters (\(blocker))")
        }
    }

    @Test func classicPageTapsIgnoreBlockers() {
        for blocker in ReaderChromeBlocker.allCases {
            var state = ReaderChromeState(mode: .classic)
            state.apply(.setBlocker(blocker, true))
            state.apply(.marginTap)
            #expect(state.isTopVisible && state.isBottomVisible, "Classic margin taps never dismiss")
            state.apply(.centerTap(alwaysShowMiniPlayer: false))
            #expect(!state.isTopVisible && !state.isBottomVisible, "Classic center tap toggles as before")
            state.apply(.centerTap(alwaysShowMiniPlayer: false))
            #expect(state.isTopVisible && state.isBottomVisible)
            state.apply(.cardDismissed)
            #expect(state.isTopVisible && !state.isBottomVisible, "legacy swipe-down hides only the card")
        }
    }

    @Test func sidebarRestoresStoredPreferenceOnEnteringClassic() {
        typealias P = ReaderSidebarPolicy
        #expect(P.sidebarOnModeChange(from: nil, to: .classic, storedPreference: true) == true,
                "first Classic apply restores an open sidebar")
        #expect(P.sidebarOnModeChange(from: nil, to: .classic, storedPreference: false) == nil)
        #expect(P.sidebarOnModeChange(from: nil, to: .classic, storedPreference: nil) == nil)
        #expect(P.sidebarOnModeChange(from: nil, to: .immersive, storedPreference: true) == nil,
                "immersive never auto-opens the sidebar")
        #expect(P.sidebarOnModeChange(from: .immersive, to: .classic, storedPreference: true) == true,
                "switching into Classic after an immersive open restores the preference")
        #expect(P.sidebarOnModeChange(from: .immersive, to: .classic, storedPreference: false) == nil,
                "never closes a sidebar the reader opened in immersive")
        #expect(P.sidebarOnModeChange(from: .classic, to: .classic, storedPreference: true) == nil,
                "re-applying Classic does not clobber the current sidebar")
        #expect(P.sidebarOnModeChange(from: .classic, to: .immersive, storedPreference: true) == nil)
    }
}

@MainActor
@Suite("Immersive reader chrome idle timer")
struct ReaderChromeControllerTests {
    private final class FakeScheduler {
        var fires: [@MainActor () -> Void] = []
        var cancelled = 0

        func schedule(_ delay: Duration, _ fire: @escaping @MainActor @Sendable () -> Void) -> @MainActor () -> Void {
            #expect(delay == ReaderChromeState.idleTimeout)
            fires.append(fire)
            return { [weak self] in self?.cancelled += 1 }
        }
    }

    @Test func idleTimerHidesAfterRevealAndIgnoresStaleFires() {
        let fake = FakeScheduler()
        let controller = ReaderChromeController(mode: .immersive, scheduler: fake.schedule)
        controller.send(.reveal)
        #expect(fake.fires.count == 1)
        controller.send(.userActivity)
        #expect(fake.fires.count == 2 && fake.cancelled == 1, "activity restarts the 4s window")
        fake.fires[0]()
        #expect(controller.state.isRevealed, "cancelled timer firing late is ignored")
        fake.fires[1]()
        #expect(!controller.state.isRevealed)
    }

    @Test func playbackTicksDoNotRestartAndBlockersCancel() {
        let fake = FakeScheduler()
        let controller = ReaderChromeController(mode: .immersive, scheduler: fake.schedule)
        controller.send(.reveal)
        controller.send(.setCurlActive(true))
        controller.send(.setCurlActive(false))
        #expect(fake.fires.count == 1, "curl / relocate-like events keep the same window")
        controller.send(.setBlocker(.scrubbing, true))
        #expect(fake.cancelled == 1)
        fake.fires[0]()
        #expect(controller.state.isRevealed, "no hide mid-scrub")
        controller.send(.setBlocker(.scrubbing, false))
        #expect(fake.fires.count == 2)
    }

    @Test func invalidateCancelsOnDisappear() {
        let fake = FakeScheduler()
        let controller = ReaderChromeController(mode: .immersive, scheduler: fake.schedule)
        controller.send(.reveal)
        controller.invalidate()
        #expect(fake.cancelled == 1)
        fake.fires[0]()
        #expect(controller.state.isRevealed)
    }
}

@SilveranUIActor
@Suite("Reader controls startup push")
struct ReaderControlsBridgeTests {
    @SilveranUIActor
    final class FakeJS: JSEvaluating {
        var startScripts: [(key: String, source: String)] = []
        var evaluated: [String] = []
        func evaluate(_ script: String) async throws -> String? {
            evaluated.append(script)
            return "pending"
        }
        func setDocumentStartScript(_ source: String, key: String) {
            startScripts.append((key, source))
        }
    }

    @SilveranUIActor
    final class PlainJS: JSEvaluating {
        func evaluate(_ script: String) async throws -> String? { "applied" }
    }

    @Test func pageLoadStateRegistersSynchronouslyWithoutSelectionMode() {
        let js = FakeJS()
        let bridge = ReaderCommsBridge(js: js)
        bridge.setReaderControlsForPageLoads(immersive: true)
        #expect(js.startScripts.count == 1)
        #expect(js.startScripts.first?.key == ReaderCommsBridge.pendingReaderControlsGlobal)
        #expect(
            js.startScripts.first?.source
                == "window.inkampPendingReaderControls = {immersive: true, selectionMode: false};")
        #expect(js.evaluated.isEmpty)
    }

    @Test func pushRegistersPageLoadStateAndPendingFallback() async throws {
        let js = FakeJS()
        let bridge = ReaderCommsBridge(js: js)
        let result = try await bridge.sendJsSetReaderControls(immersive: true, selectionMode: true)
        #expect(result == "pending")
        #expect(js.startScripts.map { $0.source } == [
            "window.inkampPendingReaderControls = {immersive: true, selectionMode: false};",
        ])
        let script = try #require(js.evaluated.first)
        #expect(script.contains("const state = {immersive: true, selectionMode: true};"))
        #expect(script.contains("window.inkampPendingReaderControls = state;"))
        #expect(script.contains("if (!window.foliateManager) return \"pending\";"))
        #expect(script.contains("window.foliateManager.setReaderControls(state);"))
    }

    @Test func recoveryBridgeRegistersClassicState() async throws {
        let js = FakeJS()
        let recovered = ReaderCommsBridge(js: js)
        try await recovered.sendJsSetReaderControls(immersive: false, selectionMode: false)
        #expect(js.startScripts.first?.source.contains("immersive: false") == true)
    }

    @Test func evaluatorWithoutDocumentStartSupportStillReceivesThePush() async throws {
        let js = PlainJS()
        let bridge = ReaderCommsBridge(js: js)
        bridge.setReaderControlsForPageLoads(immersive: true)
        #expect(try await bridge.sendJsSetReaderControls(immersive: true, selectionMode: false) == "applied")
    }
}
