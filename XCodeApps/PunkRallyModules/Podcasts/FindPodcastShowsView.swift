//
//  FindPodcastShowsView.swift
//  ink+amp
//
//  Find shows via Apple iTunes Search → Subscribe uses the same RSS path as
//  paste-URL (PodcastSubscriptionStore + RSSPodcastParser).
//  Empty search shows Browse (Top Charts + genre chips + cover grid).
//
//  SPDX-License-Identifier: AGPL-3.0-only

#if os(iOS)
import SwiftUI
import SilveranKit

/// Search Apple's podcast catalog; Subscribe resolves RSS into local subscriptions.
struct FindPodcastShowsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    let viewModel: PodcastsViewModel
    var onOpenPasteURL: (() -> Void)?

    @State private var query = ""
    @State private var results: [PRPodcastSearchResult] = []
    @State private var isSearching = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var subscribingFeed: String?
    @State private var searchTask: Task<Void, Never>?
    @State private var previewShow: PRPodcastShow?
    @State private var loadingPreviewFeed: String?
    @State private var previewError: String?

    @State private var selectedGenre: PodcastBrowseGenre = .topCharts
    @State private var browseItems: [PodcastChartHit] = []
    @State private var browseCache: [Int: [PodcastChartHit]] = [:]
    @State private var isLoadingBrowse = false
    @State private var browseError: String?
    @State private var browseTask: Task<Void, Never>?

    private var chrome: PunkRallyTheme.Chrome {
        PunkRallyTheme.Chrome(scheme: colorScheme)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isBrowseMode: Bool {
        trimmedQuery.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if isBrowseMode {
                    browseContent
                } else if isSearching && results.isEmpty {
                    ProgressView("Searching…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(chrome.bg)
                } else if results.isEmpty {
                    searchEmptyOrHint
                } else {
                    resultsList
                }
            }
            .background(chrome.bg)
            .navigationTitle("Find shows")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Show name, e.g. Vergecast")
            .onChange(of: query) { _, newValue in
                scheduleSearch(newValue)
            }
            .onChange(of: selectedGenre) { _, genre in
                loadBrowse(genre: genre)
            }
            .task {
                if isBrowseMode, browseItems.isEmpty, browseError == nil {
                    loadBrowse(genre: selectedGenre)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        onOpenPasteURL?()
                    } label: {
                        Label("Paste RSS URL", systemImage: "link")
                    }
                }
            }
            .sheet(item: $previewShow) { show in
                PodcastShowView(viewModel: viewModel, show: show)
            }
            .overlay {
                if loadingPreviewFeed != nil {
                    ZStack {
                        Color.black.opacity(0.2).ignoresSafeArea()
                        ProgressView("Loading show…")
                            .padding(20)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .alert(
                "Couldn't open show",
                isPresented: Binding(
                    get: { previewError != nil },
                    set: { if !$0 { previewError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { previewError = nil }
            } message: {
                Text(previewError ?? "")
            }
        }
    }

    // MARK: - Browse (empty / idle search)

    private var browseContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Browse")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(chrome.text)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                genreChips

                if isLoadingBrowse && browseItems.isEmpty {
                    ProgressView("Loading charts…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else if let browseError, browseItems.isEmpty {
                    browseOffline(message: browseError)
                } else if browseItems.isEmpty {
                    browseOffline(message: "No chart shows right now.")
                } else {
                    coverGrid
                    if let browseError {
                        Text(browseError)
                            .font(.caption)
                            .foregroundStyle(chrome.textMuted)
                            .padding(.horizontal, 16)
                    }
                }

                Button {
                    onOpenPasteURL?()
                } label: {
                    Label("Paste RSS URL instead", systemImage: "link")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .background(chrome.bg)
    }

    private var genreChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PodcastBrowseGenre.all) { genre in
                    let selected = genre == selectedGenre
                    Button {
                        selectedGenre = genre
                    } label: {
                        Text(genre.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selected ? Color.white : chrome.text)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(
                                    selected
                                        ? PunkRallyTheme.Accent.primary
                                        : chrome.surface2
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var coverGrid: some View {
        let columns = [
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
            GridItem(.flexible(), spacing: 12),
        ]
        return LazyVGrid(columns: columns, spacing: 16) {
            ForEach(browseItems) { hit in
                Button {
                    Task { await openChartPreview(hit) }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        AsyncImage(url: hit.coverURL) { phase in
                            switch phase {
                                case .success(let image):
                                    image.resizable().scaledToFill()
                                default:
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(chrome.surface2)
                                        .overlay(
                                            Image(systemName: "mic.fill")
                                                .foregroundStyle(chrome.textFaint)
                                        )
                            }
                        }
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                        Text(hit.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(chrome.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let author = hit.author {
                            Text(author)
                                .font(.caption2)
                                .foregroundStyle(chrome.textMuted)
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(hit.title)")
                .accessibilityHint("Opens show description without subscribing")
            }
        }
        .padding(.horizontal, 16)
        .opacity(isLoadingBrowse ? 0.55 : 1)
    }

    private func browseOffline(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 36))
                .foregroundStyle(chrome.textFaint)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(chrome.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button("Retry") {
                browseCache[selectedGenre.id] = nil
                loadBrowse(genre: selectedGenre, force: true)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func loadBrowse(genre: PodcastBrowseGenre, force: Bool = false) {
        if !force, let cached = browseCache[genre.id], !cached.isEmpty {
            browseItems = cached
            browseError = nil
            isLoadingBrowse = false
            return
        }
        browseTask?.cancel()
        if browseCache[genre.id] == nil {
            browseItems = []
        }
        isLoadingBrowse = true
        browseError = nil
        browseTask = Task {
            do {
                let hits = try await PodcastBrowseChartsService.shared.chart(genre: genre)
                guard !Task.isCancelled else { return }
                browseCache[genre.id] = hits
                browseItems = hits
                browseError = nil
            } catch let error as PodcastAppleChartsError {
                guard !Task.isCancelled else { return }
                browseError = error.errorDescription
            } catch {
                guard !Task.isCancelled else { return }
                browseError = PodcastAppleChartsError.offline.errorDescription
            }
            isLoadingBrowse = false
        }
    }

    // MARK: - Search

    private var searchEmptyOrHint: some View {
        VStack(spacing: 16) {
            Image(systemName: statusIsError ? "wifi.exclamationmark" : "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(chrome.textFaint)
            Text(statusMessage ?? "No shows found")
                .font(.title3.weight(.semibold))
                .foregroundStyle(chrome.text)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text(
                statusIsError
                    ? "You can still add a show by pasting its RSS feed URL."
                    : "Try another spelling, clear search to Browse charts, or paste an RSS URL."
            )
            .font(.subheadline)
            .foregroundStyle(chrome.textMuted)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)

            Button {
                onOpenPasteURL?()
            } label: {
                Label("Paste RSS URL instead", systemImage: "link")
                    .font(.subheadline.weight(.medium))
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsList: some View {
        List {
            if let statusMessage, statusIsError {
                Section {
                    Label(statusMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(PunkRallyTheme.Accent.danger)
                        .font(.subheadline)
                }
            }
            Section {
                ForEach(results) { hit in
                    FindShowRow(
                        result: hit,
                        isSubscribed: viewModel.isSubscribed(to: hit.feedURL),
                        isSubscribing: subscribingFeed == hit.feedURL.absoluteString,
                        chrome: chrome,
                        onOpen: { Task { await openPreview(hit) } },
                        onSubscribe: { Task { await subscribe(hit) } }
                    )
                    .listRowBackground(chrome.surface)
                }
            } footer: {
                Text("Tap a show to read the description before Subscribe. Subscribe loads the RSS feed — same as paste-URL.")
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func scheduleSearch(_ term: String) {
        searchTask?.cancel()
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            statusMessage = nil
            statusIsError = false
            isSearching = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await runSearch(trimmed)
        }
    }

    private func runSearch(_ term: String) async {
        isSearching = true
        statusMessage = nil
        statusIsError = false
        do {
            let hits = try await PodcastShowSearchService.shared.search(term: term)
            guard !Task.isCancelled else { return }
            results = hits
        } catch let error as PodcastShowSearchError {
            guard !Task.isCancelled else { return }
            results = []
            statusMessage = error.errorDescription
            statusIsError = true
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            statusMessage = PodcastShowSearchError.offline.errorDescription
            statusIsError = true
        }
        isSearching = false
    }

    private func openChartPreview(_ hit: PodcastChartHit) async {
        let searchHit = PRPodcastSearchResult(
            title: hit.title,
            author: hit.author,
            coverURL: hit.coverURL,
            feedURL: hit.feedURL,
            collectionID: hit.collectionID
        )
        await openPreview(searchHit)
    }

    private func openPreview(_ hit: PRPodcastSearchResult) async {
        let key = hit.feedURL.absoluteString
        guard loadingPreviewFeed != key else { return }
        loadingPreviewFeed = key
        previewError = nil
        let show = await viewModel.previewShow(feedURL: hit.feedURL)
        loadingPreviewFeed = nil
        if let show {
            if show.coverURL == nil, let cover = hit.coverURL {
                previewShow = PRPodcastShow(
                    uuid: show.uuid,
                    title: show.title,
                    author: show.author ?? hit.author,
                    description: show.description,
                    coverURL: cover,
                    feedURL: show.feedURL,
                    categories: show.categories,
                    episodes: show.episodes,
                    lastUpdated: show.lastUpdated,
                    addedAt: show.addedAt
                )
            } else {
                previewShow = show
            }
        } else {
            previewError =
                "Couldn't load the RSS for \(hit.title). Try Subscribe, or paste the feed URL."
        }
    }

    private func subscribe(_ hit: PRPodcastSearchResult) async {
        let key = hit.feedURL.absoluteString
        guard subscribingFeed != key else { return }
        if viewModel.isSubscribed(to: hit.feedURL) {
            dismiss()
            return
        }
        subscribingFeed = key
        statusMessage = nil
        statusIsError = false
        let ok = await viewModel.subscribe(feedURL: hit.feedURL)
        subscribingFeed = nil
        if ok {
            dismiss()
        } else {
            statusMessage =
                "Couldn't load the RSS for \(hit.title). Try again, or paste the feed URL."
            statusIsError = true
        }
    }
}

private struct FindShowRow: View {
    let result: PRPodcastSearchResult
    let isSubscribed: Bool
    let isSubscribing: Bool
    let chrome: PunkRallyTheme.Chrome
    let onOpen: () -> Void
    let onSubscribe: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    AsyncImage(url: result.coverURL) { phase in
                        switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            default:
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(chrome.surface2)
                                    .overlay(
                                        Image(systemName: "mic.fill")
                                            .foregroundStyle(chrome.textFaint)
                                    )
                        }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.title)
                            .font(.headline)
                            .foregroundStyle(chrome.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let author = result.author {
                            Text(author)
                                .font(.subheadline)
                                .foregroundStyle(chrome.textMuted)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show details for \(result.title)")
            .accessibilityHint("Opens description and episode preview without subscribing")

            Button(action: onSubscribe) {
                if isSubscribing {
                    ProgressView().controlSize(.small)
                        .frame(width: 88, height: 32)
                } else if isSubscribed {
                    Text("Added")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PunkRallyTheme.Accent.success)
                        .frame(width: 88, height: 32)
                } else {
                    Text("Subscribe")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 88, height: 32)
                        .background(PunkRallyTheme.Accent.primary)
                        .clipShape(Capsule())
                }
            }
            .buttonStyle(.plain)
            .disabled(isSubscribing || isSubscribed)
            .accessibilityLabel(isSubscribed ? "Already subscribed" : "Subscribe to \(result.title)")
        }
        .padding(.vertical, 4)
    }
}
#endif
