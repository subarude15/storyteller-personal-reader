#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import ImageIO
import SilveranKit
import SwiftUI
import UIKit
import WidgetKit

/// Lock Screen + Dynamic Island presentation for the playing item. Added to the widget
/// extension's `WidgetBundle`; timers extrapolate playback so the app never pushes
/// per-second updates.
public struct InkAmpPlaybackLiveActivity: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: InkAmpPlaybackAttributes.self) { context in
            InkAmpLiveLockScreenView(state: context.state)
                .activityBackgroundTint(InkAmpLiveColors(context.state).background)
                .activitySystemActionForegroundColor(.white)
                .widgetURL(InkAmpContinueLink.continueURL)
        } dynamicIsland: { context in
            let state = context.state
            let colors = InkAmpLiveColors(state)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    InkAmpLiveCover(filename: state.coverFilename, kind: state.itemKind, side: 52, radius: 10)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let chapter = state.chapter {
                            Text(chapter)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    InkAmpLiveRemainingText(state: state)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(colors.control)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        InkAmpLiveProgress(state: state, tint: colors.control)
                        InkAmpLiveTransport(state: state, colors: colors)
                    }
                }
            } compactLeading: {
                InkAmpLiveCover(filename: state.coverFilename, kind: state.itemKind, side: 20, radius: 5)
            } compactTrailing: {
                InkAmpLiveRemainingText(state: state)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(colors.control)
                    .frame(maxWidth: 48)
            } minimal: {
                ZStack {
                    InkAmpLiveRing(state: state, tint: colors.control)
                    InkAmpLiveCover(filename: state.coverFilename, kind: state.itemKind, side: 22, radius: 11)
                }
            }
            .keylineTint(colors.control)
            .widgetURL(InkAmpContinueLink.continueURL)
        }
    }
}

/// Dark presentation colors. The Lock Screen draws the cover's dark surface (control is
/// validated 3:1 against it) or surfaceDark without a tint; the Dynamic Island is black.
struct InkAmpLiveColors {
    let background: Color
    let control: Color
    let onControl: Color

    static let surfaceDark = CoverRGB8(red: 0x2E, green: 0x2E, blue: 0x2E)

    init(_ state: InkAmpPlaybackActivityState) {
        background = Color(liveRGB: state.tint?.dark.surface ?? Self.surfaceDark)
        if let dark = state.tint?.dark {
            control = Color(liveRGB: dark.control)
            onControl = Color(liveRGB: dark.onControl)
        } else {
            let accent = CoverRGB8(hex: InkAmpBrandPalette.tangerine) ?? CoverTintMath.onControlLight
            control = Color(liveRGB: accent)
            onControl = Color(liveRGB: CoverTintMath.onControl(for: accent) ?? CoverTintMath.onControlDark)
        }
    }
}

private extension Color {
    init(liveRGB rgb: CoverRGB8) {
        self.init(.sRGB, red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
    }
}

struct InkAmpLiveLockScreenView: View {
    let state: InkAmpPlaybackActivityState

    var body: some View {
        let colors = InkAmpLiveColors(state)
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                InkAmpLiveCover(filename: state.coverFilename, kind: state.itemKind, side: 68, radius: 10)
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let chapter = state.chapter ?? state.author {
                        Text(chapter)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    InkAmpLiveProgress(state: state, tint: colors.control)
                    HStack {
                        Spacer()
                        InkAmpLiveRemainingText(state: state)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            InkAmpLiveTransport(state: state, colors: colors)
        }
        .padding(16)
        .overlay {
            ContainerRelativeShape()
                .strokeBorder(colors.control.opacity(0.55), lineWidth: 1)
        }
    }
}

struct InkAmpLiveTransport: View {
    let state: InkAmpPlaybackActivityState
    let colors: InkAmpLiveColors

    var body: some View {
        let skip = Int(InkAmpLiveActivitySettings.skipInterval)
        HStack(spacing: 28) {
            Button(intent: InkAmpLiveSkipIntent(seconds: -skip)) {
                Image(systemName: "gobackward.30")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back 30 seconds")

            Button(intent: InkAmpLiveTogglePlayIntent()) {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(colors.onControl)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(colors.control))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.isPlaying ? "Pause" : "Play")

            Button(intent: InkAmpLiveSkipIntent(seconds: skip)) {
                Image(systemName: "goforward.30")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Forward 30 seconds")
        }
    }
}

/// Item progress: timer-driven while playing (rate-correct), static while paused.
struct InkAmpLiveProgress: View {
    let state: InkAmpPlaybackActivityState
    let tint: Color

    var body: some View {
        Group {
            if state.isPlaying, let interval = state.itemTimerInterval {
                ProgressView(
                    timerInterval: interval,
                    countsDown: false,
                    label: { EmptyView() },
                    currentValueLabel: { EmptyView() },
                )
            } else {
                ProgressView(value: min(state.position, max(state.itemEnd, 0)), total: max(state.itemEnd, 1))
            }
        }
        .progressViewStyle(.linear)
        .tint(tint)
    }
}

struct InkAmpLiveRing: View {
    let state: InkAmpPlaybackActivityState
    let tint: Color

    var body: some View {
        Group {
            if state.isPlaying, let interval = state.itemTimerInterval {
                ProgressView(
                    timerInterval: interval,
                    countsDown: false,
                    label: { EmptyView() },
                    currentValueLabel: { EmptyView() },
                )
            } else {
                ProgressView(value: min(state.position, max(state.itemEnd, 0)), total: max(state.itemEnd, 1))
            }
        }
        .progressViewStyle(.circular)
        .tint(tint)
        .frame(width: 30, height: 30)
    }
}

/// Time left in the chapter (or item): live countdown while playing, fixed when paused.
struct InkAmpLiveRemainingText: View {
    let state: InkAmpPlaybackActivityState

    var body: some View {
        if state.isPlaying, let interval = state.remainingTimerInterval {
            Text(timerInterval: interval, countsDown: true)
                .multilineTextAlignment(.trailing)
        } else {
            Text(Self.format(remainingMedia: staticRemaining, rate: state.rate))
        }
    }

    private var staticRemaining: TimeInterval {
        let end = state.chapterEnd.flatMap { $0 > state.position ? $0 : nil } ?? state.itemEnd
        return max(0, end - state.position)
    }

    static func format(remainingMedia: TimeInterval, rate: Double) -> String {
        let total = Int((remainingMedia / max(rate, 0.01)).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "-%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "-%d:%02d", minutes, seconds)
    }
}

/// Cover thumbnail from the App Group, decoded at presentation size so oversized
/// sources never exceed the activity's image budget.
struct InkAmpLiveCover: View {
    @Environment(\.displayScale) private var displayScale
    let filename: String?
    let kind: InkAmpPlaybackActivityState.ItemKind
    let side: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let image = Self.load(filename, maxPixels: side * displayScale, scale: displayScale) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.14)
                    Image(systemName: kind == .podcast ? "mic.fill" : "book.fill")
                        .font(.system(size: side * 0.4))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityHidden(true)
    }

    static func load(_ filename: String?, maxPixels: CGFloat, scale: CGFloat) -> UIImage? {
        guard let filename,
            let url = InkAmpPlaybackActivityStore.thumbnailURL(filename: filename),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixels.rounded(.up))),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: image, scale: max(scale, 1), orientation: .up)
    }
}
#endif
