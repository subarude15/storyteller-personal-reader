#if os(iOS)
import SwiftUI

/// Full-screen card for a streaming RSS podcast episode.
///
/// Deliberately thin: it renders the same session snapshot the mini player
/// and Now Playing use, and reuses the shared `PlaybackRateButton` so
/// podcasts get the identical speed control as audiobooks/readaloud — no
/// second speed UI.
public struct PodcastPlayerView: View {
    @Environment(\.colorScheme) private var colorScheme
    private let episode: PodcastPlayerPresenter.Episode
    private let onClose: () -> Void

    @State private var monitor = AudioSessionMonitor.shared
    @State private var errorMessage: String?

    public init(episode: PodcastPlayerPresenter.Episode, onClose: @escaping () -> Void) {
        self.episode = episode
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            VStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)

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
                .frame(maxHeight: 160)
            }

            Spacer(minLength: 0)

            transportRow

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .toolbar(.hidden, for: .tabBar)
        .onAppear { monitor.start() }
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
        }
        .navigationBarBackButtonHidden(true)
    }

    private var isPlaying: Bool {
        monitor.snapshot?.isPlaying ?? false
    }

    private var currentRate: Double {
        monitor.snapshot?.playbackRate ?? 1.0
    }

    private var transportRow: some View {
        VStack(spacing: 16) {
            HStack(spacing: 40) {
                Button {
                    Task { await AudioSessionActor.shared.skipPodcast(by: -15) }
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
                    Task { await AudioSessionActor.shared.skipPodcast(by: 15) }
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
