#if os(iOS)
import AppIntents
import SilveranAppleWidgets

/// Host-app Shortcuts surface for manual download intake.
struct InkAmpAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddDownloadToInkAmpIntent(),
            phrases: [
                "Add download to \(.applicationName)",
                "Send torrent to \(.applicationName)",
            ],
            shortTitle: "Add Download",
            systemImageName: "arrow.down.doc",
        )
    }
}
#endif
