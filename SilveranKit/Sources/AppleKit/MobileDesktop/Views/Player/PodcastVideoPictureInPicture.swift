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
/// points `AVPictureInPictureController` at a local layer.
///
/// **Visible vs protected source:** the currently registered visible surface
/// may differ from the layer feeding an active PiP controller. While PiP is
/// active that content-source layer is retained strongly (detached is fine;
/// still no re-parenting) and its `player` must not be cleared until PiP stops.
@MainActor
final class PodcastVideoPictureInPictureCoordinator: NSObject, AVPictureInPictureControllerDelegate {
    static let shared = PodcastVideoPictureInPictureCoordinator()

    let state = PodcastVideoPictureInPictureState()

    private weak var registeredLayer: AVPlayerLayer?
    private var registeredSurfaceID: String?
    private var activeSurface = PodcastVideoPiPActiveSurface()
    private var binding = PodcastVideoPiPBindingState()
    private var restoreGate = PodcastVideoPiPRestoreGate()
    private var restoreGeneration: UInt64 = 0
    private var pictureInPictureController: AVPictureInPictureController?
    /// ObjectIdentity of the layer the current controller was built for.
    private var controllerLayerID: ObjectIdentifier?
    /// Weak ref to the layer used when the controller was installed. Promoted
    /// to `protectedSourceLayer` when PiP becomes active.
    private weak var installedSourceLayer: AVPlayerLayer?
    /// Strong retain of the layer feeding the active PiP controller. May outlive
    /// its SwiftUI surface as a detached layer; never re-parented.
    private var protectedSourceLayer: AVPlayerLayer?
    /// Token for `binding.protectedSourceID` (stable ObjectIdentifier string).
    private var protectedSourceToken: String?
    private var automaticStartEnabled = false
    private var suppressRestore = false
    private var possibilityTask: Task<Void, Never>?
    /// Bumped whenever the controller instance changes so observers stop.
    private var possibilityObservationID = UUID()

    private override init() {
        super.init()
        state.isSupported = AVPictureInPictureController.isPictureInPictureSupported()
    }

    /// True when this surface/layer is already the visible registered surface.
    func isRegistered(surfaceID: String, layer: AVPlayerLayer) -> Bool {
        activeSurface.surfaceID == surfaceID && registeredLayer === layer
    }

    /// Portrait/fullscreen surface became the visible PiP-eligible surface.
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
        binding.registerVisible(surfaceID: surfaceID)
        registeredSurfaceID = surfaceID
        registeredLayer = layer

        #if DEBUG
        if previousID != surfaceID {
            debugLog(
                "[PodcastVideoPiP] visible surface change from=\(previousID ?? "nil") to=\(surfaceID) layer=\(ObjectIdentifier(layer)) protected=\(binding.protectedSourceID ?? "nil")"
            )
        }
        debugLog(
            "[PodcastVideoPiP] register surface=\(surfaceID) layer=\(ObjectIdentifier(layer))"
        )
        #endif

        // While PiP is running, keep the existing controller/content source.
        // Surfaces may come and go; do not rebuild mid-flight onto B.
        if state.isActive || binding.isPictureInPictureActive {
            return
        }

        // A newly visible surface can replace an orphaned protected source.
        releaseProtectedSource(clearPlayerIfOrphaned: true)

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

    /// Surface left the hierarchy. Only clears visible registration when
    /// `surfaceID` is still current. Returns whether the caller may clear
    /// `layer.player` — false while this layer is the protected PiP source.
    @discardableResult
    func unregister(surfaceID: String, sourceView: UIView) -> Bool {
        let sourceLayer = sourceView.layer as? AVPlayerLayer
        let sourceToken = sourceLayer.map(Self.sourceToken(for:))
        let matchesInstalled = sourceLayer.map { ObjectIdentifier($0) == controllerLayerID } ?? false
        let isProtectedSource =
            (sourceToken != nil && sourceToken == binding.protectedSourceID)
            || (sourceLayer != nil && sourceLayer === protectedSourceLayer)
            || (sourceLayer != nil && sourceLayer === installedSourceLayer)
            || matchesInstalled
        let pipActive = state.isActive || binding.isPictureInPictureActive
        let wasCurrent = activeSurface.surfaceID == surfaceID
        activeSurface.unregister(surfaceID: surfaceID)
        binding.unregisterVisible(surfaceID: surfaceID)

        let mayClear = PodcastVideoPiPLifecyclePolicy.shouldClearPlayerOnDismantle(
            isPictureInPictureActive: pipActive,
            isControllerContentSource: isProtectedSource
        )

        // Keep the content-source layer alive for AVKit even after the SwiftUI
        // surface goes away. Detached is fine; do not re-parent.
        if !mayClear, let sourceLayer {
            protectSourceLayer(sourceLayer, token: sourceToken)
            #if DEBUG
            debugLog(
                "[PodcastVideoPiP] protect content source during active PiP surface=\(surfaceID) token=\(sourceToken ?? "nil")"
            )
            #endif
        }

        guard wasCurrent, activeSurface.surfaceID == nil else {
            #if DEBUG
            debugLog(
                "[PodcastVideoPiP] unregister ignored stale surface=\(surfaceID) visible=\(activeSurface.surfaceID ?? "nil")"
            )
            #endif
            return mayClear
        }

        #if DEBUG
        debugLog("[PodcastVideoPiP] unregister visible surface=\(surfaceID)")
        #endif
        registeredSurfaceID = nil
        registeredLayer = nil

        if !state.isActive, !binding.isPictureInPictureActive {
            pictureInPictureController?.canStartPictureInPictureAutomaticallyFromInline = false
            stopPossibilityObservation()
            state.isPossible = false
        }
        return mayClear
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
        installedSourceLayer = nil
        // Always clear the protected source player on session teardown.
        releaseProtectedSource(clearPlayerIfOrphaned: true, forceClearPlayer: true)
        binding.endSession()
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
        installedSourceLayer = nil
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
        installedSourceLayer = layer
        // Not yet strongly protected — protection begins when PiP actually starts.
        startPossibilityObservation()
    }

    private static func sourceToken(for layer: AVPlayerLayer) -> String {
        String(describing: ObjectIdentifier(layer))
    }

    private func protectSourceLayer(_ layer: AVPlayerLayer, token: String?) {
        let token = token ?? Self.sourceToken(for: layer)
        protectedSourceLayer = layer
        protectedSourceToken = token
        installedSourceLayer = layer
        controllerLayerID = ObjectIdentifier(layer)
        binding.protectSource(sourceID: token)
    }

    /// PiP became active: strongly retain the controller's content-source layer
    /// so a later surface dismantle cannot deallocate it or clear its player.
    private func markPictureInPictureActive() {
        state.isActive = true
        if let protectedSourceLayer {
            protectSourceLayer(protectedSourceLayer, token: protectedSourceToken)
            return
        }
        if let installedSourceLayer {
            protectSourceLayer(
                installedSourceLayer,
                token: Self.sourceToken(for: installedSourceLayer)
            )
            return
        }
        if let registeredLayer, ObjectIdentifier(registeredLayer) == controllerLayerID {
            protectSourceLayer(registeredLayer, token: Self.sourceToken(for: registeredLayer))
            return
        }
        if let controllerLayerID {
            let token = String(describing: controllerLayerID)
            protectedSourceToken = token
            binding.protectSource(sourceID: token)
        }
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

    private func releaseProtectedSource(
        clearPlayerIfOrphaned: Bool,
        forceClearPlayer: Bool = false
    ) {
        let token = protectedSourceToken
        let layer = protectedSourceLayer
        let stillVisible = layer != nil && registeredLayer === layer
        let shouldClear: Bool
        if forceClearPlayer {
            shouldClear = layer != nil
        } else if clearPlayerIfOrphaned {
            shouldClear = binding.shouldClearReleasedSourcePlayer(
                releasedSourceIsStillVisibleLayer: stillVisible
            )
        } else {
            shouldClear = false
        }
        if shouldClear {
            layer?.player = nil
        }
        if layer != nil || token != nil {
            #if DEBUG
            debugLog(
                "[PodcastVideoPiP] release protected source clearPlayer=\(shouldClear) token=\(token ?? "nil")"
            )
            #endif
        }
        protectedSourceLayer = nil
        protectedSourceToken = nil
        if !stillVisible {
            installedSourceLayer = nil
        }
        binding.releaseProtectedSource()
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
            coordinator.markPictureInPictureActive()
            #if DEBUG
            debugLog(
                "[PodcastVideoPiP] willStart visible=\(coordinator.registeredSurfaceID ?? "nil") protected=\(coordinator.binding.protectedSourceID ?? "nil")"
            )
            #endif
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        hopToMain { coordinator in
            coordinator.markPictureInPictureActive()
            #if DEBUG
            debugLog(
                "[PodcastVideoPiP] didStart visible=\(coordinator.registeredSurfaceID ?? "nil") protected=\(coordinator.binding.protectedSourceID ?? "nil")"
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
            coordinator.releaseProtectedSource(clearPlayerIfOrphaned: false)
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
                "[PodcastVideoPiP] didStop visible=\(coordinator.registeredSurfaceID ?? "nil") protected=\(coordinator.binding.protectedSourceID ?? "nil")"
            )
            #endif
            // Release the protected (possibly detached) source. Clear its
            // player only when no live visible surface still uses that layer.
            // Then prepare the controller for the currently registered surface.
            coordinator.releaseProtectedSource(clearPlayerIfOrphaned: true)
            if let layer = coordinator.registeredLayer {
                coordinator.installController(for: layer)
            } else {
                coordinator.stopPossibilityObservation()
                coordinator.pictureInPictureController?.delegate = nil
                coordinator.pictureInPictureController = nil
                coordinator.controllerLayerID = nil
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
