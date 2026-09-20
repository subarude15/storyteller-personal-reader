#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI

/// Compact Request Activity entry for Library / Home.
struct RequestActivityLibraryEntry: View {
    var history: RequestActivityStore = .shared
    var now: () -> Date = { Date() }

    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel
    @State private var summary = RequestActivityLibrarySummary()
    @State private var tick = 0
    @State private var lastAppliedLibraryVersion: Int?
    @State private var openFromNotification = false

    var body: some View {
        Group {
            if let subtitle = summary.subtitle {
                NavigationLink {
                    RequestActivityView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: summary.systemImage)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(iconColor)
                            .frame(width: 28, height: 28)
                            .background(iconBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Requests")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(summary.showsAttentionStyling ? Color.orange : Color.secondary)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 8)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary.accessibilityLabel)
                .accessibilityHint("Opens request activity")
                .accessibilityAddTraits(.isButton)
            }
        }
        .background {
            NavigationLink(isActive: $openFromNotification) {
                RequestActivityView()
            } label: {
                EmptyView()
            }
            .hidden()
        }
        .id(tick)
        .onAppear {
            applyLibraryAndReload()
            if RequestActivityNavigationPending.shouldOpen {
                RequestActivityNavigationPending.shouldOpen = false
                openFromNotification = true
            }
        }
        .onChange(of: mediaViewModel.libraryVersion) { _, _ in
            applyLibraryAndReload()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .requestActivityStoreDidChange)
        ) { _ in
            reloadSummary()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .punkRallyShowRequestActivity)
        ) { _ in
            RequestActivityNavigationPending.shouldOpen = false
            openFromNotification = true
        }
    }

    private var iconColor: Color {
        summary.showsAttentionStyling ? .orange : .accentColor
    }

    private var iconBackground: Color {
        summary.showsAttentionStyling
            ? Color.orange.opacity(0.15)
            : Color.accentColor.opacity(0.12)
    }

    private func applyLibraryAndReload() {
        let version = mediaViewModel.libraryVersion
        if lastAppliedLibraryVersion != version {
            lastAppliedLibraryVersion = version
            _ = RequestActivityRefreshService(history: history).applyLibraryPresence(
                libraryBooks: mediaViewModel.library.bookMetaData,
                now: now(),
            )
        }
        reloadSummary()
    }

    private func reloadSummary() {
        summary = history.librarySummary(now: now())
        tick &+= 1
    }
}

/// Subtle request-status line for book detail when a tracked request exists.
/// Read-only: viewing detail does not refresh providers or rewrite request history.
struct BookRequestStatusIndicator: View {
    let book: BookMetadata
    var history: RequestActivityStore = .shared

    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel
    @Environment(\.bookDetailHeroColors) private var heroColors
    @State private var item: RequestActivityItem?
    @State private var tick = 0

    var body: some View {
        Group {
            if let item {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Request status")
                        .font(.caption)
                        .foregroundStyle(heroColors.secondary)
                    Text(item.libraryDetailStatusLine)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(
                            item.overallStatus.needsAttentionBucket
                                ? Color.orange
                                : heroColors.primary
                        )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Request status. \(item.libraryDetailStatusLine)")
            }
        }
        .id(tick)
        .onAppear(perform: reload)
        .onChange(of: book.id) { _, _ in reload() }
        .onChange(of: mediaViewModel.libraryVersion) { _, _ in reload() }
        .onReceive(
            NotificationCenter.default.publisher(for: .requestActivityStoreDidChange)
        ) { _ in
            reload()
        }
    }

    private func reload() {
        let index = RequestLibraryPresentationIndex(
            items: history.allItems(),
            books: mediaViewModel.library.bookMetaData,
        )
        item = index.match(book: book)
        tick &+= 1
    }
}
#endif
