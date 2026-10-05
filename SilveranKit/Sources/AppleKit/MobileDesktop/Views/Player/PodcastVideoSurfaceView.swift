#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

/// Renders the shared podcast `AVPlayer` into a local `AVPlayerLayer`.
///
/// Portrait and landscape fullscreen each own their own layer/view. They must
/// pass the same `AVPlayer` from `AudioSessionActor.podcastAVPlayer()` — never
/// allocate a second playback engine. Layers are never re-parented between
/// SwiftUI containers. Each surface registers its local layer with the PiP
/// coordinator while visible.
struct PodcastVideoSurfaceView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.surfaceID = context.coordinator.surfaceID
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        #if DEBUG
        debugLog(
            "[PodcastVideoSurface] create id=\(context.coordinator.surfaceID) player=\(ObjectIdentifier(player))"
        )
        #endif
        PodcastVideoPictureInPictureCoordinator.shared.register(
            layer: view.playerLayer,
            surfaceID: context.coordinator.surfaceID
        )
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        // Identity-only player updates. Never remove/add the view, never
        // re-claim PiP registration (a sibling fullscreen surface may already
        // be current), and never touch Observable PiP/wake-lock state here.
        if uiView.playerLayer.player !== player {
            #if DEBUG
            debugLog(
                "[PodcastVideoSurface] update id=\(context.coordinator.surfaceID) player=\(ObjectIdentifier(player))"
            )
            #endif
            uiView.playerLayer.player = player
            PodcastVideoPictureInPictureCoordinator.shared.refreshPlayerIfCurrent(
                surfaceID: context.coordinator.surfaceID,
                layer: uiView.playerLayer
            )
        }
        if uiView.backgroundColor != .black {
            uiView.backgroundColor = .black
        }
    }

    static func dismantleUIView(_ uiView: PlayerLayerView, coordinator: Coordinator) {
        #if DEBUG
        debugLog("[PodcastVideoSurface] dismantle id=\(coordinator.surfaceID)")
        #endif
        // While this layer is the protected active PiP source, leave player
        // bound and let the coordinator retain the layer (detached is fine).
        // Never re-parent into another container.
        let mayClearPlayer = PodcastVideoPictureInPictureCoordinator.shared.unregister(
            surfaceID: coordinator.surfaceID,
            sourceView: uiView
        )
        if mayClearPlayer {
            uiView.playerLayer.player = nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        let surfaceID = String(UUID().uuidString.prefix(8))
    }

    final class PlayerLayerView: UIView {
        var surfaceID = "unset"

        override class var layerClass: AnyClass { AVPlayerLayer.self }

        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
#endif
