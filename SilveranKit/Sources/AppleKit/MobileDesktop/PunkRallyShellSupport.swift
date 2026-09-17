//
//  PunkRallyShellSupport.swift
//  SilveranAppleKit
//
//  ink+amp host-app facades: public SwiftUI views over internal Silveran
//  surfaces (mini-player bar, downloads shelf, library grid) so the five-tab
//  host shell in the app target can compose them without reaching into
//  module-internal types.
//

#if os(iOS)
import SilveranKit
import SwiftUI

extension Notification.Name {
    public static let punkRallyShowShelf = Notification.Name("punkRallyShowShelf")
    public static let punkRallyShowStats = Notification.Name("punkRallyShowStats")
    public static let punkRallyOpenPlayer = Notification.Name("punkRallyOpenPlayer")
    public static let punkRallyOpenPlayerFailed = Notification.Name("punkRallyOpenPlayerFailed")
    /// PodcastsViewModel.play(episode:) → host shell: open the episode on the
    /// shared audio session and present the podcast card.
    public static let punkRallyPlayPodcastEpisode = Notification.Name("punkRallyPlayPodcastEpisode")
    /// Book or podcast last-touched changed — Home should rebuild Continue / Up next.
    public static let punkRallyHomeQueueDidChange = Notification.Name("punkRallyHomeQueueDidChange")
    /// Stats SessionTracker: begin a local reading/listening block.
    /// userInfo: kind ("reading"|"listening"), mediaID, mediaTitle
    public static let punkRallyStatsSessionStart = Notification.Name("punkRallyStatsSessionStart")
    /// Stats SessionTracker: end the active block.
    /// userInfo: progress (Double, optional 0...1)
    public static let punkRallyStatsSessionEnd = Notification.Name("punkRallyStatsSessionEnd")
    /// Stats SessionTracker: media reached ~finished locally.
    /// userInfo: mediaID, mediaTitle
    public static let punkRallyStatsMediaFinished = Notification.Name("punkRallyStatsMediaFinished")
    /// Settings / Stats footer: request an immediate Stats sync retry.
    public static let punkRallyRetryStatsSync = Notification.Name("punkRallyRetryStatsSync")
    /// StatsSyncCoordinator published UI (Settings row + footer).
    /// userInfo: isSyncing (Bool), lastSuccessfulSyncAt (Date?), footerLabel (String)
    public static let punkRallyStatsSyncUIDidChange = Notification.Name(
        "punkRallyStatsSyncUIDidChange"
    )
    /// Stats sync landed Offline after Syncing… — host shows a short toast.
    public static let punkRallyStatsSyncFailed = Notification.Name("punkRallyStatsSyncFailed")
    /// Settings: request an immediate YouTube playhead sync retry.
    public static let punkRallyRetryYouTubePlayheadSync = Notification.Name(
        "punkRallyRetryYouTubePlayheadSync"
    )
    /// YouTubePlayheadSyncCoordinator published UI (Settings row).
    /// userInfo: isSyncing (Bool), lastSuccessfulSyncAt (Date?), footerLabel (String)
    public static let punkRallyYouTubePlayheadSyncUIDidChange = Notification.Name(
        "punkRallyYouTubePlayheadSyncUIDidChange"
    )
    /// YouTube playhead sync landed Offline after Settings retry — host toast.
    public static let punkRallyYouTubePlayheadSyncFailed = Notification.Name(
        "punkRallyYouTubePlayheadSyncFailed"
    )
    /// Settings: request an immediate podcast sync retry.
    public static let punkRallyRetryPodcastSync = Notification.Name(
        "punkRallyRetryPodcastSync"
    )
    /// PodcastSyncCoordinator published UI (Settings row).
    /// userInfo: isSyncing (Bool), lastSuccessfulSyncAt (Date?), footerLabel (String)
    public static let punkRallyPodcastSyncUIDidChange = Notification.Name(
        "punkRallyPodcastSyncUIDidChange"
    )
    /// Podcast sync landed Offline after Settings retry — host toast.
    public static let punkRallyPodcastSyncFailed = Notification.Name(
        "punkRallyPodcastSyncFailed"
    )
    /// Merged remote subscriptions applied — PodcastsViewModel should reload feeds.
    public static let punkRallyPodcastSubscriptionsDidChange = Notification.Name(
        "punkRallyPodcastSubscriptionsDidChange"
    )
    /// Clean-path ad strip failed / timed out — host shows a short toast.
    public static let punkRallyAdStripFailed = Notification.Name("punkRallyAdStripFailed")
    /// YouTube in-app resolve failed / timed out — host toast; caller may hand off to Safari.
    public static let punkRallyYouTubeResolveFailed = Notification.Name(
        "punkRallyYouTubeResolveFailed"
    )
    /// SponsorBlock auto-skip fired once this session — host toast “Skipped …”.
    /// userInfo: category (String), label (String)
    public static let punkRallySponsorBlockSkipped = Notification.Name(
        "punkRallySponsorBlockSkipped"
    )
    /// Match on YouTube search failed / timed out — host toast (no hang).
    public static let punkRallyYouTubeSearchFailed = Notification.Name(
        "punkRallyYouTubeSearchFailed"
    )
    /// Match on YouTube returned zero hits — host toast “No matches”.
    public static let punkRallyYouTubeNoMatches = Notification.Name(
        "punkRallyYouTubeNoMatches"
    )
    /// Podcast / YouTube playhead just persisted — host updates Continue progress.
    /// userInfo: episodeID (String), progress (Double 0...1)
    public static let punkRallyPodcastProgressDidPersist = Notification.Name(
        "punkRallyPodcastProgressDidPersist"
    )
    /// Pause / periodic / interrupt — host should call persistPodcastProgress.
    public static let punkRallyPodcastShouldPersistProgress = Notification.Name(
        "punkRallyPodcastShouldPersistProgress"
    )
    /// Shared player opened a podcast/YouTube session — host records Home Continue.
    /// userInfo mirrors punkRallyPlayPodcastEpisode (no second play).
    public static let punkRallyPodcastSessionDidStart = Notification.Name(
        "punkRallyPodcastSessionDidStart"
    )
    /// Continue widget / `punkrally://continue` — open Home Continue / Now Playing.
    public static let punkRallyOpenContinue = Notification.Name("punkRallyOpenContinue")
    /// Host selected Home after OpenContinue — HomeTabView opens the Continue item.
    public static let punkRallyPerformContinue = Notification.Name("punkRallyPerformContinue")
}

/// Posts SessionTracker lifecycle events from AppleKit players into the app target.
public enum PunkRallyStatsEvents {
    public static func sessionStart(kind: String, mediaID: String, mediaTitle: String) {
        NotificationCenter.default.post(
            name: .punkRallyStatsSessionStart,
            object: nil,
            userInfo: [
                "kind": kind,
                "mediaID": mediaID,
                "mediaTitle": mediaTitle,
            ]
        )
    }

    public static func sessionEnd(mediaID: String? = nil, progress: Double? = nil) {
        var info: [String: Any] = [:]
        if let mediaID {
            info["mediaID"] = mediaID
        }
        if let progress {
            info["progress"] = progress
        }
        NotificationCenter.default.post(
            name: .punkRallyStatsSessionEnd,
            object: nil,
            userInfo: info.isEmpty ? nil : info
        )
    }

    public static func mediaFinished(mediaID: String, mediaTitle: String) {
        NotificationCenter.default.post(
            name: .punkRallyStatsMediaFinished,
            object: nil,
            userInfo: [
                "mediaID": mediaID,
                "mediaTitle": mediaTitle,
            ]
        )
    }
}

/// Hosts the single full-screen player/reader card for the ink+amp five-tab
/// shell. The default Silveran library view attaches the card itself
/// (iOSLibraryView.fullScreenCover); the punk shell replaces that root, so it
/// must present the card, replay the player view switch, and report failures
/// that would otherwise swallow the tap.
@MainActor
public enum PunkRallyPlayerHost {
    /// Opens a downloaded title in the player/reader. Posts a failure
    /// notification ("Can't open yet · try again") ONLY when the title IS
    /// downloaded but playback can't start (no local media resolved / path not
    /// on disk). Callers must check `preferredDownloadedCategory(for:) == nil`
    /// first and route those taps to the book detail (download UI) instead —
    /// an undownloaded tap is not a failure.
    public static func open(
        _ item: BookMetadata,
        mediaViewModel: MediaViewModel?
    ) async {
        guard let mediaViewModel else {
            postOpenFailure()
            return
        }
        guard let category = mediaViewModel.preferredDownloadedCategory(for: item) else {
            postOpenFailure()
            return
        }
        guard
            await BookServiceActor.shared.resolveLocalMedia(
                for: item.id,
                category: category
            ) != nil
        else {
            postOpenFailure()
            return
        }
        let bookData = mediaViewModel.makePlayerBookData(for: item, category: category)
        PlayerPresenter.shared.present(bookData)
    }

    /// Whether the card should open the player (title already has local media)
    /// vs navigate to the book detail (nothing downloaded yet → download UI).
    public static func shouldOpenPlayer(
        for item: BookMetadata,
        mediaViewModel: MediaViewModel?
    ) -> Bool {
        guard let mediaViewModel else { return false }
        return mediaViewModel.preferredDownloadedCategory(for: item) != nil
    }

    private static func postOpenFailure() {
        NotificationCenter.default.post(name: .punkRallyOpenPlayerFailed, object: nil)
    }

    /// Replays Silveran's playerView(for:) switch: audiobook vs ebook/readaloud.
    /// If the resolved local media path is missing, calls `onFailure` so the
    /// shell can toast "Can't open yet · try again".
    @ViewBuilder
    public static func playerView(
        for bookData: PlayerBookData,
        onFailure: @escaping () -> Void
    ) -> some View {
        if !Self.isOpenable(bookData) {
            // Path missing / not on disk: surface the failure toast immediately
            // instead of presenting an empty player.
            Color.clear
                .onAppear { onFailure() }
        } else {
            switch bookData.category {
                case .audio:
                    AudiobookPlayerView(
                        bookData: bookData,
                        onClose: { PlayerPresenter.shared.dismissCard() }
                    )
                    .navigationBarTitleDisplayMode(.inline)
                case .ebook, .synced:
                    EbookPlayerView(
                        bookData: bookData,
                        onClose: { PlayerPresenter.shared.dismissCard() }
                    )
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private static func isOpenable(_ bookData: PlayerBookData) -> Bool {
        guard let path = bookData.localMediaPath else { return false }
        let exists = FileManager.default.fileExists(atPath: path.path)
        if !exists {
            debugLog(
                "[PunkRallyPlayerHost] local media missing at \(path.path) for \(bookData.metadata.id)"
            )
        }
        return exists
    }
}

/// Internal environment switch: when true, tapping a downloaded card in the
/// hosting grid opens the player/reader directly (via PunkRallyPlayerHost.open)
/// instead of navigating to the detail screen. The punk Library/Shelf surfaces
/// set this so taps on downloaded ebook/audiobook/readaloud titles go straight
/// to playback.
private struct MediaGridTapOpensPlayerKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var mediaGridTapOpensPlayer: Bool {
        get { self[MediaGridTapOpensPlayerKey.self] }
        set { self[MediaGridTapOpensPlayerKey.self] = newValue }
    }
}

/// Mini-player bar that sits above the tab bar via per-tab `safeAreaInset`
/// (never overlay the UITabBar — TabView-level inset covers the bar on iOS).
public struct PunkRallyMiniPlayerBar: View {
    public init() {}

    public var body: some View {
        GlobalMiniPlayerBar()
            .accessibilityLabel("Mini player")
    }
}

extension View {
    /// Pads content and places GlobalMiniPlayerBar above the tab bar (or sheet
    /// bottom). Use on every tab root **and** every sheet that can sit over
    /// playback (Find, show, Import, Settings, …) so close/stop stay reachable.
    /// Collapses to zero height when nothing is playing.
    public func punkRallyMiniPlayerInset() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            PunkRallyMiniPlayerBar()
        }
    }
}

/// Sheet presentation modifier for ink+amp surfaces (Library, Shelf, Home)
/// wiring SettingsView and OfflineStatusSheet with full retry / downloads / settings routing.
public struct PunkRallySheetsModifier: ViewModifier {
    @Binding var showSettings: Bool
    var showOfflineSheet: Binding<Bool>?
    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel?
    @State private var pendingSettingsFromOffline = false

    public init(showSettings: Binding<Bool>, showOfflineSheet: Binding<Bool>? = nil) {
        self._showSettings = showSettings
        self.showOfflineSheet = showOfflineSheet
    }

    private var connectionErrorType: OfflineStatusSheet.ErrorType {
        guard let mediaViewModel else { return .networkOffline }
        if case .error(let message) = mediaViewModel.connectionStatus {
            return .authError(message)
        }
        for info in mediaViewModel.sourceConnectionInfos {
            if case .error(let message) = info.status {
                return .authError(message)
            }
        }
        return .networkOffline
    }

    private var hasConnectionError: Bool {
        mediaViewModel?.hasServerConnectionIssue ?? false
    }

    @ViewBuilder
    public func body(content: Content) -> some View {
        let base = content
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    SettingsView()
                        .navigationTitle("Settings")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") {
                                    showSettings = false
                                }
                            }
                        }
                }
                .punkRallyMiniPlayerInset()
            }

        if let showOfflineSheet {
            base.sheet(isPresented: showOfflineSheet, onDismiss: {
                if pendingSettingsFromOffline {
                    pendingSettingsFromOffline = false
                    showSettings = true
                }
            }) {
                OfflineStatusSheet(
                    errorType: connectionErrorType,
                    sources: mediaViewModel?.sourceConnectionInfos ?? [],
                    onRetry: {
                        let _ = await BookServiceActor.shared.fetchLibraryInformation()
                        if !hasConnectionError {
                            await MainActor.run {
                                showOfflineSheet.wrappedValue = false
                            }
                            return true
                        }
                        return false
                    },
                    onGoToDownloads: {
                        showOfflineSheet.wrappedValue = false
                        NotificationCenter.default.post(name: .punkRallyShowShelf, object: nil)
                    },
                    onGoToSettings: {
                        pendingSettingsFromOffline = true
                        showOfflineSheet.wrappedValue = false
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            if pendingSettingsFromOffline {
                                pendingSettingsFromOffline = false
                                showSettings = true
                            }
                        }
                    },
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        } else {
            base
        }
    }
}

public extension View {
    func punkRallySheets(
        showSettings: Binding<Bool>,
        showOfflineSheet: Binding<Bool>? = nil
    ) -> some View {
        modifier(
            PunkRallySheetsModifier(
                showSettings: showSettings,
                showOfflineSheet: showOfflineSheet
            )
        )
    }
}

/// Downloads-only shelf surface ("Shelf" tab): searchable grid of downloaded titles.
/// Wrapper around Silveran's internal `DownloadedContentView`, plus an optional
/// podcast-downloads strip and prune footer (RSS only — never Storyteller media).
public struct PunkRallyShelfView: View {
    @State private var searchText = ""
    @State private var showSettings = false
    @State private var showOfflineSheet = false
    @State private var downloadStore = PodcastDownloadStore.shared

    public init() {}

    public var body: some View {
        NavigationStack {
            DownloadedContentView(searchText: searchText)
                .environment(\.mediaGridTapOpensPlayer, true)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        PodcastShelfDownloadsStrip(store: downloadStore, searchText: searchText)
                        if downloadStore.settings.lastPruneCount > 0 {
                            Button {
                                showSettings = true
                            } label: {
                                HStack {
                                    Text(
                                        "Pruned \(downloadStore.settings.lastPruneCount) episode\(downloadStore.settings.lastPruneCount == 1 ? "" : "s") · Settings"
                                    )
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(.bar)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                "Pruned \(downloadStore.settings.lastPruneCount) episodes. Open Settings."
                            )
                        }
                    }
                }
                .iOSLibraryToolbar(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet
                )
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search"
                )
                .libraryNavigationDestinations(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet
                )
        }
        .punkRallySheets(
            showSettings: $showSettings,
            showOfflineSheet: $showOfflineSheet
        )
    }
}

/// Compact list of offline RSS episodes on Shelf (separate from book downloads).
private struct PodcastShelfDownloadsStrip: View {
    let store: PodcastDownloadStore
    let searchText: String

    private var downloads: [PodcastDownloadRecord] {
        let all = store.allDownloads()
        guard !searchText.isEmpty else { return all }
        let q = searchText.lowercased()
        return all.filter {
            $0.title.lowercased().contains(q)
                || ($0.showTitle?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        if !downloads.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Podcast downloads")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(downloads) { record in
                            PodcastShelfDownloadRow(record: record, store: store)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                }
            }
            .background(.bar)
        }
    }
}

private struct PodcastShelfDownloadRow: View {
    let record: PodcastDownloadRecord
    let store: PodcastDownloadStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 72, height: 72)
                    .overlay(
                        Image(systemName: "mic.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    )
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .padding(4)
            }
            Text(record.title)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .frame(width: 88, alignment: .leading)
            HStack(spacing: 4) {
                Text("POD")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text(record.adStripState.chipLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(adStripChipColor(record.adStripState))
            }
            if let label = PlaybackFinishabilityCopy.label(
                progress: record.progress,
                durationSeconds: record.durationSeconds
            ) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 88, alignment: .leading)
            }
        }
        .frame(width: 88, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            play(record)
        }
        .contextMenu {
            Button {
                Task {
                    guard let item = shelfQueueItem(from: record) else { return }
                    let start = await PodcastPlaybackQueueStore.shared.enqueuePlayNext(item)
                    if start { play(record) }
                }
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button {
                Task {
                    guard let item = shelfQueueItem(from: record) else { return }
                    let start = await PodcastPlaybackQueueStore.shared.enqueuePlayLast(item)
                    if start { play(record) }
                }
            } label: {
                Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            Button {
                store.setPinned(record.episodeID, pinned: !record.isPinned)
            } label: {
                Label(
                    record.isPinned ? "Remove Keep" : "Keep",
                    systemImage: record.isPinned ? "pin.slash" : "pin"
                )
            }
            Button(role: .destructive) {
                store.deleteDownload(episodeID: record.episodeID)
            } label: {
                Label("Remove Download", systemImage: "trash")
            }
        }
    }

    private func shelfQueueItem(from record: PodcastDownloadRecord) -> PodcastPlaybackQueueItem? {
        guard let audio = store.localAudioURL(for: record.episodeID) ?? record.remoteAudioURL else {
            return nil
        }
        return PodcastPlaybackQueueItem(
            episodeID: record.episodeID,
            title: record.title,
            showTitle: record.showTitle,
            audioURL: audio,
            durationSeconds: record.durationSeconds,
            coverURL: nil,
            feedURL: record.feedURL,
            mediaKindRaw: "audio"
        )
    }

    private func adStripChipColor(_ state: PodcastAdStripState) -> Color {
        switch state {
            case .original: return .secondary
            case .cleaning: return .blue
            case .clean: return .green
            case .failed: return .orange
        }
    }

    private func play(_ record: PodcastDownloadRecord) {
        guard let local = store.localAudioURL(for: record.episodeID)
            ?? record.remoteAudioURL
        else { return }
        var userInfo: [String: Any] = [
            "episodeID": record.episodeID,
            "title": record.title,
            "audioURL": local,
        ]
        userInfo["showTitle"] = record.showTitle
        if let duration = record.durationSeconds {
            userInfo["durationSeconds"] = duration
        }
        NotificationCenter.default.post(
            name: .punkRallyPlayPodcastEpisode,
            object: nil,
            userInfo: userInfo
        )
    }
}

/// Full catalogue browser ("Library" tab) without Silveran's inner tab bar:
/// searchable cover grid with book-detail navigation destinations wired.
/// Wrapper around Silveran's internal `BooksContentView`, plus Explore catalogs.
public struct PunkRallyLibraryView: View {
    private enum LibrarySegment: String, CaseIterable, Identifiable {
        case library = "Library"
        case explore = "Explore"
        var id: String { rawValue }
    }

    @State private var segment: LibrarySegment = .library
    @State private var searchText = ""
    @State private var exploreSearchText = ""
    @State private var showSettings = false
    @State private var showOfflineSheet = false
    @State private var showImport = false
    @State private var exploreStore = ExploreCatalogStore()
    @State private var navigationPath = NavigationPath()

    public init() {}

    private var searchBinding: Binding<String> {
        Binding(
            get: { segment == .library ? searchText : exploreSearchText },
            set: { newValue in
                if segment == .library {
                    searchText = newValue
                } else {
                    exploreSearchText = newValue
                }
            }
        )
    }

    public var body: some View {
        NavigationStack(path: $navigationPath) {
            VStack(spacing: 0) {
                Picker("Library section", selection: $segment) {
                    ForEach(LibrarySegment.allCases) { value in
                        Text(value.rawValue).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Group {
                    switch segment {
                    case .library:
                        BooksContentView(searchText: searchText)
                            .environment(\.mediaGridTapOpensPlayer, true)
                    case .explore:
                        ExploreRootView(store: exploreStore)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .iOSLibraryToolbar(
                showSettings: $showSettings,
                showOfflineSheet: $showOfflineSheet
            )
            .toolbar {
                if segment == .library {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showImport = true
                        } label: {
                            Label("Import", systemImage: "square.and.arrow.down")
                        }
                        .accessibilityHint(
                            "Upload EPUB and audiobook to Storyteller, then generate read-aloud"
                        )
                    }
                }
            }
            .searchable(
                text: searchBinding,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: segment == .library ? "Search" : "Search catalog"
            )
            .onChange(of: exploreSearchText) { _, newValue in
                exploreStore.setSearchText(newValue)
            }
            .onChange(of: segment) { _, newValue in
                navigationPath = NavigationPath()
                if newValue == .explore {
                    exploreStore.setSearchText(exploreSearchText)
                }
            }
            .navigationDestination(for: ExploreBook.self) { book in
                ExploreBookDetailView(book: book)
            }
            .libraryNavigationDestinations(
                showSettings: $showSettings,
                showOfflineSheet: $showOfflineSheet
            )
            .sheet(isPresented: $showImport) {
                NavigationStack {
                    UploadNewBookView()
                        .navigationTitle("Import")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showImport = false }
                            }
                        }
                }
                .punkRallyMiniPlayerInset()
            }
        }
        .punkRallySheets(
            showSettings: $showSettings,
            showOfflineSheet: $showOfflineSheet
        )
    }
}

/// Helper actions for opening current or restored book in the ink+amp shell.
public enum PunkRallyContinueAction {
    @MainActor
    public static func openLastOrCurrentBook(mediaViewModel: MediaViewModel? = nil) async {
        if let data = await LastOpenBookStore.loadPlayerBookData() {
            PlayerPresenter.shared.present(data)
            return
        }
        if let vm = mediaViewModel, let firstBook = vm.library.bookMetaData.first {
            vm.pendingOpenBookID = firstBook.id
        }
    }
}
#endif