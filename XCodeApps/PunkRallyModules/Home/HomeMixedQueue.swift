//
//  HomeMixedQueue.swift
//  ink+amp
//
//  One last-touched queue mixing Storyteller books and RSS podcasts for Home.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranAppleKit
import SilveranKit

/// A single Home Continue / Up next row (book or podcast).
public enum HomeMixedItem: Identifiable, Equatable, Sendable {
    case book(BookMetadata, lastTouched: Date, progress: Double, badge: PunkRallyTheme.KindBadgeType)
    case podcast(PodcastRecentEntry)

    public var id: String {
        switch self {
            case .book(let book, _, _, _):
                return "book:\(book.id.sourceID)/\(book.id.uuid)"
            case .podcast(let entry):
                return "pod:\(entry.episodeID)"
        }
    }

    public var lastTouched: Date {
        switch self {
            case .book(_, let date, _, _): return date
            case .podcast(let entry): return entry.lastTouched
        }
    }

    public var title: String {
        switch self {
            case .book(let book, _, _, _): return book.title
            case .podcast(let entry): return entry.title
        }
    }

    public var subtitle: String? {
        switch self {
            case .book(let book, _, _, _):
                return book.authors?.first?.name
            case .podcast(let entry):
                return entry.showTitle
        }
    }

    public var progress: Double {
        switch self {
            case .book(_, _, let progress, _): return progress
            case .podcast(let entry): return entry.progress
        }
    }

    /// Duration for finishability copy (audiobook/readaloud/ebook duration or podcast length).
    public var durationSeconds: TimeInterval? {
        switch self {
            case .book(let book, _, _, _):
                return book.durationValue
            case .podcast(let entry):
                return entry.durationSeconds
        }
    }

    public var finishabilityLabel: String? {
        PlaybackFinishabilityCopy.label(progress: progress, durationSeconds: durationSeconds)
    }

    public var badge: PunkRallyTheme.KindBadgeType {
        switch self {
            case .book(_, _, _, let badge): return badge
            case .podcast: return .podcast
        }
    }
}

public enum HomeMixedQueue {
    /// Continue = first; Up next = following (up to `upNextLimit`).
    public static func build(
        books: [BookMetadata],
        progress: [BookID: BookProgress],
        preferredCategory: (BookMetadata) -> LocalMediaCategory?,
        podcastRecents: [PodcastRecentEntry],
        podcastDownloads: [PodcastDownloadRecord],
        bookLocalTouches: [BookID: Date] = [:],
        upNextLimit: Int = 5
    ) -> (continueItem: HomeMixedItem?, upNext: [HomeMixedItem]) {
        var items: [HomeMixedItem] = []

        for book in books {
            let bp = progress[book.id]
            let fraction = bp?.progressFraction ?? book.progress
            guard fraction > 0.001, fraction < 0.995 else { continue }
            let ms = bp?.timestamp ?? book.position?.timestamp
            let progressDate: Date
            if let ms, ms > 0 {
                // Storyteller / PSA timestamps are unix milliseconds.
                progressDate = Date(timeIntervalSince1970: ms / 1000)
            } else {
                progressDate = .distantPast
            }
            let localDate = bookLocalTouches[book.id] ?? .distantPast
            let date = max(progressDate, localDate)
            // Skip books we have never actually touched and that lack a progress ts —
            // they would otherwise float as distantPast noise under real activity.
            guard date > .distantPast else { continue }
            items.append(
                .book(
                    book,
                    lastTouched: date,
                    progress: fraction,
                    badge: badge(for: book, preferred: preferredCategory(book))
                )
            )
        }

        var seenPodcasts = Set<String>()
        for entry in podcastRecents {
            var recent = entry
            recent.progress = Self.effectivePodcastProgress(for: recent)
            guard recent.progress < 0.995 else { continue }
            seenPodcasts.insert(recent.episodeID)
            items.append(.podcast(recent))
        }

        // Downloaded plays not yet in the recent store (e.g. older ledger).
        for record in podcastDownloads {
            guard !seenPodcasts.contains(record.episodeID) else { continue }
            guard let lastPlayed = record.lastPlayedAt else { continue }
            guard record.progress < 0.995 else { continue }
            guard let remote = record.remoteAudioURL else { continue }
            let entry = PodcastRecentEntry(
                episodeID: record.episodeID,
                title: record.title,
                showTitle: record.showTitle,
                coverURL: nil,
                audioURL: remote,
                durationSeconds: record.durationSeconds,
                feedURL: record.feedURL,
                mediaKind: .audio,
                lastTouched: lastPlayed,
                progress: record.progress
            )
            items.append(.podcast(entry))
        }

        items.sort { $0.lastTouched > $1.lastTouched }
        // De-dupe books that might appear twice (shouldn't, but keep stable).
        var seen = Set<String>()
        items = items.filter { seen.insert($0.id).inserted }

        let continueItem = items.first
        let upNext = Array(items.dropFirst().prefix(max(0, upNextLimit)))
        return (continueItem, upNext)
    }

    private static func badge(
        for book: BookMetadata,
        preferred: LocalMediaCategory?
    ) -> PunkRallyTheme.KindBadgeType {
        switch preferred {
            case .synced:
                return .readaloud
            case .audio:
                return .audiobook
            case .ebook, .none:
                if book.hasAvailableReadaloud { return .readaloud }
                if book.hasAvailableAudiobook, !book.hasAvailableEbook { return .audiobook }
                return .ebook
        }
    }

    /// Prefer YouTube video-id playhead, then episode playhead, then stored recent.
    private static func effectivePodcastProgress(for entry: PodcastRecentEntry) -> Double {
        let watch =
            entry.youtubeURL
            ?? PodcastMatchedYouTubeStore.shared.watchURL(for: entry.episodeID)
        if let watch,
            let videoID = PodcastYouTubeURL.videoID(from: watch),
            let yt = YouTubePlayheadStore.shared.entry(for: videoID)
        {
            return yt.progress
        }
        if let playhead = PodcastPlayheadStore.shared.entry(for: entry.episodeID) {
            return playhead.progress
        }
        return entry.progress
    }
}
