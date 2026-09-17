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
    @Environment(\.dismiss) private var dismiss
    @State private var store = PodcastPlaybackQueueStore.shared
    @State private var monitor = AudioSessionMonitor.shared
    @State private var editMode: EditMode = .active

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                if let snapshot = monitor.snapshot, case .podcast = snapshot.kind {
                    Section("Now playing") {
                        HStack(spacing: 12) {
                            queueArtwork(
                                url: PodcastPlayerPresenter.shared.artworkURL,
                                isVideo: false
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snapshot.title ?? "Podcast")
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(2)
                                if let author = snapshot.author {
                                    Text(author)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section {
                    if store.upcoming.isEmpty {
                        Text("Nothing queued — use Play Next or Play Last on an episode.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.upcoming) { item in
                            HStack(spacing: 12) {
                                queueArtwork(url: item.coverURL, isVideo: item.isVideo)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(2)
                                    if let show = item.showTitle {
                                        Text(show)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let label = PlaybackFinishabilityCopy.label(
                                        progress: progress(for: item.episodeID),
                                        durationSeconds: item.durationSeconds
                                    ) {
                                        Text(label)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                        .onDelete { store.remove(at: $0) }
                        .onMove { store.move(fromOffsets: $0, toOffset: $1) }
                    }
                } header: {
                    Text("Up next")
                } footer: {
                    Text("Drag to reorder. Removing a row does not stop the current episode.")
                        .font(.footnote)
                }
            }
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
            .onAppear { monitor.start() }
        }
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
                        Color(white: 0.12)
                        Image(systemName: isVideo ? "play.rectangle.fill" : "mic.fill")
                            .foregroundStyle(Color.white.opacity(0.72))
                    }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
#endif
