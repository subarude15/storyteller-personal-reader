//
//  StatsView.swift
//  punk+rally
//
//  Ported from Enve Book Player (AGPL-3.0-only):
//  https://github.com/opisaac9001/Enve-Book-Player
//  Original: ios/enve/Screens/Journal/JournalScreen.swift + JournalStatsComponents.swift
//  Modifications: local aggregates only; punk+rally tokens; 7-day bar chart.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

/// Stats tab — reading/listening time, streak, finished count, average session.
struct StatsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var tracker = SessionTracker.shared

    private var chrome: PunkRallyTheme.Chrome {
        PunkRallyTheme.Chrome(scheme: colorScheme)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    heroCard
                    streakAndFinishedRow
                    weekChart
                    privacyFooter
                }
                .padding(.horizontal, PunkRallyTheme.Metric.screenInset)
                .padding(.vertical, 12)
            }
            .background(chrome.bg)
            .navigationTitle("Stats")
        }
        .task {
            tracker.pruneOldSessions()
        }
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
                legendDot(color: PunkRallyTheme.Accent.primary, label: "Listen")
                legendDot(color: PunkRallyTheme.Accent.gold, label: "Read")
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

    private func barHeight(_ seconds: TimeInterval, max: TimeInterval) -> CGFloat {
        guard max > 0 else { return 4 }
        return max(4, 100 * seconds / max)
    }

    private func barColor(for day: PRDailyAggregate) -> Color {
        if day.readSeconds > day.listenSeconds {
            return PunkRallyTheme.Accent.gold
        }
        return PunkRallyTheme.Accent.primary
    }

    // MARK: - Footer

    private var privacyFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(chrome.textFaint)
            Text("Stats stay on this iPhone")
                .font(.caption)
                .foregroundStyle(chrome.textFaint)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

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