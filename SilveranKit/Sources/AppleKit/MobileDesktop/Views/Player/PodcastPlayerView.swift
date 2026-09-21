#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

/// Full-screen card for a streaming RSS podcast episode.
///
/// Deliberately thin: it renders the same session snapshot the mini player
/// and Now Playing use, and reuses the shared `PlaybackRateButton` so
/// podcasts get the identical speed control as audiobooks/readaloud — no
/// second speed UI. −15 / play / +15 and elapsed|scrub|remaining match the mini.
/// Video enclosures and in-app YouTube use a shared AVPlayer surface;
/// Watch on YouTube remains the external fallback.
public struct PodcastPlayerView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    private let episode: PodcastPlayerPresenter.Episode
    private let onClose: () -> Void

    @State private var monitor = AudioSessionMonitor.shared
    @State private var presenter = PodcastPlayerPresenter.shared
    @State private var errorMessage: String?
    @State private var scrubFraction: Double = 0
    @State private var isScrubbing = false
    @State private var showPlaybackQueue = false
    @State private var videoPlayer: AVPlayer?
    @State private var isResolvingYouTube = false
    @State private var showYouTubeMatch = false
    @State private var matchEpoch = 0
    @State private var videoPresentation = PodcastVideoPresentationCoordinator.shared

    public init(episode: PodcastPlayerPresenter.Episode, onClose: @escaping () -> Void) {
        self.episode = episode
        self.onClose = onClose
    }

    /// Prefer the live presenter episode so Play in ink+amp can flip audio → video surface.
    private var live: PodcastPlayerPresenter.Episode {
        if let current = presenter.episode, current.id == episode.id {
            return current
        }
        return episode
    }

    /// Confirmed watch URL: live presenter, else Match store / feed id.
    private var effectiveYouTubeURL: URL? {
        _ = matchEpoch
        if let url = live.youtubeURL, PodcastYouTubeURL.videoID(from: url) != nil {
            return url
        }
        return PodcastMatchedYouTubeStore.shared.watchURL(for: live.id)
    }

    private var showsMatchOnYouTube: Bool {
        !live.isVideo && effectiveYouTubeURL == nil
    }

    public var body: some View {
        ZStack {
            if videoPresentation.isFullscreen, live.isVideo {
                // Same AVPlayer as portrait — presentation-only swap of chrome.
                PodcastVideoFullscreenView(
                    title: live.title,
                    player: videoPlayer,
                    isPlaying: isPlaying,
                    isOpening: isOpening,
                    currentRate: currentRate,
                    snapshot: snapshot,
                    onExit: { videoPresentation.exitFullscreenManually() },
                    onUserInteraction: {},
                    scrubFraction: $scrubFraction,
                    isScrubbing: $isScrubbing
                )
                .transition(.opacity)
            } else {
                portraitPlayerContent
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: videoPresentation.isFullscreen)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { syncInterfaceOrientation(size: geo.size) }
                    .onChange(of: geo.size) { _, newSize in
                        syncInterfaceOrientation(size: newSize)
                    }
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .toolbar(videoPresentation.isFullscreen ? .hidden : .automatic, for: .navigationBar)
        .task(id: "\(live.id)-\(live.isVideo)-\(live.audioURL.absoluteString)") {
            await refreshVideoPlayer()
            syncVideoPresentationContext()
        }
        .onChange(of: presenter.isOpening) { _, opening in
            if !opening {
                Task { await refreshVideoPlayer() }
            }
        }
        .onChange(of: live.isVideo) { _, _ in
            syncVideoPresentationContext()
        }
        .onAppear {
            monitor.start()
            scrubFraction = monitor.snapshot?.bookProgress ?? 0
            syncVideoPresentationContext()
            syncInterfaceOrientation(size: nil)
        }
        .onDisappear {
            videoPresentation.updatePlayerVisibility(expanded: false, isInternalVideo: false)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)
        ) { _ in
            syncInterfaceOrientation(size: nil)
        }
        .onChange(of: monitor.snapshot?.bookProgress ?? 0) { _, newValue in
            if !isScrubbing { scrubFraction = newValue }
        }
        .onChange(of: presenter.startError) { _, message in
            if let message {
                errorMessage = message
                // Don't trap the user in immersive chrome when start fails.
                if videoPresentation.isFullscreen {
                    videoPresentation.exitFullscreenManually()
                }
            }
        }
        .alert("Podcast Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 {
                errorMessage = nil
                presenter.clearStartError()
            } }
        )) {
            Button("OK") {
                errorMessage = nil
                presenter.clearStartError()
            }
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
        .sheet(isPresented: $showYouTubeMatch) {
            PodcastYouTubeMatchSheet(
                showTitle: live.showTitle,
                episodeTitle: live.title,
                onPick: { hit in
                    showYouTubeMatch = false
                    PodcastMatchedYouTubeStore.shared.save(watchURL: hit.watchURL, for: live.id)
                    matchEpoch += 1
                    Task { await playYouTubeInApp(watchURL: hit.watchURL) }
                },
                onCancel: { showYouTubeMatch = false }
            )
            .presentationDetents([.medium, .large])
        }
        .navigationBarBackButtonHidden(true)
        .statusBarHidden(videoPresentation.isFullscreen)
    }

    /// Existing portrait Now Playing layout (unchanged chrome).
    private var portraitPlayerContent: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            artworkBlock

            VStack(spacing: 8) {
                if live.isVideo {
                    Text("VIDEO")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }

                Text(live.title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                if let showTitle = live.showTitle {
                    Text(showTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if let youtubeURL = effectiveYouTubeURL {
                    VStack(spacing: 8) {
                        if !live.isVideo {
                            Button {
                                Task { await playYouTubeInApp(watchURL: youtubeURL) }
                            } label: {
                                if isResolvingYouTube {
                                    Label("Resolving…", systemImage: "hourglass")
                                        .font(.subheadline.weight(.semibold))
                                } else {
                                    Label("Play in ink+amp", systemImage: "play.rectangle.fill")
                                        .font(.subheadline.weight(.semibold))
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isResolvingYouTube)
                            .accessibilityHint("Resolves a stream and plays in the app")
                        }
                        Button {
                            openURL(youtubeURL)
                        } label: {
                            Label("Watch on YouTube", systemImage: "play.rectangle.on.rectangle")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .accessibilityHint("Opens YouTube in Safari or the YouTube app")
                    }
                } else if showsMatchOnYouTube {
                    Button {
                        showYouTubeMatch = true
                    } label: {
                        Label("Match on YouTube", systemImage: "magnifyingglass")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Search YouTube and confirm the matching video")
                }
            }

            if let summary = live.summary {
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
    }

    /// Pause only when audio is truly playing — never while opening/buffering.
    private var isPlaying: Bool {
        !presenter.isOpening && (monitor.snapshot?.isPlaying ?? false)
    }

    private var isOpening: Bool {
        presenter.isOpening
    }

    private var currentRate: Double {
        monitor.snapshot?.playbackRate ?? 1.0
    }

    private var snapshot: AudioSessionSnapshot? {
        monitor.snapshot
    }

    @ViewBuilder
    private var artworkBlock: some View {
        if live.isVideo {
            // Fill the available NP video region (iPad-wide), aspect-fit inside.
            // Mini bar stays slim elsewhere — this only applies to full NP.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 180)
                .overlay {
                    ZStack {
                        Color.black
                        if let videoPlayer {
                            PodcastVideoSurfaceView(player: videoPlayer)
                        } else {
                            ProgressView()
                                .tint(.white)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        Button {
                            videoPresentation.enterFullscreenManually()
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(Circle().fill(Color.black.opacity(0.45)))
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                        .accessibilityLabel("Enter fullscreen")
                    }
                }
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .layoutPriority(1)
                .accessibilityLabel("Episode video")
        } else {
            Group {
                if let cover = monitor.coverImage {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFill()
                } else if let url = live.coverURL {
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
    }

    private var placeholderArt: some View {
        ZStack {
            Color(white: 0.12)
            Image(systemName: live.isVideo ? "play.rectangle.fill" : "mic.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.white.opacity(0.72))
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
                    Task {
                        await AudioSessionActor.shared.skipPlayback(
                            by: -AudioSessionActor.podcastSkipInterval
                        )
                    }
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back 15 seconds")

                Button {
                    guard !isOpening else { return }
                    Task { try? await AudioSessionActor.shared.transport(.togglePlayPause) }
                } label: {
                    if isOpening {
                        VStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.large)
                            Text("Loading…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 72, height: 72)
                        .accessibilityLabel("Loading")
                    } else {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 56))
                    }
                }
                .buttonStyle(.plain)
                .disabled(isOpening)
                .accessibilityLabel(isOpening ? "Loading" : (isPlaying ? "Pause" : "Play"))

                Button {
                    Task {
                        await AudioSessionActor.shared.skipPlayback(
                            by: AudioSessionActor.podcastSkipInterval
                        )
                    }
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

    private func refreshVideoPlayer() async {
        guard live.isVideo else {
            videoPlayer = nil
            return
        }
        // Reuse the session AVPlayer — never allocate a second engine for fullscreen.
        videoPlayer = await AudioSessionActor.shared.podcastAVPlayer()
    }

    private func syncVideoPresentationContext() {
        videoPresentation.updatePlayerVisibility(
            expanded: true,
            isInternalVideo: live.isVideo
        )
    }

    private func syncInterfaceOrientation(size: CGSize?) {
        let fromScene = PodcastVideoInterfaceOrientationMapping.current()
        if fromScene != .ignored {
            videoPresentation.setInterfaceOrientation(fromScene)
            return
        }
        if let size {
            let fromSize = PodcastVideoInterfaceOrientationMapping.fromSize(size)
            if fromSize != .ignored {
                videoPresentation.setInterfaceOrientation(fromSize)
            }
        }
    }

    /// Resolve via Settings YouTube URL → same openPodcast + video surface as RSS video.
    private func playYouTubeInApp(watchURL: URL) async {
        guard !isResolvingYouTube else { return }
        isResolvingYouTube = true
        defer { isResolvingYouTube = false }
        do {
            let pick = try await PodcastYouTubeResolver.shared.resolve(watchURL: watchURL)
            let videoEpisode = PodcastPlayerPresenter.Episode(
                id: live.id,
                title: live.title,
                showTitle: live.showTitle,
                summary: live.summary,
                audioURL: pick.url,
                duration: live.duration,
                isVideo: true,
                coverURL: live.coverURL,
                youtubeURL: watchURL
            )
            _ = await presenter.play(videoEpisode)
            await refreshVideoPlayer()
        } catch {
            NotificationCenter.default.post(name: .punkRallyYouTubeResolveFailed, object: nil)
        }
    }
}
#endif
