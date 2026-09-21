#if os(iOS) || os(macOS)
import Foundation

#if os(iOS)
import UIKit
#endif

@MainActor
final class ScreenWakeLock {
    static let shared = ScreenWakeLock()

    #if os(iOS)
    /// Read-aloud and internal video share one system flag. Each reason is
    /// tracked so releasing one cannot clear the other or leave video stuck on.
    private var holds = DisplaySleepHolds()
    private var lastAppliedIdleTimerDisabled: Bool?
    #endif

    #if os(macOS)
    private var displaySleepActivity: NSObjectProtocol?
    #endif

    private init() {}

    /// Read-aloud / media-overlay narration. Not used for audiobooks or podcast audio.
    func set(_ enabled: Bool) {
        #if os(iOS)
        holds.setNarration(enabled)
        applyIdleTimer()
        #elseif os(macOS)
        if enabled {
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

    #if os(iOS)
    /// Internal video playback only. Audio-only sessions must not call this.
    func setVideoPlaybackPreventsSleep(_ enabled: Bool) {
        holds.setVideoPlayback(enabled)
        applyIdleTimer()
    }

    private func applyIdleTimer() {
        let disabled = holds.disablesIdleTimer
        guard disabled != lastAppliedIdleTimerDisabled else { return }
        lastAppliedIdleTimerDisabled = disabled
        UIApplication.shared.isIdleTimerDisabled = disabled
        debugLog(
            "[ScreenWakeLock] iOS idle timer \(disabled ? "disabled" : "enabled") narration=\(holds.narration) video=\(holds.videoPlayback)"
        )
    }
    #endif
}
#endif
