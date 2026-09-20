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
import SilveranAppleWidgets
import SilveranKit

/// ink+amp five-tab shell. Library/Shelf reuse Silveran's own views when
/// MediaViewModel is available in the environment (SilveranReaderApp injects it);
/// otherwise show ink+amp placeholders so the shell always builds standalone.
public struct PunkRallyTabView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: Tab = .home
    @State private var shellToastMessage: String?
    @State private var shellToastTask: Task<Void, Never>?
    @State private var podcastPresenter = PodcastPlayerPresenter.shared

    public init() {}

    enum Tab: Hashable {
        case home, library, shelf, podcasts, stats
    }

    private var chrome: PunkRallyTheme.Chrome {
        PunkRallyTheme.Chrome(scheme: colorScheme)
    }

    public var body: some View {
        rootShell
            .modifier(PunkRallyShellToastModifier(showToast: { showShellToast($0) }))
            .modifier(
                PunkRallyPodcastBridgeModifier(
                    playPodcast: { playPodcast(from: $0) },
                    recordRecent: { recordPodcastRecent(from: $0) }
                )
            )
            .overlay(alignment: .top) {
                if let shellToastMessage {
                    Label(
                        shellToastMessage,
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
                    .accessibilityLabel(shellToastMessage)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: shellToastMessage)
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

    /// Tab chrome + book card + scene lifecycle (split from body for the type checker).
    @ViewBuilder
    private var rootShell: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                HomeTabView()
                    .punkRallyMiniPlayerInset()
                    .tabItem {
                        Label("Home", systemImage: "house.fill")
                    }
                    .tag(Tab.home)

                LibraryTabView()
                    .punkRallyMiniPlayerInset()
                    .tabItem {
                        Label("Library", systemImage: "books.vertical.fill")
                    }
                    .tag(Tab.library)

                ShelfTabView()
                    .punkRallyMiniPlayerInset()
                    .tabItem {
                        Label("Shelf", systemImage: "arrow.down.circle.fill")
                    }
                    .tag(Tab.shelf)

                PodcastsHomeView()
                    .punkRallyMiniPlayerInset()
                    .tabItem {
                        Label("Podcasts", systemImage: "mic.fill")
                    }
                    .tag(Tab.podcasts)

                StatsView()
                    .punkRallyMiniPlayerInset()
                    .tabItem {
                        Label("Stats", systemImage: "chart.bar.fill")
                    }
                    .tag(Tab.stats)
            }
            .tint(PunkRallyTheme.Accent.primary)
            .preferredColorScheme(nil) // follow system appearance
            .onAppear {
                SessionTrackerWiring.install()
                ContinueWidgetPublisher.install()
                ContinueWidgetPublisher.consumePendingWidgetCommands()
                #if os(iOS) || os(macOS)
                RequestNotificationTapHandler.install()
                #endif
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
            .onReceive(NotificationCenter.default.publisher(for: .punkRallyShowRequestActivity)) { _ in
                selectedTab = .home
            }
            .onReceive(NotificationCenter.default.publisher(for: .punkRallyOpenContinue)) { note in
                selectedTab = .home
                NotificationCenter.default.post(
                    name: .punkRallyPerformContinue,
                    object: nil,
                    userInfo: note.userInfo
                )
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .punkRallyRetryStatsSync)
            ) { _ in
                Task { await StatsSyncCoordinator.shared.syncNow(reason: "settingsRetry") }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .punkRallyRetryYouTubePlayheadSync)
            ) { _ in
                Task { await YouTubePlayheadSyncCoordinator.shared.syncNow(reason: "settingsRetry") }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .punkRallyRetryPodcastSync)
            ) { _ in
                Task { await PodcastSyncCoordinator.shared.syncNow(reason: "settingsRetry") }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    _ = PodcastDownloadStore.shared.runOvernightPruneIfDue()
                    ContinueWidgetPublisher.consumePendingWidgetCommands()
                    NotificationCenter.default.post(
                        name: .punkRallyHomeQueueDidChange,
                        object: nil
                    )
                    Task { await StatsSyncCoordinator.shared.syncNow(reason: "appActive") }
                    Task { await YouTubePlayheadSyncCoordinator.shared.syncNow(reason: "appActive") }
                    Task { await PodcastSyncCoordinator.shared.syncNow(reason: "appActive") }
                } else if phase == .background {
                    Task {
                        await AudioSessionActor.shared.refreshNowPlaying()
                        await AudioSessionActor.shared.flushResolvedResume()
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
                        YouTubePlayheadSyncCoordinator.shared.scheduleSyncAfterLocalChange()
                        PodcastSyncCoordinator.shared.scheduleSyncAfterLocalChange()
                    }
                }
            }
            .fullScreenCover(item: PlayerPresenter.shared.cardItemBinding) { wrapper in
                NavigationStack {
                    PunkRallyPlayerHost.playerView(
                        for: wrapper.data,
                        onFailure: { showShellToast("Can't open yet · try again") }
                    )
                }
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
        let fromQueueAdvance = (userInfo["fromQueueAdvance"] as? Bool) ?? false
        if !fromQueueAdvance {
            PodcastPlaybackQueueStore.shared.noteManualPlay(episodeID: episodeID)
        }
        let mediaKind = (userInfo["mediaKind"] as? String).flatMap(PRPodcastMediaKind.init(rawValue:))
            ?? .audio
        let showTitle = userInfo["showTitle"] as? String
        let duration = userInfo["durationSeconds"] as? TimeInterval
        let coverURL = userInfo["coverURL"] as? URL
        let youtubeURL = userInfo["youtubeURL"] as? URL

        recordPodcastRecent(from: userInfo)

        let episode = PodcastPlayerPresenter.Episode(
            id: episodeID,
            title: title,
            showTitle: showTitle,
            summary: userInfo["summary"] as? String,
            audioURL: audioURL,
            duration: duration,
            isVideo: mediaKind == .video,
            coverURL: coverURL,
            youtubeURL: youtubeURL
        )
        Task {
            // Pull remote playheads before resume (soft timeout; offline keeps local).
            await PodcastSyncCoordinator.shared.syncNow(reason: "beforePlay")
            if episode.youtubeVideoID != nil {
                await YouTubePlayheadSyncCoordinator.shared.syncNow(reason: "beforePlay")
            }
            await podcastPresenter.play(episode)
        }
    }

    /// Home Continue last-touched + progress (shared by play bridge and session-start).
    private func recordPodcastRecent(from userInfo: [AnyHashable: Any]?) {
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
        let youtubeURL = userInfo["youtubeURL"] as? URL

        let progress: Double = {
            if let youtubeURL,
                let videoID = PodcastYouTubeURL.videoID(from: youtubeURL),
                let entry = YouTubePlayheadStore.shared.entry(for: videoID)
            {
                return entry.progress
            }
            if let playhead = PodcastPlayheadStore.shared.entry(for: episodeID) {
                return playhead.progress
            }
            return PodcastDownloadStore.shared.record(for: episodeID)?.progress ?? 0
        }()

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
                progress: progress,
                youtubeURL: youtubeURL
            )
        )
        NotificationCenter.default.post(name: .punkRallyHomeQueueDidChange, object: nil)
    }

    private func showShellToast(_ message: String) {
        shellToastTask?.cancel()
        shellToastMessage = message
        shellToastTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                shellToastMessage = nil
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
    @State private var mediumPickerItem: HomeMixedItem? = nil

    /// Media a Home item actually has, in a stable pick order (readaloud, audiobook, ebook).
    private struct AvailableMedium: Identifiable {
        let id: String
        let label: String
        let category: LocalMediaCategory?
        let isPodcastVideo: Bool
    }

    private var mediumPickerPresented: Binding<Bool> {
        Binding(
            get: { mediumPickerItem != nil },
            set: { if !$0 { mediumPickerItem = nil } }
        )
    }

    private var chrome: PunkRallyTheme.Chrome {
        PunkRallyTheme.Chrome(scheme: colorScheme)
    }

    private var statsSnapshot: PRStatsSnapshot {
        let _ = statsTick
        let _ = tracker.revision
        return tracker.snapshot
    }

    /// In-progress books + podcasts (Continue sources), last-touched order.
    private var inProgressItems: [HomeMixedItem] {
        let _ = queueTick
        let vm = mediaViewModel
        let books = vm?.library.bookMetaData ?? []
        let progress = vm?.bookProgressCache ?? [:]
        let queue = HomeMixedQueue.build(
            books: books,
            progress: progress,
            preferredCategory: { book in
                vm?.preferredDownloadedCategory(for: book)
            },
            podcastRecents: PodcastRecentStore.shared.all(),
            podcastDownloads: podcastStore.allDownloads(),
            bookLocalTouches: BookRecentStore.shared.all(),
            upNextLimit: 40
        )
        return ([queue.continueItem].compactMap { $0 }) + queue.upNext
    }

    private var mixedQueue: (continueItem: HomeMixedItem?, upNext: [HomeMixedItem]) {
        let items = inProgressItems
        return (items.first, Array(items.dropFirst().prefix(5)))
    }

    /// Continue id + the three Up next ids the widget paints. Home queue changes
    /// republish even when the Continue item itself stays put.
    private var widgetQueueKey: String {
        let queue = mixedQueue
        let next = queue.upNext.prefix(ContinueWidgetSnapshot.upNextLimit).map(\.id)
            .joined(separator: ",")
        return "\(queue.continueItem?.id ?? "")#\(next)"
    }

    private var finishTonightPicks: (minutes: Int, items: [HomeMixedItem])? {
        let _ = queueTick
        guard let minutes = BedtimeSettings.minutesUntilBedtime() else { return nil }
        let items = FinishTonight.picks(
            from: inProgressItems,
            minutesUntilBedtime: minutes
        )
        guard !items.isEmpty else { return nil }
        return (minutes, items)
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
                    finishTonightCard
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
                Task { await publishContinueWidget() }
            }
            .onChange(of: widgetQueueKey) { _, _ in
                Task { await publishContinueWidget() }
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
                Task { await publishContinueWidget() }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .punkRallyPerformContinue)
            ) { note in
                let itemID = note.userInfo?[InkAmpContinueLink.queueItemUserInfoKey] as? String
                Task { await performContinueFromWidget(queueItemID: itemID) }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .punkRallyStatsSessionStart)
            ) { _ in statsTick &+= 1 }
            .onReceive(
                NotificationCenter.default.publisher(for: .punkRallyStatsSessionEnd)
            ) { _ in statsTick &+= 1 }
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
                queueTick &+= 1
                statsTick &+= 1
            }
        }
        .confirmationDialog(
            mediumPickerItem.map { "Open \($0.title) as" } ?? "",
            isPresented: mediumPickerPresented,
            titleVisibility: .visible
        ) {
            if let item = mediumPickerItem {
                let media = availableMedia(for: item)
                if media.isEmpty {
                    Button("Nothing available", role: .cancel) {}
                } else {
                    ForEach(media) { medium in
                        Button(medium.label) {
                            Task { await openMedium(medium, for: item) }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                }
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
        return VStack(alignment: .leading, spacing: 12) {
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
                    if let item, let label = item.finishabilityLabel {
                        Text(label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PunkRallyTheme.Accent.primary)
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
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await openMixedItem(item) }
        }
        .onLongPressGesture(minimumDuration: 0.5) {
            if let item {
                mediumPickerItem = item
            }
        }
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
                                if let label = item.finishabilityLabel {
                                    Text(label)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(chrome.textMuted)
                                        .frame(width: 96, alignment: .leading)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Task { await openMixedItem(item) }
                            }
                            .onLongPressGesture(minimumDuration: 0.5) {
                                mediumPickerItem = item
                            }
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

    @ViewBuilder
    private var finishTonightCard: some View {
        if let picks = finishTonightPicks {
            VStack(alignment: .leading, spacing: 12) {
                Text(FinishTonight.header(minutesUntilBedtime: picks.minutes))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(chrome.text)
                ForEach(picks.items) { item in
                    HStack(spacing: 12) {
                        HomeMixedCoverView(item: item, width: 44, height: 66, chrome: chrome)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(chrome.text)
                                .lineLimit(2)
                            if let why = item.finishabilityLabel {
                                Text(why)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(PunkRallyTheme.Accent.primary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Task { await openMixedItem(item) }
                    }
                    .onLongPressGesture(minimumDuration: 0.5) {
                        mediumPickerItem = item
                    }
                }
            }
            .padding(PunkRallyTheme.Metric.cardPadding)
            .background(chrome.surface)
            .clipShape(RoundedRectangle(cornerRadius: PunkRallyTheme.Metric.buttonCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: PunkRallyTheme.Metric.buttonCornerRadius)
                    .stroke(chrome.border, lineWidth: 1)
            )
            .accessibilityIdentifier("finish-tonight")
        }
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
                let watchURL =
                    entry.youtubeURL
                    ?? PodcastMatchedYouTubeStore.shared.watchURL(for: entry.episodeID)
                if let watchURL {
                    do {
                        let pick = try await PodcastYouTubeResolver.shared.resolve(
                            watchURL: watchURL
                        )
                        var userInfo: [String: Any] = [
                            "episodeID": entry.episodeID,
                            "title": entry.title,
                            "audioURL": pick.url,
                            "mediaKind": PRPodcastMediaKind.video.rawValue,
                            "youtubeURL": watchURL,
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
                    } catch {
                        NotificationCenter.default.post(
                            name: .punkRallyYouTubeResolveFailed,
                            object: nil
                        )
                    }
                    return
                }
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

    /// Media a Home item actually has, for the long-press medium picker. Books
    /// list readaloud / audiobook / ebook; a podcast row lists audio and, when a
    /// video URL is matched, video. Never lists a format the item doesn't have.
    private func availableMedia(for item: HomeMixedItem) -> [AvailableMedium] {
        switch item {
            case .book(let book, _, _, _):
                var media: [AvailableMedium] = []
                if book.hasAvailableReadaloud {
                    media.append(
                        AvailableMedium(
                            id: "readaloud",
                            label: "Readaloud",
                            category: .synced,
                            isPodcastVideo: false,
                        )
                    )
                }
                if book.hasAvailableAudiobook {
                    media.append(
                        AvailableMedium(
                            id: "audiobook",
                            label: "Audiobook",
                            category: .audio,
                            isPodcastVideo: false,
                        )
                    )
                }
                if book.hasAvailableEbook {
                    media.append(
                        AvailableMedium(
                            id: "ebook",
                            label: "Ebook",
                            category: .ebook,
                            isPodcastVideo: false,
                        )
                    )
                }
                return media
            case .podcast(let entry):
                var media = [
                    AvailableMedium(
                        id: "audio",
                        label: "Audio",
                        category: nil,
                        isPodcastVideo: false,
                    )
                ]
                let watchURL =
                    entry.youtubeURL
                    ?? PodcastMatchedYouTubeStore.shared.watchURL(for: entry.episodeID)
                if watchURL != nil {
                    media.append(
                        AvailableMedium(
                            id: "video",
                            label: "Video",
                            category: nil,
                            isPodcastVideo: true,
                        )
                    )
                }
                return media
        }
    }

    @MainActor
    private func openMedium(_ medium: AvailableMedium, for item: HomeMixedItem) async {
        switch item {
            case .book(let book, _, _, _):
                guard let vm = mediaViewModel, let category = medium.category else { return }
                await PunkRallyPlayerHost.open(book, mediaViewModel: vm, category: category)
            case .podcast(let entry):
                if medium.isPodcastVideo {
                    // Reuse the same video-open path as a normal tap.
                    await openMixedItem(.podcast(entry))
                } else {
                    await openPodcastAudio(entry)
                }
        }
    }

    @MainActor
    private func openPodcastAudio(_ entry: PodcastRecentEntry) async {
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

    /// Widget / deep link: a specific Up next row opens that item; otherwise
    /// expand Now Playing if live, else open Home Continue.
    @MainActor
    private func performContinueFromWidget(queueItemID: String? = nil) async {
        if let queueItemID {
            if let item = mixedItem(id: queueItemID) {
                await openMixedItem(item)
            }
            return
        }
        if await AudioSessionActor.shared.currentSnapshot() != nil {
            if case .podcast = await AudioSessionActor.shared.currentSnapshot()?.kind {
                PodcastPlayerPresenter.shared.expandFromMiniPlayer()
                return
            }
            // Book / readaloud — re-present the player card when possible.
            if let bookData = await LastOpenBookStore.loadPlayerBookData() {
                PlayerPresenter.shared.present(bookData)
                return
            }
        }
        await openMixedItem(mixedQueue.continueItem)
    }

    /// Queue id from the widget snapshot, then the same stores Home mixes.
    private func mixedItem(id: String) -> HomeMixedItem? {
        if let match = inProgressItems.first(where: { $0.id == id }) {
            return match
        }
        if let episodeID = InkAmpContinueLink.podcastEpisodeID(fromQueueItemID: id) {
            if let entry = PodcastRecentStore.shared.all().first(where: { $0.episodeID == episodeID })
            {
                return .podcast(entry)
            }
            if let record = podcastStore.record(for: episodeID),
                let remote = record.remoteAudioURL,
                let lastPlayed = record.lastPlayedAt
            {
                return .podcast(
                    PodcastRecentEntry(
                        episodeID: record.episodeID,
                        title: record.title,
                        showTitle: record.showTitle,
                        coverURL: nil,
                        audioURL: remote,
                        durationSeconds: record.durationSeconds,
                        feedURL: record.feedURL,
                        mediaKind: .audio,
                        lastTouched: lastPlayed,
                        progress: record.progress,
                    )
                )
            }
        }
        if let bookID = InkAmpContinueLink.bookID(fromQueueItemID: id),
            let book = mediaViewModel?.library.bookMetaData.first(where: { $0.id == bookID })
        {
            let fraction = mediaViewModel?.bookProgressCache[bookID]?.progressFraction ?? book.progress
            return .book(book, lastTouched: .distantPast, progress: fraction, badge: .ebook)
        }
        return nil
    }

    @MainActor
    private func publishContinueWidget() async {
        let queue = mixedQueue
        let upNext = await widgetDrafts(
            for: Array(queue.upNext.prefix(ContinueWidgetSnapshot.upNextLimit))
        )
        guard let item = queue.continueItem else {
            ContinueWidgetPublisher.publishHomeContinue(
                title: nil,
                subtitle: nil,
                kind: nil,
                coverData: nil,
                upNext: [],
            )
            return
        }

        let kind = widgetKind(for: item)
        let coverData = await widgetCoverData(for: item)
        ContinueWidgetPublisher.publishHomeContinue(
            title: item.title,
            subtitle: item.subtitle,
            kind: kind,
            coverData: coverData,
            progress: item.progress,
            durationSeconds: item.durationSeconds,
            upNext: upNext,
        )
    }

    private func widgetDrafts(for items: [HomeMixedItem]) async -> [ContinueWidgetUpNextDraft] {
        var drafts: [ContinueWidgetUpNextDraft] = []
        for item in items {
            drafts.append(
                ContinueWidgetUpNextDraft(
                    id: item.id,
                    title: item.title,
                    subtitle: item.subtitle,
                    kind: widgetKind(for: item),
                    deepLink: InkAmpContinueLink.queueItemURL(id: item.id).absoluteString,
                    progress: item.progress,
                    coverData: await widgetCoverData(for: item),
                )
            )
        }
        return drafts
    }

    private func widgetKind(for item: HomeMixedItem) -> ContinueWidgetKindTag {
        switch item {
            case .book(_, _, _, let badge):
                switch badge {
                    case .ebook: return .ebook
                    case .audiobook: return .audiobook
                    case .readaloud: return .readaloud
                    case .podcast: return .podcast
                }
            case .podcast:
                return .podcast
        }
    }

    private func widgetCoverData(for item: HomeMixedItem) async -> Data? {
        switch item {
            case .book(let book, _, _, _):
                if let audio = await BookServiceActor.shared.cachedCoverData(for: book.id, audio: true) {
                    return audio
                }
                return await BookServiceActor.shared.cachedCoverData(for: book.id, audio: false)
            case .podcast(let entry):
                guard let url = entry.coverURL else { return nil }
                return try? await URLSession.shared.data(from: url).0
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
                .fill(Color(white: 0.12))
            switch item {
                case .book(let book, _, _, _):
                    bookCover(book)
                case .podcast(let entry):
                    podcastCover(entry)
                case nil:
                    Image(systemName: "books.vertical")
                        .foregroundStyle(Color.white.opacity(0.72))
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
                .foregroundStyle(Color.white.opacity(0.72))
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
                        podcastArtPlaceholder
                }
            }
            .frame(width: width, height: height)
            .clipped()
        } else {
            podcastArtPlaceholder
        }
    }

    /// Missing / failed podcast art: dark charcoal like book covers (never white-on-white).
    private var podcastArtPlaceholder: some View {
        ZStack {
            Color(white: 0.2)
            Image(systemName: "mic.fill")
                .foregroundStyle(Color.white.opacity(0.72))
        }
        .frame(width: width, height: height)
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

// MARK: - Shell notification bridges (keep PunkRallyTabView.body type-checkable)

private struct PunkRallyShellToastModifier: ViewModifier {
    let showToast: (String) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .punkRallyOpenPlayerFailed)) { _ in
                showToast("Can't open yet · try again")
            }
            .onReceive(NotificationCenter.default.publisher(for: .punkRallyStatsSyncFailed)) { _ in
                showToast("Couldn't sync Stats · try again")
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .punkRallyYouTubePlayheadSyncFailed)
            ) { _ in
                showToast("Couldn't sync YouTube playheads · try again")
            }
            .onReceive(NotificationCenter.default.publisher(for: .punkRallyPodcastSyncFailed)) { _ in
                showToast("Couldn't sync podcasts · try again")
            }
            .onReceive(NotificationCenter.default.publisher(for: .punkRallyAdStripFailed)) { _ in
                showToast("Clean failed · try again")
            }
            .onReceive(NotificationCenter.default.publisher(for: .punkRallyYouTubeResolveFailed)) { _ in
                showToast("Couldn't play YouTube · opening app")
            }
            .onReceive(NotificationCenter.default.publisher(for: .punkRallySponsorBlockSkipped)) { note in
                let label = (note.userInfo?["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let label, !label.isEmpty {
                    showToast("Skipped \(label.lowercased())")
                } else {
                    showToast("Skipped sponsor")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .punkRallyYouTubeSearchFailed)) { _ in
                showToast("Couldn't search YouTube")
            }
            .onReceive(NotificationCenter.default.publisher(for: .punkRallyYouTubeNoMatches)) { _ in
                showToast("No matches")
            }
    }
}

private struct PunkRallyPodcastBridgeModifier: ViewModifier {
    let playPodcast: ([AnyHashable: Any]?) -> Void
    let recordRecent: ([AnyHashable: Any]?) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .punkRallyPlayPodcastEpisode)) {
                note in
                playPodcast(note.userInfo)
            }
            .onReceive(NotificationCenter.default.publisher(for: .punkRallyPodcastSessionDidStart)) {
                note in
                recordRecent(note.userInfo)
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .punkRallyPodcastShouldPersistProgress)
            ) { _ in
                Task {
                    await PodcastPlayerPresenter.persistPodcastProgress(markFinished: false)
                    YouTubePlayheadSyncCoordinator.shared.scheduleSyncAfterLocalChange()
                    PodcastSyncCoordinator.shared.scheduleSyncAfterLocalChange()
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .punkRallyPodcastProgressDidPersist)
            ) { note in
                guard
                    let episodeID = note.userInfo?["episodeID"] as? String,
                    let progress = note.userInfo?["progress"] as? Double
                else { return }
                PodcastRecentStore.shared.updateProgress(episodeID: episodeID, progress: progress)
                NotificationCenter.default.post(name: .punkRallyHomeQueueDidChange, object: nil)
                YouTubePlayheadSyncCoordinator.shared.scheduleSyncAfterLocalChange()
                PodcastSyncCoordinator.shared.scheduleSyncAfterLocalChange()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: Notification.Name("punkRallyPodcastDidFinish")
                )
            ) { note in
                Task {
                    await PodcastPlayerPresenter.persistPodcastProgress(markFinished: true)
                    YouTubePlayheadSyncCoordinator.shared.scheduleSyncAfterLocalChange()
                    PodcastSyncCoordinator.shared.scheduleSyncAfterLocalChange()
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
                    if let next = PodcastPlaybackQueueStore.shared.consumeNext() {
                        let info = next.playNotificationUserInfo(fromQueueAdvance: true)
                        NotificationCenter.default.post(
                            name: .punkRallyPlayPodcastEpisode,
                            object: nil,
                            userInfo: info
                        )
                    }
                }
            }
    }
}

#endif
