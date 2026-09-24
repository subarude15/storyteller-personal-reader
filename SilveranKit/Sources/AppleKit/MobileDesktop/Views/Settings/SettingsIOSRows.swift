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

#if os(iOS)
struct BedtimeSettingsRow: View {
    @State private var bedtime = BedtimeSettings.date(
        fromMinutesFromMidnight: BedtimeSettings.minutesFromMidnight
    )

    var body: some View {
        DatePicker(
            "Bedtime",
            selection: $bedtime,
            displayedComponents: .hourAndMinute
        )
        .onChange(of: bedtime) { _, newValue in
            BedtimeSettings.minutesFromMidnight = BedtimeSettings.minutesFromMidnight(
                from: newValue
            )
        }
        .onAppear {
            bedtime = BedtimeSettings.date(
                fromMinutesFromMidnight: BedtimeSettings.minutesFromMidnight
            )
        }
    }
}

struct StatsLastSyncSettingsRow: View {
    @State private var lastSync: Date?
    @State private var isSyncing = false
    @State private var footerLabel: String?
    @State private var tick = 0

    var body: some View {
        let _ = tick
        Button {
            guard !isSyncing else { return }
            isSyncing = true
            footerLabel = "Syncing…"
            NotificationCenter.default.post(name: .punkRallyRetryStatsSync, object: nil)
        } label: {
            LabeledContent("Last Stats sync") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(primaryLabel)
                        .foregroundStyle(isSyncing ? Color.accentColor : .secondary)
                        .multilineTextAlignment(.trailing)
                    if let secondaryLabel {
                        Text(secondaryLabel)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isSyncing)
        .accessibilityHint("Retries Stats sync across your devices")
        .onAppear { reload() }
        .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { _ in
            if !isSyncing { reload() }
            tick &+= 1
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .punkRallyStatsSyncUIDidChange)
        ) { note in
            applyUI(note.userInfo)
        }
    }

    private var primaryLabel: String {
        if isSyncing { return "Syncing…" }
        if let footerLabel { return footerLabel }
        guard lastSync != nil else { return "Not yet" }
        return "Synced across your devices"
    }

    private var secondaryLabel: String? {
        if isSyncing { return nil }
        guard let lastSync else {
            return footerLabel == nil ? nil : "Not yet"
        }
        return Self.formatter.string(from: lastSync)
    }

    private func reload() {
        lastSync = UserDefaults.standard.object(
            forKey: InkampStatsSyncDefaults.lastSuccessfulSyncAtKey
        ) as? Date
    }

    private func applyUI(_ userInfo: [AnyHashable: Any]?) {
        if let syncing = userInfo?["isSyncing"] as? Bool {
            isSyncing = syncing
        }
        if let label = userInfo?["footerLabel"] as? String {
            footerLabel = label
        }
        if let last = userInfo?["lastSuccessfulSyncAt"] as? Date {
            lastSync = last
        } else if isSyncing == false {
            reload()
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

struct YouTubePlayheadLastSyncSettingsRow: View {
    @State private var lastSync: Date?
    @State private var isSyncing = false
    @State private var footerLabel: String?
    @State private var tick = 0

    var body: some View {
        let _ = tick
        Button {
            guard !isSyncing else { return }
            isSyncing = true
            footerLabel = "Syncing…"
            NotificationCenter.default.post(
                name: .punkRallyRetryYouTubePlayheadSync,
                object: nil
            )
        } label: {
            LabeledContent("Last YouTube playhead sync") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(primaryLabel)
                        .foregroundStyle(isSyncing ? Color.accentColor : .secondary)
                        .multilineTextAlignment(.trailing)
                    if let secondaryLabel {
                        Text(secondaryLabel)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isSyncing)
        .accessibilityHint("Retries YouTube playhead sync across your devices")
        .onAppear { reload() }
        .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { _ in
            if !isSyncing { reload() }
            tick &+= 1
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .punkRallyYouTubePlayheadSyncUIDidChange)
        ) { note in
            applyUI(note.userInfo)
        }
    }

    private var primaryLabel: String {
        if isSyncing { return "Syncing…" }
        if let footerLabel { return footerLabel }
        guard lastSync != nil else { return "Not yet" }
        return "Synced across your devices"
    }

    private var secondaryLabel: String? {
        if isSyncing { return nil }
        guard let lastSync else {
            return footerLabel == nil ? nil : "Not yet"
        }
        return Self.formatter.string(from: lastSync)
    }

    private func reload() {
        lastSync = UserDefaults.standard.object(
            forKey: InkampYouTubePlayheadSyncDefaults.lastSuccessfulSyncAtKey
        ) as? Date
    }

    private func applyUI(_ userInfo: [AnyHashable: Any]?) {
        if let syncing = userInfo?["isSyncing"] as? Bool {
            isSyncing = syncing
        }
        if let label = userInfo?["footerLabel"] as? String {
            footerLabel = label
        }
        if let last = userInfo?["lastSuccessfulSyncAt"] as? Date {
            lastSync = last
        } else if isSyncing == false {
            reload()
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

struct PodcastSyncLastSyncSettingsRow: View {
    @State private var lastSync: Date?
    @State private var isSyncing = false
    @State private var footerLabel: String?
    @State private var tick = 0

    var body: some View {
        let _ = tick
        Button {
            guard !isSyncing else { return }
            isSyncing = true
            footerLabel = "Syncing…"
            NotificationCenter.default.post(
                name: .punkRallyRetryPodcastSync,
                object: nil
            )
        } label: {
            LabeledContent("Last podcast sync") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(primaryLabel)
                        .foregroundStyle(isSyncing ? Color.accentColor : .secondary)
                        .multilineTextAlignment(.trailing)
                    if let secondaryLabel {
                        Text(secondaryLabel)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isSyncing)
        .accessibilityHint("Retries podcast subscription and playhead sync across your devices")
        .onAppear { reload() }
        .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { _ in
            if !isSyncing { reload() }
            tick &+= 1
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .punkRallyPodcastSyncUIDidChange)
        ) { note in
            applyUI(note.userInfo)
        }
    }

    private var primaryLabel: String {
        if isSyncing { return "Syncing…" }
        if let footerLabel { return footerLabel }
        guard lastSync != nil else { return "Not yet" }
        return "Synced across your devices"
    }

    private var secondaryLabel: String? {
        if isSyncing { return nil }
        guard let lastSync else {
            return footerLabel == nil ? nil : "Not yet"
        }
        return Self.formatter.string(from: lastSync)
    }

    private func reload() {
        lastSync = UserDefaults.standard.object(
            forKey: InkampPodcastSyncDefaults.lastSuccessfulSyncAtKey
        ) as? Date
    }

    private func applyUI(_ userInfo: [AnyHashable: Any]?) {
        if let syncing = userInfo?["isSyncing"] as? Bool {
            isSyncing = syncing
        }
        if let label = userInfo?["footerLabel"] as? String {
            footerLabel = label
        }
        if let last = userInfo?["lastSuccessfulSyncAt"] as? Date {
            lastSync = last
        } else if isSyncing == false {
            reload()
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
struct IOSDebugLogView: View {
    @State private var logText: String = ""
    @State private var messageCount: Int = 0
    @State private var verbose = DebugLogBuffer.shared.isVerbose

    var body: some View {
        List {
            Section {
                Toggle("Verbose logging", isOn: $verbose)
                    .onChange(of: verbose) { _, newValue in
                        DebugLogBuffer.shared.setVerbose(newValue)
                    }
            } footer: {
                Text(
                    "Includes high-volume performance diagnostics. Turn this on, reproduce the issue, then copy the log."
                )
            }

            Section {
                Text(logText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            } header: {
                Text("\(messageCount) messages")
            }
        }
        .navigationTitle("Debug Log")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = logText
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                Button {
                    DebugLogBuffer.shared.clear()
                    loadMessages()
                } label: {
                    Image(systemName: "trash")
                }
                Button {
                    loadMessages()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onAppear {
            loadMessages()
        }
    }

    private func loadMessages() {
        let messages = DebugLogBuffer.shared.getMessages()
        messageCount = messages.count
        logText = messages.joined(separator: "\n")
    }
}

#endif

#endif
