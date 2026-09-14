//
//  PunkRallyApp.swift
//  punk+rally
//
//  Five-tab root (Home · Library · Shelf · Podcasts · Stats) per UX-SHELL.md.
//  Wraps Silveran's existing library/player content where available; keeps
//  podcasts and stats as independent local rails.
//
//  Library/Shelf surfaces are hosted by SilveranAppleKit's public punk+rally
//  facade (PunkRallyShellSupport.swift): Shelf is downloads-only; Library is a
//  searchable cover grid (no nested Silveran tab chrome). A shared mini-player
//  bar sits above the tab bar, driven by Silveran's audio session monitor.
//

#if os(iOS)
import SwiftUI
import SilveranAppleKit

/// punk+rally five-tab shell. Library/Shelf reuse Silveran's own views when
/// MediaViewModel is available in the environment (SilveranReaderApp injects it);
/// otherwise show punk+rally placeholders so the shell always builds standalone.
public struct PunkRallyTabView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab: Tab = .home

    public init() {}

    enum Tab: Hashable {
        case home, library, shelf, podcasts, stats
    }

    private var chrome: PunkRallyTheme.Chrome {
        PunkRallyTheme.Chrome(scheme: colorScheme)
    }

    public var body: some View {
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
    }
}

// MARK: - Home

private struct HomeTabView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel?

    private var chrome: PunkRallyTheme.Chrome {
        PunkRallyTheme.Chrome(scheme: colorScheme)
    }

    private var currentBook: BookMetadata? {
        guard let vm = mediaViewModel else { return nil }
        if let pendingID = vm.pendingOpenBookID {
            return vm.library.bookMetaData.first(where: { $0.id == pendingID })
        }
        return vm.library.bookMetaData.first(where: { $0.progress > 0 }) ?? vm.library.bookMetaData.first
    }

    private var syncState: SyncChipView.SyncState {
        guard let vm = mediaViewModel else { return .synced }
        if vm.hasConnectionError {
            let offlineCount = vm.library.bookMetaData.filter { $0.isDownloaded }.count
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
            .navigationTitle("punk+rally")
        }
    }

    private var greetingHeader: some View {
        HStack {
            Text("Good morning")
                .font(.title3.weight(.semibold))
                .foregroundStyle(chrome.text)
            Spacer()
            SyncChipView(state: syncState, scheme: colorScheme)
        }
    }

    private var continueHero: some View {
        Button {
            Task {
                await PunkRallyContinueAction.openLastOrCurrentBook(mediaViewModel: mediaViewModel)
            }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(chrome.surface2)
                        .frame(width: 72, height: 108)
                        .overlay(
                            Image(systemName: "book.closed.fill")
                                .foregroundStyle(chrome.textFaint)
                        )
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Continue")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PunkRallyTheme.Accent.primary)
                        Text(currentBook?.title ?? "No book in progress")
                            .font(.headline)
                            .foregroundStyle(chrome.text)
                            .lineLimit(2)
                        Text(currentBook?.authors.first ?? "Browse your library to pick up where you left off.")
                            .font(.subheadline)
                            .foregroundStyle(chrome.textMuted)
                            .lineLimit(1)
                    }
                    Spacer()
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
    }

    private var upNextRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Up next")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(chrome.text)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(0..<3, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(chrome.surface2)
                                .frame(width: 96, height: 144)
                                .overlay(
                                    Image(systemName: "books.vertical")
                                        .foregroundStyle(chrome.textFaint)
                                )
                            RoundedRectangle(cornerRadius: 3)
                                .fill(chrome.surface2)
                                .frame(width: 90, height: 10)
                        }
                    }
                }
            }
        }
    }

    private var statsStrip: some View {
        HStack(spacing: 12) {
            statCell("0m", "Today")
            statCell("0m", "This week")
            statCell("0", "Streak")
        }
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
}

// MARK: - Library

/// Library = searchable punk+rally catalogue (Silveran's full grid, no inner tab bar).
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