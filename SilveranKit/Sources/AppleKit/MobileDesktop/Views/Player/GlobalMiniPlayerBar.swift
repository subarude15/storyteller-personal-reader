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
        } catch {
            // Keep placeholder.
        }
    }
}

struct GlobalMiniPlayerBar: View {
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
        HStack(spacing: 10) {
            coverThumb(for: snapshot)
                .contentShape(Rectangle())
                .onTapGesture { presenter.expandMiniPlayer() }

            Text(snapshot.title ?? "Now Playing")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { presenter.expandMiniPlayer() }

            Button {
                Task { try? await AudioSessionActor.shared.transport(.togglePlayPause) }
            } label: {
                Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(snapshot.isPlaying ? "Pause" : "Play")

            Button {
                presenter.stopSession()
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop playback")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .modifier(MiniPlayerGlassModifier())
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
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
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: placeholderIcon(for: snapshot.kind))
                        .font(.body)
                        .foregroundStyle(.secondary)
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

private struct MiniPlayerGlassModifier: ViewModifier {
    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content
                .background(shape.fill(.regularMaterial))
                .clipShape(shape)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
    }
}
#endif
