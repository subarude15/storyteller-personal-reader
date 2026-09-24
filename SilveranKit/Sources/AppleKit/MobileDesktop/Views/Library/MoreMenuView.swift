#if os(iOS)
import SwiftUI

struct MoreMenuView: View {
    @Binding var searchText: String
    @Binding var showSettings: Bool
    @Binding var showOfflineSheet: Bool
    @Binding var navigationPath: NavigationPath
    var excludedTabs: [ConfigurableTab] = []
    @Environment(MediaViewModel.self) private var mediaViewModel
    @State private var isWatchPaired = false

    @State private var hasIncompleteDownloads = false

    enum MoreDestination: Hashable {
        case books
        case series
        case authors
        case narrators
        case tags
        case collections
        case sources
        case downloaded
        case translators
        case publicationYears
        case ratings
        case currentlyDownloading
        case addBook
        case createReadaloud
        case appleWatch
        case manualDownloads
    }

    private var hasConnectionError: Bool {
        mediaViewModel.hasServerConnectionIssue
    }

    private var connectionErrorIcon: String {
        mediaViewModel.connectionIssueIcon
    }

    private func isExcluded(_ tab: ConfigurableTab) -> Bool {
        excludedTabs.contains(tab)
    }

    var body: some View {
        List {
            Section {
                if !isExcluded(.books) {
                    NavigationLink(value: MoreDestination.books) {
                        Label("Books", systemImage: "books.vertical.fill")
                    }
                }
                if !isExcluded(.series) {
                    NavigationLink(value: MoreDestination.series) {
                        Label("Series", systemImage: "square.stack.fill")
                    }
                }
                if !isExcluded(.authors) {
                    NavigationLink(value: MoreDestination.authors) {
                        Label("Authors", systemImage: "person.2.fill")
                    }
                }
                if !isExcluded(.narrators) {
                    NavigationLink(value: MoreDestination.narrators) {
                        Label("Narrators", systemImage: "mic.fill")
                    }
                }
                if !isExcluded(.tags) {
                    NavigationLink(value: MoreDestination.tags) {
                        Label("Tags", systemImage: "tag.fill")
                    }
                }
                if !isExcluded(.collections) {
                    NavigationLink(value: MoreDestination.collections) {
                        Label("Collections", systemImage: "rectangle.stack")
                    }
                }
                if !mediaViewModel.bookSources.isEmpty {
                    NavigationLink(value: MoreDestination.sources) {
                        Label("Sources", systemImage: "externaldrive.fill")
                    }
                }
                if !isExcluded(.translators) {
                    NavigationLink(value: MoreDestination.translators) {
                        Label("Translators", systemImage: "character.book.closed.fill")
                    }
                }
                if !isExcluded(.publicationYears) {
                    NavigationLink(value: MoreDestination.publicationYears) {
                        Label("Publication Year", systemImage: "calendar")
                    }
                }
                if !isExcluded(.ratings) {
                    NavigationLink(value: MoreDestination.ratings) {
                        Label("Ratings", systemImage: "star.fill")
                    }
                }
                if !isExcluded(.downloaded) {
                    NavigationLink(value: MoreDestination.downloaded) {
                        Label("Downloaded", systemImage: "arrow.down.circle.fill")
                    }
                }
                if hasIncompleteDownloads {
                    NavigationLink(value: MoreDestination.currentlyDownloading) {
                        Label("Downloading", systemImage: "arrow.down.circle.dotted")
                    }
                }
                NavigationLink(value: MoreDestination.manualDownloads) {
                    Label {
                        HStack {
                            Text(DownloadsNavigation.downloadsDestination)
                            Spacer()
                            DownloadsAttentionBadge()
                        }
                    } icon: {
                        Image(systemName: "arrow.down.circle")
                    }
                }
                NavigationLink(value: MoreDestination.addBook) {
                    Label("Add Book", systemImage: "plus.circle")
                }
                if AppLaunchContext.environment.readaloudAligner != nil {
                    NavigationLink(value: MoreDestination.createReadaloud) {
                        Label {
                            Text("Create Readaloud")
                        } icon: {
                            Image("readalong")
                                .renderingMode(.template)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 20, height: 20)
                        }
                    }
                }
                if isWatchPaired {
                    NavigationLink(value: MoreDestination.appleWatch) {
                        Label("Apple Watch", systemImage: "applewatch")
                    }
                }
            }
        }
        .task {
            isWatchPaired = await AppleWatchActor.shared.isWatchPaired()
            let downloads = await DownloadManager.shared.incompleteDownloads
            hasIncompleteDownloads = !downloads.isEmpty

            let _ = await DownloadManager.shared.addObserver { records in
                Task { @MainActor in
                    hasIncompleteDownloads = records.contains { $0.isIncomplete }
                }
            }
        }
        .navigationTitle("More")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    if hasConnectionError {
                        Button {
                            showOfflineSheet = true
                        } label: {
                            Image(systemName: connectionErrorIcon)
                                .foregroundStyle(.red)
                        }
                    }
                    DownloadsToolbarButton()
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
        }
        .navigationDestination(for: MoreDestination.self) { destination in
            switch destination {
                case .books:
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
                case .series:
                    MoreSeriesView(
                        searchText: $searchText,
                        showSettings: $showSettings,
                        showOfflineSheet: $showOfflineSheet,
                    )
                case .authors:
                    MoreAuthorsView(
                        searchText: $searchText,
                        showSettings: $showSettings,
                        showOfflineSheet: $showOfflineSheet,
                    )
                case .narrators:
                    MoreNarratorsView(
                        searchText: $searchText,
                        showSettings: $showSettings,
                        showOfflineSheet: $showOfflineSheet,
                    )
                case .tags:
                    MoreTagsView(
                        searchText: $searchText,
                        showSettings: $showSettings,
                        showOfflineSheet: $showOfflineSheet,
                    )
                case .translators:
                    MoreTranslatorsView(
                        searchText: $searchText,
                        showSettings: $showSettings,
                        showOfflineSheet: $showOfflineSheet,
                    )
                case .publicationYears:
                    MorePublicationYearsView(
                        searchText: $searchText,
                        showSettings: $showSettings,
                        showOfflineSheet: $showOfflineSheet,
                    )
                case .ratings:
                    MoreRatingsView(
                        searchText: $searchText,
                        showSettings: $showSettings,
                        showOfflineSheet: $showOfflineSheet,
                    )
                case .collections:
                    MoreCollectionsView(
                        searchText: $searchText,
                        showSettings: $showSettings,
                        showOfflineSheet: $showOfflineSheet,
                    )
                case .sources:
                    MoreSourcesView(
                        searchText: $searchText,
                        showSettings: $showSettings,
                        showOfflineSheet: $showOfflineSheet,
                    )
                case .downloaded:
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
                case .currentlyDownloading:
                    CurrentlyDownloadingView()
                        .iOSLibraryToolbar(
                            showSettings: $showSettings,
                            showOfflineSheet: $showOfflineSheet,
                        )
                case .manualDownloads:
                    DownloadsView()
                        .iOSLibraryToolbar(
                            showSettings: $showSettings,
                            showOfflineSheet: $showOfflineSheet,
                        )
                case .addBook:
                    UploadNewBookView()
                        .iOSLibraryToolbar(
                            showSettings: $showSettings,
                            showOfflineSheet: $showOfflineSheet,
                        )
                case .createReadaloud:
                    ReadaloudGeneratorView()
                        .navigationBarTitleDisplayMode(.inline)
                case .appleWatch:
                    WatchTransferView()
                        .iOSLibraryToolbar(
                            showSettings: $showSettings,
                            showOfflineSheet: $showOfflineSheet,
                        )
            }
        }
        .libraryNavigationDestinations(
            showSettings: $showSettings,
            showOfflineSheet: $showOfflineSheet,
        )
    }
}

#endif
