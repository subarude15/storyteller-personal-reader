//
//  StatsView.swift
//  ink+amp
//
//  Ported from Enve Book Player (AGPL-3.0-only):
//  https://github.com/opisaac9001/Enve-Book-Player
//  Original: ios/enve/Screens/Journal/JournalScreen.swift + JournalStatsComponents.swift
//  Modifications: SessionTracker + Storyteller Stats sync footer states.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

/// Stats destination — reading/listening time, daily goal, streak, finished count, average session.
/// Hosted under More (not a primary tab). Expects an enclosing NavigationStack.
struct StatsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("punkRally.stats.dailyGoalMinutes") private var dailyGoalMinutes: Int = 30
    @State private var tracker = SessionTracker.shared
    @State private var sync = StatsSyncCoordinator.shared
    @State private var tick = 0
    @State private var segment: Segment = .stats

    private static let goalOptionsMinutes = [15, 30, 45, 60, 90]

    private enum Segment: String, CaseIterable, Identifiable {
        case stats = "Stats"
        case timeline = "Timeline"
        var id: String { rawValue }
    }

    private var chrome: PunkRallyTheme.Chrome {
        PunkRallyTheme.Chrome(scheme: colorScheme)
    }

    var body: some View {
        let _ = tracker.revision
        let _ = sync.revision
        let _ = tick
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                segmentPicker
                switch segment {
                    case .stats:
                        statsBody
                    case .timeline:
                        StoryTimelineView()
                }
            }
            .padding(.horizontal, PunkRallyTheme.Metric.screenInset)
            .padding(.vertical, 12)
        }
        .background(chrome.bg)
        .navigationTitle("Stats")
        .task {
            tracker.pruneOldSessions()
            await sync.syncNow(reason: "statsAppear")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await sync.syncNow(reason: "foreground") }
            }
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            // Live active-session seconds — revision may be unchanged while elapsed grows.
            tick &+= 1
        }
    }

    private var segmentPicker: some View {
        Picker("Stats section", selection: $segment) {
            ForEach(Segment.allCases) { segment in
                Text(segment.rawValue).tag(segment)
            }
        }
        .pickerStyle(.segmented)
    }

    private var statsBody: some View {
        VStack(alignment: .leading, spacing: 20) {
            dailyGoalCard
            heroCard
            streakAndFinishedRow
            weekChart
            monthlySummaryCard
            syncFooter
        }
    }

    // MARK: - Daily Goal Card

    private var dailyGoalCard: some View {
        let snapshot = tracker.snapshot
        let goalSeconds = Double(Swift.max(dailyGoalMinutes, 5) * 60)
        let progress = Swift.min(Swift.max(snapshot.todaySeconds / goalSeconds, 0), 1)
        let remainingSeconds = Swift.max(goalSeconds - snapshot.todaySeconds, 0)
        let isGoalMet = snapshot.todaySeconds >= goalSeconds

        return HStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(chrome.border, lineWidth: 7)
                    .frame(width: 64, height: 64)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        isGoalMet ? PunkRallyTheme.Accent.success : PunkRallyTheme.Accent.primary,
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 64, height: 64)
                    .animation(.easeOut(duration: 0.35), value: progress)

                if isGoalMet {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(PunkRallyTheme.Accent.success)
                } else {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(chrome.text)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Today's Goal")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(chrome.text)
                    Spacer()
                    Menu {
                        ForEach(Self.goalOptionsMinutes, id: \.self) { mins in
                            Button {
                                dailyGoalMinutes = mins
                            } label: {
                                if dailyGoalMinutes == mins {
                                    Label("\(mins) min / day", systemImage: "checkmark")
                                } else {
                                    Text("\(mins) min / day")
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(dailyGoalMinutes)m goal")
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(PunkRallyTheme.Accent.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(PunkRallyTheme.Accent.primary.opacity(0.14))
                        )
                    }
                }

                Text(snapshot.todaySeconds.hoursMinutes)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(chrome.text)

                Text(
                    isGoalMet
                        ? "Daily goal reached — keep the streak going!"
                        : "\(remainingSeconds.hoursMinutes) left to reach your \(dailyGoalMinutes)m goal"
                )
                .font(.caption)
                .foregroundStyle(isGoalMet ? PunkRallyTheme.Accent.success : chrome.textMuted)
            }
        }
        .padding(PunkRallyTheme.Metric.cardPadding)
        .background(chrome.surface)
        .clipShape(RoundedRectangle(cornerRadius: PunkRallyTheme.Metric.buttonCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: PunkRallyTheme.Metric.buttonCornerRadius)
                .stroke(chrome.border, lineWidth: 1)
        )
    }

    // MARK: - Hero

    private var heroCard: some View {
        let snapshot = tracker.snapshot
        return VStack(alignment: .leading, spacing: 12) {
            Text("This week")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(chrome.textMuted)

            Text(snapshot.weekSeconds.hoursMinutes)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(chrome.text)

            HStack(spacing: 16) {
                let listen = snapshot.recentDays.reduce(0.0) { $0 + $1.listenSeconds }
                let read = snapshot.recentDays.reduce(0.0) { $0 + $1.readSeconds }
                legendDot(
                    color: PunkRallyTheme.Accent.primary,
                    label: "Listen \(listen.hoursMinutes)"
                )
                legendDot(
                    color: PunkRallyTheme.Accent.gold,
                    label: "Read \(read.hoursMinutes)"
                )
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(chrome.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PunkRallyTheme.Metric.cardPadding)
        .background(chrome.surface)
        .clipShape(RoundedRectangle(cornerRadius: PunkRallyTheme.Metric.buttonCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: PunkRallyTheme.Metric.buttonCornerRadius)
                .stroke(chrome.border, lineWidth: 1)
        )
    }

    // MARK: - Streak / Finished / Avg

    private var streakAndFinishedRow: some View {
        let snapshot = tracker.snapshot
        return HStack(spacing: 12) {
            statTile(
                value: "\(snapshot.streakDays)",
                label: "Day streak",
                symbol: "flame.fill",
                tint: PunkRallyTheme.Accent.primary
            )
            statTile(
                value: "\(snapshot.finishedBooks30d)",
                label: "Finished · 30d",
                symbol: "checkmark.seal.fill",
                tint: PunkRallyTheme.Accent.success
            )
            statTile(
                value: snapshot.averageSessionSeconds == 0
                    ? "–"
                    : snapshot.averageSessionSeconds.minutesShort,
                label: "Avg session",
                symbol: "timer",
                tint: PunkRallyTheme.Accent.gold
            )
        }
    }

    private func statTile(value: String, label: String, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(tint)
            Text(value)
                .font(.title2.weight(.bold))
                .foregroundStyle(chrome.text)
            Text(label)
                .font(.caption)
                .foregroundStyle(chrome.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PunkRallyTheme.Metric.cardPadding)
        .background(chrome.surface)
        .clipShape(RoundedRectangle(cornerRadius: PunkRallyTheme.Metric.buttonCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: PunkRallyTheme.Metric.buttonCornerRadius)
                .stroke(chrome.border, lineWidth: 1)
        )
    }

    // MARK: - 7-day chart

    private var weekChart: some View {
        let snapshot = tracker.snapshot
        let maxSeconds = max(snapshot.recentDays.map(\.totalSeconds).max() ?? 0, 1)
        let formatter = DateFormatter()
        formatter.dateFormat = "E"

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Last 7 days")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(chrome.text)
                Spacer()
                HStack(spacing: 10) {
                    legendDot(color: PunkRallyTheme.Accent.primary, label: "Listen")
                    legendDot(color: PunkRallyTheme.Accent.gold, label: "Read")
                }
                .font(.caption2)
                .foregroundStyle(chrome.textMuted)
            }

            HStack(alignment: .bottom, spacing: 8) {
                ForEach(snapshot.recentDays) { day in
                    VStack(spacing: 4) {
                        if day.totalSeconds > 0 {
                            Text(day.totalSeconds.minutesShort)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(chrome.textFaint)
                        }
                        stackedBar(for: day, maxSeconds: maxSeconds)
                            .frame(maxWidth: 24)
                        Text(formatter.string(from: day.day))
                            .font(.caption2)
                            .foregroundStyle(chrome.textFaint)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 150, alignment: .bottom)
        }
        .padding(PunkRallyTheme.Metric.cardPadding)
        .background(chrome.surface)
        .clipShape(RoundedRectangle(cornerRadius: PunkRallyTheme.Metric.buttonCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: PunkRallyTheme.Metric.buttonCornerRadius)
                .stroke(chrome.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func stackedBar(for day: PRDailyAggregate, maxSeconds: TimeInterval) -> some View {
        let totalHeight = barHeight(day.totalSeconds, max: maxSeconds)
        if day.totalSeconds <= 0 {
            RoundedRectangle(cornerRadius: 3)
                .fill(chrome.border)
                .frame(height: 4)
        } else {
            let readFraction = day.readSeconds / day.totalSeconds
            let readHeight = CGFloat(readFraction) * totalHeight
            let listenHeight = max(0, totalHeight - readHeight)
            VStack(spacing: 0) {
                if readHeight > 0 {
                    Rectangle()
                        .fill(PunkRallyTheme.Accent.gold)
                        .frame(height: readHeight)
                }
                if listenHeight > 0 {
                    Rectangle()
                        .fill(PunkRallyTheme.Accent.primary)
                        .frame(height: listenHeight)
                }
            }
            .frame(height: totalHeight)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private func barHeight(_ seconds: TimeInterval, max maxVal: TimeInterval) -> CGFloat {
        guard maxVal > 0 else { return 4 }
        return Swift.max(4, 100 * seconds / maxVal)
    }

    // MARK: - 30-Day Summary

    private var monthlySummaryCard: some View {
        let snapshot = tracker.snapshot
        return VStack(alignment: .leading, spacing: 12) {
            Text("Last 30 days")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(chrome.text)

            HStack(spacing: 16) {
                summaryMetric(
                    title: "Total time",
                    value: snapshot.monthSeconds.hoursMinutes,
                    icon: "clock.fill",
                    tint: PunkRallyTheme.Accent.primary
                )
                Divider()
                    .frame(height: 32)
                summaryMetric(
                    title: "Active books",
                    value: "\(snapshot.activeBooks30d)",
                    icon: "books.vertical.fill",
                    tint: PunkRallyTheme.Accent.gold
                )
                Divider()
                    .frame(height: 32)
                summaryMetric(
                    title: "Best streak",
                    value: "\(snapshot.longestStreakDays)d",
                    icon: "trophy.fill",
                    tint: PunkRallyTheme.Accent.success
                )
            }
        }
        .padding(PunkRallyTheme.Metric.cardPadding)
        .background(chrome.surface)
        .clipShape(RoundedRectangle(cornerRadius: PunkRallyTheme.Metric.buttonCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: PunkRallyTheme.Metric.buttonCornerRadius)
                .stroke(chrome.border, lineWidth: 1)
        )
    }

    private func summaryMetric(
        title: String,
        value: String,
        icon: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(chrome.textMuted)
                    .lineLimit(1)
            }
            Text(value)
                .font(.headline.weight(.bold).monospacedDigit())
                .foregroundStyle(chrome.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var syncFooter: some View {
        let canRetry = sync.status != .syncing
        return Button {
            guard canRetry else { return }
            Task { await sync.syncNow(reason: "footerRetry") }
        } label: {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: sync.status.footerSymbol)
                        .foregroundStyle(chrome.textFaint)
                    Text(
                        sync.status == .offlineLocalOnly
                            ? "Offline · Retry" : sync.status.footerLabel
                    )
                        .font(.caption)
                        .foregroundStyle(chrome.textFaint)
                }
                if let last = sync.lastSuccessfulSyncAt {
                    Text("Last Stats sync · \(Self.syncTimeFormatter.string(from: last))")
                        .font(.caption2)
                        .foregroundStyle(chrome.textFaint.opacity(0.85))
                } else if sync.status != .syncing {
                    Text("Last Stats sync · Not yet · Tap to retry")
                        .font(.caption2)
                        .foregroundStyle(chrome.textFaint.opacity(0.85))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canRetry)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(sync.status.footerLabel)
        .accessibilityHint(canRetry ? "Retries Stats sync across your devices" : "")
    }

    private static let syncTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
        }
    }
}

extension TimeInterval {
    /// "5h 12m" style
    var hoursMinutes: String {
        let total = Int(self)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }

    /// "42m" / "1h" short form
    var minutesShort: String {
        let total = Int(self)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h" : "\(hours)h"
        }
        return "\(minutes)m"
    }
}
