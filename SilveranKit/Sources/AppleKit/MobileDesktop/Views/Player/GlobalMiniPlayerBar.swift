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
    @ObservationIgnored private var foregroundObserver: NSObjectProtocol?

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
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main,
        ) { _ in
            Task { @MainActor in
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
        let subtitle = MiniPlayerPolicy.subtitle(
            author: snapshot.author,
            chapterLabel: snapshot.chapterLabel,
            bookProgress: snapshot.bookProgress,
            remainingSeconds: snapshot.chapterRemainingSeconds ?? snapshot.remainingSeconds,
            playbackRate: snapshot.playbackRate,
        )

        return InkAmpMiniPlayerChrome(
            title: snapshot.title ?? "Now Playing",
            subtitle: subtitle,
            isPlaying: snapshot.isPlaying,
            progress: snapshot.bookProgress,
            cover: { coverThumb(for: snapshot) },
            onExpand: {
                ReaderHaptics.jumpNavigation()
                presenter.expandMiniPlayer()
            },
            onSkipBackward: {
                ReaderHaptics.selectionTick()
                Task { await AudioSessionActor.shared.skipPlayback(by: -15) }
            },
            onTogglePlayPause: {
                ReaderHaptics.bookmarkToggled(added: !snapshot.isPlaying)
                Task { try? await AudioSessionActor.shared.transport(.togglePlayPause) }
            },
            onStop: {
                ReaderHaptics.selectionTick()
                presenter.stopSession()
            },
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: snapshot.isPlaying)
    }

    @ViewBuilder
    private func coverThumb(for snapshot: AudioSessionSnapshot) -> some View {
        let thumbScale: CGFloat = snapshot.isPlaying ? 1.0 : 0.92
        Group {
            if let cover = monitor.coverImage {
                Image(uiImage: cover)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(theme.surface)
                    .frame(width: 42, height: 42)
                    .overlay(
                        Image(systemName: placeholderIcon(for: snapshot.kind))
                            .font(.body)
                            .foregroundStyle(theme.secondaryText)
                    )
            }
        }
        .scaleEffect(thumbScale)
        .shadow(
            color: .black.opacity(snapshot.isPlaying ? 0.18 : 0.06),
            radius: snapshot.isPlaying ? 5 : 2,
            y: snapshot.isPlaying ? 2 : 1,
        )
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: snapshot.isPlaying)
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
    @Environment(\.coverTint) private var coverTint
    private var theme: InkAmpAppTheme { .resolve(for: colorScheme) }
    private var controlColor: Color { coverTint?.control ?? theme.accent }

    let title: String
    var subtitle: String? = nil
    let isPlaying: Bool
    var progress: Double? = nil
    let cover: () -> Cover
    let onExpand: () -> Void
    var onSkipBackward: (() -> Void)? = nil
    let onTogglePlayPause: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            cover()
                .contentShape(Rectangle())
                .onTapGesture(perform: onExpand)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: onExpand)

            if let onSkipBackward {
                Button(action: onSkipBackward) {
                    Image(systemName: "gobackward.15")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(theme.primaryText)
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rewind 15 seconds")
            }

            Button(action: onTogglePlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .foregroundStyle(controlColor)
                    .frame(width: 42, height: 42)
                    .contentShape(Circle())
                    .background(Circle().fill(controlColor.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

            Button(action: onStop) {
                Image(systemName: "xmark")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop playback")
        }
        .padding(.horizontal, 12)
        .frame(height: 60)
        .background {
            if let coverTint {
                coverTint.gradient(startPoint: .leading, endPoint: .trailing)
                    .opacity(CoverTintMath.miniPlayerWashOpacity)
            }
        }
        .overlay(alignment: .bottom) {
            if let progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(controlColor.opacity(0.16))
                        Rectangle()
                            .fill(controlColor)
                            .frame(width: geo.size.width * min(max(progress, 0), 1))
                            .animation(.easeOut(duration: 0.25), value: progress)
                    }
                }
                .frame(height: 2.5)
                .accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: InkAmpMetrics.cardRadius, style: .continuous))
        .inkAmpSurface(elevated: true, radius: InkAmpMetrics.cardRadius)
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .gesture(
            DragGesture(minimumDistance: 18, coordinateSpace: .local)
                .onEnded { value in
                    if value.translation.height < -20 && abs(value.translation.width) < 60 {
                        onExpand()
                    }
                }
        )
    }
}

#if DEBUG
#Preview("Mini player · light") {
    InkAmpMiniPlayerChrome(
        title: "Piranesi — Susanna Clarke",
        subtitle: "Part 1: Piranesi · 18m left",
        isPlaying: true,
        progress: 0.42,
        cover: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.gray.opacity(0.35))
                .frame(width: 42, height: 42)
        },
        onExpand: {},
        onSkipBackward: {},
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
        subtitle: "Susanna Clarke · 42%",
        isPlaying: false,
        progress: 0.42,
        cover: {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.gray.opacity(0.45))
                .frame(width: 42, height: 42)
        },
        onExpand: {},
        onSkipBackward: {},
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
