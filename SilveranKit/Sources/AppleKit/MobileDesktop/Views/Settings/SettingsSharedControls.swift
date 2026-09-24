#if os(iOS) || os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import SilveranKit
import SilveranAppleWidgets

#if os(macOS)
import AppKit
#else
import UIKit
import CryptoKit
#endif

struct DebouncedOpacitySlider: View {
    @Binding var value: Double
    @State private var localValue: Double = 0
    @State private var debounceTask: Task<Void, Never>?
    @State private var isUpdatingFromSlider = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Opacity: \(Int(localValue * 100))%")
                .font(.subheadline)
            Slider(value: $localValue, in: 0.1...1.0, step: 0.01)
                .onAppear {
                    localValue = value
                }
                .onChange(of: localValue) { _, newValue in
                    debounceTask?.cancel()
                    debounceTask = Task {
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            isUpdatingFromSlider = true
                            value = newValue
                            isUpdatingFromSlider = false
                        }
                    }
                }
                .onChange(of: value) { _, newValue in
                    guard !isUpdatingFromSlider else { return }
                    localValue = newValue
                }
        }
    }
}

struct GeneralSettingsFields: View {
    @Binding var sync: SilveranGlobalConfig.Sync
    @State private var showClearConfirmation = false

    private let syncIntervals: [Double] = [10, 30, 60, 120, 300, 600, 1800, 3600, 7200, 14400, -1]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Progress Sync Interval")
                .font(.subheadline)
                .foregroundStyle(.primary)
            HStack(spacing: 12) {
                Picker(
                    "",
                    selection: Binding(
                        get: { sync.progressSyncIntervalSeconds },
                        set: { sync.progressSyncIntervalSeconds = $0 },
                    ),
                ) {
                    ForEach(syncIntervals, id: \.self) { interval in
                        Text(formatInterval(interval)).tag(interval)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }

        VStack(alignment: .leading, spacing: 8) {
            Text("Metadata Refresh Interval")
                .font(.subheadline)
                .foregroundStyle(.primary)
            HStack(spacing: 12) {
                Picker(
                    "",
                    selection: Binding(
                        get: { sync.metadataRefreshIntervalSeconds },
                        set: { sync.metadataRefreshIntervalSeconds = $0 },
                    ),
                ) {
                    ForEach(syncIntervals, id: \.self) { interval in
                        Text(formatInterval(interval)).tag(interval)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }

    }

    var autoNavigateSection: some View {
        Section {
            Toggle(
                "Auto-navigate to server position",
                isOn: $sync.autoSyncToNewerServerPosition,
            )
        } footer: {
            Text(
                "When the server has a newer reading position (from another device), automatically jump to that position."
            )
        }
    }

    private func formatInterval(_ seconds: Double) -> String {
        if seconds < 0 {
            return "Never"
        }
        let s = Int(seconds)
        if s < 60 {
            return "\(s) seconds"
        } else if s < 3600 {
            let m = s / 60
            return "\(m) minute\(m == 1 ? "" : "s")"
        } else {
            let h = s / 3600
            return "\(h) hour\(h == 1 ? "" : "s")"
        }
    }
}

extension Color {
    // init?(hex:) lives in Theme/Color+Hex.swift (shared with InkAmpAppTheme).

    #if os(macOS)
    func hexString() -> String? {
        let nsColor = NSColor(self)
        if let converted = nsColor.usingColorSpace(.sRGB) {
            let r = Int(round(converted.redComponent * 255))
            let g = Int(round(converted.greenComponent * 255))
            let b = Int(round(converted.blueComponent * 255))
            return String(format: "#%02X%02X%02X", r, g, b)
        }
        if let converted = nsColor.usingColorSpace(.deviceRGB) {
            let r = Int(round(converted.redComponent * 255))
            let g = Int(round(converted.greenComponent * 255))
            let b = Int(round(converted.blueComponent * 255))
            return String(format: "#%02X%02X%02X", r, g, b)
        }
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        nsColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
    #else
    func hexString() -> String? {
        let uiColor = UIColor(self)
        guard
            let converted = uiColor.cgColor.converted(
                to: CGColorSpace(name: CGColorSpace.sRGB)!,
                intent: .defaultIntent,
                options: nil,
            ),
            let components = converted.components
        else {
            return nil
        }
        let r = components.count > 0 ? components[0] : 0
        let g = components.count > 1 ? components[1] : 0
        let b = components.count > 2 ? components[2] : 0
        return String(
            format: "#%02X%02X%02X",
            Int(round(r * 255)),
            Int(round(g * 255)),
            Int(round(b * 255)),
        )
    }
    #endif
}


#endif
