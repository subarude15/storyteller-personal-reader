//
//  PunkRallyShellSupport.swift
//  SilveranAppleKit
//
//  punk+rally host-app facades: public SwiftUI views over internal Silveran
//  surfaces (mini-player bar, downloads shelf, library grid) so the five-tab
//  host shell in the app target can compose them without reaching into
//  module-internal types.
//

#if os(iOS)
import SwiftUI

/// Mini-player bar (audio/readaloud) that sits above the tab bar.
/// Wrapper around Silveran's internal `GlobalMiniPlayerBar`.
public struct PunkRallyMiniPlayerBar: View {
    public init() {}

    public var body: some View {
        GlobalMiniPlayerBar()
            .accessibilityLabel("Mini player")
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
    }
}
#endif