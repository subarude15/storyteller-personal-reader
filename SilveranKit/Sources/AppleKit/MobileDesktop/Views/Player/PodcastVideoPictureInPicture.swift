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

@MainActor
enum PodcastVideoPictureInPictureAvailability {
    static let isEnabled = InternalVideoPlaybackLifecycle.isPictureInPictureEnabled
}

/// Picture in Picture over the currently registered local `AVPlayerLayer`.
///
/// Each `PodcastVideoSurfaceView` owns its layer and registers it here. This
/// coordinator never moves, removes, or re-parents UIKit views — it only
/// points `AVPictureInPictureController` at the active surface's layer.
@MainActor
final class PodcastVideoPictureInPictureCoordinator: NSObject, AVPictureInPictureControllerDelegate {
    static let shared = PodcastVideoPictureInPictureCoordinator()

    let state = PodcastVideoPictureInPictureState()

    private weak var registeredLayer: AVPlayerLayer?
    private var registeredSurfaceID: String?
    private var activeSurface = PodcastVideoPiPActiveSurface()
    private var restoreGate = PodcastVideoPiPRestoreGate()
    private var restoreGeneration: UInt64 = 0
    private var pictureInPictureController: AVPictureInPictureController?
    /// ObjectIdentity of the layer the current controller was built for.
    private var controllerLayerID: ObjectIdentifier?
    private var automaticStartEnabled = false
    private var suppressRestore = false
    private var possibilityTask: Task<Void, Never>?

    private override init() {
        super.init()
        state.isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    }

    /// True when this surface/layer is already the active PiP source.
    func isRegistered(surfaceID: String, layer: AVPlayerLayer) -> Bool {
        activeSurface.surfaceID == surfaceID && registeredLayer === layer
    }

    /// Portrait/fullscreen surface became the active PiP source.
    ///
    /// Call from `makeUIView` / explicit appear — not from every `updateUIView`,
    /// so a dismantling sibling cannot steal registration back mid-transition.
    func register(layer: AVPlayerLayer, surfaceID: String) {
        // Identical registration is a pure no-op.
        if isRegistered(surfaceID: surfaceID, layer: layer), restoreGate.restoreAllowed {
            return
        }

        if !restoreGate.restoreAllowed {
            restoreGate.beginSession()
        }
        restoreGeneration = restoreGate.sessionGeneration
        let previousID = activeSurface.surfaceID
        activeSurface.register(surfaceID: surfaceID)
        registeredSurfaceID = surfaceID
        registeredLayer = layer

        #if DEBUG
        if previousID != surfaceID {
            debugLog(
                "[PodcastVideoPiP] active layer change from=\(previousID ?? "nil") to=\(surfaceID) layer=\(ObjectIdentifier(layer))"
            )
        }
        debugLog(
            "[PodcastVideoPiP] register surface=\(surfaceID) layer=\(ObjectIdentifier(layer))"
        )
        #endif

        // While PiP is running, keep the existing controller/content source.
        // Surfaces may come and go; do not rebuild mid-flight.
        if state.isActive {
            return
        }

        if controllerLayerID == ObjectIdentifier(layer), pictureInPictureController != nil {
            refreshPossibility()
            if !state.isPossible {
                schedulePossibilityRefresh()
            }
            return
        }

        installController(for: layer)
    }

    /// Player identity changed on a surface that is still the active source.
    /// Does nothing for stale/sibling surfaces — no registration steal.
    /// Controller rebuild is deferred so `updateUIView` never mutates
    /// Observable PiP state synchronously.
    func refreshPlayerIfCurrent(surfaceID: String, layer: AVPlayerLayer) {
        guard activeSurface.surfaceID == surfaceID, registeredLayer === layer else { return }
        guard !state.isActive else { return }
        if controllerLayerID == ObjectIdentifier(layer), pictureInPictureController != nil {
            // ContentSource follows the layer's current player — no rebuild.
            return
        }
        Task { @MainActor in
            guard self.activeSurface.surfaceID == surfaceID, self.registeredLayer === layer else {
                return
            }
            guard !self.state.isActive else { return }
            self.installController(for: layer)
        }
    }

    /// Surface left the hierarchy. Only clears when `surfaceID` is still current.
    func unregister(surfaceID: String) {
        let wasCurrent = activeSurface.surfaceID == surfaceID
        activeSurface.unregister(surfaceID: surfaceID)
        guard wasCurrent, activeSurface.surfaceID == nil else {
            #if DEBUG
            debugLog(
                "[PodcastVideoPiP] unregister ignored stale surface=\(surfaceID) current=\(activeSurface.surfaceID ?? "nil")"
            )
            #endif
            return
        }

        #if DEBUG
        debugLog("[PodcastVideoPiP] unregister surface=\(surfaceID)")
        #endif
        registeredSurfaceID = nil
        registeredLayer = nil

        if state.isActive {
            // PiP owns the content source; leave the controller alone.
            return
        }

        pictureInPictureController?.canStartPictureInPictureAutomaticallyFromInline = false
        // Keep the controller until a new surface registers or the session ends.
        // Possibility becomes false without a live layer in the hierarchy.
        state.isPossible = false
    }

    func setAutomaticStartEnabled(_ enabled: Bool) {
        let allowed = enabled && InternalVideoPlaybackLifecycle.isAutomaticPictureInPictureEnabled
        automaticStartEnabled = allowed
        pictureInPictureController?.canStartPictureInPictureAutomaticallyFromInline = allowed
    }

    func toggle() {
        guard PodcastVideoPictureInPictureAvailability.isEnabled else { return }
        guard let pictureInPictureController else { return }
        if pictureInPictureController.isPictureInPictureActive {
            pictureInPictureController.stopPictureInPicture()
            return
        }
        refreshPossibility()
        guard pictureInPictureController.isPictureInPicturePossible else {
            #if DEBUG
            debugLog("[PodcastVideoPiP] start skipped — not possible surface=\(registeredSurfaceID ?? "nil")")
            #endif
            return
        }
        #if DEBUG
        debugLog("[PodcastVideoPiP] start requested surface=\(registeredSurfaceID ?? "nil")")
        #endif
        pictureInPictureController.startPictureInPicture()
    }

    /// Session ended (stop / close). Drops PiP without seeking a replacement item.
    func endSession() {
        possibilityTask?.cancel()
        possibilityTask = nil
        restoreGate.endSession()
        restoreGeneration = restoreGate.sessionGeneration
        #if DEBUG
        debugLog("[PodcastVideoPiP] endSession generation=\(restoreGeneration)")
        #endif
        if pictureInPictureController?.isPictureInPictureActive == true {
            suppressRestore = true
            pictureInPictureController?.stopPictureInPicture()
            suppressRestore = false
        }
        pictureInPictureController?.delegate = nil
        pictureInPictureController = nil
        controllerLayerID = nil
        registeredLayer = nil
        registeredSurfaceID = nil
        activeSurface = PodcastVideoPiPActiveSurface()
        state.isActive = false
        state.isPossible = false
        automaticStartEnabled = false
    }

    private func installController(for layer: AVPlayerLayer) {
        pictureInPictureController?.delegate = nil
        pictureInPictureController = nil
        controllerLayerID = nil
        state.isPossible = false

        guard PodcastVideoPictureInPictureAvailability.isEnabled,
              state.isSupported,
              layer.player != nil
        else { return }

        #if DEBUG
        debugLog(
            "[PodcastVideoPiP] create controller surface=\(registeredSurfaceID ?? "nil") layer=\(ObjectIdentifier(layer))"
        )
        #endif

        let source = AVPictureInPictureController.ContentSource(playerLayer: layer)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = automaticStartEnabled
        pictureInPictureController = controller
        controllerLayerID = ObjectIdentifier(layer)
        refreshPossibility()
        if !state.isPossible {
            schedulePossibilityRefresh()
        }
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
        if suppressRestore { return false }
        guard restoreGate.shouldRestoreInterface(observedGeneration: restoreGeneration) else {
            #if DEBUG
            debugLog("[PodcastVideoPiP] restore blocked generation=\(restoreGeneration)")
            #endif
            return false
        }
        // Expand the card only when a live session still has a retained episode
        // under the mini player. Never reopen a session the user stopped.
        if PodcastPlayerPresenter.shared.episode == nil {
            PodcastPlayerPresenter.shared.expandFromMiniPlayer()
        }
        #if DEBUG
        debugLog("[PodcastVideoPiP] restore allowed generation=\(restoreGeneration)")
        #endif
        return true
    }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        hopToMain { coordinator in
            coordinator.state.isActive = true
            #if DEBUG
            debugLog(
                "[PodcastVideoPiP] willStart surface=\(coordinator.registeredSurfaceID ?? "nil")"
            )
            #endif
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        hopToMain { coordinator in
            coordinator.state.isActive = true
            #if DEBUG
            debugLog(
                "[PodcastVideoPiP] didStart surface=\(coordinator.registeredSurfaceID ?? "nil")"
            )
            #endif
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        let message = error.localizedDescription
        hopToMain { coordinator in
            coordinator.state.isActive = false
            #if DEBUG
            debugLog("[PodcastVideoPiP] failed: \(message)")
            #endif
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        hopToMain { coordinator in
            coordinator.state.isActive = false
            #if DEBUG
            debugLog(
                "[PodcastVideoPiP] didStop surface=\(coordinator.registeredSurfaceID ?? "nil")"
            )
            #endif
            // No UIView re-hosting — the visible surface already has its own
            // local layer bound to the same shared AVPlayer.
            if let layer = coordinator.registeredLayer {
                coordinator.installController(for: layer)
            } else {
                coordinator.refreshPossibility()
            }
        }
    }

    /// AVKit's Swift overlay is `async -> Bool`. The requirement is
    /// nonisolated (`AVPictureInPictureController` is not Sendable), so hop
    /// only the restore onto this MainActor type. The overlay invokes the
    /// completion handler once with the returned Bool.
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController
    ) async -> Bool {
        await MainActor.run {
            restoreInterfaceForPictureInPictureStop()
        }
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
