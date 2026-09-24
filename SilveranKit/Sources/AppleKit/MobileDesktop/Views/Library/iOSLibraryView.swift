#if os(iOS)
import SwiftUI

extension Notification.Name {
    public static let silveranShowLibrary = Notification.Name("silveranShowLibrary")
    public static let silveranShowReader = Notification.Name("silveranShowReader")
}

public enum ConfigurableTab: String, CaseIterable, Identifiable {
    case books
    case series
    case authors
    case narrators
    case tags
    case collections
    case downloaded
    case translators
    case publicationYears
    case ratings

    public var id: String { rawValue }

    public var label: String {
        switch self {
            case .books: "Books"
            case .series: "Series"
            case .authors: "Authors"
            case .narrators: "Narrators"
            case .tags: "Tags"
            case .collections: "Collections"
            case .downloaded: "Downloaded"
            case .translators: "Translators"
            case .publicationYears: "Publication Year"
            case .ratings: "Ratings"
        }
    }

    public var iconName: String {
        switch self {
            case .books: "books.vertical.fill"
            case .series: "square.stack.fill"
            case .authors: "person.2.fill"
            case .narrators: "mic.fill"
            case .tags: "tag.fill"
            case .collections: "rectangle.stack"
            case .downloaded: "arrow.down.circle.fill"
            case .translators: "character.book.closed.fill"
            case .publicationYears: "calendar"
            case .ratings: "star.fill"
        }
    }
}

public struct iOSLibraryView: View {
    @Environment(\.colorScheme) private var colorScheme
    private var theme: InkAmpAppTheme { .resolve(for: colorScheme) }
    @State private var searchText: String = ""
    @State private var selectedTab: Tab = .home
    @State private var showSettings = false
    @State private var showDownloads = false
    @State private var showOfflineSheet = false
    @State private var sections: [SidebarSectionDescription] = LibrarySidebarDefaults.getSections()
    @State private var selectedItem: SidebarItemDescription? = nil
    @State private var moreNavigationPath = NavigationPath()
    @State private var collectionsNavigationPath = NavigationPath()
    @State private var booksNavigationPath = NavigationPath()
    @State private var downloadedNavigationPath = NavigationPath()
    @State private var shortcutDetailBook: BookMetadata?
    @State private var metadataEditorData: MetadataEditorData?
    @State private var metadataEditorHasUnsavedChanges = false
    @State private var showMetadataEditorCloseWarning = false
    @State private var showMetadataPermissionError = false
    @State private var metadataPermissionErrorMessage = ""
    @State private var settingsViewModel = SettingsViewModel()
    @AppStorage("coverPref.iOSLibrary") private var coverPrefRaw: String = CoverPreference
        .preferEbook.rawValue
    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel

    private var coverPreference: CoverPreference {
        CoverPreference(rawValue: coverPrefRaw) ?? .preferEbook
    }

    public init() {}

    private var connectionErrorType: OfflineStatusSheet.ErrorType {
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
        mediaViewModel.hasServerConnectionIssue
    }

    private var connectionErrorIcon: String {
        mediaViewModel.connectionIssueIcon
    }

    enum Tab: Hashable {
        case home
        case slot1
        case slot2
        case more
    }

    private var slot1Tab: ConfigurableTab {
        ConfigurableTab(rawValue: settingsViewModel.tabBarSlot1) ?? .books
    }

    private var slot2Tab: ConfigurableTab {
        ConfigurableTab(rawValue: settingsViewModel.tabBarSlot2) ?? .series
    }

    private func tabLabel(for tab: Tab) -> String {
        switch tab {
            case .home: "Home"
            case .slot1: slot1Tab.label
            case .slot2: slot2Tab.label
            case .more: "More"
        }
    }

    private func tabIcon(for tab: Tab) -> String {
        switch tab {
            case .home: "house.fill"
            case .slot1: slot1Tab.iconName
            case .slot2: slot2Tab.iconName
            case .more: "ellipsis.circle.fill"
        }
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            homeTab
                .safeAreaInset(edge: .bottom, spacing: 0) { GlobalMiniPlayerBar() }
                .tabItem {
                    Label(tabLabel(for: .home), systemImage: tabIcon(for: .home))
                }
                .tag(Tab.home)

            configurableTabView(for: slot1Tab)
                .safeAreaInset(edge: .bottom, spacing: 0) { GlobalMiniPlayerBar() }
                .tabItem {
                    Label(tabLabel(for: .slot1), systemImage: tabIcon(for: .slot1))
                }
                .tag(Tab.slot1)

            configurableTabView(for: slot2Tab)
                .safeAreaInset(edge: .bottom, spacing: 0) { GlobalMiniPlayerBar() }
                .tabItem {
                    Label(tabLabel(for: .slot2), systemImage: tabIcon(for: .slot2))
                }
                .tag(Tab.slot2)

            moreTab
                .safeAreaInset(edge: .bottom, spacing: 0) { GlobalMiniPlayerBar() }
                .tabItem {
                    Label(tabLabel(for: .more), systemImage: tabIcon(for: .more))
                }
                .tag(Tab.more)
        }
        .tint(theme.accent)
        .toolbarBackground(theme.surfaceElevated, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .environment(\.editMetadataAction, handleEditMetadata)
        .id("\(settingsViewModel.tabBarSlot1)-\(settingsViewModel.tabBarSlot2)")
        .onChange(of: selectedTab) { _, _ in
            searchText = ""
        }
        .onReceive(NotificationCenter.default.publisher(for: .silveranShowLibrary)) { _ in
            selectedTab = .home
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
                        showOfflineSheet: $showOfflineSheet,
                    )
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") {
                                shortcutDetailBook = nil
                            }
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
                            Button("Done") {
                                showSettings = false
                            }
                        }
                    }
            }
        }
        .sheet(isPresented: $showDownloads) {
            NavigationStack {
                DownloadsView()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showDownloads = false }
                        }
                    }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .inkampShowManualDownloads)) { _ in
            showDownloads = true
        }
        .sheet(isPresented: $showOfflineSheet) {
            OfflineStatusSheet(
                errorType: connectionErrorType,
                sources: mediaViewModel.sourceConnectionInfos,
                onRetry: {
                    let _ = await BookServiceActor.shared.fetchLibraryInformation()
                    if !hasConnectionError {
                        await MainActor.run {
                            showOfflineSheet = false
                        }
                        return true
                    }
                    return false
                },
                onGoToDownloads: {
                    showOfflineSheet = false
                    selectedTab = .more
                    moreNavigationPath.append(MoreMenuView.MoreDestination.downloaded)
                },
                onGoToSettings: {
                    showOfflineSheet = false
                    showSettings = true
                },
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(
            item: $metadataEditorData,
            onDismiss: {
                metadataEditorData = nil
                metadataEditorHasUnsavedChanges = false
            },
        ) { metadataEditorData in
            VStack(spacing: 0) {
                HStack {
                    Text("Edit Metadata")
                        .font(.headline)
                    Spacer()
                    Button("Done") {
                        closeMetadataEditor()
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(.bar)

                Divider()

                MetadataEditorView(
                    initialBookIds: metadataEditorData.bookIds,
                    hasUnsavedChanges: $metadataEditorHasUnsavedChanges,
                )
                .environment(mediaViewModel)
            }
            .interactiveDismissDisabled(metadataEditorHasUnsavedChanges)
            .alert(
                "Discard unsaved metadata changes?",
                isPresented: $showMetadataEditorCloseWarning,
            ) {
                Button("Discard Changes", role: .destructive) {
                    metadataEditorHasUnsavedChanges = false
                    self.metadataEditorData = nil
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Closing the metadata editor will lose any unsaved changes.")
            }
        }
        .alert("Edit Metadata", isPresented: $showMetadataPermissionError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(metadataPermissionErrorMessage)
        }
    }

    private func closeMetadataEditor() {
        if metadataEditorHasUnsavedChanges {
            showMetadataEditorCloseWarning = true
        } else {
            metadataEditorData = nil
        }
    }

    private func handleEditMetadata(bookIds: [BookID]) {
        if bookIds.contains(where: { mediaViewModel.isLocalStandaloneBook($0) }) {
            metadataPermissionErrorMessage =
                "Editing metadata for local books is not supported yet."
            showMetadataPermissionError = true
            return
        }

        Task {
            let sourceIDs = mediaViewModel.sourceIDs(for: bookIds)
            let result = await checkMetadataEditPermission(sourceIDs: sourceIDs)
            await MainActor.run {
                switch result {
                    case .allowed:
                        Task {
                            await Task.yield()
                            metadataEditorData = MetadataEditorData(bookIds: bookIds)
                        }
                    case .denied:
                        metadataPermissionErrorMessage =
                            "Your account does not have permission to edit metadata on this server."
                        showMetadataPermissionError = true
                    case .error(let message):
                        metadataPermissionErrorMessage =
                            "Could not verify server permissions: \(message)"
                        showMetadataPermissionError = true
                }
            }
        }
    }

    private func checkMetadataEditPermission(sourceIDs: [BookSourceID]) async
        -> StorytellerActor.PermissionCheckResult
    {
        for sourceID in sourceIDs {
            let result = await BookServiceActor.shared.checkBookUpdatePermission(
                sourceID: sourceID
            )
            if case .allowed = result {
                continue
            }
            return result
        }
        return .allowed
    }

    private var homeTab: some View {
        HomeView(
            searchText: $searchText,
            sidebarSections: $sections,
            selectedSidebarItem: $selectedItem,
            showSettings: $showSettings,
            showOfflineSheet: $showOfflineSheet,
        )
    }

    @ViewBuilder
    private func configurableTabView(for tab: ConfigurableTab) -> some View {
        switch tab {
            case .books:
                booksTabContent
            case .series:
                seriesTabContent
            case .authors:
                authorsTabContent
            case .narrators:
                narratorsTabContent
            case .tags:
                tagsTabContent
            case .collections:
                collectionsTabContent
            case .downloaded:
                downloadedTabContent
            case .translators:
                translatorsTabContent
            case .publicationYears:
                publicationYearsTabContent
            case .ratings:
                ratingsTabContent
        }
    }

    private var booksTabContent: some View {
        NavigationStack(path: $booksNavigationPath) {
            BooksContentView(searchText: searchText)
                .iOSLibraryToolbar(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet,
                )
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search",
                )
                .libraryNavigationDestinations(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet,
                )
        }
        .environment(\.mediaNavigationPath, $booksNavigationPath)
    }

    private var seriesTabContent: some View {
        SeriesView(
            mediaKind: .ebook,
            searchText: $searchText,
            sidebarSections: $sections,
            selectedSidebarItem: $selectedItem,
            showSettings: $showSettings,
            showOfflineSheet: $showOfflineSheet,
        )
    }

    private var authorsTabContent: some View {
        AuthorView(
            mediaKind: .ebook,
            searchText: $searchText,
            sidebarSections: $sections,
            selectedSidebarItem: $selectedItem,
            showSettings: $showSettings,
            showOfflineSheet: $showOfflineSheet,
        )
    }

    private var narratorsTabContent: some View {
        NarratorView(
            mediaKind: .ebook,
            searchText: $searchText,
            sidebarSections: $sections,
            selectedSidebarItem: $selectedItem,
            showSettings: $showSettings,
            showOfflineSheet: $showOfflineSheet,
        )
    }

    private var tagsTabContent: some View {
        TagView(
            mediaKind: .ebook,
            searchText: $searchText,
            sidebarSections: $sections,
            selectedSidebarItem: $selectedItem,
            showSettings: $showSettings,
            showOfflineSheet: $showOfflineSheet,
        )
    }

    private var collectionsTabContent: some View {
        CollectionsView(
            mediaKind: .ebook,
            searchText: $searchText,
            sidebarSections: $sections,
            selectedSidebarItem: $selectedItem,
            showSettings: $showSettings,
            showOfflineSheet: $showOfflineSheet,
        )
    }

    private var downloadedTabContent: some View {
        NavigationStack(path: $downloadedNavigationPath) {
            DownloadedContentView(searchText: searchText)
                .iOSLibraryToolbar(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet,
                )
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search",
                )
                .libraryNavigationDestinations(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet,
                )
        }
        .environment(\.mediaNavigationPath, $downloadedNavigationPath)
    }

    private var translatorsTabContent: some View {
        TranslatorView(
            mediaKind: .ebook,
            searchText: $searchText,
            sidebarSections: $sections,
            selectedSidebarItem: $selectedItem,
            showSettings: $showSettings,
            showOfflineSheet: $showOfflineSheet,
        )
    }

    private var publicationYearsTabContent: some View {
        PublicationYearView(
            mediaKind: .ebook,
            searchText: $searchText,
            sidebarSections: $sections,
            selectedSidebarItem: $selectedItem,
            showSettings: $showSettings,
            showOfflineSheet: $showOfflineSheet,
        )
    }

    private var ratingsTabContent: some View {
        RatingView(
            mediaKind: .ebook,
            searchText: $searchText,
            sidebarSections: $sections,
            selectedSidebarItem: $selectedItem,
            showSettings: $showSettings,
            showOfflineSheet: $showOfflineSheet,
        )
    }

    private var moreTab: some View {
        NavigationStack(path: $moreNavigationPath) {
            MoreMenuView(
                searchText: $searchText,
                showSettings: $showSettings,
                showOfflineSheet: $showOfflineSheet,
                navigationPath: $moreNavigationPath,
                excludedTabs: [slot1Tab, slot2Tab],
            )
        }
        .environment(\.mediaNavigationPath, $moreNavigationPath)
    }

    @ViewBuilder
    private func playerView(for bookData: PlayerBookData) -> some View {
        switch bookData.category {
            case .audio:
                AudiobookPlayerView(
                    bookData: bookData,
                    onClose: { PlayerPresenter.shared.dismissCard() },
                )
                .navigationBarTitleDisplayMode(.inline)
            case .ebook, .synced:
                EbookPlayerView(
                    bookData: bookData,
                    onClose: { PlayerPresenter.shared.dismissCard() },
                )
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func openPendingBookIfReady() {
        guard let target = mediaViewModel.pendingOpenBookID,
            !mediaViewModel.library.bookMetaData.isEmpty
        else { return }
        mediaViewModel.pendingOpenBookID = nil

        guard let book = mediaViewModel.library.bookMetaData.first(where: { $0.id == target })
        else {
            debugLog("[iOSLibraryView] Dropping unknown deep link for book \(target)")
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
                    category: category,
                )
            )
        }
    }
}

#endif
