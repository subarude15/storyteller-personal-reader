//
//  InkAmpContinueWidget.swift
//  Silveran Reader Widgets (iOS)
//
//  The real ink+amp Continue tile: cover art, what you were on, progress, and
//  transport controls that work without opening the app.
//
//  Why this exists (free AltStore history): the previous tile shipped as a
//  static "Open ink+amp" card because a hard-coded App Group id never resolved
//  on an AltStore-resigned build — AltStore rewrites granted groups to
//  `<group>.<TEAMID>` and re-publishes them in `ALTAppGroups`. The snapshot
//  store now reads that key first, so the widget can actually see what the app
//  publishes. The transport buttons are AppIntents that conform to
//  `AudioPlaybackIntent`, which makes WidgetKit run them in the app's process.
//

import AppIntents
import SilveranAppleWidgets
import SwiftUI
import WidgetKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@main
struct SilveranReaderWidgets: WidgetBundle {
    var body: some Widget {
        InkAmpContinueWidget()
    }
}

struct InkAmpContinueEntry: TimelineEntry {
    let date: Date
    let snapshot: ContinueWidgetSnapshot

    static var placeholder: InkAmpContinueEntry {
        InkAmpContinueEntry(
            date: Date(),
            snapshot: ContinueWidgetSnapshot(
                title: "The Book You Were On",
                subtitle: "Chapter 12 · ink+amp",
                isPlaying: true,
                kind: .audiobook,
                deepLink: InkAmpContinueLink.continueURL.absoluteString,
                progress: 0.42,
                elapsedSeconds: 5400,
                durationSeconds: 12_600,
                hasLiveSession: true,
                rate: 1.0,
            ),
        )
    }
}

struct InkAmpContinueTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> InkAmpContinueEntry {
        .placeholder
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (InkAmpContinueEntry) -> Void,
    ) {
        if context.isPreview {
            completion(.placeholder)
            return
        }
        SilveranWidgetSnapshotStore.logAppGroupAvailability(source: "continue.snapshot")
        completion(InkAmpContinueEntry(date: Date(), snapshot: Self.loadSnapshot()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<InkAmpContinueEntry>) -> Void,
    ) {
        SilveranWidgetSnapshotStore.logAppGroupAvailability(source: "continue.timeline")
        let snapshot = Self.loadSnapshot()
        let entry = InkAmpContinueEntry(date: Date(), snapshot: snapshot)
        // Playback state is pushed by the app (`reloadTimelines`); this cadence is
        // only a safety net, so it stays inside WidgetKit's reload budget.
        let refresh: TimeInterval = snapshot.isPlaying ? 5 * 60 : 15 * 60
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(refresh))))
    }

    static func loadSnapshot() -> ContinueWidgetSnapshot {
        ContinueWidgetSnapshotStore.loadSnapshot()
    }
}

struct InkAmpContinueWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: SilveranWidgetConstants.continueWidgetKind,
            provider: InkAmpContinueTimelineProvider(),
        ) { entry in
            InkAmpContinueWidgetView(entry: entry)
        }
        .configurationDisplayName("Continue")
        .description("Pick up where you left off — cover, progress, play/pause and ±15s.")
        .supportedFamilies(supportedFamilies)
        .contentMarginsDisabled()
    }

    private var supportedFamilies: [WidgetFamily] {
        var families: [WidgetFamily] = [.systemSmall, .systemMedium]
        #if !os(macOS)
        families += [.accessoryRectangular, .accessoryCircular]
        #endif
        return families
    }
}

// MARK: - View

private struct InkAmpContinueWidgetView: View {
    let entry: InkAmpContinueEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: ContinueWidgetSnapshot { entry.snapshot }

    var body: some View {
        Group {
            // `#if` at statement level (not inside a `switch`) — the accessory
            // families only exist off macOS.
            #if os(macOS)
            mainBody
            #else
            if family == .accessoryRectangular {
                accessoryRectangular
            } else if family == .accessoryCircular {
                accessoryCircular
            } else {
                mainBody
            }
            #endif
        }
        .containerBackground(for: .widget) {
            InkAmpWidgetPalette.background
        }
        .widgetURL(tapURL)
    }

    @ViewBuilder
    private var mainBody: some View {
        if family == .systemSmall {
            smallBody
        } else {
            mediumBody
        }
    }

    private var tapURL: URL {
        if let deepLink = snapshot.deepLink, let url = URL(string: deepLink) {
            return url
        }
        return InkAmpContinueLink.continueURL
    }

    // MARK: System small

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                cover(size: 54)
                Spacer(minLength: 0)
                if snapshot.supportsTransportControls {
                    playPauseButton(size: 36)
                } else {
                    continueChevron(size: 36)
                }
            }
            Spacer(minLength: 0)
            titleBlock(lineLimit: 2, titleFont: .subheadline.weight(.semibold))
            if let progress = snapshot.clampedProgress {
                InkAmpProgressBar(progress: progress, height: 4)
            }
            if let caption = snapshot.progressCaption {
                Text(caption)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(InkAmpWidgetPalette.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .padding(12)
    }

    // MARK: System medium

    private var mediumBody: some View {
        HStack(alignment: .top, spacing: 12) {
            cover(size: 84)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Continue")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(InkAmpWidgetPalette.accent)
                    if let kind = snapshot.kind {
                        Text(kind.label)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(InkAmpWidgetPalette.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(InkAmpWidgetPalette.secondary.opacity(0.12))
                            )
                    }
                    Spacer(minLength: 0)
                    if snapshot.isPlaying {
                        Text("PLAYING")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(InkAmpWidgetPalette.accent)
                    }
                }
                titleBlock(lineLimit: 2, titleFont: .headline)
                    .padding(.top, 1)
                if let subtitle = snapshot.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(InkAmpWidgetPalette.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                if let progress = snapshot.clampedProgress {
                    InkAmpProgressBar(progress: progress, height: 4)
                        .padding(.top, 2)
                }
                if let caption = snapshot.progressCaption {
                    Text(caption)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(InkAmpWidgetPalette.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                transportRow
                    .padding(.top, 4)
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private var transportRow: some View {
        if snapshot.supportsTransportControls {
            HStack(spacing: 10) {
                transportButton(symbol: "gobackward.15", size: 30, intent: ContinueSkipBackwardIntent())
                playPauseButton(size: 38)
                transportButton(symbol: "goforward.15", size: 30, intent: ContinueSkipForwardIntent())
                Spacer(minLength: 0)
            }
            .buttonStyle(.plain)
        } else {
            continuePill
        }
    }

    // MARK: Buttons

    private func playPauseButton(size: CGFloat) -> some View {
        Button(intent: ContinuePlayPauseIntent()) {
            ZStack {
                Circle().fill(InkAmpWidgetPalette.accent)
                Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(snapshot.isPlaying ? "Pause" : "Play")
    }

    private func transportButton<I: AppIntent>(
        symbol: String,
        size: CGFloat,
        intent: I,
    ) -> some View {
        Button(intent: intent) {
            ZStack {
                Circle().fill(InkAmpWidgetPalette.accent.opacity(0.14))
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(InkAmpWidgetPalette.accent)
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
    }

    /// No live session: the tap has to open ink+amp to actually start playback.
    private func continueChevron(size: CGFloat) -> some View {
        ZStack {
            Circle().fill(InkAmpWidgetPalette.accent)
            Image(systemName: "play.fill")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    private var continuePill: some View {
        Text("Tap to continue")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(InkAmpWidgetPalette.accent))
    }

    // MARK: Lock Screen

    #if !os(macOS)
    private var accessoryRectangular: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(displaySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if snapshot.supportsTransportControls {
                Button(intent: ContinuePlayPauseIntent()) {
                    Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3.weight(.semibold))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var accessoryCircular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let progress = snapshot.clampedProgress {
                Gauge(value: progress) {
                    Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                }
                .gaugeStyle(.accessoryCircularCapacity)
            } else {
                Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3.weight(.semibold))
            }
        }
    }
    #endif

    // MARK: Pieces

    private func titleBlock(lineLimit: Int, titleFont: Font) -> some View {
        Text(displayTitle)
            .font(titleFont)
            .foregroundStyle(InkAmpWidgetPalette.primary)
            .lineLimit(lineLimit)
    }

    private func cover(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(InkAmpWidgetPalette.coverFallback)
            if let image = coverImage {
                image
                    .resizable()
                    .inkAmpFullColorRendering()
                    .scaledToFill()
            } else {
                Image(systemName: coverSymbol)
                    .font(.system(size: size * 0.32, weight: .semibold))
                    .foregroundStyle(InkAmpWidgetPalette.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.black.opacity(0.08), lineWidth: 1)
        )
    }

    private var coverImage: Image? {
        guard let filename = snapshot.coverFilename,
            let url = ContinueWidgetSnapshotStore.coverURL(for: filename)
        else { return nil }
        #if canImport(UIKit)
        guard let ui = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: ui)
        #elseif canImport(AppKit)
        guard let data = try? Data(contentsOf: url), let ns = NSImage(data: data) else {
            return nil
        }
        return Image(nsImage: ns)
        #else
        return nil
        #endif
    }

    private var coverSymbol: String {
        switch snapshot.kind {
            case .podcast: return "mic.fill"
            case .audiobook, .readaloud: return "headphones"
            case .ebook, .none: return "book.closed.fill"
        }
    }

    /// Never blank: live snapshot, else this process's last known title, else invite.
    private var displayTitle: String {
        if snapshot.hasItem, let title = snapshot.title {
            return title
        }
        if let fallback = ContinueWidgetSnapshotStore.lastTitleFallback() {
            return fallback
        }
        return "Open ink+amp"
    }

    private var displaySubtitleIfAny: String? {
        guard snapshot.hasItem else { return nil }
        guard let subtitle = snapshot.subtitle, !subtitle.isEmpty else { return nil }
        return subtitle
    }

    private var displaySubtitle: String {
        if let subtitle = displaySubtitleIfAny {
            return subtitle
        }
        if snapshot.hasItem {
            return snapshot.remainingText ?? "Tap to continue"
        }
        if ContinueWidgetSnapshotStore.lastTitleFallback() != nil {
            return "Open ink+amp"
        }
        return "Tap to continue"
    }
}

// MARK: - Palette + primitives

enum InkAmpWidgetPalette {
    static let accent = Color(red: 0.91, green: 0.365, blue: 0.016)  // #E85D04
    // Explicit ink colors — Color.primary can wash out on some WidgetKit surfaces.
    static let primary = Color(red: 0.102, green: 0.094, blue: 0.078)  // #1A1814
    static let secondary = Color(red: 0.420, green: 0.396, blue: 0.376)  // #6B6560
    static let coverFallback = Color(white: 0.2)
    static let background = LinearGradient(
        colors: [
            Color(red: 0.97, green: 0.96, blue: 0.95),
            Color(red: 0.93, green: 0.91, blue: 0.88),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing,
    )
}

extension Image {
    /// `widgetAccentedRenderingMode` is an `Image` method and iOS-only; the
    /// macOS widget target compiles this file too, so the tinted-mode opt-out
    /// has to be conditional.
    @ViewBuilder
    func inkAmpFullColorRendering() -> some View {
        #if os(iOS)
        widgetAccentedRenderingMode(.fullColor)
        #else
        self
        #endif
    }
}

struct InkAmpProgressBar: View {
    let progress: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(InkAmpWidgetPalette.primary.opacity(0.12))
                Capsule()
                    .fill(InkAmpWidgetPalette.accent)
                    .frame(width: max(height, proxy.size.width * progress))
            }
        }
        .frame(height: height)
    }
}
