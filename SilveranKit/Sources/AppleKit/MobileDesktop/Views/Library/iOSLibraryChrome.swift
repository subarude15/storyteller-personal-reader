#if os(iOS)
import SwiftUI

public struct OfflineStatusSheet: View {
    public enum ErrorType: Equatable {
        case networkOffline
        case authError(String)
    }

    public let errorType: ErrorType
    public let sources: [SourceConnectionInfo]
    public let onRetry: () async -> Bool
    public let onGoToDownloads: () -> Void
    public let onGoToSettings: (() -> Void)?

    @State private var isRetrying = false

    public init(
        errorType: ErrorType = .networkOffline,
        sources: [SourceConnectionInfo] = [],
        onRetry: @escaping () async -> Bool,
        onGoToDownloads: @escaping () -> Void,
        onGoToSettings: (() -> Void)? = nil,
    ) {
        self.errorType = errorType
        self.sources = sources
        self.onRetry = onRetry
        self.onGoToDownloads = onGoToDownloads
        self.onGoToSettings = onGoToSettings
    }

    private var icon: String {
        "exclamationmark.triangle"
    }

    private var title: String {
        switch errorType {
            case .networkOffline: return "Connection Status"
            case .authError: return "Connection Error"
        }
    }

    private var message: String {
        switch errorType {
            case .networkOffline:
                if sources.filter({ $0.kind == .storyteller }).isEmpty {
                    return "No Storyteller server is connected yet. You can connect a server in Settings or read downloaded books on your shelf."
                }
                return
                    "Downloaded books are always available. Per-source status is shown below."
            case .authError(let details):
                return
                    "Unable to connect to a server: \(details). Please check your server credentials in Settings."
        }
    }

    @ViewBuilder
    private var sourceStatusList: some View {
        let serverSources = sources.filter { $0.kind == .storyteller }
        if !serverSources.isEmpty {
            VStack(spacing: 8) {
                ForEach(serverSources) { source in
                    HStack(spacing: 12) {
                        Image(systemName: "server.rack")
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                        Text(source.name)
                            .font(.subheadline)
                            .lineLimit(1)
                        Spacer()
                        Circle()
                            .fill(statusColor(for: source))
                            .frame(width: 8, height: 8)
                        Text(statusLabel(for: source))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.secondary.opacity(0.12))
                    )
                }
            }
            .padding(.horizontal)
        }
    }

    private func statusLabel(for source: SourceConnectionInfo) -> String {
        switch source.status {
            case .connected: return "Connected"
            case .connecting: return "Connecting…"
            case .disconnected: return "Offline"
            case .error: return "Error"
        }
    }

    private func statusColor(for source: SourceConnectionInfo) -> Color {
        switch source.status {
            case .connected: return .green
            case .connecting: return .yellow
            case .disconnected: return .orange
            case .error: return .red
        }
    }

    public var body: some View {
        VStack(spacing: 24) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.weight(.semibold))

                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            sourceStatusList

            VStack(spacing: 12) {
                if let onGoToSettings {
                    Button(action: onGoToSettings) {
                        HStack {
                            Image(systemName: "gearshape.fill")
                            Text("Go to Settings")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                }

                HStack(spacing: 12) {
                    Button {
                        isRetrying = true
                        Task {
                            let _ = await onRetry()
                            isRetrying = false
                        }
                    } label: {
                        HStack {
                            if isRetrying {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text("Retry")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRetrying)

                    Button(action: onGoToDownloads) {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("Downloads")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)
            }
        }
        .padding(24)
    }
}

extension OfflineStatusSheet.ErrorType {
    public var isAuthError: Bool {
        if case .authError = self { return true }
        return false
    }
}

struct IOSLibraryToolbarModifier: ViewModifier {
    @Binding var showSettings: Bool
    @Binding var showOfflineSheet: Bool
    /// When false (ink+amp Home/Library/Shelf), Downloads and Settings live under More.
    var includeDownloadsAndSettingsShortcuts: Bool = true
    @Environment(MediaViewModel.self) private var mediaViewModel

    private var hasConnectionError: Bool {
        mediaViewModel.hasServerConnectionIssue
    }

    private var connectionErrorIcon: String {
        mediaViewModel.connectionIssueIcon
    }

    func body(content: Content) -> some View {
        content
            .toolbar {
                if hasConnectionError || includeDownloadsAndSettingsShortcuts {
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
                            if includeDownloadsAndSettingsShortcuts {
                                DownloadsToolbarButton()
                                Button {
                                    showSettings = true
                                } label: {
                                    Label("Settings", systemImage: "gearshape")
                                }
                            }
                        }
                    }
                }
            }
    }
}

extension View {
    func iOSLibraryToolbar(
        showSettings: Binding<Bool>,
        showOfflineSheet: Binding<Bool>,
        includeDownloadsAndSettingsShortcuts: Bool = true,
    ) -> some View {
        modifier(
            IOSLibraryToolbarModifier(
                showSettings: showSettings,
                showOfflineSheet: showOfflineSheet,
                includeDownloadsAndSettingsShortcuts: includeDownloadsAndSettingsShortcuts,
            )
        )
    }
}

struct LibraryNavigationDestinations: ViewModifier {
    @Binding var showSettings: Bool
    @Binding var showOfflineSheet: Bool

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: BookMetadata.self) { item in
                iOSBookDetailView(item: item, mediaKind: .ebook)
                    .iOSLibraryToolbar(
                        showSettings: $showSettings,
                        showOfflineSheet: $showOfflineSheet,
                    )
            }
            .navigationDestination(for: String.self) { authorName in
                MediaGridView(
                    title: authorName,
                    searchText: "",
                    mediaKind: .ebook,
                    viewOptionsKey: "authorView.ebook",
                    tagFilter: nil,
                    seriesFilter: nil,
                    authorFilter: authorName,
                    statusFilter: nil,
                    defaultSort: "title",
                    preferredTileWidth: 110,
                    minimumTileWidth: 90,
                    columnBreakpoints: [
                        MediaGridView.ColumnBreakpoint(columns: 3, minWidth: 0)
                    ],
                    initialNarrationFilterOption: .both,
                )
                .navigationTitle(authorName)
                .iOSLibraryToolbar(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet,
                )
            }
            .navigationDestination(for: SeriesNavIdentifier.self) { series in
                MediaGridView(
                    title: series.name,
                    searchText: "",
                    mediaKind: .ebook,
                    viewOptionsKey: "seriesView.ebook",
                    tagFilter: nil,
                    seriesFilter: series.name,
                    statusFilter: nil,
                    defaultSort: "titleAZ",
                    preferredTileWidth: 110,
                    minimumTileWidth: 90,
                    columnBreakpoints: [
                        MediaGridView.ColumnBreakpoint(columns: 3, minWidth: 0)
                    ],
                    initialNarrationFilterOption: .both,
                )
                .navigationTitle(series.name)
                .iOSLibraryToolbar(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet,
                )
            }
            .navigationDestination(for: CollectionNavIdentifier.self) { collection in
                MediaGridView(
                    title: collection.name,
                    searchText: "",
                    mediaKind: .ebook,
                    viewOptionsKey: "collectionsView.ebook",
                    tagFilter: nil,
                    seriesFilter: nil,
                    collectionFilter: collection.name,
                    statusFilter: nil,
                    defaultSort: "titleAZ",
                    preferredTileWidth: 110,
                    minimumTileWidth: 90,
                    columnBreakpoints: [
                        MediaGridView.ColumnBreakpoint(columns: 3, minWidth: 0)
                    ],
                    initialNarrationFilterOption: .both,
                )
                .navigationTitle(collection.name)
                .iOSLibraryToolbar(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet,
                )
            }
            .navigationDestination(for: SourceNavIdentifier.self) { source in
                MediaGridView(
                    title: source.name,
                    searchText: "",
                    mediaKind: .ebook,
                    viewOptionsKey: "sourceView.ebook.\(source.id)",
                    defaultSort: "titleAZ",
                    preferredTileWidth: 110,
                    minimumTileWidth: 90,
                    columnBreakpoints: [
                        MediaGridView.ColumnBreakpoint(columns: 3, minWidth: 0)
                    ],
                    initialNarrationFilterOption: .both,
                    showAddBookButton: true,
                    addBookSourceID: source.id,
                    sourceFilterID: source.id,
                    sourceFilterName: source.name,
                )
                .navigationTitle(source.name)
                .iOSLibraryToolbar(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet,
                )
            }
            .navigationDestination(for: NarratorNavIdentifier.self) { narrator in
                MediaGridView(
                    title: narrator.name,
                    searchText: "",
                    mediaKind: .ebook,
                    viewOptionsKey: "narratorView.ebook",
                    tagFilter: nil,
                    seriesFilter: nil,
                    authorFilter: nil,
                    narratorFilter: narrator.name,
                    statusFilter: nil,
                    defaultSort: "titleAZ",
                    preferredTileWidth: 110,
                    minimumTileWidth: 90,
                    columnBreakpoints: [
                        MediaGridView.ColumnBreakpoint(columns: 3, minWidth: 0)
                    ],
                    initialNarrationFilterOption: .both,
                )
                .navigationTitle(narrator.name)
                .iOSLibraryToolbar(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet,
                )
            }
            .navigationDestination(for: TagNavIdentifier.self) { tag in
                MediaGridView(
                    title: tag.name.capitalized,
                    searchText: "",
                    mediaKind: .ebook,
                    viewOptionsKey: "tagView.ebook",
                    tagFilter: tag.name,
                    seriesFilter: nil,
                    authorFilter: nil,
                    statusFilter: nil,
                    defaultSort: "titleAZ",
                    preferredTileWidth: 110,
                    minimumTileWidth: 90,
                    columnBreakpoints: [
                        MediaGridView.ColumnBreakpoint(columns: 3, minWidth: 0)
                    ],
                    initialNarrationFilterOption: .both,
                )
                .navigationTitle(tag.name.capitalized)
                .iOSLibraryToolbar(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet,
                )
            }
            .navigationDestination(for: TranslatorNavIdentifier.self) { translator in
                MediaGridView(
                    title: translator.name,
                    searchText: "",
                    mediaKind: .ebook,
                    viewOptionsKey: "translatorView.ebook",
                    translatorFilter: translator.name,
                    statusFilter: nil,
                    defaultSort: "titleAZ",
                    preferredTileWidth: 110,
                    minimumTileWidth: 90,
                    columnBreakpoints: [
                        MediaGridView.ColumnBreakpoint(columns: 3, minWidth: 0)
                    ],
                    initialNarrationFilterOption: .both,
                )
                .navigationTitle(translator.name)
                .iOSLibraryToolbar(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet,
                )
            }
            .navigationDestination(for: PublicationYearNavIdentifier.self) { year in
                MediaGridView(
                    title: year.name,
                    searchText: "",
                    mediaKind: .ebook,
                    viewOptionsKey: "publicationYearView.ebook",
                    publicationYearFilter: year.name,
                    statusFilter: nil,
                    defaultSort: "titleAZ",
                    preferredTileWidth: 110,
                    minimumTileWidth: 90,
                    columnBreakpoints: [
                        MediaGridView.ColumnBreakpoint(columns: 3, minWidth: 0)
                    ],
                    initialNarrationFilterOption: .both,
                )
                .navigationTitle(year.name)
                .iOSLibraryToolbar(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet,
                )
            }
            .navigationDestination(for: RatingNavIdentifier.self) { rating in
                MediaGridView(
                    title: rating.name,
                    searchText: "",
                    mediaKind: .ebook,
                    viewOptionsKey: "ratingView.ebook",
                    ratingFilter: rating.name,
                    statusFilter: nil,
                    defaultSort: "titleAZ",
                    preferredTileWidth: 110,
                    minimumTileWidth: 90,
                    columnBreakpoints: [
                        MediaGridView.ColumnBreakpoint(columns: 3, minWidth: 0)
                    ],
                    initialNarrationFilterOption: .both,
                )
                .navigationTitle(rating.name)
                .iOSLibraryToolbar(
                    showSettings: $showSettings,
                    showOfflineSheet: $showOfflineSheet,
                )
            }
    }
}

extension View {
    func libraryNavigationDestinations(
        showSettings: Binding<Bool>,
        showOfflineSheet: Binding<Bool>,
    )
        -> some View
    {
        modifier(
            LibraryNavigationDestinations(
                showSettings: showSettings,
                showOfflineSheet: showOfflineSheet,
            )
        )
    }
}

#endif
