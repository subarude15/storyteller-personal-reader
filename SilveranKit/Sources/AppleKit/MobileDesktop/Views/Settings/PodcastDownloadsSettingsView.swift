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
    @State private var adStripURLText = PodcastAdStripSettings.urlString
    @State private var adStripTestStatus: AdStripTestStatus = .idle
    @State private var adStripTestTask: Task<Void, Never>?
    @State private var youtubeResolveURLText = PodcastYouTubeResolveSettings.urlString
    @State private var youtubeResolveTestStatus: AdStripTestStatus = .idle
    @State private var youtubeResolveTestTask: Task<Void, Never>?
    @State private var sponsorBlockEnabled = SponsorBlockSettings.isEnabled
    @State private var sponsorBlockShowToast = SponsorBlockSettings.showSkipToast

    public init() {}

    private enum AdStripTestStatus: Equatable {
        case idle
        case testing
        case ok(String)
        case failed(String)
    }

    private var settings: PodcastDownloadSettings {
        store.settings
    }

    public var body: some View {
        Form {
            Section {
                TextField("http://192.168.1.2:20129", text: $adStripURLText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onChange(of: adStripURLText) { _, newValue in
                        PodcastAdStripSettings.urlString = newValue
                        if case .ok = adStripTestStatus { adStripTestStatus = .idle }
                        if case .failed = adStripTestStatus { adStripTestStatus = .idle }
                    }
                Button {
                    adStripTestTask?.cancel()
                    adStripTestTask = Task { await runAdStripTest() }
                } label: {
                    HStack {
                        Text("Test")
                        Spacer()
                        switch adStripTestStatus {
                            case .idle:
                                EmptyView()
                            case .testing:
                                ProgressView()
                                    .controlSize(.small)
                            case .ok(let detail):
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            case .failed(let detail):
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.trailing)
                        }
                    }
                }
                .disabled({
                    if case .testing = adStripTestStatus { return true }
                    return false
                }())
            } header: {
                Text("Ad strip URL")
            } footer: {
                Text(adStripFooterText)
            }

            Section {
                TextField("http://192.168.1.2:20130", text: $youtubeResolveURLText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onChange(of: youtubeResolveURLText) { _, newValue in
                        PodcastYouTubeResolveSettings.urlString = newValue
                        if case .ok = youtubeResolveTestStatus { youtubeResolveTestStatus = .idle }
                        if case .failed = youtubeResolveTestStatus { youtubeResolveTestStatus = .idle }
                    }
                Button {
                    youtubeResolveTestTask?.cancel()
                    youtubeResolveTestTask = Task { await runYouTubeResolveTest() }
                } label: {
                    HStack {
                        Text("Test")
                        Spacer()
                        switch youtubeResolveTestStatus {
                            case .idle:
                                EmptyView()
                            case .testing:
                                ProgressView()
                                    .controlSize(.small)
                            case .ok(let detail):
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            case .failed(let detail):
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.trailing)
                        }
                    }
                }
                .disabled({
                    if case .testing = youtubeResolveTestStatus { return true }
                    return false
                }())
            } header: {
                Text("YouTube resolve URL")
            } footer: {
                Text(youtubeResolveFooterText)
            }

            Section {
                Toggle("Skip sponsors & intros", isOn: $sponsorBlockEnabled)
                    .onChange(of: sponsorBlockEnabled) { _, newValue in
                        SponsorBlockSettings.isEnabled = newValue
                    }
                if sponsorBlockEnabled {
                    ForEach(SponsorBlockCategory.allCases) { category in
                        Toggle(
                            category.settingsTitle,
                            isOn: Binding(
                                get: { SponsorBlockSettings.isCategoryEnabled(category) },
                                set: { SponsorBlockSettings.setCategory(category, enabled: $0) }
                            )
                        )
                    }
                    Toggle("Show skip toast", isOn: $sponsorBlockShowToast)
                        .onChange(of: sponsorBlockShowToast) { _, newValue in
                            SponsorBlockSettings.showSkipToast = newValue
                        }
                }
            } header: {
                Text("SponsorBlock")
            } footer: {
                Text(
                    "Auto-skip marked segments while watching YouTube in ink+amp (Match / Play in ink+amp). Not used for podcast Clean downloads. Soft-fails if the API is unreachable."
                )
            }

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
            adStripURLText = PodcastAdStripSettings.urlString
            youtubeResolveURLText = PodcastYouTubeResolveSettings.urlString
            sponsorBlockEnabled = SponsorBlockSettings.isEnabled
            sponsorBlockShowToast = SponsorBlockSettings.showSkipToast
            if settings.autoCleanEnabled && !settings.hasSeenAutoCleanExplainer {
                showExplainer = true
            }
        }
        .onDisappear {
            adStripTestTask?.cancel()
            youtubeResolveTestTask?.cancel()
        }
    }

    private var adStripFooterText: String {
        var text =
            "PrincessDonut worker base URL (no trailing path). Clean downloads upload Original, poll the job, then save a Clean sibling — Original is never deleted."
        if let err = PodcastAdStripSettings.lastReachError {
            text += " Last error: \(err)."
        }
        return text
    }

    private var youtubeResolveFooterText: String {
        var text =
            "Invidious / Piped-style base URL (no trailing path). Play in ink+amp and Match on YouTube use this host — /api/v1/videos/{id}, /api/v1/search, or Piped /streams/{id}. Soft timeout ~20s; resolve failure toasts and opens Watch on YouTube."
        if let err = PodcastYouTubeResolveSettings.lastReachError {
            text += " Last error: \(err)."
        }
        return text
    }

    private func runAdStripTest() async {
        await MainActor.run { adStripTestStatus = .testing }
        PodcastAdStripSettings.urlString = adStripURLText
        guard let base = PodcastAdStripSettings.baseURL else {
            await MainActor.run {
                adStripTestStatus = .failed("Enter a URL")
                PodcastAdStripSettings.markUnreachable("empty URL")
            }
            return
        }
        let result = await PodcastAdStripHTTPPipeline.shared.testReachability(baseURL: base)
        await MainActor.run {
            switch result {
                case .success:
                    PodcastAdStripSettings.clearOfflineState()
                    adStripTestStatus = .ok("OK")
                case .failure(let error):
                    let message: String
                    switch error {
                        case .timedOut:
                            message = "Timed out"
                        case .missingURL:
                            message = "Enter a URL"
                        case .unreachable(let detail):
                            message = detail.isEmpty ? "Unreachable" : String(detail.prefix(80))
                        case .badResponse(let detail):
                            message = String(detail.prefix(80))
                        case .jobFailed(let detail):
                            message = String(detail.prefix(80))
                    }
                    PodcastAdStripSettings.markUnreachable(message)
                    adStripTestStatus = .failed(message)
            }
        }
    }

    private func runYouTubeResolveTest() async {
        await MainActor.run { youtubeResolveTestStatus = .testing }
        PodcastYouTubeResolveSettings.urlString = youtubeResolveURLText
        guard let base = PodcastYouTubeResolveSettings.baseURL else {
            await MainActor.run {
                youtubeResolveTestStatus = .failed("Enter a URL")
                PodcastYouTubeResolveSettings.markUnreachable("empty URL")
            }
            return
        }
        let result = await PodcastYouTubeResolver.shared.testReachability(baseURL: base)
        await MainActor.run {
            switch result {
                case .success(let label):
                    PodcastYouTubeResolveSettings.clearOfflineState()
                    youtubeResolveTestStatus = .ok(label)
                case .failure(let error):
                    let message: String
                    switch error {
                        case .timedOut:
                            message = "Timed out"
                        case .missingURL:
                            message = "Enter a URL"
                        case .missingVideoID:
                            message = "Bad video id"
                        case .unreachable(let detail):
                            message = detail.isEmpty ? "Unreachable" : String(detail.prefix(80))
                        case .badResponse(let detail):
                            message = String(detail.prefix(80))
                        case .noStream:
                            message = "No stream"
                    }
                    PodcastYouTubeResolveSettings.markUnreachable(message)
                    youtubeResolveTestStatus = .failed(message)
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
