#if os(iOS)
import SwiftUI

/// Full-screen card for a streaming RSS podcast episode.
///
/// Deliberately thin: it renders the same session snapshot the mini player
/// and Now Playing use, and reuses the shared `PlaybackRateButton` so
/// podcasts get the identical speed control as audiobooks/readaloud — no
/// second speed UI. −15 / play / +15 and elapsed|scrub|remaining match the mini.
public struct PodcastPlayerView: View {
    @Environment(\.colorScheme) private var colorScheme
    private let episode: PodcastPlayerPresenter.Episode
    private let onClose: () -> Void

    @State private var monitor = AudioSessionMonitor.shared
    @State private var errorMessage: String?
    @State private var scrubFraction: Double = 0
    @State private var isScrubbing = false
    @State private var showPlaybackQueue = false

    public init(episode: PodcastPlayerPresenter.Episode, onClose: @escaping () -> Void) {
        self.episode = episode
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            artworkBlock

            VStack(spacing: 8) {
                if episode.isVideo {
                    Text("VIDEO")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }

                Text(episode.title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                if let showTitle = episode.showTitle {
                    Text(showTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let summary = episode.summary {
                ScrollView {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }

            scrubber

            Spacer(minLength: 0)

            transportRow

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            monitor.start()
            scrubFraction = monitor.snapshot?.bookProgress ?? 0
        }
        .onChange(of: monitor.snapshot?.bookProgress ?? 0) { _, newValue in
            if !isScrubbing { scrubFraction = newValue }
        }
        .alert("Podcast Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let errorMessage { Text(errorMessage) }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    onClose()
                } label: {
                    Label("Podcasts", systemImage: "chevron.left")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showPlaybackQueue = true
                } label: {
                    Label("Play queue", systemImage: "list.bullet")
                }
            }
        }
        .sheet(isPresented: $showPlaybackQueue) {
            PodcastPlaybackQueueView()
        }
        .navigationBarBackButtonHidden(true)
    }

    private var isPlaying: Bool {
        monitor.snapshot?.isPlaying ?? false
    }

    private var currentRate: Double {
        monitor.snapshot?.playbackRate ?? 1.0
    }

    private var snapshot: AudioSessionSnapshot? {
        monitor.snapshot
    }

    @ViewBuilder
    private var artworkBlock: some View {
        Group {
            if let cover = monitor.coverImage {
                Image(uiImage: cover)
                    .resizable()
                    .scaledToFill()
            } else if let url = episode.coverURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            placeholderArt
                    }
                }
            } else {
                placeholderArt
            }
        }
        .frame(width: 220, height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    private var placeholderArt: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            Image(systemName: episode.isVideo ? "play.rectangle.fill" : "mic.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
        }
    }

    private var scrubber: some View {
        let elapsed = isScrubbing
            ? (snapshot?.durationSeconds ?? 0) * scrubFraction
            : (snapshot?.elapsedSeconds ?? 0)
        let remaining = max(0, (snapshot?.durationSeconds ?? 0) - elapsed)
        let fraction = isScrubbing ? scrubFraction : (snapshot?.bookProgress ?? 0)

        return VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { fraction },
                    set: { scrubFraction = $0 }
                ),
                in: 0...1
            ) { editing in
                isScrubbing = editing
                if !editing {
                    let target = scrubFraction
                    Task { await AudioSessionActor.shared.seekPlayback(toFraction: target) }
                }
            }

            HStack {
                Text(GlobalMiniPlayerBar.formatClock(elapsed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("−\(GlobalMiniPlayerBar.formatClock(remaining))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var transportRow: some View {
        VStack(spacing: 16) {
            HStack(spacing: 40) {
                Button {
                    Task { await AudioSessionActor.shared.skipPlayback(by: -15) }
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back 15 seconds")

                Button {
                    Task { try? await AudioSessionActor.shared.transport(.togglePlayPause) }
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 56))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Pause" : "Play")

                Button {
                    Task { await AudioSessionActor.shared.skipPlayback(by: 15) }
                } label: {
                    Image(systemName: "goforward.15")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Forward 15 seconds")
            }

            // Shared speed control — same component audiobooks use.
            PlaybackRateButton(
                currentRate: currentRate,
                onRateChange: { rate in
                    Task { await AudioSessionActor.shared.setPlaybackRate(rate) }
                },
                backgroundColor: Color.secondary,
                foregroundColor: Color.primary,
                transparency: 1.0,
                showLabel: true,
            )
        }
    }
}
#endif
