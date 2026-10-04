#if os(iOS)
import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// Observable PiP flags for the video chrome. Playback stays on the shared AVPlayer.
@MainActor
@Observable
final class PodcastVideoPictureInPictureState {
    var isActive = false
    var isPossible = false
    var isSupported = false
}

/// One `AVPictureInPictureController` bound to the shared podcast `AVPlayerLayer`.
///
/// Portrait and fullscreen re-parent that layer. Entering or leaving PiP does
/// not seek, reload, or replace the `AudioSessionActor` session.
@MainActor
final class PodcastVideoPictureInPictureCoordinator: NSObject, AVPictureInPictureControllerDelegate {
    static let shared = PodcastVideoPictureInPictureCoordinator()

    let state = PodcastVideoPictureInPictureState()

    private var host: PodcastPlayerLayerView?
    private weak var visibleContainer: PodcastVideoContainerView?
    private var pictureInPictureController: AVPictureInPictureController?
    private var automaticStartEnabled = false
    private var suppressRestore = false
    /// Stays set after the session ends so a late PiP restore cannot reopen it.
    private var blockRestore = false
    private var possibilityTask: Task<Void, Never>?

    private override init() {
        super.init()
        state.isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    }

    func attach(container: PodcastVideoContainerView, player: AVPlayer) {
        blockRestore = false
        visibleContainer = container
        let layerHost = ensureHost()
        if layerHost.playerLayer.player !== player {
            swapPlayer(to: player, on: layerHost)
        } else if pictureInPictureController == nil {
            installController(for: layerHost)
        }
        // While PiP owns the layer, leave it where the system put it.
        guard !state.isActive else { return }
        place(layerHost, in: container)
        refreshPossibility()
        if !state.isPossible {
            schedulePossibilityRefresh()
        }
    }

    func detach(container: PodcastVideoContainerView) {
        if visibleContainer === container {
            visibleContainer = nil
        }
        guard let host, host.superview === container else { return }
        host.removeFromSuperview()
        if !state.isActive {
            pictureInPictureController?.canStartPictureInPictureAutomaticallyFromInline = false
        }
    }

    func setAutomaticStartEnabled(_ enabled: Bool) {
        automaticStartEnabled = enabled
        pictureInPictureController?.canStartPictureInPictureAutomaticallyFromInline = enabled
    }

    func toggle() {
        guard let pictureInPictureController else { return }
        if pictureInPictureController.isPictureInPictureActive {
            pictureInPictureController.stopPictureInPicture()
            return
        }
        refreshPossibility()
        guard pictureInPictureController.isPictureInPicturePossible else { return }
        pictureInPictureController.startPictureInPicture()
    }

    /// Session ended (stop / close). Drops PiP without seeking a replacement item.
    func endSession() {
        possibilityTask?.cancel()
        possibilityTask = nil
        blockRestore = true
        if pictureInPictureController?.isPictureInPictureActive == true {
            pictureInPictureController?.stopPictureInPicture()
        }
        pictureInPictureController?.delegate = nil
        pictureInPictureController = nil
        host?.playerLayer.player = nil
        host?.removeFromSuperview()
        host = nil
        visibleContainer = nil
        state.isActive = false
        state.isPossible = false
        automaticStartEnabled = false
    }

    private func ensureHost() -> PodcastPlayerLayerView {
        if let host { return host }
        let host = PodcastPlayerLayerView()
        host.backgroundColor = .black
        host.playerLayer.videoGravity = .resizeAspect
        self.host = host
        return host
    }

    private func swapPlayer(to player: AVPlayer, on layerHost: PodcastPlayerLayerView) {
        if pictureInPictureController?.isPictureInPictureActive == true {
            suppressRestore = true
            pictureInPictureController?.stopPictureInPicture()
            state.isActive = false
            suppressRestore = false
        }
        layerHost.playerLayer.player = player
        installController(for: layerHost)
    }

    private func installController(for layerHost: PodcastPlayerLayerView) {
        pictureInPictureController?.delegate = nil
        pictureInPictureController = nil
        state.isPossible = false
        guard state.isSupported, layerHost.playerLayer.player != nil else { return }

        let source = AVPictureInPictureController.ContentSource(playerLayer: layerHost.playerLayer)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = automaticStartEnabled
        pictureInPictureController = controller
        refreshPossibility()
    }

    private func place(_ layerHost: PodcastPlayerLayerView, in container: PodcastVideoContainerView) {
        if layerHost.superview !== container {
            layerHost.removeFromSuperview()
            layerHost.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            layerHost.frame = container.bounds
            container.addSubview(layerHost)
        } else {
            layerHost.frame = container.bounds
        }
    }

    private func rehostIfNeeded() {
        guard !state.isActive, let host, let visibleContainer else { return }
        place(host, in: visibleContainer)
    }

    private func refreshPossibility() {
        state.isPossible = pictureInPictureController?.isPictureInPicturePossible ?? false
    }

    /// `isPictureInPicturePossible` becomes true after the layer has frames.
    /// ponytail: short poll instead of KVO. Upgrade path: observe the property
    /// on the main actor when the callback isolation allows it.
    private func schedulePossibilityRefresh() {
        guard possibilityTask == nil else { return }
        possibilityTask = Task { @MainActor in
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                refreshPossibility()
                if state.isPossible { break }
            }
            possibilityTask = nil
        }
    }

    private func restoreInterfaceForPictureInPictureStop() -> Bool {
        if suppressRestore || blockRestore { return false }
        if PodcastPlayerPresenter.shared.episode == nil {
            PodcastPlayerPresenter.shared.expandFromMiniPlayer()
        }
        return true
    }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        hopToMain { coordinator in
            coordinator.state.isActive = true
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        hopToMain { coordinator in
            coordinator.state.isActive = true
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        let message = error.localizedDescription
        hopToMain { coordinator in
            coordinator.state.isActive = false
            debugLog("[PodcastVideoPiP] failed to start: \(message)")
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        hopToMain { coordinator in
            coordinator.state.isActive = false
            coordinator.rehostIfNeeded()
        }
    }

    /// AVKit's Swift overlay is `async -> Bool` (the completion handler is
    /// `@Sendable`). Stay on this MainActor type so restore and the one
    /// generated completion run together, with no cross-isolation send.
    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController
    ) async -> Bool {
        restoreInterfaceForPictureInPictureStop()
    }

    private nonisolated func hopToMain(
        _ body: @escaping @MainActor (PodcastVideoPictureInPictureCoordinator) -> Void
    ) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                body(self)
            }
        } else {
            Task { @MainActor in
                body(self)
            }
        }
    }
}

struct PodcastVideoPictureInPictureButton: View {
    enum Chrome {
        case overlay
        case fullscreenBar
    }

    var chrome: Chrome = .overlay

    @State private var pipState = PodcastVideoPictureInPictureCoordinator.shared.state

    private var context: InternalVideoPlaybackContext {
        InternalVideoPlaybackContext(
            isInternalVideo: true,
            isPlaying: true,
            isPlayerPresented: true,
            isPictureInPictureActive: pipState.isActive,
            isAppActive: true,
            isPictureInPicturePossible: pipState.isPossible,
            isPictureInPictureSupported: pipState.isSupported
        )
    }

    var body: some View {
        if InternalVideoPlaybackLifecycle.shouldShowPictureInPictureControl(context) {
            Button {
                PodcastVideoPictureInPictureCoordinator.shared.toggle()
            } label: {
                Image(systemName: pipState.isActive ? "pip.exit" : "pip.enter")
                    .font(chrome == .overlay ? .caption.weight(.semibold) : .body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: chrome == .overlay ? 32 : 44, height: chrome == .overlay ? 32 : 44)
                    .background {
                        if chrome == .overlay {
                            Circle().fill(Color.black.opacity(0.45))
                        }
                    }
            }
            .buttonStyle(.plain)
            .disabled(!pipState.isActive && !InternalVideoPlaybackLifecycle.canStartPictureInPicture(context))
            .opacity(!pipState.isActive && !pipState.isPossible ? 0.45 : 1)
            .accessibilityLabel(pipState.isActive ? "Exit picture in picture" : "Picture in picture")
        }
    }
}
#endif
