//
//  PodcastPlaybackQueueView.swift
//  SilveranAppleKit
//
//  Editable upcoming queue for the shared podcast player.
//
//  SPDX-License-Identifier: AGPL-3.0-only

#if os(iOS)
import SwiftUI
import SilveranKit

public struct PodcastPlaybackQueueView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var store = PodcastPlaybackQueueStore.shared
    @State private var monitor = AudioSessionMonitor.shared
    @State private var editMode: EditMode = .active

    private var theme: InkAmpAppTheme { .resolve(for: colorScheme) }

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                if let snapshot = monitor.snapshot, case .podcast = snapshot.kind {
                    Section {
                        queueRow(
                            title: snapshot.title ?? "Podcast",
                            subtitle: snapshot.author,
                            finishLabel: nil,
                            artworkURL: PodcastPlayerPresenter.shared.artworkURL,
                            isVideo: false,
                        )
                    } header: {
                        Text("Now playing")
                            .foregroundStyle(theme.secondaryText)
                    }
                    .listRowBackground(theme.surfaceElevated)
                }

                Section {
                    if store.upcoming.isEmpty {
                        Text("Nothing queued — use Play Next or Play Last on an episode.")
                            .font(.subheadline)
                            .foregroundStyle(theme.secondaryText)
                            .listRowBackground(theme.surfaceElevated)
                    } else {
                        ForEach(store.upcoming) { item in
                            queueRow(
                                title: item.title,
                                subtitle: item.showTitle,
                                finishLabel: PlaybackFinishabilityCopy.label(
                                    progress: progress(for: item.episodeID),
                                    durationSeconds: item.durationSeconds,
                                ),
                                artworkURL: item.coverURL,
                                isVideo: item.isVideo,
                            )
                            .listRowBackground(theme.surfaceElevated)
                        }
                        .onDelete { store.remove(at: $0) }
                        .onMove { store.move(fromOffsets: $0, toOffset: $1) }
                    }
                } header: {
                    Text("Up next")
                        .foregroundStyle(theme.secondaryText)
                } footer: {
                    Text("Drag to reorder. Removing a row does not stop the current episode.")
                        .font(.footnote)
                        .foregroundStyle(theme.tertiaryText)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.background)
            .environment(\.editMode, $editMode)
            .navigationTitle("Play queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Clear finished") {
                            store.clearFinished()
                        }
                        Button("Clear all", role: .destructive) {
                            store.clearAll()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .tint(theme.accent)
            .inkAmpAppThemed()
            .onAppear { monitor.start() }
        }
    }

    private func queueRow(
        title: String,
        subtitle: String?,
        finishLabel: String?,
        artworkURL: URL?,
        isVideo: Bool,
    ) -> some View {
        HStack(spacing: 12) {
            queueArtwork(url: artworkURL, isVideo: isVideo)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
                if let finishLabel {
                    Text(finishLabel)
                        .font(.caption2)
                        .foregroundStyle(theme.tertiaryText)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func progress(for episodeID: String) -> Double {
        if let record = PodcastDownloadStore.shared.record(for: episodeID) {
            return record.progress
        }
        return PodcastPlayheadStore.shared.entry(for: episodeID)?.progress ?? 0
    }

    private func queueArtwork(url: URL?, isVideo: Bool) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    ZStack {
                        theme.surface
                        Image(systemName: isVideo ? "play.rectangle.fill" : "mic.fill")
                            .foregroundStyle(theme.secondaryText)
                    }
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(
            RoundedRectangle(cornerRadius: InkAmpMetrics.controlRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: InkAmpMetrics.controlRadius, style: .continuous)
                .strokeBorder(theme.border.opacity(0.7), lineWidth: 1)
        )
    }
}
#endif
