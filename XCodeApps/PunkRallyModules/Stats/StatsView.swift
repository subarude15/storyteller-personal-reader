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

/// Stats tab — reading/listening time, streak, finished count, average session.
struct StatsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var tracker = SessionTracker.shared
    @State private var sync = StatsSyncCoordinator.shared
    @State private var motivation = ReadingMotivationStore.shared
    @State private var weekOffset = 0
    @State private var tick = 0

    private var chrome: PunkRallyTheme.Chrome {
        PunkRallyTheme.Chrome(scheme: colorScheme)
    }

    var body: some View {
        let _ = tracker.revision
        let _ = sync.revision
        let _ = tick
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    heroCard
                    dailyGoalsCard
                    pinnedStatsCard
                    streakAndFinishedRow
                    Text("Streaks use local calendar days with recorded activity; the current streak can carry through yesterday until today's activity is recorded.")
                        .font(.caption)
                        .foregroundStyle(chrome.textFaint)
                    weekChart
                    weeklyReceiptCard
                    syncFooter
                }
                .padding(.horizontal, PunkRallyTheme.Metric.screenInset)
                .padding(.vertical, 12)
            }
            .background(chrome.bg)
            .navigationTitle("Stats")
        }
        .task {
            tracker.pruneOldSessions()
            await sync.syncNow(reason: "statsAppear")
            await motivation.refreshNotifications()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await sync.syncNow(reason: "foreground") }
                Task { await motivation.refreshNotifications() }
            }
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            // Live active-session seconds — revision may be unchanged while elapsed grows.
            tick &+= 1
        }
    }

    private var dailyGoalsCard: some View {
        let _ = tracker.revision
        let day = motivation.today
        return VStack(alignment: .leading, spacing: 14) {
            Text("Today's goals")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(chrome.text)
            goalRow(
                "Reading",
                seconds: day.readingSeconds,
                goalMinutes: motivation.settings.dailyReadingGoalMinutes,
                tint: PunkRallyTheme.Accent.gold
            )
            goalRow(
                "Listening",
                seconds: day.listeningSeconds,
                goalMinutes: motivation.settings.dailyListeningGoalMinutes,
                tint: PunkRallyTheme.Accent.primary
            )
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

    private func goalRow(
        _ title: String,
        seconds: TimeInterval,
        goalMinutes: Int,
        tint: Color
    ) -> some View {
        let target = Double(goalMinutes) * 60
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .foregroundStyle(chrome.text)
                Spacer()
                Text(seconds.minutesShort + " / " + String(goalMinutes) + " min")
                    .foregroundStyle(chrome.textMuted)
                    .monospacedDigit()
            }
            ProgressView(value: min(max(seconds / target, 0), 1))
                .tint(tint)
        }
        .font(.subheadline)
    }

    private var pinnedStatsCard: some View {
        let _ = motivation.revision
        return VStack(alignment: .leading, spacing: 10) {
            Text("Pinned stats")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(chrome.text)
            if motivation.settings.pinnedStats.isEmpty {
                Text("No stats pinned. Choose up to three in Home settings → Reading motivation.")
                    .font(.caption)
                    .foregroundStyle(chrome.textMuted)
            } else {
                ForEach(motivation.settings.pinnedStats, id: \.self) { stat in
                    HStack {
                        Text(stat.label)
                            .foregroundStyle(chrome.textMuted)
                        Spacer()
                        Text(motivation.value(for: stat))
                            .fontWeight(.semibold)
                            .foregroundStyle(chrome.text)
                            .monospacedDigit()
                    }
                    .font(.subheadline)
                }
            }
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

    // MARK: - Hero

    private var heroCard: some View {
        let snapshot = tracker.snapshot
        let receipt = motivation.weeklyReceipt()
        return VStack(alignment: .leading, spacing: 12) {
            Text("This week")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(chrome.textMuted)

            Text(snapshot.weekSeconds.hoursMinutes)
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(chrome.text)

            HStack(spacing: 16) {
                legendDot(
                    color: PunkRallyTheme.Accent.primary,
                    label: "Listen \(receipt.listeningSeconds.minutesShort)"
                )
                legendDot(
                    color: PunkRallyTheme.Accent.gold,
                    label: "Read \(receipt.readingSeconds.minutesShort)"
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

    private var statPods: [StatPod] {
        let s = tracker.snapshot
        return [
            StatPod(value: "\(s.streakDays)", label: "Day streak",
                    symbol: "flame.fill", tint: PunkRallyTheme.Accent.primary),
            StatPod(value: "\(s.finishedBooks30d)", label: "Finished · 30d",
                    symbol: "checkmark.seal.fill", tint: PunkRallyTheme.Accent.success),
            StatPod(value: s.averageSessionSeconds == 0
                    ? "–" : s.averageSessionSeconds.minutesShort,
                    label: "Avg session", symbol: "timer", tint: PunkRallyTheme.Accent.gold),
        ]
    }

    private struct StatPod: Identifiable {
        let value: String
        let label: String
        let symbol: String
        let tint: Color
        var id: String { label }
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
            Text("Last 7 days")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(chrome.text)

            HStack(alignment: .bottom, spacing: 8) {
                ForEach(snapshot.recentDays) { day in
                    VStack(spacing: 4) {
                        if day.totalSeconds > 0 {
                            Text(day.totalSeconds.minutesShort)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(chrome.textFaint)
                        }
                        RoundedRectangle(cornerRadius: 3)
                            .fill(barColor(for: day))
                            .frame(
                                height: barHeight(day.totalSeconds, max: maxSeconds)
                            )
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

    private func barHeight(_ seconds: TimeInterval, max maxVal: TimeInterval) -> CGFloat {
        guard maxVal > 0 else { return 4 }
        return Swift.max(4, 100 * seconds / maxVal)
    }

    private func barColor(for day: PRDailyAggregate) -> Color {
        if day.readSeconds > day.listenSeconds {
            return PunkRallyTheme.Accent.gold
        }
        return PunkRallyTheme.Accent.primary
    }

    private var weeklyReceiptCard: some View {
        let receipt = motivation.weeklyReceipt(offset: weekOffset)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let minuteLabel = receipt.minutes.map {
            $0 == 0 ? "Under 1 min" : String($0) + " min"
        } ?? "Time unavailable"
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(weekOffset == 0 ? "This week's receipt" : "Previous week's receipt")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(chrome.text)
                Spacer()
                Button {
                    weekOffset = -1
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(weekOffset < 0)
                Button {
                    weekOffset = 0
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(weekOffset == 0)
            }
            Text("Week of " + formatter.string(from: receipt.weekStart))
                .font(.caption)
                .foregroundStyle(chrome.textMuted)
            if receipt.seconds == 0 && receipt.completedTitles == 0 {
                Text("No reading or listening recorded this week.")
                    .font(.subheadline)
                    .foregroundStyle(chrome.textMuted)
            } else {
                receiptRow("Reading and listening", value: minuteLabel)
                receiptRow("Activity days", value: String(receipt.activityDays) + " / 7")
                receiptRow("Titles finished", value: String(receipt.completedTitles))
                receiptRow(
                    "Streak at week end",
                    value: receipt.streakDays == 0 ? "No active streak" : String(receipt.streakDays) + " days"
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

    private func receiptRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(chrome.textMuted)
            Spacer()
            Text(value)
                .foregroundStyle(chrome.text)
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .font(.subheadline)
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
