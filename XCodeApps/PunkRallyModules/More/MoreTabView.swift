//
//  MoreTabView.swift
//  ink+amp
//
//  Fifth primary tab: hub for Downloads, Settings, Stats, and related destinations.
//

#if os(iOS)
import SwiftUI
import SilveranAppleKit
import SilveranKit

/// Intentional More hub — not iOS's automatic overflow More tab.
struct MoreTabView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var path: NavigationPath
    @Binding var showSettings: Bool

    @State private var downloadsAttention = 0

    private var chrome: PunkRallyTheme.Chrome {
        PunkRallyTheme.Chrome(scheme: colorScheme)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(InkAmpMoreDestination.primary, id: \.self) { destination in
                        primaryRow(destination)
                    }
                }

                Section("Other") {
                    ForEach(InkAmpMoreDestination.secondary, id: \.self) { destination in
                        secondaryRow(destination)
                    }
                }
            }
            .navigationTitle(InkAmpPrimaryTab.more.title)
            .navigationDestination(for: InkAmpMoreDestination.self) { destination in
                moreDestinationView(destination)
            }
        }
        .task { await reloadAttention() }
        .onReceive(NotificationCenter.default.publisher(for: .inkampManualDownloadJobsDidChange)) { _ in
            Task { await reloadAttention() }
        }
    }

    @ViewBuilder
    private func primaryRow(_ destination: InkAmpMoreDestination) -> some View {
        switch destination {
            case .downloads:
                NavigationLink(value: destination) {
                    moreLabel(
                        title: destination.title,
                        subtitle: destination.subtitle,
                        systemImage: destination.systemImage,
                        badge: downloadsAttention,
                    )
                }
            case .settings:
                Button {
                    showSettings = true
                } label: {
                    moreLabel(
                        title: destination.title,
                        subtitle: destination.subtitle,
                        systemImage: destination.systemImage,
                        badge: 0,
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            case .stats, .requestsActivity, .services:
                EmptyView()
        }
    }

    @ViewBuilder
    private func secondaryRow(_ destination: InkAmpMoreDestination) -> some View {
        NavigationLink(value: destination) {
            Label(destination.title, systemImage: destination.systemImage)
        }
    }

    private func moreLabel(
        title: String,
        subtitle: String?,
        systemImage: String,
        badge: Int,
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(PunkRallyTheme.Accent.primary)
                .frame(width: 28, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(chrome.text)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if badge > 0 {
                Text(badge > 9 ? "9+" : "\(badge)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.red))
                    .accessibilityLabel("\(badge) downloads need attention")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func moreDestinationView(_ destination: InkAmpMoreDestination) -> some View {
        switch destination {
            case .downloads:
                DownloadsView()
            case .settings:
                SettingsView()
            case .stats:
                StatsView()
            case .requestsActivity:
                RequestActivityView()
            case .services:
                ServicesHealthView()
        }
    }

    private func reloadAttention() async {
        let jobs = await ManualDownloadJobStore.shared.allJobs()
        downloadsAttention = ManualDownloadBuckets.partition(jobs).attentionCount
    }
}
#endif
