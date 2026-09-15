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
/// Wrapper around Silveran's internal `DownloadedContentView`.
public struct PunkRallyShelfView: View {
    @State private var searchText = ""
    @State private var showSettings = false
    @State private var showOfflineSheet = false

    public init() {}

    public var body: some View {
        NavigationStack {
            DownloadedContentView(searchText: searchText)
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