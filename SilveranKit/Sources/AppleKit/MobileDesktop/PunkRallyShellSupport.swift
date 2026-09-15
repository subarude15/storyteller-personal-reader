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
    public static let punkRallyOpenPlayer = Notification.Name("punkRallyOpenPlayer")
    public static let punkRallyOpenPlayerFailed = Notification.Name("punkRallyOpenPlayerFailed")
    /// PodcastsViewModel.play(episode:) → host shell: open the episode on the
    /// shared audio session and present the podcast card.
    public static let punkRallyPlayPodcastEpisode = Notification.Name("punkRallyPlayPodcastEpisode")
    /// Book or podcast last-touched changed — Home should rebuild Continue / Up next.
    public static let punkRallyHomeQueueDidChange = Notification.Name("punkRallyHomeQueueDidChange")
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

/// Mini-player bar (audio/readaloud) that sits above the tab bar.
/// Wrapper around Silveran's internal `GlobalMiniPlayerBar`.
public struct PunkRallyMiniPlayerBar: View {
    public init() {}

    public var body: some View {
        GlobalMiniPlayerBar()
            .accessibilityLabel("Mini player")
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
            Image(systemName: "mic.fill")
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 56)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(record.title)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .frame(width: 88, alignment: .leading)
            HStack(spacing: 4) {
                Text("POD")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.blue)
                if record.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            play(record)
        }
        .contextMenu {
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
/// Wrapper around Silveran's internal `BooksContentView`.
public struct PunkRallyLibraryView: View {
    @State private var searchText = ""
    @State private var showSettings = false
    @State private var showOfflineSheet = false

    public init() {}

    public var body: some View {
        NavigationStack {
            BooksContentView(searchText: searchText)
                .environment(\.mediaGridTapOpensPlayer, true)
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