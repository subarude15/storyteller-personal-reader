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
///
/// When the content-source surface is dismantled while PiP is active, the
/// coordinator strongly retains that source view (still no re-parenting) so
/// `layer.player` stays bound until PiP stops or a new surface takes over
/// after stop.
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
    /// Weak identity of the layer currently feeding the PiP controller.
    private weak var controllerSourceLayer: AVPlayerLayer?
    /// Retains a dismantled content-source view while PiP is still using it.
    /// Not inserted into any other hierarchy — ownership only.
    private var retainedSourceView: UIView?
    private var automaticStartEnabled = false
    private var suppressRestore = false
    private var possibilityTask: Task<Void, Never>?
    /// Bumped whenever the controller instance changes so observers stop.
    private var possibilityObservationID = UUID()

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

        // A newly visible surface can replace a retained orphaned source.
        releaseRetainedSource(clearPlayer: true)

        if controllerLayerID == ObjectIdentifier(layer), pictureInPictureController != nil {
            startPossibilityObservation()
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

    /// Surface left the hierarchy. Only clears registration when `surfaceID`
    /// is still current. Returns whether the caller may clear `layer.player`.
    @discardableResult
    func unregister(surfaceID: String, sourceView: UIView) -> Bool {
        let sourceLayer = sourceView.layer as? AVPlayerLayer
        let isControllerSource = sourceLayer != nil && sourceLayer === controllerSourceLayer
        let wasCurrent = activeSurface.surfaceID == surfaceID
        activeSurface.unregister(surfaceID: surfaceID)

        let shouldClear = PodcastVideoPiPLifecyclePolicy.shouldClearPlayerOnDismantle(
            isPictureInPictureActive: state.isActive,
            isControllerContentSource: isControllerSource
        )

        // Whether or not this surface still owns registration, if PiP is
        // sampling its layer we must retain the view and keep player bound.
        if !shouldClear {
            retainedSourceView = sourceView
            #if DEBUG
            debugLog(
                "[PodcastVideoPiP] retain content source during active PiP surface=\(surfaceID)"
            )
            #endif
        }

        guard wasCurrent, activeSurface.surfaceID == nil else {
            #if DEBUG
            debugLog(
                "[PodcastVideoPiP] unregister ignored stale surface=\(surfaceID) current=\(activeSurface.surfaceID ?? "nil")"
            )
            #endif
            return shouldClear
        }

        #if DEBUG
        debugLog("[PodcastVideoPiP] unregister surface=\(surfaceID)")
        #endif
        registeredSurfaceID = nil
        registeredLayer = nil

        if !state.isActive {
            pictureInPictureController?.canStartPictureInPictureAutomaticallyFromInline = false
            stopPossibilityObservation()
            state.isPossible = false
        }
        return shouldClear
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
        stopPossibilityObservation()
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
        controllerSourceLayer = nil
        releaseRetainedSource(clearPlayer: true)
        registeredLayer = nil
        registeredSurfaceID = nil
        activeSurface = PodcastVideoPiPActiveSurface()
        state.isActive = false
        state.isPossible = false
        automaticStartEnabled = false
    }

    private func installController(for layer: AVPlayerLayer) {
        stopPossibilityObservation()
        pictureInPictureController?.delegate = nil
        pictureInPictureController = nil
        controllerLayerID = nil
        controllerSourceLayer = nil
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
        controllerSourceLayer = layer
        startPossibilityObservation()
    }

    private func refreshPossibility() {
        state.isPossible = pictureInPictureController?.isPictureInPicturePossible ?? false
    }

    /// Observe `isPictureInPicturePossible` for the life of the current
    /// controller. Polls with backoff until possible (or the controller
    /// changes) so slow stream start does not leave the button stuck off.
    private func startPossibilityObservation() {
        stopPossibilityObservation()
        refreshPossibility()
        guard !state.isPossible, pictureInPictureController != nil else { return }

        let observationID = UUID()
        possibilityObservationID = observationID
        let observedLayerID = controllerLayerID

        possibilityTask = Task { @MainActor in
            var delayMs: UInt64 = 300
            while !Task.isCancelled {
                let hasController = self.pictureInPictureController != nil
                let matches = self.controllerLayerID == observedLayerID
                    && self.possibilityObservationID == observationID
                self.refreshPossibility()
                let shouldContinue = PodcastVideoPiPLifecyclePolicy.shouldContinuePossibilityRefresh(
                    isPossible: self.state.isPossible,
                    hasController: hasController,
                    controllerMatchesObserved: matches
                )
                guard shouldContinue else { break }
                try? await Task.sleep(for: .milliseconds(delayMs))
                delayMs = min(delayMs * 2, 2_000)
            }
            if self.possibilityObservationID == observationID {
                self.possibilityTask = nil
            }
        }
    }

    private func stopPossibilityObservation() {
        possibilityObservationID = UUID()
        possibilityTask?.cancel()
        possibilityTask = nil
    }

    private func releaseRetainedSource(clearPlayer: Bool) {
        if clearPlayer, let retainedSourceView,
           let layer = retainedSourceView.layer as? AVPlayerLayer
        {
            layer.player = nil
        }
        if retainedSourceView != nil {
            #if DEBUG
            debugLog("[PodcastVideoPiP] release retained content source clearPlayer=\(clearPlayer)")
            #endif
        }
        retainedSourceView = nil
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
            // Drop any orphaned content-source view retained during teardown.
            // Prefer the currently registered live surface for the next controller.
            coordinator.releaseRetainedSource(clearPlayer: true)
            if let layer = coordinator.registeredLayer {
                coordinator.installController(for: layer)
            } else {
                coordinator.stopPossibilityObservation()
                coordinator.pictureInPictureController?.delegate = nil
                coordinator.pictureInPictureController = nil
                coordinator.controllerLayerID = nil
                coordinator.controllerSourceLayer = nil
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
