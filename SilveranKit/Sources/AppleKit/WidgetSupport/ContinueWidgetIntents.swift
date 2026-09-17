#if os(iOS)
import AppIntents
import Foundation
import SilveranKit

/// Transport the Continue widget can ask the live audio session to perform.
public enum ContinueWidgetTransportCommand: Sendable, CaseIterable {
    case togglePlayPause
    case skipBackward
    case skipForward

    /// Matches the in-app player and Lock Screen/Control Center skip interval.
    public static var skipInterval: TimeInterval { AudioSessionActor.podcastSkipInterval }
}

/// Shared transport used by the widget's AppIntent buttons.
///
/// The intents conform to `AudioPlaybackIntent`, so WidgetKit performs them in
/// the *app's* process (launching it in the background when needed) instead of
/// the widget extension's sandbox. That is what makes play/pause/skip work
/// without the app coming forward.
///
/// The intent type must exist in **both** the app target and the widget
/// extension target — both link `SilveranAppleWidgets`, so that holds.
public enum ContinueWidgetTransport {
    /// - Returns: true when a live session handled the command.
    @discardableResult
    public static func perform(_ command: ContinueWidgetTransportCommand) async -> Bool {
        let session = await AudioSessionActor.shared.currentSnapshot()
        guard session != nil else {
            // App relaunched with nothing playing: keep the tile honest so the
            // next tap takes the deep link into ink+amp Continue instead of
            // appearing to play.
            ContinueWidgetSnapshotStore.markSessionInactive()
            ContinueWidgetSnapshotStore.reloadTimelines()
            return false
        }

        switch command {
            case .togglePlayPause:
                try? await AudioSessionActor.shared.transport(.togglePlayPause)
            case .skipForward:
                await AudioSessionActor.shared.skipPlayback(
                    by: ContinueWidgetTransportCommand.skipInterval
                )
            case .skipBackward:
                await AudioSessionActor.shared.skipPlayback(
                    by: -ContinueWidgetTransportCommand.skipInterval
                )
        }

        await ContinueWidgetSnapshotStore.publishFromLiveSession()
        return true
    }
}

/// Play/Pause tile button. `AudioPlaybackIntent` keeps this in the app process
/// so it drives the same `AudioSessionActor` as the in-app player and the
/// Lock Screen controls.
public struct ContinuePlayPauseIntent: AudioPlaybackIntent {
    public static let title: LocalizedStringResource = "Play or Pause"
    public static let description = IntentDescription(
        "Play or pause what ink+amp is on right now."
    )

    /// iOS 26 replacement for `openAppWhenRun`: `.background` means the tile
    /// button never brings ink+amp forward, while `AudioPlaybackIntent` still
    /// routes `perform()` into the app's process.
    @available(iOS 26.0, *)
    public static var supportedModes: IntentModes { .background }

    public init() {}

    public func perform() async throws -> some IntentResult {
        _ = await ContinueWidgetTransport.perform(.togglePlayPause)
        return .result()
    }
}

/// −15s tile button (same interval as the in-app player).
public struct ContinueSkipBackwardIntent: AudioPlaybackIntent {
    public static let title: LocalizedStringResource = "Skip Back 15 Seconds"
    public static let description = IntentDescription("Skip the current item back 15 seconds.")

    /// iOS 26 replacement for `openAppWhenRun`: `.background` means the tile
    /// button never brings ink+amp forward, while `AudioPlaybackIntent` still
    /// routes `perform()` into the app's process.
    @available(iOS 26.0, *)
    public static var supportedModes: IntentModes { .background }

    public init() {}

    public func perform() async throws -> some IntentResult {
        _ = await ContinueWidgetTransport.perform(.skipBackward)
        return .result()
    }
}

/// +15s tile button (same interval as the in-app player).
public struct ContinueSkipForwardIntent: AudioPlaybackIntent {
    public static let title: LocalizedStringResource = "Skip Forward 15 Seconds"
    public static let description = IntentDescription("Skip the current item forward 15 seconds.")

    /// iOS 26 replacement for `openAppWhenRun`: `.background` means the tile
    /// button never brings ink+amp forward, while `AudioPlaybackIntent` still
    /// routes `perform()` into the app's process.
    @available(iOS 26.0, *)
    public static var supportedModes: IntentModes { .background }

    public init() {}

    public func perform() async throws -> some IntentResult {
        _ = await ContinueWidgetTransport.perform(.skipForward)
        return .result()
    }
}
#endif
