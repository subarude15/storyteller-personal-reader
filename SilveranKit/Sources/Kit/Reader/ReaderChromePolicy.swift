import Foundation
import Observation

/// How iOS ebook / readaloud chrome is summoned. Comics and macOS always behave
/// as `.classic`.
public enum ReaderControlsMode: String, CaseIterable, Codable, Sendable {
    /// Chrome starts hidden; long-press reveals, center tap or 4s idle hides,
    /// highlighting goes through the explicit Select Text mode.
    case immersive
    /// Original behavior: center tap toggles, long-press selects text.
    case classic

    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .immersive
    }

    public var displayName: String {
        switch self {
            case .immersive: "Immersive"
            case .classic: "Classic"
        }
    }
}

/// Anything that must keep revealed chrome on screen while it lasts: idle,
/// page taps, and Hide cannot dismiss it; only a deliberate card dismiss can
/// close the card.
public enum ReaderChromeBlocker: Hashable, Sendable, CaseIterable {
    case scrubbing
    case cardDrag
    case cardExpanded
    case modal
    case selectionMode
}

public enum ReaderChromeEvent: Equatable, Sendable {
    /// Long-press or the VoiceOver "Show reader controls" action.
    case reveal
    /// Explicit "Hide reader controls". Like page taps, refused while any
    /// `ReaderChromeBlocker` is active.
    case hide
    case centerTap(alwaysShowMiniPlayer: Bool)
    case marginTap
    /// Touches on chrome controls. Playback ticks and relocates are not activity.
    case userActivity
    case idleTimeout(generation: Int)
    /// Swipe-down on the compact card.
    case cardDismissed
    case setMode(ReaderControlsMode)
    case setBlocker(ReaderChromeBlocker, Bool)
    case setCurlActive(Bool)
    case setVoiceOver(Bool)
    case setForeground(Bool)
}

/// Single source of truth for reader chrome visibility. Pure value type so the
/// whole policy is host-testable; `ReaderChromeController` owns the idle timer.
public struct ReaderChromeState: Equatable, Sendable {
    public static let idleTimeout: Duration = .seconds(4)

    public private(set) var mode: ReaderControlsMode
    public private(set) var isTopVisible: Bool
    public private(set) var isBottomVisible: Bool
    public private(set) var blockers: Set<ReaderChromeBlocker> = []
    public private(set) var isCurlActive = false
    public private(set) var isVoiceOverRunning = false
    public private(set) var isForeground = true
    /// Bumped whenever the idle window restarts or chrome changes, so a timer
    /// armed for an older window can never hide newer chrome.
    public private(set) var idleGeneration = 0

    public init(mode: ReaderControlsMode = .immersive) {
        self.mode = mode
        isTopVisible = mode == .classic
        isBottomVisible = mode == .classic
    }

    public var isSelectionMode: Bool { blockers.contains(.selectionMode) }
    public var isRevealed: Bool { isTopVisible || isBottomVisible }

    /// Page curl masks presentation only; it never changes the underlying state.
    public var showsTopBar: Bool { isTopVisible && !isCurlActive }

    /// Classic keeps legacy Always Show. Immersive only pins the compact
    /// narration card, never the pure-ebook scrubber.
    public func cardAlwaysShows(alwaysShowMiniPlayer: Bool, hasAudioNarration: Bool) -> Bool {
        switch mode {
            case .classic: alwaysShowMiniPlayer
            case .immersive: alwaysShowMiniPlayer && hasAudioNarration
        }
    }

    public func showsBottomCard(alwaysShowMiniPlayer: Bool, hasAudioNarration: Bool) -> Bool {
        guard !isCurlActive else { return false }
        return isBottomVisible
            || cardAlwaysShows(alwaysShowMiniPlayer: alwaysShowMiniPlayer, hasAudioNarration: hasAudioNarration)
    }

    /// Legacy hidden-chrome narration overlay (time remaining + transport).
    /// Immersive never shows it: playback stays reachable through revealed
    /// chrome and the card, and only the pinned compact card may persist.
    public func showsNarrationOverlay(hasAudioNarration: Bool, isSidebarOpen: Bool) -> Bool {
        mode == .classic && hasAudioNarration && !isSidebarOpen && !isTopVisible && !isCurlActive
    }

    /// Floating progress / page readout shown with revealed chrome when the
    /// bottom card is not covering the footer. Same rule in both modes.
    public func showsRevealedProgressOverlay(isSidebarOpen: Bool, isBottomCardPresented: Bool) -> Bool {
        isTopVisible && !isSidebarOpen && !isCurlActive && !isBottomCardPresented
    }

    /// Thin narration progress strip along the bottom edge. Classic: always
    /// (legacy). Immersive: only with revealed chrome or the pinned compact card.
    public func showsPlaybackProgressStrip(alwaysShowMiniPlayer: Bool, hasAudioNarration: Bool) -> Bool {
        guard hasAudioNarration && !isCurlActive else { return false }
        return mode == .classic
            || isRevealed
            || cardAlwaysShows(alwaysShowMiniPlayer: alwaysShowMiniPlayer, hasAudioNarration: true)
    }

    /// Page-bookmarked ribbon replaces the toolbar bookmark icon while hidden.
    public func showsBookmarkRibbon(isCurrentPageBookmarked: Bool) -> Bool {
        isCurrentPageBookmarked && !isTopVisible && !isCurlActive
    }

    public var autoHideEligible: Bool {
        mode == .immersive && isRevealed && blockers.isEmpty && !isVoiceOverRunning && isForeground
    }

    public mutating func apply(_ event: ReaderChromeEvent) {
        switch event {
            case .reveal:
                setVisible(top: true, bottom: true)
            case .hide:
                if blockers.isEmpty { setVisible(top: false, bottom: false) }
            case .centerTap(let alwaysShowMiniPlayer):
                switch mode {
                    case .classic:
                        let top = !isTopVisible
                        setVisible(top: top, bottom: alwaysShowMiniPlayer ? isBottomVisible : top)
                    case .immersive:
                        if isRevealed && blockers.isEmpty { setVisible(top: false, bottom: false) }
                }
            case .marginTap:
                // The page still turns; only the chrome dismissal is refused.
                if mode == .immersive && isRevealed && blockers.isEmpty {
                    setVisible(top: false, bottom: false)
                }
            case .userActivity:
                if mode == .immersive && isRevealed { idleGeneration += 1 }
            case .idleTimeout(let generation):
                if generation == idleGeneration && autoHideEligible {
                    setVisible(top: false, bottom: false)
                }
            case .cardDismissed:
                // Deliberate swipe-down always closes the card, but never takes
                // the toolbar (Done Selecting, sheet presenters) with it.
                let keepTop = mode == .classic || isSelectionMode || blockers.contains(.modal)
                setVisible(top: keepTop && isTopVisible, bottom: false)
            case .setMode(let next):
                guard next != mode else { return }
                mode = next
                if next == .classic {
                    blockers.remove(.selectionMode)
                    setVisible(top: true, bottom: true)
                } else {
                    idleGeneration += 1
                }
            case .setBlocker(let blocker, let on):
                if blocker == .selectionMode && mode != .immersive { return }
                let changed = on ? blockers.insert(blocker).inserted : blockers.remove(blocker) != nil
                guard changed else { return }
                if blocker == .selectionMode && on { isTopVisible = true }
                idleGeneration += 1
            case .setCurlActive(let active):
                isCurlActive = active
            case .setVoiceOver(let running):
                guard running != isVoiceOverRunning else { return }
                isVoiceOverRunning = running
                if running && mode == .immersive {
                    setVisible(top: true, bottom: true)
                } else {
                    idleGeneration += 1
                }
            case .setForeground(let foreground):
                guard foreground != isForeground else { return }
                isForeground = foreground
                idleGeneration += 1
        }
    }

    private mutating func setVisible(top: Bool, bottom: Bool) {
        isTopVisible = top
        isBottomVisible = bottom
        idleGeneration += 1
    }
}

/// iPad narration sidebar on a controls-mode change. Classic restores the
/// stored preference each time it is entered (including the first apply);
/// Immersive never auto-opens it. Nothing here ever closes a sidebar the
/// reader opened, and re-applying the same mode is a no-op.
public enum ReaderSidebarPolicy {
    /// Returns the value to assign, or nil to leave the sidebar alone.
    public static func sidebarOnModeChange(
        from previous: ReaderControlsMode?,
        to next: ReaderControlsMode,
        storedPreference: Bool?
    ) -> Bool? {
        guard next == .classic, previous != .classic, storedPreference == true else { return nil }
        return true
    }
}

/// Per-device, versioned first-run hint for immersive controls.
public enum ReaderControlsHint {
    /// Bump when the gesture vocabulary changes so returning readers see it again.
    public static let currentVersion = 1
    public static let storageKey = "ReaderControlsHintAcknowledgedVersion"

    public static func shouldShow(
        mode: ReaderControlsMode,
        isReaderReady: Bool,
        acknowledgedVersion: Int
    ) -> Bool {
        mode == .immersive && isReaderReady && acknowledgedVersion < currentVersion
    }
}

/// Owns the cancellable idle timer around `ReaderChromeState`.
@SilveranUIActor
@Observable
public final class ReaderChromeController {
    public typealias Cancel = @SilveranUIActor () -> Void
    public typealias IdleScheduler = @SilveranUIActor (
        Duration, @escaping @SilveranUIActor @Sendable () -> Void
    ) -> Cancel

    public private(set) var state: ReaderChromeState
    private let scheduler: IdleScheduler
    @ObservationIgnored private var cancelScheduled: Cancel?
    @ObservationIgnored private var scheduledGeneration: Int?

    public init(mode: ReaderControlsMode = .immersive, scheduler: IdleScheduler? = nil) {
        state = ReaderChromeState(mode: mode)
        self.scheduler = scheduler ?? Self.taskScheduler
    }

    public func send(_ event: ReaderChromeEvent) {
        state.apply(event)
        reconcileIdleTimer()
    }

    /// Disappear, background, or book change: drop any armed timer.
    public func invalidate() {
        cancelScheduled?()
        cancelScheduled = nil
        scheduledGeneration = nil
    }

    private func reconcileIdleTimer() {
        guard state.autoHideEligible else {
            invalidate()
            return
        }
        let generation = state.idleGeneration
        guard scheduledGeneration != generation else { return }
        invalidate()
        scheduledGeneration = generation
        cancelScheduled = scheduler(ReaderChromeState.idleTimeout) { [weak self] in
            guard let self, self.scheduledGeneration == generation else { return }
            self.cancelScheduled = nil
            self.scheduledGeneration = nil
            self.send(.idleTimeout(generation: generation))
        }
    }

    private static func taskScheduler(
        _ delay: Duration,
        _ fire: @escaping @SilveranUIActor @Sendable () -> Void
    ) -> Cancel {
        let task = Task { @SilveranUIActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            fire()
        }
        return { task.cancel() }
    }
}
