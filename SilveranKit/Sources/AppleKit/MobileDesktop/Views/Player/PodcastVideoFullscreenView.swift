#if os(iOS)
import AVFoundation
import SwiftUI

/// Immersive landscape (or manually entered) video chrome over the shared AVPlayer.
///
/// Re-hosts `PodcastVideoSurfaceView` only — does not create a second playback engine.
struct PodcastVideoFullscreenView: View {
    let title: String
    let player: AVPlayer?
    let isPlaying: Bool
    let isOpening: Bool
    let currentRate: Double
    let snapshot: AudioSessionSnapshot?
    let onExit: () -> Void
    let onUserInteraction: () -> Void

    @Binding var scrubFraction: Double
    @Binding var isScrubbing: Bool

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    private let autoHideDelay: Duration = .seconds(3)

    var body: some View {
        GeometryReader { geo in
            let safe = geo.safeAreaInsets
            ZStack {
                Color.black.ignoresSafeArea()

                videoSurface
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()

                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        noteInteraction()
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if controlsVisible {
                                controlsVisible = false
                                cancelHideTimer()
                            } else {
                                controlsVisible = true
                                scheduleHideIfNeeded()
                            }
                        }
                    }

                if controlsVisible {
                    controlsOverlay(safe: safe)
                        .transition(.opacity)
                }
            }
        }
        .background(Color.black)
        .statusBarHidden(controlsVisible == false && isPlaying)
        .onChange(of: isPlaying) { _, playing in
            if playing {
                scheduleHideIfNeeded()
            } else {
                cancelHideTimer()
                controlsVisible = true
            }
        }
        .onAppear {
            controlsVisible = true
            scheduleHideIfNeeded()
        }
        .onDisappear {
            cancelHideTimer()
        }
        .accessibilityElement(children: .contain)
    }

    private func noteInteraction() {
        onUserInteraction()
        if isPlaying {
            scheduleHideIfNeeded()
        } else {
            cancelHideTimer()
            controlsVisible = true
        }
    }

    private func scheduleHideIfNeeded() {
        cancelHideTimer()
        guard isPlaying, controlsVisible else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: autoHideDelay)
            guard !Task.isCancelled, isPlaying, !isScrubbing else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                controlsVisible = false
            }
        }
    }

    private func cancelHideTimer() {
        hideTask?.cancel()
        hideTask = nil
    }

    @ViewBuilder
    private var videoSurface: some View {
        ZStack {
            Color.black
            if let player {
                PodcastVideoSurfaceView(player: player)
            } else if isOpening {
                ProgressView()
                    .tint(.white)
            } else {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .accessibilityLabel("Episode video")
    }

    private func controlsOverlay(safe: EdgeInsets) -> some View {
        VStack(spacing: 0) {
            topBar
                .padding(.top, max(safe.top, 8))
                .padding(.horizontal, max(safe.leading, safe.trailing, 16))

            Spacer(minLength: 0)

            centerTransport

            Spacer(minLength: 0)

            bottomScrubber
                .padding(.horizontal, max(safe.leading, safe.trailing, 20))
                .padding(.bottom, max(safe.bottom, 12))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                noteInteraction()
                onExit()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Exit fullscreen")

            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            PlaybackRateButton(
                currentRate: currentRate,
                onRateChange: { rate in
                    noteInteraction()
                    Task { await AudioSessionActor.shared.setPlaybackRate(rate) }
                },
                backgroundColor: Color.white,
                foregroundColor: Color.white,
                transparency: 0.9,
                showLabel: false,
                buttonSize: 36,
                showBackground: false,
                compactLabel: true,
                iconFont: .body.weight(.semibold)
            )
            .accessibilityLabel("Playback speed")
        }
    }

    private var centerTransport: some View {
        HStack(spacing: 48) {
            Button {
                noteInteraction()
                Task {
                    await AudioSessionActor.shared.skipPlayback(
                        by: -AudioSessionActor.podcastSkipInterval
                    )
                }
            } label: {
                Image(systemName: "gobackward.15")
                    .font(.title)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip back 15 seconds")

            Button {
                noteInteraction()
                guard !isOpening else { return }
                Task { try? await AudioSessionActor.shared.transport(.togglePlayPause) }
            } label: {
                if isOpening {
                    ProgressView()
                        .tint(.white)
                        .frame(width: 72, height: 72)
                        .accessibilityLabel("Loading")
                } else {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(isOpening)
            .accessibilityLabel(isOpening ? "Loading" : (isPlaying ? "Pause" : "Play"))

            Button {
                noteInteraction()
                Task {
                    await AudioSessionActor.shared.skipPlayback(
                        by: AudioSessionActor.podcastSkipInterval
                    )
                }
            } label: {
                Image(systemName: "goforward.15")
                    .font(.title)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Skip forward 15 seconds")
        }
    }

    private var bottomScrubber: some View {
        let elapsed = isScrubbing
            ? (snapshot?.durationSeconds ?? 0) * scrubFraction
            : (snapshot?.elapsedSeconds ?? 0)
        let remaining = max(0, (snapshot?.durationSeconds ?? 0) - elapsed)
        let fraction = isScrubbing ? scrubFraction : (snapshot?.bookProgress ?? 0)

        return VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { fraction },
                    set: {
                        noteInteraction()
                        scrubFraction = $0
                    }
                ),
                in: 0...1
            ) { editing in
                noteInteraction()
                isScrubbing = editing
                if !editing {
                    let target = scrubFraction
                    Task { await AudioSessionActor.shared.seekPlayback(toFraction: target) }
                }
            }
            .tint(.white)
            .accessibilityLabel("Playback position")

            HStack {
                Text(GlobalMiniPlayerBar.formatClock(elapsed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                Spacer()
                Text("−\(GlobalMiniPlayerBar.formatClock(remaining))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }
}
#endif
