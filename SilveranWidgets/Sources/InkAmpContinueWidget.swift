//
//  InkAmpContinueWidget.swift
//  Silveran Reader Widgets (iOS)
//
//  Four Continue + Next Up Home Screen tiles (light/dark × medium/large).
//  Shared App Group snapshot / AltStore ALTAppGroups resolution is unchanged.
//  Playback transport intents are intentionally not surfaced here.
//

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
        InkAmpLightMediumWidget()
        InkAmpLightLargeWidget()
        InkAmpDarkMediumWidget()
        InkAmpDarkLargeWidget()
    }
}

// MARK: - Timeline

struct InkAmpContinueEntry: TimelineEntry {
    let date: Date
    let snapshot: ContinueWidgetSnapshot

    static var placeholder: InkAmpContinueEntry {
        InkAmpContinueEntry(
            date: Date(),
            snapshot: ContinueWidgetSnapshot(
                title: "The Quiet Path",
                subtitle: "Ella Monroe",
                isPlaying: false,
                kind: .audiobook,
                deepLink: InkAmpContinueLink.continueURL.absoluteString,
                progress: 0.56,
                elapsedSeconds: 17_640,
                durationSeconds: 31_680,
                hasLiveSession: false,
                rate: 1.0,
                upNext: [
                    ContinueWidgetQueueItem(
                        id: "book:preview/good-energy",
                        title: "Good Energy",
                        subtitle: "Casey Lin",
                        kind: .ebook,
                        deepLink: InkAmpContinueLink.queueItemURL(id: "book:preview/good-energy")
                            .absoluteString,
                    ),
                    ContinueWidgetQueueItem(
                        id: "book:preview/next-chapter",
                        title: "The Next Chapter",
                        subtitle: "Jordan Lee",
                        kind: .audiobook,
                        deepLink: InkAmpContinueLink.queueItemURL(id: "book:preview/next-chapter")
                            .absoluteString,
                    ),
                    ContinueWidgetQueueItem(
                        id: "book:preview/make-it-happen",
                        title: "Make It Happen",
                        subtitle: "Avery Chen",
                        kind: .ebook,
                        deepLink: InkAmpContinueLink.queueItemURL(id: "book:preview/make-it-happen")
                            .absoluteString,
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
        let refresh: TimeInterval = snapshot.isPlaying ? 5 * 60 : 15 * 60
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(refresh))))
    }

    static func loadSnapshot() -> ContinueWidgetSnapshot {
        ContinueWidgetSnapshotStore.loadSnapshot()
    }
}

// MARK: - Four widget kinds

struct InkAmpLightMediumWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: SilveranWidgetConstants.continueWidgetKinds[0],
            provider: InkAmpContinueTimelineProvider(),
        ) { entry in
            InkAmpContinueWidgetView(entry: entry, theme: .light, layout: .medium)
        }
        .configurationDisplayName("ink+amp Light Medium")
        .description("Continue plus the next two in queue — light theme.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

struct InkAmpLightLargeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: SilveranWidgetConstants.continueWidgetKinds[1],
            provider: InkAmpContinueTimelineProvider(),
        ) { entry in
            InkAmpContinueWidgetView(entry: entry, theme: .light, layout: .large)
        }
        .configurationDisplayName("ink+amp Light Large")
        .description("Continue plus the next three in queue — light theme.")
        .supportedFamilies([.systemLarge])
        .contentMarginsDisabled()
    }
}

struct InkAmpDarkMediumWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: SilveranWidgetConstants.continueWidgetKinds[2],
            provider: InkAmpContinueTimelineProvider(),
        ) { entry in
            InkAmpContinueWidgetView(entry: entry, theme: .dark, layout: .medium)
        }
        .configurationDisplayName("ink+amp Dark Medium")
        .description("Continue plus the next two in queue — dark theme.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

struct InkAmpDarkLargeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: SilveranWidgetConstants.continueWidgetKinds[3],
            provider: InkAmpContinueTimelineProvider(),
        ) { entry in
            InkAmpContinueWidgetView(entry: entry, theme: .dark, layout: .large)
        }
        .configurationDisplayName("ink+amp Dark Large")
        .description("Continue plus the next three in queue — dark theme.")
        .supportedFamilies([.systemLarge])
        .contentMarginsDisabled()
    }
}

// MARK: - Shared view

struct InkAmpContinueWidgetView: View {
    let entry: InkAmpContinueEntry
    let theme: InkAmpWidgetTheme
    let layout: InkAmpContinueWidgetLayout

    private var snapshot: ContinueWidgetSnapshot { entry.snapshot }
    private var colors: InkAmpWidgetColors { InkAmpWidgetColors(theme: theme) }
    private var upNext: [ContinueWidgetQueueItem] {
        InkAmpContinueWidgetActions.upNextItems(for: snapshot, layout: layout)
    }

    var body: some View {
        Group {
            if InkAmpContinueWidgetActions.showsEmptyState(snapshot) {
                emptyState
            } else if layout == .medium {
                mediumBody
            } else {
                largeBody
            }
        }
        .containerBackground(for: .widget) {
            colors.background
        }
    }

    // MARK: Medium

    private var mediumBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                let gap = InkAmpContinueWidgetMetrics.mediumColumnGap
                let usableWidth = max(0, proxy.size.width - gap)
                let currentWidth = InkAmpContinueWidgetMetrics.mediumCurrentWidth(
                    usableWidth: usableWidth
                )
                let queueWidth = InkAmpContinueWidgetMetrics.mediumQueueWidth(
                    usableWidth: usableWidth
                )

                HStack(alignment: .top, spacing: gap) {
                    mediumNowColumn
                        .frame(width: currentWidth, alignment: .leading)
                    mediumUpNextColumn
                        .frame(width: queueWidth, alignment: .leading)
                }
            }
            .frame(maxHeight: .infinity)

            mediumActionRow
        }
        .padding(InkAmpContinueWidgetMetrics.mediumOuterPadding)
    }

    /// Compact Medium current column — vertical stack so title keeps width.
    private var mediumNowColumn: some View {
        Link(destination: InkAmpContinueWidgetActions.continueURL(for: snapshot)) {
            VStack(alignment: .leading, spacing: 5) {
                Text("NOW LISTENING")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(colors.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(colors.accent.opacity(theme == .light ? 0.14 : 0.18))
                    )

                cover(
                    filename: snapshot.coverFilename,
                    kind: snapshot.kind,
                    size: InkAmpContinueWidgetMetrics.mediumCoverSize,
                )

                Text(snapshot.title ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colors.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.leading)

                if let subtitle = snapshot.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(colors.secondary)
                        .lineLimit(1)
                }

                if let progress = snapshot.clampedProgress {
                    InkAmpThemedProgressBar(
                        progress: progress,
                        fill: colors.progress,
                        track: colors.progressTrack,
                        height: 3.5,
                    )
                }

                if let caption = snapshot.progressCaption {
                    Text(caption)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(colors.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Continue, \(snapshot.title ?? "")")
    }

    private var mediumUpNextColumn: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("UP NEXT")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(colors.secondary)

            if upNext.isEmpty {
                Text("Queue is clear")
                    .font(.system(size: 10))
                    .foregroundStyle(colors.secondary)
            } else {
                ForEach(upNext) { item in
                    mediumUpNextRow(item)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mediumUpNextRow(_ item: ContinueWidgetQueueItem) -> some View {
        Link(destination: InkAmpContinueWidgetActions.upNextURL(for: item)) {
            HStack(spacing: 6) {
                cover(
                    filename: item.coverFilename,
                    kind: item.kind,
                    size: InkAmpContinueWidgetMetrics.mediumQueueCoverSize,
                )
                Text(item.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(colors.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Up next, \(item.title)")
    }

    private var mediumActionRow: some View {
        HStack(spacing: 7) {
            Link(destination: InkAmpContinueWidgetActions.continueURL(for: snapshot)) {
                Text("Continue")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(colors.continueLabel)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6.5)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(colors.continueFill)
                    )
            }
            .buttonStyle(.plain)

            Link(destination: InkAmpContinueWidgetActions.browseQueueURL()) {
                Text("Browse Queue")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(colors.browseLabel)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6.5)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(colors.browseFill)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Large

    private var largeBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { proxy in
                let gap: CGFloat = 14
                let usableWidth = max(0, proxy.size.width - gap)
                let currentWidth = usableWidth * 0.42
                let queueWidth = usableWidth - currentWidth

                HStack(alignment: .top, spacing: gap) {
                    largeNowColumn
                        .frame(width: currentWidth, alignment: .leading)

                    upNextColumn
                        .frame(width: queueWidth, alignment: .leading)
                }
            }
            .frame(maxHeight: .infinity)

            actionRow(continueProminent: true)
        }
        .padding(16)
    }

    private var largeNowColumn: some View {
        Link(destination: InkAmpContinueWidgetActions.continueURL(for: snapshot)) {
            VStack(alignment: .leading, spacing: 7) {
                Text("NOW LISTENING")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.55)
                    .foregroundStyle(colors.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(colors.accent.opacity(theme == .light ? 0.14 : 0.18))
                    )

                cover(
                    filename: snapshot.coverFilename,
                    kind: snapshot.kind,
                    size: InkAmpContinueWidgetMetrics.largeCoverSize,
                )

                Text(snapshot.title ?? "")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(colors.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .multilineTextAlignment(.leading)

                if let subtitle = snapshot.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(colors.secondary)
                        .lineLimit(1)
                }

                if let progress = snapshot.clampedProgress {
                    InkAmpThemedProgressBar(
                        progress: progress,
                        fill: colors.progress,
                        track: colors.progressTrack,
                        height: 5,
                    )
                }

                if let caption = snapshot.progressCaption {
                    Text(caption)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(colors.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Continue, \(snapshot.title ?? "")")
    }

    private var upNextColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("UP NEXT")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(colors.secondary)
            if upNext.isEmpty {
                Text("Queue is clear")
                    .font(.caption)
                    .foregroundStyle(colors.secondary)
            } else {
                ForEach(upNext) { item in
                    upNextRow(item)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func upNextRow(_ item: ContinueWidgetQueueItem) -> some View {
        Link(destination: InkAmpContinueWidgetActions.upNextURL(for: item)) {
            HStack(spacing: 8) {
                cover(filename: item.coverFilename, kind: item.kind, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(colors.primary)
                        .lineLimit(2)
                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(colors.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Up next, \(item.title)")
    }

    private func actionRow(continueProminent: Bool) -> some View {
        HStack(spacing: 8) {
            Link(destination: InkAmpContinueWidgetActions.continueURL(for: snapshot)) {
                Text("Continue")
                    .font(.system(size: continueProminent ? 14 : 12, weight: .bold))
                    .foregroundStyle(colors.continueLabel)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, continueProminent ? 12 : 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(colors.continueFill)
                    )
            }
            .buttonStyle(.plain)

            Link(destination: InkAmpContinueWidgetActions.browseQueueURL()) {
                Text("Browse Queue")
                    .font(.system(size: continueProminent ? 14 : 12, weight: .semibold))
                    .foregroundStyle(colors.browseLabel)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, continueProminent ? 12 : 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(colors.browseFill)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ink+amp")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(colors.accent)
            Spacer(minLength: 0)
            Text("Nothing in progress")
                .font(.headline)
                .foregroundStyle(colors.primary)
            Text("Start a book or podcast in ink+amp.")
                .font(.caption)
                .foregroundStyle(colors.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Link(destination: InkAmpContinueWidgetActions.openAppURL()) {
                Text("Open ink+amp")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(colors.continueLabel)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(colors.continueFill)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: Cover

    private func cover(
        filename: String?,
        kind: ContinueWidgetKindTag?,
        size: CGFloat,
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colors.coverFallback)
            if let image = coverImage(filename: filename) {
                image
                    .resizable()
                    .inkAmpFullColorRendering()
                    .scaledToFill()
            } else {
                Image(systemName: coverSymbol(kind))
                    .font(.system(size: size * 0.32, weight: .semibold))
                    .foregroundStyle(colors.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(colors.accent.opacity(theme == .light ? 0.35 : 0.2), lineWidth: 1)
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
}

// MARK: - Theme colors (SwiftUI)

private struct InkAmpWidgetColors {
    let theme: InkAmpWidgetTheme

    var background: Color {
        switch theme {
            case .light: return Color(hex: InkAmpContinueWidgetPalette.Light.blanc)
            case .dark: return Color(hex: InkAmpContinueWidgetPalette.Dark.seaGrey)
        }
    }

    var primary: Color {
        switch theme {
            case .light: return Color(hex: InkAmpContinueWidgetPalette.Light.primaryText)
            case .dark: return Color(hex: InkAmpContinueWidgetPalette.Dark.primaryText)
        }
    }

    var secondary: Color {
        switch theme {
            case .light: return Color(hex: InkAmpContinueWidgetPalette.Light.secondaryText)
            case .dark: return Color(hex: InkAmpContinueWidgetPalette.Dark.secondaryText)
        }
    }

    var accent: Color {
        switch theme {
            case .light: return Color(hex: InkAmpContinueWidgetPalette.Light.aqua)
            case .dark: return Color(hex: InkAmpContinueWidgetPalette.Dark.tangerine)
        }
    }

    var progress: Color {
        switch theme {
            case .light: return Color(hex: InkAmpContinueWidgetPalette.Light.carmin)
            case .dark: return Color(hex: InkAmpContinueWidgetPalette.Dark.tangerine)
        }
    }

    var progressTrack: Color {
        primary.opacity(theme == .light ? 0.1 : 0.18)
    }

    var continueFill: Color {
        switch theme {
            case .light: return Color(hex: InkAmpContinueWidgetPalette.Light.carmin)
            case .dark: return Color(hex: InkAmpContinueWidgetPalette.Dark.tangerine)
        }
    }

    var continueLabel: Color {
        switch theme {
            case .light: return .white
            case .dark: return Color(hex: InkAmpContinueWidgetPalette.Dark.seaGrey)
        }
    }

    var browseFill: Color {
        switch theme {
            case .light: return Color.black.opacity(0.06)
            case .dark: return Color(hex: InkAmpContinueWidgetPalette.Dark.leafGreen)
        }
    }

    var browseLabel: Color {
        switch theme {
            case .light: return primary
            case .dark: return .white
        }
    }

    var coverFallback: Color {
        switch theme {
            case .light: return Color(hex: InkAmpContinueWidgetPalette.Light.aqua).opacity(0.25)
            case .dark: return Color.white.opacity(0.08)
        }
    }
}

private extension Color {
    /// Parses `#RRGGBB`. Invalid input falls back to a loud red so a bad constant is obvious.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        guard cleaned.count == 6 else {
            self.init(red: 1, green: 0, blue: 1)
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
        )
    }
}

struct InkAmpThemedProgressBar: View {
    let progress: Double
    let fill: Color
    let track: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(fill)
                    .frame(width: max(height, proxy.size.width * progress))
            }
        }
        .frame(height: height)
    }
}

extension Image {
    @ViewBuilder
    func inkAmpFullColorRendering() -> some View {
        #if os(iOS)
        widgetAccentedRenderingMode(.fullColor)
        #else
        self
        #endif
    }
}

#if DEBUG
private enum InkAmpMediumWidgetPreviewData {
    static var longTitleEntry: InkAmpContinueEntry {
        InkAmpContinueEntry(
            date: Date(),
            snapshot: ContinueWidgetSnapshot(
                title: "The Southern Book Club's Guide to Slaying Vampires",
                subtitle: "Grady Hendrix",
                isPlaying: false,
                kind: .audiobook,
                deepLink: InkAmpContinueLink.continueURL.absoluteString,
                progress: 0.37,
                elapsedSeconds: 11_880,
                durationSeconds: 32_400,
                hasLiveSession: false,
                rate: 1.25,
                upNext: [
                    ContinueWidgetQueueItem(
                        id: "book:preview/curious-incident",
                        title: "The Curious Incident of the Dog in the Night-Time",
                        subtitle: "Mark Haddon",
                        kind: .ebook,
                        deepLink: InkAmpContinueLink.queueItemURL(
                            id: "book:preview/curious-incident"
                        ).absoluteString,
                    ),
                    ContinueWidgetQueueItem(
                        id: "book:preview/fiends-of-hell",
                        title: "All the Fiends of Hell",
                        subtitle: "Adam Nevill",
                        kind: .audiobook,
                        deepLink: InkAmpContinueLink.queueItemURL(
                            id: "book:preview/fiends-of-hell"
                        ).absoluteString,
                    ),
                ],
            ),
        )
    }
}

#Preview("Medium long titles · light") {
    InkAmpContinueWidgetView(
        entry: InkAmpMediumWidgetPreviewData.longTitleEntry,
        theme: .light,
        layout: .medium,
    )
    .containerBackground(for: .widget) {
        Color(hex: InkAmpContinueWidgetPalette.Light.blanc)
    }
}

#Preview("Medium long titles · dark") {
    InkAmpContinueWidgetView(
        entry: InkAmpMediumWidgetPreviewData.longTitleEntry,
        theme: .dark,
        layout: .medium,
    )
    .containerBackground(for: .widget) {
        Color(hex: InkAmpContinueWidgetPalette.Dark.seaGrey)
    }
}
#endif
