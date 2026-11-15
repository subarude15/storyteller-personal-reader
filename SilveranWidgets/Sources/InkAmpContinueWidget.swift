//
//  InkAmpContinueWidget.swift
//  Silveran Reader Widgets (iOS)
//
//  Four Continue + Next Up Home Screen tiles (light/dark × medium/large).
//  Shared App Group snapshot / AltStore ALTAppGroups resolution is unchanged.
//  Playback transport intents are intentionally not surfaced here.
//

import AppIntents
import ImageIO
import OSLog
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
        InkAmpStreakMediumWidget()
        SilveranReadingWidget()
    }
}

// MARK: - Timeline

struct InkAmpContinueEntry: TimelineEntry {
    let date: Date
    let snapshot: ContinueWidgetSnapshot
    /// True only for the redacted Widget Gallery sample. Live snapshot and
    /// timeline entries are never placeholders.
    let isPlaceholder: Bool
    /// Empty copy is a property of the shared snapshot, not of theme.
    let showsEmptyState: Bool

    init(date: Date, resolved: InkAmpContinueResolvedTimeline) {
        self.date = date
        self.snapshot = resolved.snapshot
        self.isPlaceholder = resolved.isPlaceholder
        self.showsEmptyState = resolved.showsEmptyState
    }

    /// Live entry. Previews and tests use this; theme is not an input.
    init(date: Date, snapshot: ContinueWidgetSnapshot) {
        self.init(
            date: date,
            resolved: InkAmpContinueTimelineResolver.resolveLive(
                loaded: snapshot,
                phase: .timeline,
            ),
        )
    }

    static var placeholderSnapshot: ContinueWidgetSnapshot {
        ContinueWidgetSnapshot(
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
            )
    }

    static var placeholder: InkAmpContinueEntry {
        InkAmpContinueEntry(
            date: Date(),
            resolved: InkAmpContinueTimelineResolver.placeholder(sample: placeholderSnapshot),
        )
    }

    static var streakPlaceholder: InkAmpContinueEntry {
        var sample = placeholderSnapshot
        sample.streakDays = 4
        sample.todayActiveSeconds = 18 * 60
        sample.dailyGoalMinutes = 30
        sample.longestStreakDays = 12
        return InkAmpContinueEntry(
            date: Date(),
            resolved: InkAmpContinueTimelineResolver.placeholder(sample: sample),
        )
    }
}

struct InkAmpContinueTimelineProvider: TimelineProvider {
    private static let logger = Logger(subsystem: "com.punkrally.reader", category: "ContinueWidget")
    private static let bundleRole = Bundle.main.bundleURL.pathExtension == "appex" ? "widget" : "app"

    /// Logged only. Not passed to the snapshot store.
    let kind: String
    /// Logged only. Live entries do not branch on this.
    let theme: InkAmpWidgetTheme

    func placeholder(in context: Context) -> InkAmpContinueEntry {
        Self.logger.notice("provider bundle=\(Self.bundleRole, privacy: .public) phase=placeholder event=start")
        let entry = kind == SilveranWidgetConstants.streakWidgetKind
            ? InkAmpContinueEntry.streakPlaceholder
            : InkAmpContinueEntry.placeholder
        log(
            phase: .placeholder,
            preview: context.isPreview,
            snapshot: entry.snapshot,
            family: context.family,
            entryDate: entry.date,
            refreshAfter: nil,
        )
        Self.logger.notice("provider bundle=\(Self.bundleRole, privacy: .public) phase=placeholder event=success")
        return entry
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (InkAmpContinueEntry) -> Void,
    ) {
        Self.logger.notice("provider bundle=\(Self.bundleRole, privacy: .public) phase=snapshot event=start")
        // Gallery preview included. `isPreview` must not swap in the redacted
        // sample — that sample is what made the light compact tile look like a
        // skeleton while a live entry was available.
        SilveranWidgetSnapshotStore.logAppGroupAvailability(source: "continue.snapshot")
        let update = liveUpdate(phase: .snapshot)
        log(
            phase: update.resolved.phase,
            preview: context.isPreview,
            snapshot: update.snapshot,
            family: context.family,
            entryDate: update.entryDate,
            refreshAfter: update.refreshAfter,
        )
        Self.logger.notice("provider bundle=\(Self.bundleRole, privacy: .public) phase=snapshot event=success hasItem=\(update.snapshot.hasItem, privacy: .public)")
        completion(InkAmpContinueEntry(date: update.entryDate, resolved: update.resolved))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<InkAmpContinueEntry>) -> Void,
    ) {
        Self.logger.notice("provider bundle=\(Self.bundleRole, privacy: .public) phase=timeline event=start")
        SilveranWidgetSnapshotStore.logAppGroupAvailability(source: "continue.timeline")
        let update = liveUpdate(phase: .timeline)
        log(
            phase: update.resolved.phase,
            preview: context.isPreview,
            snapshot: update.snapshot,
            family: context.family,
            entryDate: update.entryDate,
            refreshAfter: update.refreshAfter,
        )
        let calendar = ContinueWidgetSnapshot.normalizedLocalCalendar()
        let raw = Self.loadSnapshot()
        let entry = InkAmpContinueEntry(date: update.entryDate, resolved: update.resolved)
        var entries = [entry]
        let dayEnd = calendar.dateInterval(of: .day, for: update.entryDate)?.end
        // For Streak + Goal, transition cleanly to Evening Urgency at 8:00 PM local time.
        if kind == SilveranWidgetConstants.streakWidgetKind,
            let eveningBoundary = calendar.date(
                bySettingHour: 20, minute: 0, second: 0, of: update.entryDate
            ),
            eveningBoundary > update.entryDate,
            dayEnd.map({ eveningBoundary < $0 }) ?? true
        {
            entries.append(
                InkAmpContinueEntry(
                    date: eveningBoundary,
                    resolved: InkAmpContinueTimelineResolver.resolveLive(
                        loaded: raw.resolvingStreak(at: eveningBoundary, calendar: calendar),
                        phase: .timeline
                    )
                )
            )
        }
        // Day-boundary entry expires/recomputes streak text even if Home never
        // republishes and audio-session updates keep refreshing the snapshot.
        if let dayEnd, dayEnd > update.entryDate {
            entries.append(
                InkAmpContinueEntry(
                    date: dayEnd,
                    resolved: InkAmpContinueTimelineResolver.resolveLive(
                        loaded: raw.resolvingStreak(at: dayEnd, calendar: calendar),
                        phase: .timeline
                    )
                )
            )
        }
        let policy: TimelineReloadPolicy
        if let refreshAfter = update.refreshAfter {
            let bound = entries.dropFirst().map(\.date)
            let next = ([refreshAfter] + bound).filter { $0 > update.entryDate }.min() ?? refreshAfter
            policy = .after(next)
        } else {
            policy = .atEnd
        }
        Self.logger.notice("provider bundle=\(Self.bundleRole, privacy: .public) phase=timeline event=success hasItem=\(update.snapshot.hasItem, privacy: .public)")
        completion(Timeline(entries: entries, policy: policy))
    }

    static func loadSnapshot() -> ContinueWidgetSnapshot {
        ContinueWidgetSnapshotStore.loadSnapshot()
    }

    private func liveUpdate(phase: InkAmpContinueLivePhase) -> ContinueWidgetLiveUpdate {
        let now = Date()
        let calendar = ContinueWidgetSnapshot.normalizedLocalCalendar()
        return ContinueWidgetLiveUpdateBuilder.make(
            loaded: Self.loadSnapshot().resolvingStreak(at: now, calendar: calendar),
            phase: phase,
            theme: theme,
            now: now,
        )
    }

    private func log(
        phase: InkAmpContinueTimelinePhase,
        preview: Bool,
        snapshot: ContinueWidgetSnapshot,
        family: WidgetFamily,
        entryDate: Date,
        refreshAfter: Date?,
    ) {
        #if DEBUG
        print(
            InkAmpContinueTimelineResolver.logLine(
                kind: kind,
                family: String(describing: family),
                theme: theme,
                phase: phase,
                isPreview: preview,
                snapshot: snapshot,
                generatedAt: snapshot.generatedAt,
                entryDate: entryDate,
                refreshAfter: refreshAfter,
            )
        )
        #endif
    }
}

// MARK: - Four widget kinds

struct InkAmpLightMediumWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: SilveranWidgetConstants.continueWidgetKinds[0],
            provider: InkAmpContinueTimelineProvider(
                kind: SilveranWidgetConstants.continueWidgetKinds[0],
                theme: .light,
            ),
        ) { entry in
            // Same entry the dark compact tile gets; theme is paint only.
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
            provider: InkAmpContinueTimelineProvider(
                kind: SilveranWidgetConstants.continueWidgetKinds[1],
                theme: .light,
            ),
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
            provider: InkAmpContinueTimelineProvider(
                kind: SilveranWidgetConstants.continueWidgetKinds[2],
                theme: .dark,
            ),
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
            provider: InkAmpContinueTimelineProvider(
                kind: SilveranWidgetConstants.continueWidgetKinds[3],
                theme: .dark,
            ),
        ) { entry in
            InkAmpContinueWidgetView(entry: entry, theme: .dark, layout: .large)
        }
        .configurationDisplayName("ink+amp Dark Large")
        .description("Continue plus the next three in queue — dark theme.")
        .supportedFamilies([.systemLarge])
        .contentMarginsDisabled()
    }
}

struct InkAmpStreakMediumWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: SilveranWidgetConstants.streakWidgetKind,
            provider: InkAmpContinueTimelineProvider(
                kind: SilveranWidgetConstants.streakWidgetKind,
                theme: .light,
            ),
        ) { entry in
            InkAmpStreakMediumWidgetView(entry: entry)
        }
        .configurationDisplayName("ink+amp · Streak & Goal")
        .description("Your most recent book or podcast alongside today's reading goal countdown and streak.")
        .supportedFamilies([.systemMedium])
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
    private var statusBadge: InkAmpContinueStatusBadge {
        InkAmpContinueWidgetActions.statusBadge(for: snapshot)
    }

    var body: some View {
        Group {
            if entry.showsEmptyState {
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
        .inkAmpLiveContent(isPlaceholder: entry.isPlaceholder)
    }

    private func statusBadgePill(compact: Bool) -> some View {
        InkAmpStatusBadgePill(badge: statusBadge, compact: compact, theme: theme, colors: colors)
    }

    private var subtitleLine: String? {
        let values = [snapshot.subtitle, snapshot.streakText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !values.isEmpty else { return nil }
        return values.joined(separator: " · ")
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
        .padding(.horizontal, InkAmpContinueWidgetMetrics.mediumOuterPadding)
        .padding(.vertical, InkAmpContinueWidgetMetrics.mediumOuterVerticalPadding)
    }

    /// Compact Medium current column — chip, then cover beside title, then full-width progress.
    private var mediumNowColumn: some View {
        Link(destination: InkAmpContinueWidgetActions.continueURL(for: snapshot)) {
            VStack(alignment: .leading, spacing: InkAmpContinueWidgetMetrics.mediumNowColumnSpacing) {
                statusBadgePill(compact: true)

                HStack(alignment: .top, spacing: InkAmpContinueWidgetMetrics.mediumCoverMetadataGap) {
                    cover(
                        filename: snapshot.coverFilename,
                        kind: snapshot.kind,
                        size: InkAmpContinueWidgetMetrics.mediumCoverSize,
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.title ?? "")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(colors.primary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                            .multilineTextAlignment(.leading)

                        if let subtitle = subtitleLine {
                            Text(subtitle)
                                .font(.system(size: 10))
                                .foregroundStyle(colors.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let progress = snapshot.clampedProgress {
                    InkAmpThemedProgressBar(
                        progress: progress,
                        fill: colors.progress,
                        track: colors.progressTrack,
                        height: InkAmpContinueWidgetMetrics.mediumProgressHeight,
                    )
                }

                if let caption = snapshot.progressCaption {
                    Text(caption)
                        .font(
                            .system(
                                size: InkAmpContinueWidgetMetrics.mediumCaptionFontSize,
                                weight: .medium,
                                design: .rounded,
                            )
                        )
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
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(colors.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    HStack(spacing: 3) {
                        Image(systemName: (item.kind ?? .ebook).symbolName)
                            .font(.system(size: 7.5, weight: .semibold))
                            .foregroundStyle(colors.accent)
                        if let pct = item.percentComplete {
                            Text("\(pct)%")
                                .font(.system(size: 8.5, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(colors.secondary)
                        } else if let subtitle = item.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 8.5))
                                .foregroundStyle(colors.secondary)
                                .lineLimit(1)
                        } else {
                            Text((item.kind ?? .ebook).label)
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(colors.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Up next, \(item.title)")
    }

    private var mediumActionRow: some View {
        HStack(spacing: 6) {
            #if os(iOS)
            if InkAmpContinueWidgetActions.showsInlineTransport(for: snapshot) {
                Button(intent: ContinuePlayPauseIntent()) {
                    HStack(spacing: 4) {
                        Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 10, weight: .bold))
                        Text(snapshot.isPlaying ? "Pause" : "Play")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(colors.continueLabel)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, InkAmpContinueWidgetMetrics.mediumActionVerticalPadding)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(colors.continueFill)
                    )
                }
                .buttonStyle(.plain)

                Button(intent: ContinueSkipBackwardIntent()) {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(colors.browseLabel)
                        .padding(.horizontal, 10)
                        .padding(.vertical, InkAmpContinueWidgetMetrics.mediumActionVerticalPadding)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(colors.browseFill)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rewind 15 seconds")

                Link(destination: InkAmpContinueWidgetActions.browseQueueURL()) {
                    Text("Queue")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(colors.browseLabel)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, InkAmpContinueWidgetMetrics.mediumActionVerticalPadding)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(colors.browseFill)
                        )
                }
                .buttonStyle(.plain)
            } else {
                mediumDefaultActionLinks
            }
            #else
            mediumDefaultActionLinks
            #endif
        }
    }

    @ViewBuilder
    private var mediumDefaultActionLinks: some View {
        Link(destination: InkAmpContinueWidgetActions.continueURL(for: snapshot)) {
            Text("Continue")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(colors.continueLabel)
                .frame(maxWidth: .infinity)
                .padding(.vertical, InkAmpContinueWidgetMetrics.mediumActionVerticalPadding)
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
                .padding(.vertical, InkAmpContinueWidgetMetrics.mediumActionVerticalPadding)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(colors.browseFill)
                )
        }
        .buttonStyle(.plain)
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
                statusBadgePill(compact: false)

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

                if let subtitle = subtitleLine {
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
        VStack(alignment: .leading, spacing: 7) {
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
                cover(filename: item.coverFilename, kind: item.kind, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(colors.primary)
                        .lineLimit(2)

                    HStack(spacing: 4) {
                        Image(systemName: (item.kind ?? .ebook).symbolName)
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(colors.accent)
                        if let subtitle = item.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 10))
                                .foregroundStyle(colors.secondary)
                                .lineLimit(1)
                        } else {
                            Text((item.kind ?? .ebook).label)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(colors.secondary)
                        }
                        if let pct = item.percentComplete {
                            Text("· \(pct)%")
                                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(colors.secondary)
                        }
                    }

                    if let progress = item.clampedProgress {
                        InkAmpThemedProgressBar(
                            progress: progress,
                            fill: colors.progress,
                            track: colors.progressTrack,
                            height: 2.5,
                        )
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
            #if os(iOS)
            if InkAmpContinueWidgetActions.showsInlineTransport(for: snapshot) {
                Button(intent: ContinuePlayPauseIntent()) {
                    HStack(spacing: 5) {
                        Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: continueProminent ? 13 : 11, weight: .bold))
                        Text(snapshot.isPlaying ? "Pause" : "Play")
                            .font(.system(size: continueProminent ? 14 : 12, weight: .bold))
                    }
                    .foregroundStyle(colors.continueLabel)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, continueProminent ? 12 : 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(colors.continueFill)
                    )
                }
                .buttonStyle(.plain)

                Button(intent: ContinueSkipBackwardIntent()) {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: continueProminent ? 14 : 12, weight: .semibold))
                        .foregroundStyle(colors.browseLabel)
                        .padding(.horizontal, 12)
                        .padding(.vertical, continueProminent ? 12 : 9)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(colors.browseFill)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rewind 15 seconds")

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
            } else {
                defaultLargeActionLinks(continueProminent: continueProminent)
            }
            #else
            defaultLargeActionLinks(continueProminent: continueProminent)
            #endif
        }
    }

    @ViewBuilder
    private func defaultLargeActionLinks(continueProminent: Bool) -> some View {
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
        InkAmpWidgetCoverView(
            filename: filename,
            kind: kind,
            width: size,
            height: size,
            cornerRadius: 8,
            theme: theme,
            colors: colors,
        )
    }
}

// MARK: - Medium Streak + Goal Widget

struct InkAmpStreakMediumWidgetView: View {
    @Environment(\.colorScheme) private var colorScheme
    let entry: InkAmpContinueEntry

    private var theme: InkAmpWidgetTheme { colorScheme == .dark ? .dark : .light }
    private var colors: InkAmpWidgetColors { InkAmpWidgetColors(theme: theme) }
    private var snapshot: ContinueWidgetSnapshot { entry.snapshot }
    private var goal: InkAmpStreakGoalPresentation {
        InkAmpStreakGoalPresentation.resolve(from: snapshot, now: entry.date)
    }
    private var statusBadge: InkAmpContinueStatusBadge {
        InkAmpContinueWidgetActions.statusBadge(for: snapshot)
    }
    private var tierColor: Color {
        Color(hex: goal.tier.accentHex(for: theme))
    }

    var body: some View {
        HStack(spacing: 12) {
            leftNowPlayingColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            rightGoalCard
                .frame(width: 132)
                .frame(maxHeight: .infinity)
        }
        .padding(14)
        .containerBackground(for: .widget) {
            colors.background
        }
        .inkAmpLiveContent(isPlaceholder: entry.isPlaceholder)
    }

    @ViewBuilder
    private var leftNowPlayingColumn: some View {
        if entry.showsEmptyState {
            VStack(alignment: .leading, spacing: 6) {
                Text("ink+amp")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(colors.accent)
                HStack(alignment: .top, spacing: 8) {
                    InkAmpWidgetCoverView(
                        filename: nil,
                        kind: nil,
                        width: 42,
                        height: 56,
                        cornerRadius: 7,
                        theme: theme,
                        colors: colors,
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nothing in progress")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(colors.primary)
                            .lineLimit(2)
                        Text("Open ink+amp to read or listen")
                            .font(.system(size: 10))
                            .foregroundStyle(colors.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Link(destination: InkAmpContinueWidgetActions.openAppURL()) {
                    Text("Open ink+amp")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(colors.continueLabel)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(colors.continueFill)
                        )
                }
                .buttonStyle(.plain)
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Link(destination: InkAmpContinueWidgetActions.continueURL(for: snapshot)) {
                    VStack(alignment: .leading, spacing: 6) {
                        InkAmpStatusBadgePill(
                            badge: statusBadge,
                            compact: true,
                            theme: theme,
                            colors: colors,
                        )
                        HStack(alignment: .top, spacing: 8) {
                            InkAmpWidgetCoverView(
                                filename: snapshot.coverFilename,
                                kind: snapshot.kind,
                                width: 42,
                                height: 56,
                                cornerRadius: 7,
                                theme: theme,
                                colors: colors,
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(snapshot.title ?? "")
                                    .font(.system(size: 12.5, weight: .bold))
                                    .foregroundStyle(colors.primary)
                                    .lineLimit(2)
                                    .minimumScaleFactor(0.85)
                                    .multilineTextAlignment(.leading)

                                if let subtitle = snapshot.subtitle?
                                    .trimmingCharacters(in: .whitespacesAndNewlines),
                                    !subtitle.isEmpty
                                {
                                    Text(subtitle)
                                        .font(.system(size: 10))
                                        .foregroundStyle(colors.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let progress = snapshot.clampedProgress {
                            InkAmpThemedProgressBar(
                                progress: progress,
                                fill: colors.progress,
                                track: colors.progressTrack,
                                height: 4,
                            )
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Continue, \(snapshot.title ?? "")")

                Spacer(minLength: 0)

                leftActionRow
            }
        }
    }

    private var leftActionRow: some View {
        HStack(spacing: 6) {
            if let caption = snapshot.progressCaption {
                Text(caption)
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(colors.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 2)
            #if os(iOS)
            if InkAmpContinueWidgetActions.showsInlineTransport(for: snapshot) {
                Button(intent: ContinuePlayPauseIntent()) {
                    HStack(spacing: 4) {
                        Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 9.5, weight: .bold))
                        Text(snapshot.isPlaying ? "Pause" : "Play")
                            .font(.system(size: 10.5, weight: .bold))
                    }
                    .foregroundStyle(colors.continueLabel)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(colors.continueFill)
                    )
                }
                .buttonStyle(.plain)
            } else {
                continuePillLink
            }
            #else
            continuePillLink
            #endif
        }
    }

    private var continuePillLink: some View {
        Link(destination: InkAmpContinueWidgetActions.continueURL(for: snapshot)) {
            HStack(spacing: 3) {
                Text("Continue")
                    .font(.system(size: 10.5, weight: .bold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
            }
            .foregroundStyle(colors.continueLabel)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(colors.continueFill)
            )
        }
        .buttonStyle(.plain)
    }

    private var rightGoalCard: some View {
        let glowFill = tierColor.opacity(theme == .light ? 0.11 : 0.16)
        let glowStroke = tierColor.opacity(theme == .light ? 0.30 : 0.42)
        let ringTrack = tierColor.opacity(theme == .light ? 0.16 : 0.22)
        return Link(destination: InkAmpContinueLink.homeURL) {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .stroke(ringTrack, lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: goal.progressFraction)
                        .stroke(tierColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if goal.tier == .completed {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(tierColor)
                    } else {
                        Text(goal.percentText)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(colors.primary)
                            .minimumScaleFactor(0.75)
                    }
                }
                .frame(width: 44, height: 44)

                VStack(spacing: 1) {
                    Text(goal.countdownHeadline)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(tierColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(goal.todayRatioText)
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(colors.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 0)

                Text(goal.streakBadgeText)
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundStyle(tierColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .frame(maxWidth: .infinity)
                    .background(
                        Capsule(style: .continuous)
                            .fill(tierColor.opacity(theme == .light ? 0.14 : 0.20))
                    )
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(glowFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(glowStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(goal.todayRatioText), \(goal.countdownHeadline), \(goal.streakBadgeText)")
    }
}

// MARK: - Shared Widget Building Blocks

private struct InkAmpStatusBadgePill: View {
    let badge: InkAmpContinueStatusBadge
    let compact: Bool
    let theme: InkAmpWidgetTheme
    let colors: InkAmpWidgetColors

    var body: some View {
        HStack(spacing: compact ? 3 : 4) {
            Image(systemName: badge.symbolName)
                .font(.system(size: compact ? 7.5 : 8.5, weight: .bold))
            Text(badge.label)
                .font(.system(size: compact ? 8 : 9, weight: .bold))
                .tracking(compact ? 0.45 : 0.55)
        }
        .foregroundStyle(colors.accent)
        .padding(.horizontal, compact ? 6 : 7)
        .padding(.vertical, compact ? 3 : 4)
        .background(
            Capsule(style: .continuous)
                .fill(colors.accent.opacity(theme == .light ? 0.14 : 0.18))
        )
    }
}

private struct InkAmpWidgetCoverView: View {
    @Environment(\.displayScale) private var displayScale
    let filename: String?
    let kind: ContinueWidgetKindTag?
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let theme: InkAmpWidgetTheme
    let colors: InkAmpWidgetColors

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(colors.coverFallback)
            if let image = coverImage(filename: filename, maxPoints: max(width, height)) {
                image
                    .resizable()
                    .inkAmpFullColorRendering()
                    .scaledToFill()
            } else {
                Image(systemName: coverSymbol(kind))
                    .font(.system(size: min(width, height) * 0.34, weight: .semibold))
                    .foregroundStyle(colors.secondary)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(colors.accent.opacity(theme == .light ? 0.35 : 0.2), lineWidth: 1)
        )
    }

    private func coverImage(filename: String?, maxPoints: CGFloat) -> Image? {
        guard let filename,
            let url = ContinueWidgetSnapshotStore.coverURL(for: filename)
        else { return nil }
        #if canImport(UIKit)
        let maxPixels = max(64, Int((maxPoints * max(displayScale, 2)).rounded(.up)))
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return Image(uiImage: UIImage(cgImage: cgImage, scale: max(displayScale, 1), orientation: .up))
            }
        }
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

extension View {
    /// Live timelines opt out of WidgetKit's placeholder redaction. The gallery
    /// sample stays redacted so it cannot be mistaken for the book in progress.
    @ViewBuilder
    func inkAmpLiveContent(isPlaceholder: Bool) -> some View {
        if isPlaceholder {
            self
        } else {
            unredacted()
        }
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

    static var streakAquaEntry: InkAmpContinueEntry {
        InkAmpContinueEntry(
            date: Date(),
            snapshot: ContinueWidgetSnapshot(
                title: "The Southern Book Club's Guide to Slaying Vampires",
                subtitle: "Grady Hendrix",
                isPlaying: true,
                kind: .audiobook,
                deepLink: InkAmpContinueLink.continueURL.absoluteString,
                progress: 0.37,
                elapsedSeconds: 11_880,
                durationSeconds: 32_400,
                hasLiveSession: true,
                rate: 1.25,
                streakDays: 4,
                todayActiveSeconds: 18 * 60,
                dailyGoalMinutes: 30,
                longestStreakDays: 12,
            ),
        )
    }
}

/// Constrains Medium chrome to a realistic systemMedium canvas so vertical overflow is visible.
private struct InkAmpMediumSystemSizedPreview: View {
    let theme: InkAmpWidgetTheme

    var body: some View {
        InkAmpContinueWidgetView(
            entry: InkAmpMediumWidgetPreviewData.longTitleEntry,
            theme: theme,
            layout: .medium,
        )
        .frame(
            width: InkAmpContinueWidgetMetrics.mediumPreviewWidth,
            height: InkAmpContinueWidgetMetrics.mediumPreviewHeight,
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
        )
    }
}

#Preview("Medium systemMedium · light", as: .systemMedium) {
    InkAmpLightMediumWidget()
} timeline: {
    InkAmpMediumWidgetPreviewData.longTitleEntry
}

#Preview("Medium systemMedium · dark", as: .systemMedium) {
    InkAmpDarkMediumWidget()
} timeline: {
    InkAmpMediumWidgetPreviewData.longTitleEntry
}

#Preview("Streak + Goal (Medium)", as: .systemMedium) {
    InkAmpStreakMediumWidget()
} timeline: {
    InkAmpMediumWidgetPreviewData.streakAquaEntry
}

#Preview("Medium fixed canvas · light") {
    InkAmpMediumSystemSizedPreview(theme: .light)
}

#Preview("Medium fixed canvas · dark") {
    InkAmpMediumSystemSizedPreview(theme: .dark)
}
#endif
