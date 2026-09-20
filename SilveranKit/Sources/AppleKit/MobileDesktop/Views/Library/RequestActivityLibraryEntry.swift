#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI

/// Compact Request Activity entry for Library / Home.
struct RequestActivityLibraryEntry: View {
    var history: RequestActivityStore = .shared
    var now: () -> Date = { Date() }

    @State private var summary = RequestActivityLibrarySummary()
    @State private var tick = 0

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
        .id(tick)
        .onAppear(perform: reload)
        .onReceive(
            NotificationCenter.default.publisher(for: .requestActivityStoreDidChange)
        ) { _ in
            reload()
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

    private func reload() {
        summary = history.librarySummary(now: now())
        tick &+= 1
    }
}

/// Subtle request-status line for book detail when a tracked request exists.
struct BookRequestStatusIndicator: View {
    let workID: String
    var history: RequestActivityStore = .shared

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
        .onChange(of: workID) { _, _ in reload() }
        .onReceive(
            NotificationCenter.default.publisher(for: .requestActivityStoreDidChange)
        ) { _ in
            reload()
        }
    }

    private func reload() {
        item = history.item(forWorkID: workID)
        tick &+= 1
    }
}
#endif
