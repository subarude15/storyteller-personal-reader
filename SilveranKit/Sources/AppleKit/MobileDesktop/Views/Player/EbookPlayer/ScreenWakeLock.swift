#if os(iOS) || os(macOS)
import Foundation

#if os(iOS)
import UIKit
#endif

/// Process-wide idle-timer / display-sleep lock.
///
/// Clients hold a named token (`IdleTimerHold`). The timer stays disabled
/// until every holder releases, so video playback and read-aloud cannot
/// clear each other's lock or leave the screen awake after they stop.
@MainActor
final class ScreenWakeLock {
    static let shared = ScreenWakeLock()

    private var hold = IdleTimerHold()
    private var appliedDisablesIdleTimer = false

    #if os(macOS)
    private var displaySleepActivity: NSObjectProtocol?
    #endif

    private init() {}

    func set(_ enabled: Bool) {
        set(enabled, for: IdleTimerClient.mediaOverlay)
    }

    func set(_ enabled: Bool, for client: String) {
        hold = hold.setting(enabled, client: client)
        apply(hold.disablesIdleTimer)
    }

    func applyInternalVideo(_ context: InternalVideoPlaybackContext) {
        set(
            InternalVideoPlaybackLifecycle.shouldDisableIdleTimer(context),
            for: IdleTimerClient.internalVideo
        )
    }

    func releaseInternalVideo() {
        set(false, for: IdleTimerClient.internalVideo)
    }

    private func apply(_ disablesIdleTimer: Bool) {
        guard disablesIdleTimer != appliedDisablesIdleTimer else { return }
        appliedDisablesIdleTimer = disablesIdleTimer
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = disablesIdleTimer
        debugLog(
            "[ScreenWakeLock] iOS idle timer \(disablesIdleTimer ? "disabled" : "enabled")"
        )
        #elseif os(macOS)
        if disablesIdleTimer {
            guard displaySleepActivity == nil else { return }
            displaySleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated],
                reason: "Audio narration playback",
            )
            debugLog("[ScreenWakeLock] macOS display sleep disabled")
        } else if let activity = displaySleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            displaySleepActivity = nil
            debugLog("[ScreenWakeLock] macOS display sleep enabled")
        }
        #endif
    }
}
#endif
