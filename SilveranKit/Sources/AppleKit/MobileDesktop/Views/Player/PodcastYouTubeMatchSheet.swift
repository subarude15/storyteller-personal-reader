//
//  PodcastYouTubeMatchSheet.swift
//  SilveranAppleKit
//
//  Match on YouTube confirm sheet: search via Settings resolve URL, show top
//  hits, user picks one. Never auto-picks.
//
//  SPDX-License-Identifier: AGPL-3.0-only

#if os(iOS)
import SilveranKit
import SwiftUI

/// Confirm sheet for Match on YouTube — searches then lists top video hits.
public struct PodcastYouTubeMatchSheet: View {
    public let showTitle: String?
    public let episodeTitle: String
    public let onPick: (PodcastYouTubeSearchResult) -> Void
    public let onCancel: () -> Void

    @State private var phase: Phase = .searching
    @State private var results: [PodcastYouTubeSearchResult] = []

    private enum Phase: Equatable {
        case searching
        case results
        case empty
        case failed
    }

    public init(
        showTitle: String?,
        episodeTitle: String,
        onPick: @escaping (PodcastYouTubeSearchResult) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.showTitle = showTitle
        self.episodeTitle = episodeTitle
        self.onPick = onPick
        self.onCancel = onCancel
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch phase {
                    case .searching:
                        VStack(spacing: 16) {
                            ProgressView()
                            Text("Searching YouTube…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .empty:
                        ContentUnavailableView(
                            "No matches",
                            systemImage: "magnifyingglass",
                            description: Text("Nothing matched this episode title.")
                        )
                    case .failed:
                        ContentUnavailableView(
                            "Couldn't search",
                            systemImage: "exclamationmark.triangle",
                            description: Text("Check YouTube resolve URL on Wi‑Fi and try again.")
                        )
                    case .results:
                        List(results) { hit in
                            Button {
                                onPick(hit)
                            } label: {
                                resultRow(hit)
                            }
                            .buttonStyle(.plain)
                        }
                        .listStyle(.plain)
                }
            }
            .navigationTitle("Match on YouTube")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
            .task {
                await runSearch()
            }
        }
    }

    @ViewBuilder
    private func resultRow(_ hit: PodcastYouTubeSearchResult) -> some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail(hit.thumbnailURL)
            VStack(alignment: .leading, spacing: 4) {
                Text(hit.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                if let author = hit.author, !author.isEmpty {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let duration = hit.durationLabel {
                    Text(duration)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Selects this video for the episode")
    }

    @ViewBuilder
    private func thumbnail(_ url: URL?) -> some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            thumbPlaceholder
                    }
                }
            } else {
                thumbPlaceholder
            }
        }
        .frame(width: 96, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var thumbPlaceholder: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            Image(systemName: "play.rectangle.fill")
                .foregroundStyle(.secondary)
        }
    }

    private func runSearch() async {
        phase = .searching
        let query = Self.searchQuery(showTitle: showTitle, episodeTitle: episodeTitle)
        do {
            let hits = try await PodcastYouTubeResolver.shared.search(query: query, limit: 5)
            if hits.isEmpty {
                phase = .empty
                NotificationCenter.default.post(name: .punkRallyYouTubeNoMatches, object: nil)
            } else {
                results = hits
                phase = .results
            }
        } catch {
            phase = .failed
            NotificationCenter.default.post(name: .punkRallyYouTubeSearchFailed, object: nil)
        }
    }

    /// `{showTitle} {episodeTitle}` — show omitted when empty / duplicate.
    public static func searchQuery(showTitle: String?, episodeTitle: String) -> String {
        let ep = episodeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let show = (showTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if show.isEmpty { return ep }
        if ep.localizedCaseInsensitiveContains(show) { return ep }
        return "\(show) \(ep)"
    }
}
#endif
