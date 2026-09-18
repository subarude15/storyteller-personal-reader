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
                upNext: [
                    ContinueWidgetQueueItem(
                        id: "pod:preview-1",
                        title: "Next in the queue",
                        kind: .podcast,
                        deepLink: InkAmpContinueLink.queueItemURL(id: "pod:preview-1").absoluteString,
                    ),
                    ContinueWidgetQueueItem(
                        id: "book:preview/two",
                        title: "The Following Book",
                        kind: .ebook,
                        deepLink: InkAmpContinueLink.queueItemURL(id: "book:preview/two")
                            .absoluteString,
                    ),
                    ContinueWidgetQueueItem(
                        id: "pod:preview-3",
                        title: "One More Episode",
                        kind: .audiobook,
                        deepLink: InkAmpContinueLink.queueItemURL(id: "pod:preview-3").absoluteString,
                    ),
                ],
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
        .configurationDisplayName("Continue + Up next")
        .description("Now, plus the next three from Home — books and podcasts.")
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
        .widgetURL(usesRowLinks ? nil : tapURL)
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
        if snapshot.hasItem, let deepLink = snapshot.deepLink, let url = URL(string: deepLink) {
            return url
        }
        return InkAmpContinueLink.continueURL
    }

    /// Medium with Up next rows uses `Link` per row. A widget-wide URL would swallow them.
    private var usesRowLinks: Bool {
        family == .systemMedium && snapshot.hasItem && !snapshot.upNextItems.isEmpty
    }

    // MARK: System small

    @ViewBuilder
    private var smallBody: some View {
        if snapshot.hasItem {
            smallNow
        } else {
            emptyState
        }
    }

    private var smallNow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                cover(filename: snapshot.coverFilename, kind: snapshot.kind, size: 54)
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

    @ViewBuilder
    private var mediumBody: some View {
        if !snapshot.hasItem {
            emptyState
        } else if snapshot.upNextItems.isEmpty {
            mediumNowOnly
        } else {
            mediumWithQueue
        }
    }

    private var mediumNowOnly: some View {
        HStack(alignment: .top, spacing: 12) {
            cover(filename: snapshot.coverFilename, kind: snapshot.kind, size: 84)
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

    private var mediumWithQueue: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Link(destination: tapURL) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top, spacing: 8) {
                            cover(filename: snapshot.coverFilename, kind: snapshot.kind, size: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Now")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(InkAmpWidgetPalette.accent)
                                titleBlock(lineLimit: 2, titleFont: .subheadline.weight(.semibold))
                            }
                        }
                        if let progress = snapshot.clampedProgress {
                            InkAmpProgressBar(progress: progress, height: 3)
                        }
                        if let caption = snapshot.progressCaption {
                            Text(caption)
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .foregroundStyle(InkAmpWidgetPalette.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                    }
                }
                .buttonStyle(.plain)
                compactTransport
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text("Up next")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(InkAmpWidgetPalette.secondary)
                ForEach(snapshot.upNextItems) { item in
                    upNextRow(item)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 132, alignment: .leading)
        }
        .padding(12)
    }

    private func upNextRow(_ item: ContinueWidgetQueueItem) -> some View {
        let destination = URL(string: item.deepLink) ?? InkAmpContinueLink.queueItemURL(id: item.id)
        return Link(destination: destination) {
            HStack(spacing: 6) {
                cover(filename: item.coverFilename, kind: item.kind, size: 28)
                Text(item.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(InkAmpWidgetPalette.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Up next, \(item.title)")
    }

    @ViewBuilder
    private var compactTransport: some View {
        if snapshot.supportsTransportControls {
            HStack(spacing: 6) {
                transportButton(symbol: "gobackward.15", size: 26, intent: ContinueSkipBackwardIntent())
                playPauseButton(size: 30)
                transportButton(symbol: "goforward.15", size: 26, intent: ContinueSkipForwardIntent())
                Spacer(minLength: 0)
            }
            .buttonStyle(.plain)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Continue")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(InkAmpWidgetPalette.accent)
            Spacer(minLength: 0)
            Text("Nothing in progress")
                .font(.headline)
                .foregroundStyle(InkAmpWidgetPalette.primary)
                .lineLimit(2)
            Text("Books and podcasts you start show up here.")
                .font(.caption)
                .foregroundStyle(InkAmpWidgetPalette.secondary)
                .lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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

    private func cover(
        filename: String?,
        kind: ContinueWidgetKindTag?,
        size: CGFloat,
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(InkAmpWidgetPalette.coverFallback)
            if let image = coverImage(filename: filename) {
                image
                    .resizable()
                    .inkAmpFullColorRendering()
                    .scaledToFill()
            } else {
                Image(systemName: coverSymbol(kind))
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

    private func coverImage(filename: String?) -> Image? {
        guard let filename,
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

    private func coverSymbol(_ kind: ContinueWidgetKindTag?) -> String {
        switch kind {
            case .podcast: return "mic.fill"
            case .audiobook, .readaloud: return "headphones"
            case .ebook, .none: return "book.closed.fill"
        }
    }

    /// Live snapshot, else an honest empty. A missing App Group still paints the
    /// last item via `localFallbackSnapshot` (that path sets `hasItem`).
    private var displayTitle: String {
        if snapshot.hasItem, let title = snapshot.title {
            return title
        }
        return "Nothing in progress"
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
        return "Books and podcasts you start show up here."
    }
}

// MARK: - Palette + primitives

enum InkAmpWidgetPalette {
    static let accent = Color(red: 0.91, green: 0.365, blue: 0.016)  // #E85D04
    // Dark-chrome ink. Color.primary washes out on WidgetKit, and a clear
    // container lets the wallpaper through so the tile looks blank.
    static let primary = Color(red: 0.957, green: 0.945, blue: 0.918)  // #F4F1EA
    static let secondary = Color(red: 0.604, green: 0.584, blue: 0.549)  // #9A958C
    static let coverFallback = Color(white: 0.2)
    /// Opaque charcoal (#0B0B0C). Never `Color.clear`.
    static let background = Color(red: 0.043, green: 0.043, blue: 0.047)
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
