#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

/// Renders the shared podcast `AVPlayer` into an `AVPlayerLayer` (no extra controls).
///
/// Portrait and landscape fullscreen must pass the same `AVPlayer` instance from
/// `AudioSessionActor.podcastAVPlayer()` — never allocate a second engine when
/// re-hosting this surface.
struct PodcastVideoSurfaceView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }

        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
#endif
