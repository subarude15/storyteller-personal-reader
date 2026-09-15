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

/// Podcasts tab: shows grid, latest episodes, and Add Feed.
struct PodcastsHomeView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel = PodcastsViewModel()
    @State private var showAddFeed = false
    @State private var selectedShow: PRPodcastShow?
    @State private var refreshTask: Task<Void, Never>?

    private var chrome: PunkRallyTheme.Chrome {
        PunkRallyTheme.Chrome(scheme: colorScheme)
    }

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.shows.isEmpty {
                    skeletonGrid
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
                        showAddFeed = true
                    } label: {
                        Label("Add Feed", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddFeed) {
                AddPodcastFeedView(viewModel: viewModel)
            }
            .sheet(item: $selectedShow) { show in
                PodcastShowView(viewModel: viewModel, show: show)
            }
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
            Text("Add an RSS feed to start listening — podcasts stay separate from your Storyteller library.")
                .font(.body)
                .foregroundStyle(chrome.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                showAddFeed = true
            } label: {
                Label("Add Feed", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(PunkRallyTheme.Accent.primary)
                    .clipShape(Capsule())
            }
            .padding(.top, 8)
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
                    Text("RSS Feed URL")
                } footer: {
                    Text("Enter the direct RSS/Atom feed URL of the podcast. Shows appear under Podcasts — they never mix into your Storyteller library.")
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
                            Text("Add Feed")
                        }
                    }
                    .disabled(!isValidURL || isAdding)
                }
            }
            .navigationTitle("Add Podcast Feed")
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
        await viewModel.subscribe(feedURL: url)
        if viewModel.show(for: url) != nil {
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

    private var chrome: PunkRallyTheme.Chrome {
        PunkRallyTheme.Chrome(scheme: colorScheme)
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
                }

                Section("Episodes") {
                    if show.episodes.isEmpty {
                        Text("No episodes yet — check back later.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(show.episodes) { episode in
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
}

struct EpisodeRow: View {
    let episode: PRPodcastEpisode
    let chrome: PunkRallyTheme.Chrome
    let viewModel: PodcastsViewModel
    var showFeedURL: URL? = nil

    @State private var downloadStore = PodcastDownloadStore.shared

    private var isDownloaded: Bool {
        downloadStore.isDownloaded(episode.id)
    }

    private var isPinned: Bool {
        downloadStore.record(for: episode.id)?.isPinned ?? false
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
                HStack(spacing: 8) {
                    if let duration = episode.durationSeconds {
                        Text(duration.formattedDuration)
                            .font(.caption2)
                            .foregroundStyle(chrome.textFaint)
                    }
                    if let publishedAt = episode.publishedAt {
                        Text(publishedAt.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption2)
                            .foregroundStyle(chrome.textFaint)
                    }
                    if isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(PunkRallyTheme.Accent.primary)
                    }
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(chrome.textMuted)
                    }
                }
            }
            Spacer()
            Button {
                viewModel.play(episode: episode)
            } label: {
                Image(systemName: "play.circle")
                    .font(.title3)
                    .foregroundStyle(PunkRallyTheme.Accent.primary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .contextMenu {
            if let audioURL = episode.audioURL {
                if isDownloaded {
                    Button {
                        downloadStore.deleteDownload(episodeID: episode.id)
                    } label: {
                        Label("Remove Download", systemImage: "trash")
                    }
                } else if downloadStore.isDownloading(episode.id) {
                    Label("Downloading…", systemImage: "arrow.down.circle")
                } else {
                    Button {
                        downloadStore.enqueueDownload(
                            episodeID: episode.id,
                            title: episode.title,
                            showTitle: episode.showTitle,
                            feedURL: showFeedURL,
                            remoteAudioURL: audioURL,
                            durationSeconds: episode.durationSeconds
                        )
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                }
            }
            if isDownloaded || isPinned {
                Button {
                    downloadStore.setPinned(episode.id, pinned: !isPinned)
                } label: {
                    Label(
                        isPinned ? "Remove Keep" : "Keep",
                        systemImage: isPinned ? "pin.slash" : "pin"
                    )
                }
            } else if episode.audioURL != nil {
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