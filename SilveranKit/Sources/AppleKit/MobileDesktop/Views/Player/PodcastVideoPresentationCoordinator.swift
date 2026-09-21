#if os(iOS)
import SwiftUI
import UIKit

/// Tracks portrait vs landscape-fullscreen presentation for the expanded podcast video player.
///
/// Owns UI state only — playback stays on `AudioSessionActor` / the shared `AVPlayer`.
@MainActor
@Observable
public final class PodcastVideoPresentationCoordinator {
    public static let shared = PodcastVideoPresentationCoordinator()

    public private(set) var state: PodcastVideoPresentationState = .portrait

    /// Expanded full Now Playing card is visible (not mini-player alone).
    public private(set) var isPlayerExpanded = false

    /// Live episode is internal video (RSS video or in-app YouTube stream).
    public private(set) var isInternalVideo = false

    public private(set) var interfaceOrientation: PodcastVideoInterfaceOrientation = .portrait

    private init() {}

    /// iPhone may rotate while the expanded video player is up; other screens stay portrait.
    public var allowsLandscapeOrientation: Bool {
        PodcastVideoPresentationLogic.allowsLandscapeOrientation(
            isPhone: UIDevice.current.userInterfaceIdiom == .phone,
            isPlayerExpanded: isPlayerExpanded,
            isInternalVideo: isInternalVideo
        )
    }

    /// Last mask we asked UIKit to re-read. Skips repeated refresh calls.
    private var notifiedAllowsLandscape: Bool?

    public var isFullscreen: Bool {
        state.mode == .landscapeFullscreen
    }

    private var context: PodcastVideoPresentationContext {
        PodcastVideoPresentationContext(
            isInternalVideo: isInternalVideo,
            isPlayerExpanded: isPlayerExpanded,
            isPhone: UIDevice.current.userInterfaceIdiom == .phone
        )
    }

    public func updatePlayerVisibility(expanded: Bool, isInternalVideo: Bool) {
        let previousAllowsLandscape = allowsLandscapeOrientation
        let wasVideo = self.isInternalVideo
        self.isPlayerExpanded = expanded
        self.isInternalVideo = isInternalVideo
        // Eligibility change (expanded video on/off) must re-query the delegate
        // mask before the next physical rotation. Unchanged eligibility is a no-op.
        refreshSupportedOrientationsIfNeeded(previousAllowsLandscape: previousAllowsLandscape)

        if !expanded {
            apply(.playerCollapsed)
            return
        }
        if wasVideo, !isInternalVideo {
            apply(.mediaBecameNonVideo)
            return
        }
        if !isInternalVideo {
            apply(.mediaBecameNonVideo)
            return
        }
        // Re-evaluate against the current interface orientation (e.g. already landscape).
        apply(.interfaceOrientationChanged(interfaceOrientation))
    }

    public func setInterfaceOrientation(_ orientation: PodcastVideoInterfaceOrientation) {
        interfaceOrientation = orientation
        apply(.interfaceOrientationChanged(orientation))
    }

    public func enterFullscreenManually() {
        apply(.manualEnterFullscreen)
    }

    public func exitFullscreenManually() {
        apply(.manualExitFullscreen)
    }

    private func apply(_ event: PodcastVideoPresentationEvent) {
        let previous = state
        state = PodcastVideoPresentationLogic.reduce(
            state: state,
            event: event,
            context: context
        )
        if previous.mode == .landscapeFullscreen, state.mode == .portrait {
            requestPortraitLockIfNeeded()
        }
        if !isPlayerExpanded || !isInternalVideo {
            requestPortraitLockIfNeeded()
        }
    }

    /// Keep ordinary iPhone screens portrait after leaving video fullscreen.
    /// Does not request landscape — physical rotation drives that once the mask allows it.
    private func requestPortraitLockIfNeeded() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        guard !allowsLandscapeOrientation || state.mode == .portrait else { return }
        // If landscape was just revoked, the portrait mask must be current
        // before the geometry request, or UIKit ignores it.
        if !allowsLandscapeOrientation, notifiedAllowsLandscape != allowsLandscapeOrientation {
            refreshSupportedOrientations()
            notifiedAllowsLandscape = allowsLandscapeOrientation
        }
        foregroundWindowScene()?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
    }

    private func refreshSupportedOrientationsIfNeeded(previousAllowsLandscape: Bool) {
        let next = allowsLandscapeOrientation
        guard PodcastVideoPresentationLogic.shouldRefreshSupportedOrientations(
            previousAllowsLandscape: previousAllowsLandscape,
            nextAllowsLandscape: next
        ) else { return }
        refreshSupportedOrientations()
        notifiedAllowsLandscape = next
    }

    /// Ask the active controller hierarchy to re-read `supportedInterfaceOrientations`.
    /// Landscape eligibility changes must trigger this; do not call it continuously.
    private func refreshSupportedOrientations() {
        guard let root = foregroundRootViewController() else { return }
        var current: UIViewController? = root
        while let controller = current {
            controller.setNeedsUpdateOfSupportedInterfaceOrientations()
            current = controller.presentedViewController
        }
    }

    private func foregroundWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    private func foregroundRootViewController() -> UIViewController? {
        guard let scene = foregroundWindowScene() else { return nil }
        let window = scene.keyWindow
            ?? scene.windows.first { $0.isKeyWindow }
            ?? scene.windows.first
        return window?.rootViewController
    }
}

/// Maps a window-scene interface orientation into presentation coarse buckets.
enum PodcastVideoInterfaceOrientationMapping {
    static func from(_ orientation: UIInterfaceOrientation) -> PodcastVideoInterfaceOrientation {
        switch orientation {
            case .portrait, .portraitUpsideDown:
                return .portrait
            case .landscapeLeft, .landscapeRight:
                return .landscape
            case .unknown:
                return .ignored
            @unknown default:
                return .ignored
        }
    }

    /// Prefer the key window scene’s interface orientation over raw device orientation.
    @MainActor
    static func current() -> PodcastVideoInterfaceOrientation {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? scenes.compactMap { $0 as? UIWindowScene }.first
        guard let windowScene else { return .ignored }
        return from(windowScene.interfaceOrientation)
    }

    /// Geometry fallback when scene orientation is briefly unknown during rotation.
    static func fromSize(_ size: CGSize) -> PodcastVideoInterfaceOrientation {
        guard size.width > 1, size.height > 1 else { return .ignored }
        return size.width > size.height ? .landscape : .portrait
    }
}
#endif
