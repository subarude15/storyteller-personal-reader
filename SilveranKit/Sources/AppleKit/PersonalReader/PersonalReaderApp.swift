#if os(iOS)
import SilveranKit
import SwiftUI
import UIKit

/// Personal iPhone/iPad shell for the Storyteller Personal Reader fork.
///
/// Silveran continues to own startup, Storyteller sync, reading, playback, and
/// downloads. This shell only owns top-level product navigation and presentation.
struct PersonalReaderApp: App {
    @UIApplicationDelegateAdaptor(SilveranAppDelegate.self) var appDelegate
    @State private var mediaViewModel: MediaViewModel
    private let startupTask: Task<Bool, Never>
    private let restorePrerequisitesTask: Task<Bool, Never>

    init() {
        StorytellerFontRegistration.registerBundledFonts()

        let vm = MediaViewModel()
        _mediaViewModel = State(initialValue: vm)

        let prerequisites = Task {
            let started = CFAbsoluteTimeGetCurrent()
            guard await SilveranRuntime.start() else { return false }
            await vm.start()
            await AppleWatchActor.shared.activate()
            await ProgressUploadManager.shared.setBackstopScheduler {
                await SilveranAppDelegate.scheduleProgressSyncRefreshIfNeeded()
            }
            do {
                let webResourcesURL = try KitResources.webResourcesDirectory()
                try await FilesystemActor.shared.copyWebResources(from: webResourcesURL)
            } catch {
                debugLog(
                    "[PersonalReaderApp] Failed to copy web resources: \(error.localizedDescription)"
                )
            }
            debugLog(
                "[RestoreTrace][PersonalReaderStartup] prerequisites deltaMs=\(String(format: \"%.1f\", (CFAbsoluteTimeGetCurrent() - started) * 1000))"
            )
            return true
        }
        restorePrerequisitesTask = prerequisites

        startupTask = Task {
            guard await prerequisites.value else { return false }
            let started = CFAbsoluteTimeGetCurrent()
            await BookServiceActor.shared.refreshLibraryFromSources()
            debugLog(
                "[RestoreTrace][PersonalReaderStartup] refreshLibraryFromSources deltaMs=\(String(format: \"%.1f\", (CFAbsoluteTimeGetCurrent() - started) * 1000))"
            )

            if LastOpenBookStore.hasSavedRoute {
                debugLog(
                    "[PersonalReaderApp] Skipping extracted EPUB cleanup because a last-open book route is pending"
                )
            } else {
                await FilesystemActor.shared.cleanupExtractedEpubDirectories()
            }
            return true
        }
    }

    var body: some Scene {
        WindowGroup("Personal Reader", id: "MyLibrary") {
            PersonalReaderLaunchView(restorePrerequisitesTask: restorePrerequisitesTask)
                .environment(AppLaunchContext.environment)
                .environment(mediaViewModel)
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didEnterBackgroundNotification
                    )
                ) { _ in
                    handleDidEnterBackground()
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: UIApplication.didBecomeActiveNotification
                    )
                ) { _ in
                    handleDidBecomeActive()
                }
                .task {
                    if UIApplication.shared.applicationState == .active {
                        handleDidBecomeActive()
                    }
                }
        }
        .commands {
            CommandMenu("Go") {
                Button("Show Library") {
                    NotificationCenter.default.post(name: .silveranShowLibrary, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)
                Button("Open Reader") {
                    NotificationCenter.default.post(name: .silveranShowReader, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }

    private func handleDidEnterBackground() {
        debugLog("[PersonalReaderApp] App entering background")
        NotificationCenter.default.post(name: .appWillResignActive, object: nil)
        Task {
            guard await SilveranRuntime.start() else { return }
            await BookServiceActor.shared.setActive(false, source: .app)
        }

        var backgroundTask: UIBackgroundTaskIdentifier = .invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
        Task {
            guard await SilveranRuntime.start() else {
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                    backgroundTask = .invalid
                }
                return
            }
            try? await Task.sleep(for: .seconds(2))
            await ProgressUploadManager.shared.enqueuePendingUploads()
            await SilveranAppDelegate.scheduleProgressSyncRefreshIfNeeded()

            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }
    }

    private func handleDidBecomeActive() {
        debugLog("[PersonalReaderApp] App becoming active")
        Task {
            guard await SilveranRuntime.start() else { return }
            await BookServiceActor.shared.setActive(true, source: .app)
        }
    }
}

private struct PersonalReaderLaunchView: View {
    let restorePrerequisitesTask: Task<Bool, Never>
    @Environment(MediaViewModel.self) private var mediaViewModel
    @State private var restoreStartupFinished = false
    @State private var readaloudGeneratorData: ReadaloudGeneratorData?

    var body: some View {
        Group {
            if !restoreStartupFinished {
                ProgressView(LastOpenBookStore.hasSavedRoute ? "Loading book..." : "Loading...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PersonalReaderRootView()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .silveranCreateReadaloud)) {
            notification in
            guard AppLaunchContext.environment.readaloudAligner != nil else { return }
            readaloudGeneratorData = notification.object as? ReadaloudGeneratorData
        }
        .sheet(item: $readaloudGeneratorData) { data in
            NavigationStack {
                ReadaloudGeneratorView(initialData: data)
                    .environment(mediaViewModel)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") {
                                readaloudGeneratorData = nil
                            }
                        }
                    }
            }
        }
        .onOpenURL { url in
            guard let bookID = SilveranBookLink.bookID(from: url) else { return }
            mediaViewModel.pendingOpenBookID = bookID
        }
        .task {
            guard await restorePrerequisitesTask.value else { return }
            if mediaViewModel.pendingOpenBookID == nil,
                let bookData = await LastOpenBookStore.loadPlayerBookData(),
                mediaViewModel.pendingOpenBookID == nil
            {
                PlayerPresenter.shared.present(bookData)
            }
            restoreStartupFinished = true
        }
    }
}

/// First personal shell milestone. Home and Library are backed directly by
/// Silveran's existing views; Podcasts and Journal intentionally start as explicit
/// feature placeholders so their domains can arrive independently in later PRs.
struct PersonalReaderRootView: View {
    enum Tab: Hashable {
        case home
        case library
        case podcasts
        case journal
    }

    @Environment(MediaViewModel.self) private var mediaViewModel
    @State private var selectedTab: Tab = .home
    @State private var searchText = ""
    @State private var sections: [SidebarSectionDescription] = LibrarySidebarDefaults.getSections()
    @State private var selectedSidebarItem: SidebarItemDescription?
    @State private var libraryNavigationPath = NavigationPath()
    @State private var showSettings = false
    @State private var showOfflineSheet = false
    @State private var shortcutDetailBook: BookMetadata?

    var body: some View {
        TabView(selection: $selectedTab) {
            homeTab
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(Tab.home)

            libraryTab
                .tabItem { Label("Library", systemImage: "books.vertical.fill") }
                .tag(Tab.library)

            featurePlaceholder(
                title: "Podcasts",
                subtitle: "Subscriptions, episodes, downloads, and Up Next arrive in PR006–PR008.",
                systemImage: "mic.fill"
            )
            .tabItem { Label("Podcasts", systemImage: "mic.fill") }
            .tag(Tab.podcasts)

            featurePlaceholder(
                title: "Journal",
                subtitle: "Reading and listening history arrives after the activity tracker in PR004–PR005.",
                systemImage: "book.closed.fill"
            )
            .tabItem { Label("Journal", systemImage: "book.closed.fill") }
            .tag(Tab.journal)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            GlobalMiniPlayerBar()
        }
        .onChange(of: selectedTab) { _, _ in
            searchText = ""
        }
        .onReceive(NotificationCenter.default.publisher(for: .silveranShowLibrary)) { _ in
            selectedTab = .library
        }
        .onReceive(NotificationCenter.default.publisher(for: .silveranShowReader)) { _ in
            Task {
                if let data = await LastOpenBookStore.loadPlayerBookData() {
                    PlayerPresenter.shared.present(data)
                }
            }
        }
        .onChange(of: mediaViewModel.pendingOpenBookID) { _, _ in
            openPendingBookIfReady()
        }
        .onChange(of: mediaViewModel.library.bookMetaData.count) { _, _ in
            openPendingBookIfReady()
        }
        .task {
            openPendingBookIfReady()
        }
        .fullScreenCover(item: PlayerPresenter.shared.cardItemBinding) { wrapper in
            NavigationStack {
                playerView(for: wrapper.data)
            }
        }
        .sheet(item: $shortcutDetailBook) { book in
            NavigationStack {
                iOSBookDetailView(item: book, mediaKind: .ebook)
                    .libraryNavigationDestinations(
                        showSettings: $showSettings,
                        showOfflineSheet: $showOfflineSheet
                    )
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { shortcutDetailBook = nil }
                        }
                    }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showSettings = false }
                        }
                    }
            }
        }
    }

    private var homeTab: some View {
        HomeView(
            searchText: $searchText,
            sidebarSections: $sections,
            selectedSidebarItem: $selectedSidebarItem,
            showSettings: $showSettings,
            showOfflineSheet: $showOfflineSheet
        )
    }

    private var libraryTab: some View {
        NavigationStack(path: $libraryNavigationPath) {
            BooksContentView(searchText: searchText)
                .navigationTitle("Library")
                .iOSLibraryToolbar(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet
                )
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search books"
                )
                .libraryNavigationDestinations(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet
                )
        }
        .environment(\.mediaNavigationPath, $libraryNavigationPath)
    }

    private func featurePlaceholder(
        title: String,
        subtitle: String,
        systemImage: String
    ) -> some View {
        NavigationStack {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                Text(subtitle)
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func playerView(for bookData: PlayerBookData) -> some View {
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

    private func openPendingBookIfReady() {
        guard let target = mediaViewModel.pendingOpenBookID,
            !mediaViewModel.library.bookMetaData.isEmpty
        else { return }

        mediaViewModel.pendingOpenBookID = nil

        guard let book = mediaViewModel.library.bookMetaData.first(where: { $0.id == target }) else {
            debugLog("[PersonalReaderRootView] Dropping unknown deep link for book \(target)")
            return
        }

        guard let category = mediaViewModel.preferredDownloadedCategory(for: book) else {
            shortcutDetailBook = book
            return
        }

        Task {
            PlayerPresenter.shared.present(
                await mediaViewModel.makePlayerBookDataLoadingCovers(
                    for: book,
                    category: category
                )
            )
        }
    }
}
#endif
