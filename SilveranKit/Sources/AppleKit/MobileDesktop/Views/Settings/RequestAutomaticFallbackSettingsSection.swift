#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI

/// Opt-in automatic provider fallback under Book requests.
struct RequestAutomaticFallbackSettingsSection: View {
    @State private var enabled = RequestAutomaticFallbackSettings.enabled
    @State private var delay = RequestAutomaticFallbackSettings.delay

    var body: some View {
        Section {
            Toggle(
                "Automatically try another provider",
                isOn: Binding(
                    get: { enabled },
                    set: { value in
                        enabled = value
                        RequestAutomaticFallbackSettings.enabled = value
                    },
                )
            )
            if enabled {
                Picker(
                    "Fallback delay",
                    selection: Binding(
                        get: { delay },
                        set: { value in
                            delay = value
                            RequestAutomaticFallbackSettings.delay = value
                        },
                    )
                ) {
                    ForEach(AutomaticFallbackDelay.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
            }
        } header: {
            Text("Automatic Fallback")
        } footer: {
            Text(
                "If a book request needs attention, ink+amp can try the other configured request provider once. Automatic fallback never uses your LAN-only alternate search and will not repeatedly bounce requests between providers."
            )
        }
        .onAppear {
            enabled = RequestAutomaticFallbackSettings.enabled
            delay = RequestAutomaticFallbackSettings.delay
        }
    }
}
#endif
