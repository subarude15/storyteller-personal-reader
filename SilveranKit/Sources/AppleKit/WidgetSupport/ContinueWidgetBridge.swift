import Foundation
import SilveranKit

#if canImport(AppIntents) && os(iOS)
import AppIntents
#endif

/// Cross-process Continue widget → app bridge.
///
/// App Group holds the snapshot; Darwin notifications poke the running app
/// for play/pause when the widget intent cannot reach `AudioSessionActor`
/// in-process (extension process / AltStore edge cases).
public enum ContinueWidgetBridge {
    public static let toggleDarwinName = "com.punkrally.reader.continueToggle"
    public static let openDarwinName = "com.punkrally.reader.continueOpen"
    private static let defaultsToggleKey = "continue.widget.pendingToggle"
    private static let defaultsOpenKey = "continue.widget.pendingOpen"

    private static var suite: UserDefaults? {
        UserDefaults(suiteName: SilveranWidgetSnapshotStore.appGroupIdentifier())
    }

    public static func postToggle() {
        suite?.set(true, forKey: defaultsToggleKey)
        suite?.synchronize()
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(toggleDarwinName as CFString),
            nil,
            nil,
            true,
        )
    }

    public static func postOpenContinue() {
        suite?.set(true, forKey: defaultsOpenKey)
        suite?.synchronize()
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(openDarwinName as CFString),
            nil,
            nil,
            true,
        )
    }

    public static func consumePendingToggle() -> Bool {
        guard suite?.bool(forKey: defaultsToggleKey) == true else { return false }
        suite?.set(false, forKey: defaultsToggleKey)
        return true
    }

    public static func consumePendingOpen() -> Bool {
        guard suite?.bool(forKey: defaultsOpenKey) == true else { return false }
        suite?.set(false, forKey: defaultsOpenKey)
        return true
    }

    /// Install once from the host app. Handlers run on an arbitrary queue.
    public static func installAppObservers(
        onToggle: @escaping @Sendable () -> Void,
        onOpen: @escaping @Sendable () -> Void,
    ) {
        let toggleCallback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            let box = Unmanaged<ObserverBox>.fromOpaque(observer).takeUnretainedValue()
            box.onToggle()
        }
        let openCallback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            let box = Unmanaged<ObserverBox>.fromOpaque(observer).takeUnretainedValue()
            box.onOpen()
        }
        let box = ObserverBox(onToggle: onToggle, onOpen: onOpen)
        let retained = Unmanaged.passRetained(box)
        // ponytail: retained for process lifetime; uninstall not needed for ink+amp host.
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            retained.toOpaque(),
            toggleCallback,
            toggleDarwinName as CFString,
            nil,
            .deliverImmediately,
        )
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            retained.toOpaque(),
            openCallback,
            openDarwinName as CFString,
            nil,
            .deliverImmediately,
        )
    }

    private final class ObserverBox: @unchecked Sendable {
        let onToggle: @Sendable () -> Void
        let onOpen: @Sendable () -> Void
        init(onToggle: @escaping @Sendable () -> Void, onOpen: @escaping @Sendable () -> Void) {
            self.onToggle = onToggle
            self.onOpen = onOpen
        }
    }
}

#if canImport(AppIntents) && os(iOS)
/// Interactive Continue play/pause. Prefers in-process audio session; falls
/// back to Darwin/App Group so AltStore can still poke a backgrounded player.
@available(iOS 17.0, *)
public struct ContinueTogglePlaybackIntent: AudioPlaybackIntent {
    public static let title: LocalizedStringResource = "Play or Pause"
    public static let description = IntentDescription(
        "Toggle ink+amp Continue playback from the Home Screen widget."
    )

    public init() {}

    public func perform() async throws -> some IntentResult {
        if await AudioSessionActor.shared.currentSnapshot() != nil {
            try? await AudioSessionActor.shared.transport(.togglePlayPause)
        } else {
            // No live session in this process — ask the host app (may need open).
            ContinueWidgetBridge.postToggle()
            ContinueWidgetBridge.postOpenContinue()
        }
        return .result()
    }
}
#endif
