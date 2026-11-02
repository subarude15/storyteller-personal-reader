import Foundation
import SilveranKit

/// One playable CarPlay row. Platform-free so tab contents can be tested off-device.
public struct CarPlayBrowseItem: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case book(BookID, LocalMediaCategory)
        case podcast(PodcastPlaybackQueueItem)
    }

    public let source: Source
    public let title: String
    public let detail: String?
    /// 0...1 when known.
    public let progress: Double?
    public let lastTouched: Date?
    /// Playable with no network (local book media or downloaded episode audio).
    public let isLocal: Bool

    public init(
        source: Source,
        title: String,
        detail: String?,
        progress: Double?,
        lastTouched: Date?,
        isLocal: Bool,
    ) {
        self.source = source
        self.title = title
        self.detail = detail
        self.progress = progress.map { min(max($0, 0), 1) }
        self.lastTouched = lastTouched
        self.isLocal = isLocal
    }

    public var id: String {
        switch source {
            case .book(let id, let category): return "book:\(category.rawValue):\(id.sourceID)/\(id.uuid)"
            case .podcast(let item): return "pod:\(item.episodeID)"
        }
    }

    public var isPodcast: Bool {
        if case .podcast = source { return true }
        return false
    }

    /// True when this row is the live audio session (resume instead of reopening).
    public func matches(_ kind: AudioSessionKind?) -> Bool {
        switch (source, kind) {
            case (.book(let id, .audio), .audiobook(let live)?): return id == live
            case (.book(let id, .synced), .readaloud(let live)?): return id == live
            case (.podcast(let item), .podcast(let live)?): return item.episodeID == live
            default: return false
        }
    }
}

/// Extra CarPlay Now Playing buttons; transport and skip come from MPRemoteCommandCenter.
public enum CarPlayNowPlayingAction: Equatable, Sendable {
    case rate, chapters, markSpot
}

/// A subscribed show; its episodes are fetched only when the row is opened.
public struct CarPlayPodcastShow: Equatable, Sendable {
    public let feedURL: URL
    public let title: String

    public init(feedURL: URL, title: String) {
        self.feedURL = feedURL
        self.title = title
    }
}

/// Full list behind an "All …" row when a tab's content exceeds its row budget.
public enum CarPlayBrowseOverflow: Equatable, Sendable {
    case recent, audiobooks, upNext, shows, downloaded

    public var title: String {
        switch self {
            case .recent: return "All Recent"
            case .audiobooks: return "All Audiobooks"
            case .upNext: return "All Up Next"
            case .shows: return "All Shows"
            case .downloaded: return "All Downloaded"
        }
    }
}

public enum CarPlayBrowseRow: Equatable, Sendable {
    case item(CarPlayBrowseItem)
    case show(CarPlayPodcastShow)
    case more(CarPlayBrowseOverflow, count: Int)
}

public struct CarPlayBrowseSection: Equatable, Sendable {
    public let header: String?
    public let rows: [CarPlayBrowseRow]
}

public enum CarPlayBrowseTab: CaseIterable, Sendable {
    case continueListening, audiobooks, podcasts, downloaded

    public var title: String {
        switch self {
            case .continueListening: return "Continue"
            case .audiobooks: return "Audiobooks"
            case .podcasts: return "Podcasts"
            case .downloaded: return "Downloaded"
        }
    }

    public var systemImage: String {
        switch self {
            case .continueListening: return "play.circle"
            case .audiobooks: return "books.vertical"
            case .podcasts: return "mic"
            case .downloaded: return "arrow.down.circle"
        }
    }
}

/// Pure tab/section building for the CarPlay browse UI.
public enum CarPlayBrowse {
    /// Driver-distraction cap per list, further limited by the head unit.
    public static let itemCap = 12
    /// Continue shows the resume item plus this many recents.
    public static let continueRecents = 3
    /// Remote skip interval while CarPlay is connected (shared MPRemoteCommandCenter).
    public static let remoteSkipSeconds: TimeInterval = 30
    /// How long the Mark spot button shows a filled pin after a save.
    public static let markedSpotFeedbackSeconds: TimeInterval = 2
    public static let playbackRates: [Double] = [0.75, 1.0, 1.1, 1.2, 1.3, 1.5, 1.75, 2.0, 2.5, 3.0, 5.0]

    /// Mark spot uses the audiobook Previous Positions milestone path only.
    public static func nowPlayingActions(for kind: AudioSessionKind?) -> [CarPlayNowPlayingAction] {
        switch kind {
            case .audiobook?: return [.rate, .chapters, .markSpot]
            case .readaloud?: return [.rate, .chapters]
            case .podcast?, nil: return [.rate]
        }
    }

    public static func upNextEnabled(for kind: AudioSessionKind?) -> Bool {
        if case .podcast? = kind { return true }
        return false
    }

    public static func tabs(maximumTabCount: Int) -> [CarPlayBrowseTab] {
        Array(CarPlayBrowseTab.allCases.prefix(max(1, maximumTabCount)))
    }

    public static func itemLimit(maximumItemCount: Int) -> Int {
        max(1, min(itemCap, maximumItemCount))
    }

    /// Recently touched books and episodes, newest first (also the "All Recent" list).
    public static func orderedRecent(books: [CarPlayBrowseItem], podcasts: [CarPlayBrowseItem]) -> [CarPlayBrowseItem] {
        byRecency(dedupe(books + podcasts))
    }

    /// Storyteller books (audiobook + readaloud): recently played first, then local.
    public static func orderedAudiobooks(_ books: [CarPlayBrowseItem]) -> [CarPlayBrowseItem] {
        dedupe(books).sorted {
            switch ($0.lastTouched, $1.lastTouched) {
                case let (lhs?, rhs?): return lhs > rhs
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return $0.isLocal && !$1.isLocal
            }
        }
    }

    /// Only items that play without a network.
    public static func orderedDownloaded(_ items: [CarPlayBrowseItem]) -> [CarPlayBrowseItem] {
        byRecency(dedupe(items.filter(\.isLocal)))
    }

    public static func orderedUpNext(_ items: [CarPlayBrowseItem]) -> [CarPlayBrowseItem] {
        dedupe(items)
    }

    /// Row for the live session so Continue shows it even before local recents record it.
    /// Podcasts need the playing episode (for its stable fields); nonlocal media stays nonlocal.
    public static func liveItem(
        _ snapshot: AudioSessionSnapshot?,
        episode: PodcastPlaybackQueueItem?,
        episodeIsLocal: Bool,
    ) -> CarPlayBrowseItem? {
        guard let snapshot else { return nil }
        let source: CarPlayBrowseItem.Source
        var podcast: PodcastPlaybackQueueItem?
        switch snapshot.kind {
            case .audiobook(let id): source = .book(id, .audio)
            case .readaloud(let id): source = .book(id, .synced)
            case .podcast(let episodeID):
                guard let episode, episode.episodeID == episodeID else { return nil }
                source = .podcast(episode)
                podcast = episode
        }
        guard let title = snapshot.title ?? podcast?.title, !title.isEmpty else { return nil }
        return CarPlayBrowseItem(
            source: source,
            title: title,
            detail: snapshot.author ?? podcast?.showTitle,
            progress: snapshot.bookProgress,
            lastTouched: nil,
            isLocal: podcast != nil && episodeIsLocal,
        )
    }

    /// Resume item (the live session first, when there is one), then up to three recents;
    /// "All Recent" keeps older history reachable.
    public static func continueSections(
        books: [CarPlayBrowseItem],
        podcasts: [CarPlayBrowseItem],
        live: CarPlayBrowseItem? = nil,
        limit: Int,
    ) -> [CarPlayBrowseSection] {
        var ordered = orderedRecent(books: books, podcasts: podcasts)
        if let live {
            let cached = ordered.first { $0.id == live.id } ?? live
            ordered = [cached] + ordered.filter { $0.id != live.id }
        }
        guard let resume = ordered.first else { return [] }
        let resumeSection = section(nil, [.item(resume)])
        guard limit > 1 else { return resumeSection }
        let rest = ordered.dropFirst().map(CarPlayBrowseRow.item)
        let recentRows: [CarPlayBrowseRow]
        if rest.count <= min(continueRecents, limit - 1) {
            recentRows = rest
        } else {
            let shown = limit - 1 > continueRecents ? continueRecents : limit - 2
            recentRows = Array(rest.prefix(shown)) + [.more(.recent, count: ordered.count)]
        }
        return resumeSection + section("Recent", recentRows)
    }

    public static func audiobookSections(books: [CarPlayBrowseItem], limit: Int) -> [CarPlayBrowseSection] {
        section(nil, paged(orderedAudiobooks(books).map(CarPlayBrowseRow.item), overflow: .audiobooks, limit: limit))
    }

    /// Up Next first, then subscribed shows, sharing one row budget. Shows keep at least
    /// half the rows (when they have that many) so a long queue cannot hide them.
    public static func podcastSections(
        upNext: [CarPlayBrowseItem],
        shows: [CarPlayPodcastShow],
        limit: Int,
    ) -> [CarPlayBrowseSection] {
        let showRows = shows.map(CarPlayBrowseRow.show)
        let reserve = showRows.isEmpty || limit < 2 ? 0 : min(showRows.count, limit / 2)
        let upNextRows = paged(orderedUpNext(upNext).map(CarPlayBrowseRow.item), overflow: .upNext, limit: limit - reserve)
        let shownShows = paged(showRows, overflow: .shows, limit: limit - upNextRows.count)
        return section("Up Next", upNextRows) + section("Shows", shownShows)
    }

    public static func downloadedSections(items: [CarPlayBrowseItem], limit: Int) -> [CarPlayBrowseSection] {
        section(nil, paged(orderedDownloaded(items).map(CarPlayBrowseRow.item), overflow: .downloaded, limit: limit))
    }

    /// `rows` within `limit`; the overflow collapses into one trailing "All …" row.
    public static func paged(_ rows: [CarPlayBrowseRow], overflow: CarPlayBrowseOverflow, limit: Int) -> [CarPlayBrowseRow] {
        guard limit > 0 else { return [] }
        guard rows.count > limit else { return rows }
        return Array(rows.prefix(limit - 1)) + [.more(overflow, count: rows.count)]
    }

    /// Long lists page in place (Prev/Next bar buttons) at `limit` rows per page.
    public static func pageCount(count: Int, limit: Int) -> Int {
        let limit = max(1, limit)
        return max(1, (max(count, 0) + limit - 1) / limit)
    }

    /// Rows on page `index`, clamped to the valid pages.
    public static func pageRange(_ index: Int, count: Int, limit: Int) -> Range<Int> {
        let limit = max(1, limit)
        let page = clampedPage(index, count: count, limit: limit)
        return (page * limit)..<min(max(count, 0), (page + 1) * limit)
    }

    public static func clampedPage(_ index: Int, count: Int, limit: Int) -> Int {
        min(max(index, 0), pageCount(count: count, limit: limit) - 1)
    }

    /// Page that shows `row` (e.g. the current chapter); page 0 when unknown.
    public static func page(containing row: Int?, count: Int, limit: Int) -> Int {
        clampedPage((row ?? 0) / max(1, limit), count: count, limit: limit)
    }

    /// Storyteller `position.updatedAt` (ISO 8601, with or without fractional seconds).
    public static func date(fromISO8601 string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func section(_ header: String?, _ rows: [CarPlayBrowseRow]) -> [CarPlayBrowseSection] {
        rows.isEmpty ? [] : [CarPlayBrowseSection(header: header, rows: rows)]
    }

    private static func byRecency(_ items: [CarPlayBrowseItem]) -> [CarPlayBrowseItem] {
        items.enumerated().sorted {
            let lhs = $0.element.lastTouched ?? .distantPast
            let rhs = $1.element.lastTouched ?? .distantPast
            return lhs != rhs ? lhs > rhs : $0.offset < $1.offset
        }.map(\.element)
    }

    private static func dedupe(_ items: [CarPlayBrowseItem]) -> [CarPlayBrowseItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }
}
