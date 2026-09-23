#if os(iOS)
import UIKit

/// Single owner of idle-timer changes for internal video playback.
///
/// Portrait, landscape, and fullscreen all report through
/// `PodcastVideoPresentationCoordinator`. This type decides whether that
/// session should keep the screen awake and asks `ScreenWakeLock` to apply
/// it, so read-aloud narration and video cannot clear each other's hold.
@MainActor
final class VideoPlaybackSleepController {
    static let shared = VideoPlaybackSleepController()

    private var state = VideoPlaybackSleepState(appIsActive: true)
    private var observers: [NSObjectProtocol] = []
    private var started = false

    private init() {}

    func notePlayerVisibility(isInternalVideo: Bool, isPlayerExpanded: Bool) {
        startIfNeeded()
        apply(.playerVisibility(isInternalVideo: isInternalVideo, isPlayerExpanded: isPlayerExpanded))
    }

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        if UIApplication.shared.applicationState != .active {
            state.appIsActive = false
        }

        observe(UIApplication.didEnterBackgroundNotification) { _ in
            .appBackgrounded
        }
        observe(UIApplication.didBecomeActiveNotification) { _ in
            .appBecameActive
        }
        observe(.punkRallyPodcastPlaybackBecameActive) { _ in
            .playbackBecameActive
        }
        observe(Notification.Name("punkRallyPodcastDidFinish")) { _ in
            .playbackDidFinish
        }

        Task {
            await AudioSessionActor.shared.addSnapshotObserver { snapshot in
                let isPodcast: Bool
                if let snapshot, case .podcast = snapshot.kind {
                    isPodcast = true
                } else {
                    isPodcast = false
                }
                Task { @MainActor in
                    VideoPlaybackSleepController.shared.apply(.sessionSnapshot(isPodcast: isPodcast))
                }
            }
        }
    }

    private func observe(
        _ name: Notification.Name,
        event: @escaping @Sendable (Notification) -> VideoPlaybackSleepEvent
    ) {
        observers.append(
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { note in
                let mapped = event(note)
                Task { @MainActor in
                    VideoPlaybackSleepController.shared.apply(mapped)
                }
            }
        )
    }

    private func apply(_ event: VideoPlaybackSleepEvent) {
        state = VideoPlaybackSleepLogic.reduce(state: state, event: event)
        // Always push the video reason. Releasing it is unconditional on
        // dismiss, end, background, and session teardown, so the hold cannot
        // stay on after leaving playback. Narration is a separate reason.
        ScreenWakeLock.shared.setVideoPlaybackPreventsSleep(state.preventsSleep)
    }
}
#endif
