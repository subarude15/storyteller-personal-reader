#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

/// Renders the shared podcast `AVPlayer` into a local `AVPlayerLayer`.
///
/// Portrait and landscape fullscreen each own their own layer/view. They must
/// pass the same `AVPlayer` from `AudioSessionActor.podcastAVPlayer()` — never
/// allocate a second playback engine. Layers are never re-parented between
/// SwiftUI containers.
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
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        // Identity-only player updates. Never remove/add the view or touch
        // observable PiP/wake-lock state from this path.
        if uiView.playerLayer.player !== player {
            #if DEBUG
            debugLog(
                "[PodcastVideoSurface] update id=\(context.coordinator.surfaceID) player=\(ObjectIdentifier(player))"
            )
            #endif
            uiView.playerLayer.player = player
        }
        if uiView.backgroundColor != .black {
            uiView.backgroundColor = .black
        }
    }

    static func dismantleUIView(_ uiView: PlayerLayerView, coordinator: Coordinator) {
        #if DEBUG
        debugLog("[PodcastVideoSurface] dismantle id=\(coordinator.surfaceID)")
        #endif
        uiView.playerLayer.player = nil
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
