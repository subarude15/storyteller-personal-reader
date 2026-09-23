#if os(iOS)
import SilveranKit
import SwiftUI
import UIKit

/// One app-wide subscription to the audio session snapshot, shared by the
/// per-tab mini player bars and podcast Now Playing.
@MainActor
@Observable
final class AudioSessionMonitor {
    static let shared = AudioSessionMonitor()

    private(set) var snapshot: AudioSessionSnapshot?
    private(set) var coverImage: UIImage?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var coverBookID: BookID?
    @ObservationIgnored private var podcastCoverURL: URL?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        Task {
            await AudioSessionActor.shared.addSnapshotObserver { snapshot in
                Task { @MainActor in
                    AudioSessionMonitor.shared.apply(snapshot)
                }
            }
        }
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard AudioSessionMonitor.shared.snapshot?.isPlaying == true else { continue }
                let fresh = await AudioSessionActor.shared.currentSnapshot()
                AudioSessionMonitor.shared.apply(fresh)
            }
        }
    }

    private func apply(_ snapshot: AudioSessionSnapshot?) {
        let hadSession = self.snapshot != nil
        self.snapshot = snapshot
        if hadSession, snapshot == nil {
            PunkRallyStatsEvents.sessionEnd()
            coverBookID = nil
            podcastCoverURL = nil
            coverImage = nil
            return
        }
        guard let snapshot else {
            coverBookID = nil
            podcastCoverURL = nil
            coverImage = nil
            return
        }

        if case .podcast = snapshot.kind {
            coverBookID = nil
            let url = PodcastPlayerPresenter.shared.artworkURL
            if url != podcastCoverURL {
                podcastCoverURL = url
                coverImage = nil
                if let url {
                    Task { @MainActor in
                        await self.loadRemoteCover(url)
                    }
                }
            } else if coverImage == nil, let url {
                Task { @MainActor in
                    await self.loadRemoteCover(url)
                }
            }
            return
        }

        podcastCoverURL = nil
        let bookID = snapshot.kind.bookID
        guard bookID != coverBookID else { return }
        coverBookID = bookID
        coverImage = nil
        Task { @MainActor in
            var data = await BookServiceActor.shared.cachedCoverData(for: bookID, audio: true)
            if data == nil {
                data = await BookServiceActor.shared.cachedCoverData(for: bookID, audio: false)
            }
            guard self.coverBookID == bookID else { return }
            self.coverImage = data.flatMap(UIImage.init(data:))
        }
    }

    private func loadRemoteCover(_ url: URL) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard podcastCoverURL == url else { return }
            coverImage = UIImage(data: data)
            // Keep system Now Playing art in sync with the mini-player cover.
            await AudioSessionActor.shared.setSessionArtwork(data)
        } catch {
            // Keep placeholder.
        }
    }
}

struct GlobalMiniPlayerBar: View {
    @Environment(\.colorScheme) private var colorScheme
    private var theme: InkAmpAppTheme { .resolve(for: colorScheme) }

    private var monitor = AudioSessionMonitor.shared
    private var presenter = PlayerPresenter.shared
    private var podcastPresenter = PodcastPlayerPresenter.shared

    var body: some View {
        content
            .onAppear { monitor.start() }
    }

    @ViewBuilder
    private var content: some View {
        // Hide while a full-screen card is up so the inset collapses; show only
        // for headless / mini-player playback above the tab bar.
        if let snapshot = monitor.snapshot,
            presenter.card == nil,
            podcastPresenter.episode == nil
        {
            barContent(snapshot)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func barContent(_ snapshot: AudioSessionSnapshot) -> some View {
        InkAmpMiniPlayerChrome(
            title: snapshot.title ?? "Now Playing",
            isPlaying: snapshot.isPlaying,
            cover: { coverThumb(for: snapshot) },
            onExpand: { presenter.expandMiniPlayer() },
            onTogglePlayPause: {
                Task { try? await AudioSessionActor.shared.transport(.togglePlayPause) }
            },
            onStop: { presenter.stopSession() },
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: snapshot.isPlaying)
    }

    @ViewBuilder
    private func coverThumb(for snapshot: AudioSessionSnapshot) -> some View {
        if let cover = monitor.coverImage {
            Image(uiImage: cover)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.surface)
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: placeholderIcon(for: snapshot.kind))
                        .font(.body)
                        .foregroundStyle(theme.secondaryText)
                )
        }
    }

    private func placeholderIcon(for kind: AudioSessionKind) -> String {
        switch kind {
            case .podcast: return "mic.fill"
            case .audiobook, .readaloud: return "book.fill"
        }
    }

    static func formatClock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

/// Shared visual chrome for the live mini-player and SwiftUI previews.
struct InkAmpMiniPlayerChrome<Cover: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private var theme: InkAmpAppTheme { .resolve(for: colorScheme) }

    let title: String
    let isPlaying: Bool
    let cover: () -> Cover
    let onExpand: () -> Void
    let onTogglePlayPause: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            cover()
                .contentShape(Rectangle())
                .onTapGesture(perform: onExpand)

            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: onExpand)

            Button(action: onTogglePlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(theme.accent)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .background(Circle().fill(theme.accent.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            Button(action: onStop) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop playback")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .inkAmpSurface(elevated: true, radius: InkAmpMetrics.cardRadius)
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }
}

#if DEBUG
#Preview("Mini player · light") {
    InkAmpMiniPlayerChrome(
        title: "Piranesi — Susanna Clarke",
        isPlaying: true,
        cover: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.gray.opacity(0.35))
                .frame(width: 40, height: 40)
        },
        onExpand: {},
        onTogglePlayPause: {},
        onStop: {},
    )
    .padding()
    .inkAmpAppThemed()
    .preferredColorScheme(.light)
}

#Preview("Mini player · dark") {
    InkAmpMiniPlayerChrome(
        title: "Piranesi — Susanna Clarke",
        isPlaying: false,
        cover: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.gray.opacity(0.45))
                .frame(width: 40, height: 40)
        },
        onExpand: {},
        onTogglePlayPause: {},
        onStop: {},
    )
    .padding()
    .background(InkAmpAppTheme(colorScheme: .dark).background)
    .inkAmpAppThemed()
    .preferredColorScheme(.dark)
}
#endif
#endif
