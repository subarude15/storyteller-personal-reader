#if os(iOS)
import SwiftUI

/// Picture in Picture is temporarily disabled.
///
/// The PR #116 singleton `AVPlayerLayer` re-parenting path could freeze the
/// device when portrait and fullscreen SwiftUI surfaces competed for one
/// UIKit child. Surfaces now own local layers again. Shipping wake-lock and
/// lock-screen audio is more important than PiP until a non-reparenting
/// registration model lands.
@MainActor
enum PodcastVideoPictureInPictureAvailability {
    static let isEnabled = false
}

/// No-op session cleanup so call sites stay compile-clean while PiP is off.
@MainActor
enum PodcastVideoPictureInPictureCoordinator {
    static let shared = PodcastVideoPictureInPictureCoordinatorProxy()
}

@MainActor
final class PodcastVideoPictureInPictureCoordinatorProxy {
    func endSession() {}
    func setAutomaticStartEnabled(_ enabled: Bool) {
        _ = enabled
    }
}
#endif
