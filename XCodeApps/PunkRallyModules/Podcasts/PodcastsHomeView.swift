//
//  PodcastsHomeView.swift
//  ink+amp
//
//  Ported from Enve Book Player (AGPL-3.0-only):
//  https://github.com/opisaac9001/Enve-Book-Player
//  Original: ios/enve/Screens/Podcasts/PodcastsHomeScreen.swift
//  Modifications: ink+amp tokens; RSS-only; no server provider.
//
//  SPDX-License-Identifier: AGPL-3.0-only

#if os(iOS)
import SwiftUI
import SilveranAppleKit
import SilveranKit

/// Podcasts tab: shows grid, latest episodes, Find shows, and paste-URL fallback.
struct PodcastsHomeView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = PodcastsViewModel()
    @State private var showFindShows = false
    @State private var showAddFeed = false
    @State private var selectedShow: PRPodcastShow?
    @State private var refreshTask: Task<Void, Never>?
    @State private var showPlaybackQueue = false
    @State private var playbackQueue = PodcastPlaybackQueueStore.shared

    private var chrome: PunkRallyTheme.Chrome {
        PunkRallyTheme.Chrome(scheme: colorScheme)
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.shows.isEmpty {
                    skeletonGrid
                } else if viewModel.loadFailed && viewModel.shows.isEmpty {
                    loadFailedState
                } else if viewModel.shows.isEmpty {
                    emptyState
                } else {
                    contentList
                }
            }
            .navigationTitle("Podcasts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showPlaybackQueue = true
                    } label: {
                        if playbackQueue.count > 0 {
                            Label("Play queue", systemImage: "list.bullet")
                                .badge(playbackQueue.count)
                        } else {
                            Label("Play queue", systemImage: "list.bullet")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showFindShows = true
                    } label: {
                        Label("Find shows", systemImage: "magnifyingglass")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddFeed = true
                    } label: {
                        Label("Paste RSS URL", systemImage: "link")
                    }
                }
            }
            .sheet(isPresented: $showFindShows) {
                FindPodcastShowsView(viewModel: viewModel) {
                    showFindShows = false
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        showAddFeed = true
                    }
                }
            }
            .sheet(isPresented: $showAddFeed) {
                AddPodcastFeedView(viewModel: viewModel)
            }
            .sheet(item: $selectedShow) { show in
                PodcastShowView(viewModel: viewModel, show: show)
            }
            .sheet(isPresented: $showPlaybackQueue) {
                PodcastPlaybackQueueView()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .punkRallyPodcastPlaybackQueueDidChange)
        ) { _ in
            playbackQueue = PodcastPlaybackQueueStore.shared
        }
        .task {
            await viewModel.loadIfNeeded()
        }
        .refreshable {
            await viewModel.load()
        }
    }

    private var contentList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if !viewModel.playableShows.isEmpty {
                    Text("Latest")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(chrome.text)
                }

                ForEach(viewModel.playableShows) { show in
                    Button {
                        selectedShow = show
                    } label: {
                        PodcastShowRow(show: show, chrome: chrome)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, PunkRallyTheme.Metric.screenInset)
            .padding(.vertical, 12)
        }
        .background(chrome.bg)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic")
                .font(.system(size: 44))
                .foregroundStyle(chrome.textFaint)
            Text("No podcasts yet")
                .font(.title2.weight(.semibold))
                .foregroundStyle(chrome.text)
            Text("Find a show by name, or paste an RSS feed URL. Podcasts stay separate from your Storyteller library.")
                .font(.body)
                .foregroundStyle(chrome.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                showFindShows = true
            } label: {
                Label("Find shows", systemImage: "magnifyingglass")
                    .font(.headline)
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(PunkRallyTheme.Accent.primary)
                    .clipShape(Capsule())
            }
            .padding(.top, 8)
            Button {
                showAddFeed = true
            } label: {
                Label("Paste RSS URL", systemImage: "link")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(PunkRallyTheme.Accent.primary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(chrome.bg)
    }

    private var loadFailedState: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(chrome.textFaint)
            Text("Couldn't refresh feeds")
                .font(.title2.weight(.semibold))
                .foregroundStyle(chrome.text)
            Text("Check your connection and try again. Your subscriptions are still saved on this device.")
                .font(.body)
                .foregroundStyle(chrome.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                Task { await viewModel.load() }
            } label: {
                Label("Try again", systemImage: "arrow.clockwise")
                    .font(.headline)
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(PunkRallyTheme.Accent.primary)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(chrome.bg)
    }

    private var skeletonGrid: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(0..<6, id: \.self) { index in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(chrome.surface2)
                            .frame(width: 72, height: 72)
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(chrome.surface2)
                                .frame(height: 16)
                                .frame(width: 180)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(chrome.surface2)
                                .frame(height: 12)
                                .frame(width: 120)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(chrome.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal, PunkRallyTheme.Metric.screenInset)
            .padding(.vertical, 12)
        }
        .background(chrome.bg)
    }
}

struct PodcastShowRow: View {
    let show: PRPodcastShow
    let chrome: PunkRallyTheme.Chrome

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: show.coverURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: 8)
                    .fill(chrome.surface2)
                    .overlay(
                        Image(systemName: "mic")
                            .foregroundStyle(chrome.textFaint)
                    )
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(show.title)
                    .font(.headline)
                    .foregroundStyle(chrome.text)
                    .lineLimit(2)
                if let author = show.author {
                    Text(author)
                        .font(.subheadline)
                        .foregroundStyle(chrome.textMuted)
                        .lineLimit(1)
                }
                Text("\(show.episodes.count) episodes")
                    .font(.caption)
                    .foregroundStyle(chrome.textFaint)
            }
            Spacer()
            KindBadgeView(kind: .podcast, scheme: chrome.scheme)
        }
        .padding(12)
        .background(chrome.surface)
        .clipShape(RoundedRectangle(cornerRadius: PunkRallyTheme.Metric.buttonCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: PunkRallyTheme.Metric.buttonCornerRadius)
                .stroke(chrome.border, lineWidth: 1)
        )
        .accessibilityLabel(Text("\(show.title), \(show.episodes.count) episodes"))
    }
}

struct AddPodcastFeedView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    let viewModel: PodcastsViewModel

    @State private var feedURLString = ""
    @State private var isAdding = false
    @State private var errorMessage: String?

    private var chrome: PunkRallyTheme.Chrome {
        PunkRallyTheme.Chrome(scheme: colorScheme)
    }

    private var trimmedURL: String {
        feedURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValidURL: Bool {
        guard let url = URL(string: trimmedURL), url.scheme == "https" || url.scheme == "http"
        else { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/feed.xml", text: $feedURLString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Advanced — paste RSS")
                } footer: {
                    Text("Use this when Find shows can't locate the feed. Enter the direct RSS/Atom URL. Shows appear under Podcasts — they never mix into your Storyteller library.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(PunkRallyTheme.Accent.danger)
                    }
                }

                Section {
                    Button {
                        Task {
                            await addFeed()
                        }
                    } label: {
                        if isAdding {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Adding…")
                            }
                        } else {
                            Text("Subscribe")
                        }
                    }
                    .disabled(!isValidURL || isAdding)
                }
            }
            .navigationTitle("Paste RSS URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func addFeed() async {
        guard let url = URL(string: trimmedURL) else { return }
        isAdding = true
        errorMessage = nil
        let ok = await viewModel.subscribe(feedURL: url)
        if ok {
            dismiss()
        } else {
            errorMessage = "Couldn't load that feed. Check the URL and try again."
        }
        isAdding = false
    }
}

struct PodcastShowView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    let viewModel: PodcastsViewModel
    let show: PRPodcastShow

    @State private var isSubscribed = false
    @State private var episodeFilter: ShowEpisodeFilter = .all
    @State private var downloadStore = PodcastDownloadStore.shared

    private var chrome: PunkRallyTheme.Chrome {
        PunkRallyTheme.Chrome(scheme: colorScheme)
    }

    private var filteredEpisodes: [PRPodcastEpisode] {
        show.episodes.filter { episodeMatchesFilter($0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        AsyncImage(url: show.coverURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(chrome.surface2)
                        }
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(show.title).font(.title3.weight(.bold))
                            if let author = show.author {
                                Text(author).font(.subheadline).foregroundStyle(.secondary)
                            }
                            KindBadgeView(kind: .podcast, scheme: colorScheme)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)

                    if let description = show.description {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Picker("Filter", selection: $episodeFilter) {
                        ForEach(ShowEpisodeFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                Section("Episodes") {
                    if show.episodes.isEmpty {
                        Text("No episodes yet — check back later.")
                            .foregroundStyle(.secondary)
                    } else if filteredEpisodes.isEmpty {
                        Text("No episodes match this filter.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredEpisodes) { episode in
                            EpisodeRow(
                                episode: episode,
                                chrome: chrome,
                                viewModel: viewModel,
                                showFeedURL: show.feedURL
                            )
                        }
                    }
                }
            }
            .navigationTitle(show.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            if let feedURL = show.feedURL {
                                if isSubscribed {
                                    await viewModel.unsubscribe(feedURL: feedURL)
                                } else {
                                    await viewModel.subscribe(feedURL: feedURL)
                                }
                                isSubscribed.toggle()
                            }
                        }
                    } label: {
                        Image(systemName: isSubscribed ? "checkmark.circle.fill" : "plus.circle")
                    }
                    .disabled(show.feedURL == nil)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                if let feedURL = show.feedURL {
                    isSubscribed = viewModel.subscribedFeedURLs.contains(feedURL)
                }
            }
        }
    }

    private func episodeMatchesFilter(_ episode: PRPodcastEpisode) -> Bool {
        switch episodeFilter {
            case .all:
                return true
            case .downloaded:
                return downloadStore.isDownloaded(episode.id)
            case .inProgress:
                let progress = episodePlayProgress(episode.id, duration: episode.durationSeconds)
                return progress > 0.01 && progress < 0.95
            case .cleanPending:
                guard let record = downloadStore.record(for: episode.id) else { return false }
                return record.wantsClean && record.adStripState != .clean
        }
    }

    private func episodePlayProgress(_ episodeID: String, duration: TimeInterval?) -> Double {
        if let record = downloadStore.record(for: episodeID) {
            if record.isFinished || record.progress >= 0.95 { return 1 }
            if record.progress > 0 { return record.progress }
        }
        if let entry = PodcastPlayheadStore.shared.entry(for: episodeID) {
            if let d = entry.durationSeconds ?? duration, d > 0 {
                return min(max(entry.positionSeconds / d, 0), 1)
            }
            return entry.progress
        }
        return 0
    }
}

private enum ShowEpisodeFilter: String, CaseIterable, Identifiable {
    case all
    case downloaded
    case inProgress
    case cleanPending

    var id: String { rawValue }

    var title: String {
        switch self {
            case .all: return "All"
            case .downloaded: return "Downloaded"
            case .inProgress: return "In progress"
            case .cleanPending: return "Clean pending"
        }
    }
}

struct EpisodeRow: View {
    let episode: PRPodcastEpisode
    let chrome: PunkRallyTheme.Chrome
    let viewModel: PodcastsViewModel
    var showFeedURL: URL? = nil

    @Environment(\.openURL) private var openURL
    @State private var downloadStore = PodcastDownloadStore.shared
    @State private var showMediaPicker = false
    @State private var isResolvingYouTube = false

    private var isDownloaded: Bool {
        downloadStore.isDownloaded(episode.id)
    }

    private var isPinned: Bool {
        downloadStore.record(for: episode.id)?.isPinned ?? false
    }

    private var adStripState: PodcastAdStripState? {
        downloadStore.adStripState(for: episode.id)
    }

    private var isCleaning: Bool {
        downloadStore.isCleaning(episode.id)
    }

    private var playProgress: Double {
        if let record = downloadStore.record(for: episode.id) {
            if record.isFinished { return 1 }
            if record.progress > 0 { return record.progress }
        }
        if let entry = PodcastPlayheadStore.shared.entry(for: episode.id) {
            if let d = entry.durationSeconds ?? episode.durationSeconds, d > 0 {
                return min(max(entry.positionSeconds / d, 0), 1)
            }
            return entry.progress
        }
        return 0
    }

    private var durationForProgress: TimeInterval? {
        downloadStore.record(for: episode.id)?.durationSeconds
            ?? PodcastPlayheadStore.shared.entry(for: episode.id)?.durationSeconds
            ?? episode.durationSeconds
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(chrome.text)
                    .lineLimit(2)
                if let summary = episode.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(chrome.textMuted)
                        .lineLimit(2)
                }
                statusCluster
                if let youtubeURL = episode.watchOnYouTubeURL {
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            Task { await playYouTubeInApp(watchURL: youtubeURL) }
                        } label: {
                            if isResolvingYouTube {
                                Label("Resolving…", systemImage: "hourglass")
                                    .font(.caption.weight(.semibold))
                            } else {
                                Label("Play in ink+amp", systemImage: "play.rectangle.fill")
                                    .font(.caption.weight(.semibold))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isResolvingYouTube)
                        .accessibilityHint("Resolves a stream and plays in the app")

                        Button {
                            openURL(youtubeURL)
                        } label: {
                            Label("Watch on YouTube", systemImage: "play.rectangle.on.rectangle")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityHint("Opens YouTube in Safari or the YouTube app")
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { requestPlay() }
        .padding(.vertical, 6)
        .sheet(isPresented: $showMediaPicker) {
            PodcastAudioVideoPickerSheet(
                episode: episode,
                preferred: PodcastMediaPreferenceStore.shared.preference(for: showFeedURL)
                    ?? .video,
                onSelect: { kind in
                    showMediaPicker = false
                    viewModel.play(episode: episode, mediaKind: kind, feedURL: showFeedURL)
                },
                onCancel: { showMediaPicker = false }
            )
            .presentationDetents([.height(280)])
        }
        .contextMenu { episodeContextMenu }
    }

    /// L→R: download glyph · Clean chip · played / Xm left.
    /// Cleaning… stays a job chip (never duration-looking); Xm left stays on progress.
    private var statusCluster: some View {
        HStack(spacing: 8) {
            downloadGlyph

            if isDownloaded || isCleaning, let state = adStripState {
                Text(state.chipLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(adStripChipColor(state))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(adStripChipColor(state).opacity(0.14))
                    .clipShape(Capsule())
                    .accessibilityLabel(adStripAccessibilityLabel(state))
            }

            if let label = PlaybackFinishabilityCopy.label(
                progress: playProgress,
                durationSeconds: durationForProgress
            ) {
                if playProgress >= 0.95 {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.green)
                    Text(label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.green)
                } else {
                    // Keep episode remaining visually separate from Cleaning… job chip.
                    Text(isCleaning ? label : "· \(label)")
                        .font(.caption2)
                        .foregroundStyle(chrome.textMuted)
                        .accessibilityLabel("Episode \(label)")
                }
            }

            if episode.hasAudioAndVideo {
                Text("A|V")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(PunkRallyTheme.Accent.primary)
            }

            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(chrome.textMuted)
            }
        }
    }

    @ViewBuilder
    private var downloadGlyph: some View {
        if downloadStore.isDownloading(episode.id) {
            ProgressView()
                .controlSize(.mini)
        } else if isDownloaded {
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(PunkRallyTheme.Accent.primary)
                .accessibilityLabel("On device")
        } else if episode.audioURL != nil {
            Image(systemName: "icloud")
                .font(.caption)
                .foregroundStyle(chrome.textFaint)
                .accessibilityLabel("Not downloaded")
        }
    }

    @ViewBuilder
    private var episodeContextMenu: some View {
        if episode.hasAudioAndVideo {
            Button {
                viewModel.play(episode: episode, mediaKind: .audio, feedURL: showFeedURL)
            } label: {
                Label("Play Audio", systemImage: "headphones")
            }
            Button {
                viewModel.play(episode: episode, mediaKind: .video, feedURL: showFeedURL)
            } label: {
                Label("Play Video", systemImage: "play.rectangle")
            }
        }

        if episode.audioURL != nil || episode.videoURL != nil {
            Button {
                viewModel.playNext(episode: episode, feedURL: showFeedURL)
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button {
                viewModel.playLast(episode: episode, feedURL: showFeedURL)
            } label: {
                Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
        }

        if episode.audioURL != nil {
            if downloadStore.isDownloading(episode.id) || downloadStore.isCleaning(episode.id) {
                Label(
                    downloadStore.isCleaning(episode.id) ? "Cleaning…" : "Downloading…",
                    systemImage: "arrow.down.circle"
                )
            } else {
                Button {
                    startDownload(intent: .original)
                } label: {
                    Label("Download now", systemImage: "arrow.down.circle")
                }
                Button {
                    startDownload(intent: .clean)
                } label: {
                    Label("Strip ads, then download", systemImage: "wand.and.stars")
                }
                Button {
                    downloadStore.keepEpisode(
                        episodeID: episode.id,
                        title: episode.title,
                        showTitle: episode.showTitle,
                        feedURL: showFeedURL,
                        remoteAudioURL: episode.audioURL,
                        durationSeconds: episode.durationSeconds
                    )
                } label: {
                    Label("Keep", systemImage: "pin")
                }
            }

            if isDownloaded {
                Button(role: .destructive) {
                    downloadStore.deleteDownload(episodeID: episode.id)
                } label: {
                    Label("Remove download", systemImage: "trash")
                }
            }
        }

        if isPinned {
            Button {
                downloadStore.setPinned(episode.id, pinned: false)
            } label: {
                Label("Remove Keep", systemImage: "pin.slash")
            }
        }
    }

    private func adStripChipColor(_ state: PodcastAdStripState) -> Color {
        switch state {
            case .original: return chrome.textMuted
            case .cleaning: return PunkRallyTheme.Accent.primary
            case .clean: return Color.green
            case .failed: return Color.orange
        }
    }

    private func adStripAccessibilityLabel(_ state: PodcastAdStripState) -> String {
        switch state {
            case .original: return "Original download"
            case .cleaning: return "Cleaning ads"
            case .clean: return "Clean download"
            case .failed: return "Clean failed"
        }
    }

    private func startDownload(intent: PodcastDownloadIntent) {
        guard let audioURL = episode.audioURL else { return }
        PodcastDownloadPreferenceStore.shared.setLastIntent(intent, for: showFeedURL)
        downloadStore.enqueueDownload(
            episodeID: episode.id,
            title: episode.title,
            showTitle: episode.showTitle,
            feedURL: showFeedURL,
            remoteAudioURL: audioURL,
            durationSeconds: episode.durationSeconds,
            intent: intent
        )
    }

    private func requestPlay() {
        if episode.hasAudioAndVideo {
            showMediaPicker = true
        } else if episode.videoURL != nil, episode.audioURL == nil {
            viewModel.play(episode: episode, mediaKind: .video, feedURL: showFeedURL)
        } else {
            viewModel.play(episode: episode, mediaKind: .audio, feedURL: showFeedURL)
        }
    }

    /// Resolve YouTube → shared AVPlayer video path (same as RSS video).
    private func playYouTubeInApp(watchURL: URL) async {
        guard !isResolvingYouTube else { return }
        isResolvingYouTube = true
        defer { isResolvingYouTube = false }
        let ok = await viewModel.playYouTubeInApp(
            episode: episode,
            watchURL: watchURL,
            feedURL: showFeedURL
        )
        if !ok {
            openURL(watchURL)
        }
    }
}

/// Episode download sheet: Original vs Clean; remembers last choice per show.
private struct PodcastDownloadIntentSheet: View {
    let episodeTitle: String
    let preferred: PodcastDownloadIntent
    let onSelect: (PodcastDownloadIntent) -> Void
    let onCancel: () -> Void

    @State private var selection: PodcastDownloadIntent

    init(
        episodeTitle: String,
        preferred: PodcastDownloadIntent,
        onSelect: @escaping (PodcastDownloadIntent) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.episodeTitle = episodeTitle
        self.preferred = preferred
        self.onSelect = onSelect
        self.onCancel = onCancel
        _selection = State(initialValue: preferred)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text(episodeTitle)
                    .font(.headline)
                    .lineLimit(2)

                Text("How do you want to download?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                VStack(spacing: 12) {
                    downloadChoiceButton(
                        title: "Download now",
                        subtitle: "Original — no ad strip",
                        intent: .original
                    )
                    downloadChoiceButton(
                        title: "Strip ads, then download",
                        subtitle: "Clean path (stub strip this IPA)",
                        intent: .clean
                    )
                }

                Spacer()
            }
            .padding(20)
            .navigationTitle("Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }

    private func downloadChoiceButton(
        title: String,
        subtitle: String,
        intent: PodcastDownloadIntent
    ) -> some View {
        Button {
            onSelect(intent)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selection == intent {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(PunkRallyTheme.Accent.primary)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.secondary.opacity(selection == intent ? 0.18 : 0.08))
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

/// Sheet shown only when an episode has both audio and video enclosures.
private struct PodcastAudioVideoPickerSheet: View {
    let episode: PRPodcastEpisode
    let preferred: PRPodcastMediaKind
    let onSelect: (PRPodcastMediaKind) -> Void
    let onCancel: () -> Void

    @State private var selection: PRPodcastMediaKind

    init(
        episode: PRPodcastEpisode,
        preferred: PRPodcastMediaKind,
        onSelect: @escaping (PRPodcastMediaKind) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.episode = episode
        self.preferred = preferred
        self.onSelect = onSelect
        self.onCancel = onCancel
        _selection = State(initialValue: preferred)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text(episode.title)
                    .font(.headline)
                    .lineLimit(2)

                Text("This episode has audio and video. Which do you want?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("Media", selection: $selection) {
                    Text("Audio").tag(PRPodcastMediaKind.audio)
                    Text("Video").tag(PRPodcastMediaKind.video)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Audio or Video")

                Button {
                    onSelect(selection)
                } label: {
                    Text(selection == .video ? "Play Video" : "Play Audio")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle("Audio | Video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}

extension TimeInterval {
    var formattedDuration: String {
        let total = Int(self)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
#endif
#if os(iOS) || os(macOS)
struct KindBadgeView: View {
    let kind: PunkRallyTheme.KindBadgeType
    let scheme: ColorScheme

    var body: some View {
        Text(kind.rawValue)
            .font(.caption2.weight(.bold))
            .foregroundStyle(kind.foregroundColor(scheme: scheme))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(kind.backgroundColor(scheme: scheme))
            .clipShape(Capsule())
    }
}
#endif