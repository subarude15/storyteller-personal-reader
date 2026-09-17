//
//  FindPodcastShowsView.swift
//  ink+amp
//
//  Find shows via Apple iTunes Search → Subscribe uses the same RSS path as
//  paste-URL (PodcastSubscriptionStore + RSSPodcastParser).
//
//  SPDX-License-Identifier: AGPL-3.0-only

#if os(iOS)
import SwiftUI

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

    private var chrome: PunkRallyTheme.Chrome {
        PunkRallyTheme.Chrome(scheme: colorScheme)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isSearching && results.isEmpty {
                    ProgressView("Searching…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(chrome.bg)
                } else if results.isEmpty {
                    emptyOrHint
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

    private var emptyOrHint: some View {
        VStack(spacing: 16) {
            Image(systemName: statusIsError ? "wifi.exclamationmark" : "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(chrome.textFaint)
            Text(statusMessage ?? "Search for a show")
                .font(.title3.weight(.semibold))
                .foregroundStyle(chrome.text)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text(
                statusIsError
                    ? "You can still add a show by pasting its RSS feed URL."
                    : "Results come from Apple Podcasts Search and include artwork when available."
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

    private func openPreview(_ hit: PRPodcastSearchResult) async {
        let key = hit.feedURL.absoluteString
        guard loadingPreviewFeed != key else { return }
        loadingPreviewFeed = key
        previewError = nil
        let show = await viewModel.previewShow(feedURL: hit.feedURL)
        loadingPreviewFeed = nil
        if let show {
            // Prefer search artwork when the feed omits a cover.
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
