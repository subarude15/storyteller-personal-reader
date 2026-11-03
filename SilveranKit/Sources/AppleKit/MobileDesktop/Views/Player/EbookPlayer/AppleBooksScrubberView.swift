#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI

/// Interactive Apple Books–style progress scrubber track with chapter/page tick marks,
/// live floating callout bubble, origin marker dot, and selection haptics.
struct AppleBooksScrubberTrack: View {
    let value: Double
    let scope: ReaderScrubberPolicy.ScrubScope
    let chapterTicks: [ReaderScrubberPolicy.ChapterTick]
    let totalPagesInChapter: Int?
    let jumpOriginFraction: Double?
    let accentColor: Color
    let trackColor: Color
    let calloutTitle: String?
    let calloutSubtitle: String?
    let onScrubBegan: () -> Void
    let onScrubChanged: (Double) -> Void
    let onScrubEnded: (Double) -> Void

    @State private var isDragging = false
    @State private var dragValue: Double = 0
    @State private var lastHapticToken: Int? = nil

    private var displayedFraction: Double {
        let raw = isDragging ? dragValue : value
        return min(max(raw, 0.0), 1.0)
    }

    private var pageTicks: [Double] {
        guard scope == .chapter, let total = totalPagesInChapter else { return [] }
        return ReaderScrubberPolicy.pageTickFractions(totalPages: total)
    }

    var body: some View {
        VStack(spacing: 6) {
            if isDragging, calloutTitle != nil || calloutSubtitle != nil {
                scrubCalloutBubble
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }

            GeometryReader { geometry in
                let width = max(geometry.size.width, 1)
                let height = geometry.size.height
                let trackHeight: CGFloat = isDragging ? 7 : 5
                let thumbDiameter: CGFloat = isDragging ? 18 : 13
                let progressX = width * displayedFraction

                ZStack(alignment: .leading) {
                    // Base capsule track
                    Capsule(style: .continuous)
                        .fill(trackColor)
                        .frame(height: trackHeight)

                    // Filled progress bar
                    Capsule(style: .continuous)
                        .fill(accentColor)
                        .frame(width: max(trackHeight, progressX), height: trackHeight)

                    // Chapter or page tick marks
                    tickMarksLayer(width: width, trackHeight: trackHeight)

                    // Origin marker dot (shows where user started before scrubbing)
                    if let origin = jumpOriginFraction {
                        let clampedOrigin = min(max(origin, 0.0), 1.0)
                        if abs(clampedOrigin - displayedFraction) >= 0.015 {
                            Circle()
                                .strokeBorder(accentColor.opacity(0.85), lineWidth: 1.5)
                                .background(Circle().fill(Color.white.opacity(0.9)))
                                .frame(width: 7, height: 7)
                                .offset(x: min(max(width * clampedOrigin - 3.5, 0), width - 7))
                                .allowsHitTesting(false)
                        }
                    }

                    // Thumb knob
                    Circle()
                        .fill(accentColor)
                        .frame(width: thumbDiameter, height: thumbDiameter)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5)
                        )
                        .shadow(color: .black.opacity(0.22), radius: isDragging ? 4 : 2, y: 1)
                        .offset(
                            x: min(
                                max(progressX - (thumbDiameter / 2), 0),
                                max(0, width - thumbDiameter)
                            )
                        )
                }
                .frame(width: width, height: height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let fraction = min(max(gesture.location.x / width, 0.0), 1.0)
                            if !isDragging {
                                withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                                    isDragging = true
                                }
                                dragValue = fraction
                                ReaderHaptics.prepareForScrub()
                                lastHapticToken = ReaderScrubberPolicy.hapticStepToken(
                                    for: fraction,
                                    scope: scope,
                                    totalPages: totalPagesInChapter,
                                    ticks: chapterTicks
                                )
                                onScrubBegan()
                            } else {
                                dragValue = fraction
                            }

                            let token = ReaderScrubberPolicy.hapticStepToken(
                                for: fraction,
                                scope: scope,
                                totalPages: totalPagesInChapter,
                                ticks: chapterTicks
                            )
                            if token != lastHapticToken {
                                lastHapticToken = token
                                ReaderHaptics.selectionTick()
                            }

                            onScrubChanged(fraction)
                        }
                        .onEnded { gesture in
                            let fraction = min(max(gesture.location.x / width, 0.0), 1.0)
                            dragValue = fraction
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                isDragging = false
                            }
                            lastHapticToken = nil
                            onScrubEnded(fraction)
                        }
                )
            }
            .frame(height: 26)
        }
    }

    @ViewBuilder
    private func tickMarksLayer(width: CGFloat, trackHeight: CGFloat) -> some View {
        let ticks: [Double] =
            switch scope {
                case .book:
                    chapterTicks.map(\.fraction).filter { $0 > 0.01 && $0 < 0.99 }
                case .chapter:
                    pageTicks
            }

        ForEach(Array(ticks.enumerated()), id: \.offset) { _, fraction in
            let xPos = width * CGFloat(fraction)
            let isPassed = fraction <= displayedFraction
            RoundedRectangle(cornerRadius: 1)
                .fill(isPassed ? Color.white.opacity(0.65) : accentColor.opacity(0.42))
                .frame(width: 1.5, height: trackHeight)
                .offset(x: xPos - 0.75)
                .allowsHitTesting(false)
        }
    }

    private var scrubCalloutBubble: some View {
        VStack(spacing: 2) {
            if let calloutTitle, !calloutTitle.isEmpty {
                Text(calloutTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            if let calloutSubtitle, !calloutSubtitle.isEmpty {
                Text(calloutSubtitle)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
    }
}

/// Floating Apple Books "Back to Page X" / "Forward to Page Y" pill shown after
/// scrubbing, jumping chapters, or navigating to a search result or bookmark.
struct ReaderJumpBackPillView: View {
    let snapshot: ReaderScrubberPolicy.JumpSnapshot
    let foregroundColor: Color
    let backgroundColor: Color
    let onReturn: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onReturn) {
                HStack(spacing: 6) {
                    Image(
                        systemName: snapshot.isForwardTarget
                            ? "arrow.uturn.forward" : "arrow.uturn.backward"
                    )
                    .font(.caption.weight(.bold))

                    Text(snapshot.pillLabel)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                }
                .foregroundStyle(foregroundColor)
                .padding(.leading, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(foregroundColor.opacity(0.65))
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .accessibilityLabel("Dismiss jump pill")
        }
        .background(
            Capsule(style: .continuous)
                .fill(backgroundColor.opacity(0.94))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(foregroundColor.opacity(0.18), lineWidth: 0.8)
        )
    }
}

/// Apple Books–style crimson bookmark ribbon hanging from the top-right page margin.
struct BookmarkPageRibbonView: View {
    let onTap: () -> Void

    static let ribbonColor = Color(red: 0.85, green: 0.22, blue: 0.23)

    var body: some View {
        Button(action: onTap) {
            RibbonShape()
                .fill(
                    LinearGradient(
                        colors: [
                            Self.ribbonColor,
                            Self.ribbonColor.opacity(0.88),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 22, height: 38)
                .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 2)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove page bookmark")
    }

    private struct RibbonShape: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let notchHeight = min(rect.height * 0.24, 9)
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - notchHeight))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }
}
#endif
