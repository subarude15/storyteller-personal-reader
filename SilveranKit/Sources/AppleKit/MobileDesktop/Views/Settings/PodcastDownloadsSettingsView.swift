#if os(iOS)
import SilveranKit
import SwiftUI

/// Settings → Podcasts → Downloads (auto-prune policy from PODCASTS-SHELF-PRUNE.md).
public struct PodcastDownloadsSettingsView: View {
    @State private var store = PodcastDownloadStore.shared
    @State private var showExplainer = false
    @State private var showCleanPreview = false
    @State private var previewCandidates: [PodcastPruneCandidate] = []
    @State private var advancedExpanded = false

    public init() {}

    private var settings: PodcastDownloadSettings {
        store.settings
    }

    public var body: some View {
        Form {
            Section {
                Toggle("Auto-clean downloads", isOn: autoCleanBinding)
            } footer: {
                Text(
                    "Auto-remove finished episodes and anything older than 30 days (keeps pinned + in-progress)."
                )
            }

            if settings.autoCleanEnabled {
                Section {
                    Toggle("Remove when finished", isOn: removeWhenFinishedBinding)

                    Picker("Max age", selection: maxAgeBinding) {
                        Text("Off").tag(Optional<Int>.none)
                        Text("7 days").tag(Optional(7))
                        Text("14 days").tag(Optional(14))
                        Text("30 days").tag(Optional(30))
                        Text("90 days").tag(Optional(90))
                    }

                    Picker("Max downloads", selection: maxDownloadsBinding) {
                        Text("Off").tag(Optional<Int>.none)
                        Text("25").tag(Optional(25))
                        Text("50").tag(Optional(50))
                        Text("100").tag(Optional(100))
                    }
                } header: {
                    Text("Downloads")
                }

                Section {
                    DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                        Picker("Protect if played at least", selection: protectBinding) {
                            Text("0%").tag(0.0)
                            Text("10%").tag(0.10)
                            Text("25%").tag(0.25)
                            Text("50%").tag(0.50)
                        }
                    }
                }

                Section {
                    Button("Clean now") {
                        previewCandidates = store.previewPrune()
                        showCleanPreview = true
                    }
                } footer: {
                    if let last = settings.lastPruneAt, settings.lastPruneCount > 0 {
                        Text(
                            "Last cleaned \(settings.lastPruneCount) episode\(settings.lastPruneCount == 1 ? "" : "s") · \(last.formatted(date: .abbreviated, time: .shortened))"
                        )
                    }
                }
            }
        }
        .navigationTitle("Podcast Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showExplainer) {
            PodcastAutoCleanExplainerSheet(
                onContinue: {
                    store.markExplainerSeen()
                    showExplainer = false
                },
                onDefer: {
                    showExplainer = false
                }
            )
        }
        .sheet(isPresented: $showCleanPreview) {
            PodcastCleanNowPreviewSheet(
                candidates: previewCandidates,
                onConfirm: {
                    _ = store.applyPrune(previewCandidates)
                    showCleanPreview = false
                },
                onCancel: { showCleanPreview = false }
            )
        }
        .onAppear {
            if settings.autoCleanEnabled && !settings.hasSeenAutoCleanExplainer {
                showExplainer = true
            }
        }
    }

    private var autoCleanBinding: Binding<Bool> {
        Binding(
            get: { store.settings.autoCleanEnabled },
            set: { newValue in
                let wasOff = !store.settings.autoCleanEnabled
                store.updateSettings { $0.autoCleanEnabled = newValue }
                if newValue && wasOff && !store.settings.hasSeenAutoCleanExplainer {
                    showExplainer = true
                }
            }
        )
    }

    private var removeWhenFinishedBinding: Binding<Bool> {
        Binding(
            get: { store.settings.removeWhenFinished },
            set: { newValue in store.updateSettings { $0.removeWhenFinished = newValue } }
        )
    }

    private var maxAgeBinding: Binding<Int?> {
        Binding(
            get: { store.settings.maxAgeDays },
            set: { newValue in store.updateSettings { $0.maxAgeDays = newValue } }
        )
    }

    private var maxDownloadsBinding: Binding<Int?> {
        Binding(
            get: { store.settings.maxDownloads },
            set: { newValue in store.updateSettings { $0.maxDownloads = newValue } }
        )
    }

    private var protectBinding: Binding<Double> {
        Binding(
            get: { store.settings.protectProgress },
            set: { newValue in store.updateSettings { $0.protectProgress = newValue } }
        )
    }
}

struct PodcastAutoCleanExplainerSheet: View {
    let onContinue: () -> Void
    let onDefer: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Auto-clean podcast downloads")
                    .font(.title2.weight(.semibold))
                Text(
                    "ink+amp can free Shelf space by removing finished episodes and abandoned downloads older than your max age. Pinned episodes and ones you’re still listening to stay."
                )
                .foregroundStyle(.secondary)
                Text(
                    "Defaults: remove when finished, 30-day max age, keep up to 50 downloads, protect if played at least 10%."
                )
                .foregroundStyle(.secondary)
                Spacer()
                Button(action: onContinue) {
                    Text("Got it")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now", action: onDefer)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct PodcastCleanNowPreviewSheet: View {
    let candidates: [PodcastPruneCandidate]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if candidates.isEmpty {
                    Text("Nothing to remove right now.")
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(candidates) { candidate in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(candidate.record.title)
                                    .font(.body.weight(.medium))
                                if let show = candidate.record.showTitle {
                                    Text(show)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(candidate.reason.rawValue)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("Would remove \(candidates.count)")
                    }
                }
            }
            .navigationTitle("Clean now")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Remove", role: .destructive, action: onConfirm)
                        .disabled(candidates.isEmpty)
                }
            }
        }
    }
}
#endif
