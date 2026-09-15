//
//  PunkRallyApp.swift
//  ink+amp
//
//  Five-tab root (Home · Library · Shelf · Podcasts · Stats) per UX-SHELL.md.
//  Wraps Silveran's existing library/player content where available; keeps
//  podcasts and stats as independent local rails.
//
//  Library/Shelf surfaces are hosted by SilveranAppleKit's public ink+amp
//  facade (PunkRallyShellSupport.swift): Shelf is downloads-only; Library is a
//  searchable cover grid (no nested Silveran tab chrome). A shared mini-player
//  bar sits above the tab bar, driven by Silveran's audio session monitor.
//

#if os(iOS)
import SwiftUI
import SilveranAppleKit

/// ink+amp five-tab shell. Library/Shelf reuse Silveran's own views when
/// MediaViewModel is available in the environment (SilveranReaderApp injects it);
/// otherwise show ink+amp placeholders so the shell always builds standalone.
public struct PunkRallyTabView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: Tab = .home
    @State private var openFailureToastVisible = false
    @State private var openFailureToastTask: Task<Void, Never>?
    @State private var podcastPresenter = PodcastPlayerPresenter.shared

    public init() {}

    enum Tab: Hashable {
        case home, library, shelf, podcasts, stats
    }

    private var chrome: PunkRallyTheme.Chrome {
        PunkRallyTheme.Chrome(scheme: colorScheme)
    }

    public var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                HomeTabView()
                    .tabItem {
                        Label("Home", systemImage: "house.fill")
                    }
                    .tag(Tab.home)

                LibraryTabView()
                    .tabItem {
                        Label("Library", systemImage: "books.vertical.fill")
                    }
                    .tag(Tab.library)

                ShelfTabView()
                    .tabItem {
                        Label("Shelf", systemImage: "arrow.down.circle.fill")
                    }
                    .tag(Tab.shelf)

                PodcastsHomeView()
                    .tabItem {
                        Label("Podcasts", systemImage: "mic.fill")
                    }
                    .tag(Tab.podcasts)

                StatsView()
                    .tabItem {
                        Label("Stats", systemImage: "chart.bar.fill")
                    }
                    .tag(Tab.stats)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PunkRallyMiniPlayerBar()
            }
            .tint(PunkRallyTheme.Accent.primary)
            .preferredColorScheme(nil) // follow system appearance
            .onAppear {
                SessionTrackerWiring.install()
            }
            .onReceive(NotificationCenter.default.publisher(for: .punkRallyShowShelf)) { _ in
                selectedTab = .shelf
            }
            .onReceive(NotificationCenter.default.publisher(for: .silveranShowLibrary)) { _ in
                selectedTab = .library
            }
            .onReceive(NotificationCenter.default.publisher(for: .punkRallyShowStats)) { _ in
                selectedTab = .stats
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .punkRallyOpenPlayerFailed)
            ) { _ in
                showOpenFailureToast()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .punkRallyPlayPodcastEpisode)
            ) { note in
                playPodcast(from: note.userInfo)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: Notification.Name("punkRallyPodcastDidFinish")
                )
            ) { note in
                Task {
                    await PodcastPlayerPresenter.persistPodcastProgress(markFinished: true)
                    if let episodeID = note.userInfo?["episodeID"] as? String {
                        PodcastRecentStore.shared.updateProgress(
                            episodeID: episodeID,
                            progress: 1
                        )
                        NotificationCenter.default.post(
                            name: .punkRallyHomeQueueDidChange,
                            object: nil
                        )
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    _ = PodcastDownloadStore.shared.runOvernightPruneIfDue()
                    NotificationCenter.default.post(
                        name: .punkRallyHomeQueueDidChange,
                        object: nil
                    )
                } else if phase == .background {
                    Task {
                        await PodcastPlayerPresenter.persistPodcastProgress(markFinished: false)
                        if let progress = await AudioSessionActor.shared.podcastPlaybackProgress() {
                            PodcastRecentStore.shared.updateProgress(
                                episodeID: progress.episodeID,
                                progress: progress.duration > 0
                                    ? progress.position / progress.duration
                                    : 0
                            )
                            NotificationCenter.default.post(
                                name: .punkRallyHomeQueueDidChange,
                                object: nil
                            )
                        }
                    }
                }
            }
            .fullScreenCover(item: PlayerPresenter.shared.cardItemBinding) { wrapper in
                NavigationStack {
                    PunkRallyPlayerHost.playerView(
                        for: wrapper.data,
                        onFailure: showOpenFailureToast
                    )
                }
            }
        }
        .overlay(alignment: .top) {
            if openFailureToastVisible {
                Label(
                    "Can't open yet · try again",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.82))
                )
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityLabel("Can't open yet · try again")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: openFailureToastVisible)
        // Podcast card is a separate presentation source (the book card above
        // lives on the inner TabView); two fullScreenCovers on one view would
        // collide, so this one attaches to the ZStack.
        .fullScreenCover(item: podcastPresenter.episodeItemBinding) { episode in
            NavigationStack {
                PodcastPlayerView(
                    episode: episode,
                    onClose: { podcastPresenter.dismiss() }
                )
            }
        }
    }

    /// Builds an episode from the `punkRallyPlayPodcastEpisode` userInfo posted
    /// by `PodcastsViewModel.play(episode:)` and hands it to the shared player.
    private func playPodcast(from userInfo: [AnyHashable: Any]?) {
        guard
            let userInfo,
            let episodeID = userInfo["episodeID"] as? String,
            let title = userInfo["title"] as? String,
            let audioURL = userInfo["audioURL"] as? URL
        else { return }
        let mediaKind = (userInfo["mediaKind"] as? String).flatMap(PRPodcastMediaKind.init(rawValue:))
            ?? .audio
        let showTitle = userInfo["showTitle"] as? String
        let duration = userInfo["durationSeconds"] as? TimeInterval
        let coverURL = userInfo["coverURL"] as? URL
        let feedURL = userInfo["feedURL"] as? URL

        PodcastRecentStore.shared.record(
            PodcastRecentEntry(
                episodeID: episodeID,
                title: title,
                showTitle: showTitle,
                coverURL: coverURL,
                audioURL: audioURL,
                durationSeconds: duration,
                feedURL: feedURL,
                mediaKind: mediaKind,
                lastTouched: Date(),
                progress: PodcastDownloadStore.shared.record(for: episodeID)?.progress ?? 0
            )
        )
        NotificationCenter.default.post(name: .punkRallyHomeQueueDidChange, object: nil)

        let episode = PodcastPlayerPresenter.Episode(
            id: episodeID,
            title: title,
            showTitle: showTitle,
            summary: userInfo["summary"] as? String,
            audioURL: audioURL,
            duration: duration,
            isVideo: mediaKind == .video
        )
        Task { await podcastPresenter.play(episode) }
    }

    private func showOpenFailureToast() {
        openFailureToastTask?.cancel()
        openFailureToastVisible = true
        openFailureToastTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                openFailureToastVisible = false
            }
        }
    }
}

// MARK: - Home

private struct HomeTabView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel?
    @State private var showSettings = false
    @State private var showOfflineSheet = false
    @State private var podcastStore = PodcastDownloadStore.shared
    @State private var queueTick = 0
    @State private var tracker = SessionTracker.shared
    @State private var statsTick = 0

    private var chrome: PunkRallyTheme.Chrome {
        PunkRallyTheme.Chrome(scheme: colorScheme)
    }

    private var statsSnapshot: PRStatsSnapshot {
        let _ = statsTick
        let _ = tracker.revision
        return tracker.snapshot
    }

    private var mixedQueue: (continueItem: HomeMixedItem?, upNext: [HomeMixedItem]) {
        let _ = queueTick
        let vm = mediaViewModel
        let books = vm?.library.bookMetaData ?? []
        let progress = vm?.bookProgressCache ?? [:]
        return HomeMixedQueue.build(
            books: books,
            progress: progress,
            preferredCategory: { book in
                vm?.preferredDownloadedCategory(for: book)
            },
            podcastRecents: PodcastRecentStore.shared.all(),
            podcastDownloads: podcastStore.allDownloads(),
            bookLocalTouches: BookRecentStore.shared.all(),
            upNextLimit: 5
        )
    }

    private var syncState: SyncChipView.SyncState {
        guard let vm = mediaViewModel else { return .synced }
        if vm.hasServerConnectionIssue {
            let offlineCount = vm.library.bookMetaData.filter { item in
                let hasDownload =
                    vm.isCategoryDownloaded(.ebook, for: item)
                    || vm.isCategoryDownloaded(.audio, for: item)
                    || vm.isCategoryDownloaded(.synced, for: item)
                return hasDownload && !vm.isLocalStandaloneBook(item.id)
            }.count
            return .offline(count: offlineCount)
        }
        return .synced
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    greetingHeader
                    continueHero
                    upNextRow
                    statsStrip
                }
                .padding(.horizontal, PunkRallyTheme.Metric.screenInset)
                .padding(.vertical, 12)
            }
            .background(chrome.bg)
            .navigationTitle("ink+amp")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        if mediaViewModel?.hasServerConnectionIssue == true {
                            Button {
                                showOfflineSheet = true
                            } label: {
                                Image(systemName: mediaViewModel?.connectionIssueIcon ?? "exclamationmark.triangle")
                                    .foregroundStyle(.red)
                            }
                            .accessibilityLabel("Server connection issue")
                        }
                        Button {
                            showSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
            }
            .onAppear {
                queueTick &+= 1
                statsTick &+= 1
                Task { await mediaViewModel?.refreshMetadata(source: "HomeMixed") }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .punkRallyPlayPodcastEpisode)
            ) { _ in
                queueTick &+= 1
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .punkRallyHomeQueueDidChange)
            ) { _ in
                queueTick &+= 1
                statsTick &+= 1
                Task { await mediaViewModel?.refreshMetadata(source: "HomeMixedQueue") }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .punkRallyStatsSessionStart)
            ) { _ in statsTick &+= 1 }
            .onReceive(
                NotificationCenter.default.publisher(for: .punkRallyStatsSessionEnd)
            ) { _ in statsTick &+= 1 }
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
                statsTick &+= 1
            }
        }
        .punkRallySheets(
            showSettings: $showSettings,
            showOfflineSheet: $showOfflineSheet
        )
    }

    private var greetingHeader: some View {
        HStack {
            Text("Good morning")
                .font(.title3.weight(.semibold))
                .foregroundStyle(chrome.text)
            Spacer()
            Button {
                if case .offline = syncState {
                    showOfflineSheet = true
                } else {
                    showSettings = true
                }
            } label: {
                SyncChipView(state: syncState, scheme: colorScheme)
            }
            .buttonStyle(.plain)
        }
    }

    private var continueHero: some View {
        let item = mixedQueue.continueItem
        return Button {
            Task { await openMixedItem(item) }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    HomeMixedCoverView(item: item, width: 72, height: 108, chrome: chrome)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("Continue")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PunkRallyTheme.Accent.primary)
                            if let item {
                                KindBadgeView(kind: item.badge, scheme: colorScheme)
                            }
                        }
                        Text(item?.title ?? "Nothing in progress")
                            .font(.headline)
                            .foregroundStyle(chrome.text)
                            .lineLimit(2)
                        Text(
                            item?.subtitle
                                ?? "Browse Library or Podcasts to pick up where you left off."
                        )
                        .font(.subheadline)
                        .foregroundStyle(chrome.textMuted)
                        .lineLimit(1)
                        if let item, item.progress > 0 {
                            ProgressView(value: item.progress)
                                .tint(PunkRallyTheme.Accent.primary)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(PunkRallyTheme.Metric.cardPadding)
            .background(chrome.surface)
            .clipShape(RoundedRectangle(cornerRadius: PunkRallyTheme.Metric.buttonCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: PunkRallyTheme.Metric.buttonCornerRadius)
                    .stroke(chrome.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(item == nil)
    }

    private var upNextRow: some View {
        let items = mixedQueue.upNext
        return VStack(alignment: .leading, spacing: 12) {
            Text("Up next")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(chrome.text)
            if items.isEmpty {
                Text("Titles you touch next will show up here — books and podcasts together.")
                    .font(.caption)
                    .foregroundStyle(chrome.textMuted)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(items) { item in
                            Button {
                                Task { await openMixedItem(item) }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HomeMixedCoverView(
                                        item: item,
                                        width: 96,
                                        height: 144,
                                        chrome: chrome
                                    )
                                    KindBadgeView(kind: item.badge, scheme: colorScheme)
                                    Text(item.title)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(chrome.text)
                                        .lineLimit(2)
                                        .frame(width: 96, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var statsStrip: some View {
        let snapshot = statsSnapshot
        return Button {
            NotificationCenter.default.post(name: .punkRallyShowStats, object: nil)
        } label: {
            HStack(spacing: 12) {
                statCell(snapshot.todaySeconds.hoursMinutes, "Today")
                statCell(snapshot.weekSeconds.hoursMinutes, "This week")
                statCell("\(snapshot.streakDays)", "Streak")
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Stats")
    }

    private func statCell(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline)
                .foregroundStyle(chrome.text)
            Text(label)
                .font(.caption)
                .foregroundStyle(chrome.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(chrome.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @MainActor
    private func openMixedItem(_ item: HomeMixedItem?) async {
        guard let item else { return }
        switch item {
            case .book(let book, _, _, _):
                guard let vm = mediaViewModel else { return }
                if PunkRallyPlayerHost.shouldOpenPlayer(for: book, mediaViewModel: vm) {
                    await PunkRallyPlayerHost.open(book, mediaViewModel: vm)
                } else {
                    vm.pendingOpenBookID = book.id
                    NotificationCenter.default.post(name: .silveranShowLibrary, object: nil)
                }
            case .podcast(let entry):
                var userInfo: [String: Any] = [
                    "episodeID": entry.episodeID,
                    "title": entry.title,
                    "audioURL": entry.audioURL,
                    "mediaKind": entry.mediaKind.rawValue,
                ]
                userInfo["showTitle"] = entry.showTitle
                if let duration = entry.durationSeconds {
                    userInfo["durationSeconds"] = duration
                }
                if let cover = entry.coverURL {
                    userInfo["coverURL"] = cover
                }
                if let feed = entry.feedURL {
                    userInfo["feedURL"] = feed
                }
                NotificationCenter.default.post(
                    name: .punkRallyPlayPodcastEpisode,
                    object: nil,
                    userInfo: userInfo
                )
        }
    }
}

/// Cover for a mixed Home item — Storyteller cover via MediaViewModel, or podcast artwork URL.
private struct HomeMixedCoverView: View {
    let item: HomeMixedItem?
    let width: CGFloat
    let height: CGFloat
    let chrome: PunkRallyTheme.Chrome
    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel?
    @State private var bookImage: Image?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(chrome.surface2)
            switch item {
                case .book(let book, _, _, _):
                    bookCover(book)
                case .podcast(let entry):
                    podcastCover(entry)
                case nil:
                    Image(systemName: "books.vertical")
                        .foregroundStyle(chrome.textFaint)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func bookCover(_ book: BookMetadata) -> some View {
        if let bookImage {
            bookImage
                .resizable()
                .scaledToFill()
                .frame(width: width, height: height)
                .clipped()
        } else {
            Image(systemName: "book.closed.fill")
                .foregroundStyle(chrome.textFaint)
                .task(id: book.id) {
                    await loadBookCover(book)
                }
        }
    }

    private func loadBookCover(_ book: BookMetadata) async {
        guard let vm = mediaViewModel else { return }
        vm.ensureCoverLoaded(for: book, debugSource: "HomeMixed")
        vm.ensureCoverLoaded(for: book, variant: .audioSquare, debugSource: "HomeMixed")
        for _ in 0..<25 {
            if let image = vm.coverImage(for: book)
                ?? vm.coverImage(for: book, variant: .audioSquare)
                ?? vm.coverImage(for: book, variant: .standard)
            {
                bookImage = image
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    @ViewBuilder
    private func podcastCover(_ entry: PodcastRecentEntry) -> some View {
        if let url = entry.coverURL {
            AsyncImage(url: url) { phase in
                switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Image(systemName: "mic.fill")
                            .foregroundStyle(chrome.textFaint)
                }
            }
            .frame(width: width, height: height)
            .clipped()
        } else {
            Image(systemName: "mic.fill")
                .foregroundStyle(chrome.textFaint)
        }
    }
}

// MARK: - Library

/// Library = searchable ink+amp catalogue (Silveran's full grid, no inner tab bar).
private struct LibraryTabView: View {
    var body: some View {
        PunkRallyLibraryView()
    }
}

// MARK: - Shelf

/// Shelf = downloads-only surface ("Nothing offline yet" when empty).
private struct ShelfTabView: View {
    var body: some View {
        PunkRallyShelfView()
    }
}

// MARK: - Sync chip

public struct SyncChipView: View {
    public enum SyncState {
        case synced, syncing, offline(count: Int)
    }

    let state: SyncState
    let scheme: ColorScheme

    public init(state: SyncState, scheme: ColorScheme) {
        self.state = state
        self.scheme = scheme
    }

    public var body: some View {
        let (label, icon, color): (String, String, Color) = {
            switch state {
            case .synced:
                return ("Synced", "checkmark.icloud", PunkRallyTheme.Accent.success)
            case .syncing:
                return ("Syncing…", "icloud.and.arrow.up", PunkRallyTheme.Accent.gold)
            case .offline(let count):
                return (
                    "Offline · \(count) on shelf",
                    "icloud.slash",
                    PunkRallyTheme.Accent.danger
                )
            }
        }()

        return HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(color)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
        .accessibilityLabel(Text(label))
    }
}

#endif