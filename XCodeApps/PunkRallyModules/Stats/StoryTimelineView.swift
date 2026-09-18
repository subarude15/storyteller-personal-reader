//
//  StoryTimelineView.swift
//  ink+amp
//
//  Stats → Timeline segment: a day-grouped history of what Josh has actually
//  read and listened to (owned library books + podcasts), newest first.
//
//  Reuses SessionTracker's local ledger (offline-safe); each beat resolves
//  back to a library book or podcast so tapping Continues in that medium via
//  the same player/reader host as Home long-press — no new player stack.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI
import SilveranKit
import SilveranAppleKit

/// Normalized medium for a timeline beat (chip label + continue category).
enum TimelineMedium: String {
    case ebook
    case audiobook
    case readaloud
    case podcast

    var badge: PunkRallyTheme.KindBadgeType {
        switch self {
            case .ebook: return .ebook
            case .audiobook: return .audiobook
            case .readaloud: return .readaloud
            case .podcast: return .podcast
        }
    }

    /// Book category to Continue in (nil for podcasts).
    var category: LocalMediaCategory? {
        switch self {
            case .ebook: return .ebook
            case .audiobook: return .audio
            case .readaloud: return .synced
            case .podcast: return nil
        }
    }

    static func resolve(for session: PRMediaSession) -> TimelineMedium {
        if let medium = session.medium, let resolved = TimelineMedium(rawValue: medium) {
            return resolved
        }
        // Legacy sessions (recorded before medium capture): infer.
        if session.mediaID.hasPrefix("podcast/") { return .podcast }
        return session.kind == .reading ? .ebook : .audiobook
    }
}

/// Day-grouped reading/listening history under Stats.
struct StoryTimelineView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel?
    @State private var tracker = SessionTracker.shared
    @State private var tick = 0

    private var chrome: PunkRallyTheme.Chrome {
        PunkRallyTheme.Chrome(scheme: colorScheme)
    }

    var body: some View {
        let _ = tracker.revision
        let _ = tick
        let sections = daySections
        if sections.isEmpty {
            emptyState
        } else {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(sections) { section in
                    daySection(section)
                }
            }
        }
    }

    // MARK: - Empty / offline

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 32))
                .foregroundStyle(chrome.textFaint)
            Text("Sessions show up here as you read and listen.")
                .font(.subheadline)
                .foregroundStyle(chrome.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, PunkRallyTheme.Metric.screenInset)
    }

    // MARK: - Day sections

    private struct DaySection: Identifiable {
        let id: Date
        let day: Date
        let beats: [TimelineBeat]
    }

    @MainActor
    private var daySections: [DaySection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: beats) {
            calendar.startOfDay(for: $0.session.endedAt)
        }
        return grouped
            .map { DaySection(id: $0.key, day: $0.key, beats: $0.value.sorted { $0.session.endedAt > $1.session.endedAt }) }
            .sorted { $0.day > $1.day }
    }

    /// Resolved beats for every recorded session, newest first.
    @MainActor
    private var beats: [TimelineBeat] {
        let resolver = TimelineBeatResolver(mediaViewModel: mediaViewModel)
        let sessions = tracker.allSessions.sorted { $0.endedAt > $1.endedAt }
        return sessions.map { session in
            TimelineBeat(
                id: session.id.uuidString,
                session: session,
                source: resolver.resolve(session)
            )
        }
    }

    // MARK: - Section / rows

    private func daySection(_ section: DaySection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.dayLabel(section.day))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(chrome.text)
            VStack(spacing: 0) {
                ForEach(section.beats) { beat in
                    TimelineBeatRow(
                        beat: beat,
                        chrome: chrome,
                        scheme: colorScheme,
                        onContinue: { await continueBeat(beat) }
                    )
                    if beat.id != section.beats.last?.id {
                        Divider()
                            .overlay(chrome.border)
                            .padding(.leading, 52)
                    }
                }
            }
            .background(chrome.surface)
            .clipShape(RoundedRectangle(cornerRadius: PunkRallyTheme.Metric.buttonCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: PunkRallyTheme.Metric.buttonCornerRadius)
                    .stroke(chrome.border, lineWidth: 1)
            )
        }
    }

    private static func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: day)
    }

    // MARK: - Continue

    @MainActor
    private func continueBeat(_ beat: TimelineBeat) async {
        switch beat.source {
            case .book(let book, let category):
                guard let vm = mediaViewModel else { return }
                await PunkRallyPlayerHost.open(book, mediaViewModel: vm, category: category)
            case .podcast(let entry):
                await openPodcast(entry)
            case nil:
                break
        }
    }

    @MainActor
    private func openPodcast(_ entry: PodcastRecentEntry) async {
        var userInfo: [String: Any] = [
            "episodeID": entry.episodeID,
            "title": entry.title,
            "audioURL": entry.audioURL,
            "mediaKind": entry.mediaKind.rawValue,
        ]
        userInfo["showTitle"] = entry.showTitle
        if let duration = entry.durationSeconds {
            userInfo["durationSeconds"] = duration
        }
        if let cover = entry.coverURL {
            userInfo["coverURL"] = cover
        }
        if let feed = entry.feedURL {
            userInfo["feedURL"] = feed
        }
        NotificationCenter.default.post(
            name: .punkRallyPlayPodcastEpisode,
            object: nil,
            userInfo: userInfo
        )
    }
}

// MARK: - Beat

/// One history row: session + the book/podcast it resolves to for Continue.
private struct TimelineBeat: Identifiable {
    enum Source {
        case book(BookMetadata, category: LocalMediaCategory)
        case podcast(PodcastRecentEntry)
    }

    let id: String
    let session: PRMediaSession
    let source: Source?
}

/// Resolves a session's `mediaID` back to a book/podcast for cover + Continue.
/// Built once per render so dictionary lookups are cheap.
@MainActor
private struct TimelineBeatResolver {
    let booksByID: [String: BookMetadata]
    let podcastsByID: [String: PodcastRecentEntry]

    init(mediaViewModel: MediaViewModel?) {
        var books: [String: BookMetadata] = [:]
        for book in mediaViewModel?.library.bookMetaData ?? [] {
            books[book.id.description] = book
        }
        self.booksByID = books

        var podcasts: [String: PodcastRecentEntry] = [:]
        for entry in PodcastRecentStore.shared.all() {
            podcasts[entry.episodeID] = entry
        }
        // Downloaded plays not in the recent store (older ledger).
        for record in PodcastDownloadStore.shared.allDownloads() {
            guard podcasts[record.episodeID] == nil, let remote = record.remoteAudioURL else { continue }
            podcasts[record.episodeID] = PodcastRecentEntry(
                episodeID: record.episodeID,
                title: record.title,
                showTitle: record.showTitle,
                coverURL: nil,
                audioURL: remote,
                durationSeconds: record.durationSeconds,
                feedURL: record.feedURL,
                mediaKind: .audio,
                lastTouched: record.lastPlayedAt ?? .distantPast,
                progress: record.progress
            )
        }
        self.podcastsByID = podcasts
    }

    func resolve(_ session: PRMediaSession) -> TimelineBeat.Source? {
        let medium = TimelineMedium.resolve(for: session)
        if medium == .podcast {
            let episodeID = String(session.mediaID.dropFirst("podcast/".count))
            if let entry = podcastsByID[episodeID] {
                return .podcast(entry)
            }
            return nil
        }
        guard let category = medium.category,
            let book = booksByID[session.mediaID]
        else { return nil }
        return .book(book, category: category)
    }
}

// MARK: - Row

private struct TimelineBeatRow: View {
    let beat: TimelineBeat
    let chrome: PunkRallyTheme.Chrome
    let scheme: ColorScheme
    let onContinue: @MainActor () async -> Void
    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel?

    private var medium: TimelineMedium { TimelineMedium.resolve(for: beat.session) }

    var body: some View {
        Button {
            Task { await onContinue() }
        } label: {
            HStack(spacing: 12) {
                TimelineCoverView(beat: beat, size: CGSize(width: 40, height: 56))
                VStack(alignment: .leading, spacing: 4) {
                    Text(beat.session.mediaTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(chrome.text)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        KindBadgeView(kind: medium.badge, scheme: scheme)
                        Text(timeAndProgressLine)
                            .font(.caption)
                            .foregroundStyle(chrome.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(beat.source == nil)
        .opacity(beat.source == nil ? 0.55 : 1)
    }

    /// e.g. "8:42 PM · 32 min" (+ " · 63%" when a progress was recorded).
    private var timeAndProgressLine: String {
        var parts: [String] = []
        parts.append(Self.timeFormatter.string(from: beat.session.endedAt))
        parts.append(beat.session.durationSeconds.durationLine)
        if let progress = beat.session.endProgress, progress > 0.01 {
            parts.append("\(Int((progress * 100).rounded()))%")
        }
        return parts.joined(separator: " · ")
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}

// MARK: - Cover

private struct TimelineCoverView: View {
    let beat: TimelineBeat
    let size: CGSize
    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel?
    @State private var bookImage: Image?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(white: 0.12))
            switch beat.source {
                case .book(let book, _):
                    if let bookImage {
                        bookImage
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "book.closed.fill")
                            .foregroundStyle(Color.white.opacity(0.72))
                            .task(id: book.id) { await loadBookCover(book) }
                    }
                case .podcast(let entry):
                    if let url = entry.coverURL {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFill()
                            } else {
                                placeholder
                            }
                        }
                    } else {
                        placeholder
                    }
                case nil:
                    Image(systemName: "questionmark")
                        .foregroundStyle(Color.white.opacity(0.72))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var placeholder: some View {
        ZStack {
            Color(white: 0.2)
            Image(systemName: "mic.fill")
                .foregroundStyle(Color.white.opacity(0.72))
        }
    }

    private func loadBookCover(_ book: BookMetadata) async {
        guard let vm = mediaViewModel else { return }
        vm.ensureCoverLoaded(for: book, debugSource: "Timeline")
        vm.ensureCoverLoaded(for: book, variant: .audioSquare, debugSource: "Timeline")
        for _ in 0..<25 {
            if let image = vm.coverImage(for: book)
                ?? vm.coverImage(for: book, variant: .audioSquare)
                ?? vm.coverImage(for: book, variant: .standard)
            {
                bookImage = image
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}

// MARK: - Formatting

extension TimeInterval {
    /// "32 min" / "1h 5m"
    var durationLine: String {
        let total = Int(self)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(max(minutes, 1)) min"
    }
}
