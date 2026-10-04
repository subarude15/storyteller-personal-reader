#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

/// Renders the shared podcast `AVPlayer` into one `AVPlayerLayer`.
///
/// Portrait and fullscreen both embed `PodcastVideoPictureInPictureCoordinator`'s
/// layer host. They never allocate a second `AVPlayer` or a second layer.
struct PodcastVideoSurfaceView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PodcastVideoContainerView {
        let view = PodcastVideoContainerView()
        view.backgroundColor = .black
        PodcastVideoPictureInPictureCoordinator.shared.attach(container: view, player: player)
        return view
    }

    func updateUIView(_ uiView: PodcastVideoContainerView, context: Context) {
        if uiView.backgroundColor != .black {
            uiView.backgroundColor = .black
        }
        PodcastVideoPictureInPictureCoordinator.shared.attach(container: uiView, player: player)
    }

    static func dismantleUIView(_ uiView: PodcastVideoContainerView, coordinator: Coordinator) {
        PodcastVideoPictureInPictureCoordinator.shared.detach(container: uiView)
    }
}

/// Host for the single shared player layer. Layout keeps the layer full-bleed.
final class PodcastVideoContainerView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        subviews.first?.frame = bounds
    }
}

final class PodcastPlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
#endif
