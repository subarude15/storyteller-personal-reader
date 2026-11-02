import Foundation
import SilveranAppleKit
import SilveranKit
import Testing

@Suite("CarPlay browse model")
struct CarPlayBrowseTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func book(
        _ name: String,
        _ category: LocalMediaCategory = .audio,
        touched: TimeInterval? = nil,
        progress: Double? = nil,
    ) -> CarPlayBrowseItem {
        CarPlayBrowseItem(
            source: .book(BookID(sourceID: "src", uuid: name), category),
            title: name,
            detail: nil,
            progress: progress,
            lastTouched: touched.map { t0.addingTimeInterval($0) },
            isLocal: true,
        )
    }

    private func episode(_ id: String, touched: TimeInterval? = nil, local: Bool = false) -> CarPlayBrowseItem {
        CarPlayBrowseItem(
            source: .podcast(
                PodcastPlaybackQueueItem(episodeID: id, title: id, audioURL: URL(string: "https://example.com/\(id).mp3")!)
            ),
            title: id,
            detail: nil,
            progress: nil,
            lastTouched: touched.map { t0.addingTimeInterval($0) },
            isLocal: local,
        )
    }

    private func show(_ name: String) -> CarPlayPodcastShow {
        CarPlayPodcastShow(feedURL: URL(string: "https://example.com/\(name).xml")!, title: name)
    }

    private func titles(_ sections: [CarPlayBrowseSection]) -> [[String]] {
        sections.map { section in
            section.rows.map { row in
                switch row {
                    case .item(let item): return item.title
                    case .show(let show): return "show:\(show.title)"
                    case .more(let overflow, let count): return "\(overflow.title) (\(count))"
                }
            }
        }
    }

    private func rowCount(_ sections: [CarPlayBrowseSection]) -> Int {
        sections.reduce(0) { $0 + $1.rows.count }
    }

    @Test func tabsFollowSpecOrderAndHeadUnitLimit() {
        #expect(CarPlayBrowse.tabs(maximumTabCount: 5) == [.continueListening, .audiobooks, .podcasts, .downloaded])
        #expect(CarPlayBrowse.tabs(maximumTabCount: 2) == [.continueListening, .audiobooks])
        #expect(CarPlayBrowse.tabs(maximumTabCount: 0) == [.continueListening])
        #expect(CarPlayBrowseTab.allCases.map(\.systemImage) == ["play.circle", "books.vertical", "mic", "arrow.down.circle"])
    }

    @Test func itemLimitCapsAtTwelveAndHeadUnit() {
        #expect(CarPlayBrowse.itemLimit(maximumItemCount: 100) == 12)
        #expect(CarPlayBrowse.itemLimit(maximumItemCount: 8) == 8)
        #expect(CarPlayBrowse.itemLimit(maximumItemCount: 0) == 1)
    }

    @Test func continueShowsResumeThenThreeRecents() {
        let sections = CarPlayBrowse.continueSections(
            books: [book("old", touched: 1), book("newest", touched: 50), book("mid", touched: 20)],
            podcasts: [episode("ep", touched: 30), episode("ep2", touched: 10)],
            limit: 12,
        )
        #expect(titles(sections) == [["newest"], ["ep", "mid", "ep2", "All Recent (5)"]])
        #expect(sections.last?.header == "Recent")
        #expect(CarPlayBrowse.continueSections(books: [], podcasts: [], limit: 12).isEmpty)
        #expect(titles(CarPlayBrowse.continueSections(books: [book("only")], podcasts: [], limit: 12)) == [["only"]])
        let exact = CarPlayBrowse.continueSections(
            books: [book("a", touched: 4), book("b", touched: 3), book("c", touched: 2), book("d", touched: 1)],
            podcasts: [],
            limit: 12,
        )
        #expect(titles(exact) == [["a"], ["b", "c", "d"]])
        // Tight head unit: overflow row still fits inside the limit.
        let tight = CarPlayBrowse.continueSections(
            books: [book("a", touched: 4), book("b", touched: 3), book("c", touched: 2), book("d", touched: 1)],
            podcasts: [],
            limit: 3,
        )
        #expect(titles(tight) == [["a"], ["b", "All Recent (4)"]])
    }

    private func snapshot(_ kind: AudioSessionKind, title: String? = "Live") -> AudioSessionSnapshot {
        AudioSessionSnapshot(
            kind: kind,
            title: title,
            author: "Author",
            isPlaying: true,
            chapterLabel: nil,
            bookProgress: 0.4,
            playbackRate: 1,
        )
    }

    @Test func continueLeadsWithLiveSessionMissingFromRecents() {
        let liveBook = CarPlayBrowse.liveItem(
            snapshot(.audiobook(BookID(sourceID: "src", uuid: "live"))),
            episode: nil,
            episodeIsLocal: true,
        )
        #expect(liveBook?.isLocal == false, "uncached live book is not downloaded")
        #expect(liveBook?.progress == 0.4)
        let recents = [book("a", touched: 4), book("b", touched: 3), book("c", touched: 2)]
        #expect(
            titles(CarPlayBrowse.continueSections(books: recents, podcasts: [], live: liveBook, limit: 12))
                == [["Live"], ["a", "b", "c"]]
        )
        // Already cached: the cached row moves to the front once, no duplicate.
        let cachedLive = CarPlayBrowse.continueSections(
            books: recents,
            podcasts: [],
            live: book("b", touched: 3),
            limit: 12,
        )
        #expect(titles(cachedLive) == [["b"], ["a", "c"]])

        let playing = PodcastPlaybackQueueItem(episodeID: "ep", title: "Episode", audioURL: URL(string: "https://example.com/ep.mp3")!)
        let livePodcast = CarPlayBrowse.liveItem(snapshot(.podcast("ep"), title: nil), episode: playing, episodeIsLocal: false)
        #expect(livePodcast?.title == "Episode")
        #expect(livePodcast?.isLocal == false)
        #expect(livePodcast?.matches(.podcast("ep")) == true)
        #expect(CarPlayBrowse.liveItem(snapshot(.podcast("other")), episode: playing, episodeIsLocal: true) == nil)
        #expect(CarPlayBrowse.liveItem(nil, episode: playing, episodeIsLocal: true) == nil)
    }

    @Test func audiobooksRecentFirstThenLocal() {
        let remote = CarPlayBrowseItem(
            source: .book(BookID(sourceID: "src", uuid: "remote"), .audio),
            title: "remote",
            detail: nil,
            progress: nil,
            lastTouched: nil,
            isLocal: false,
        )
        let sections = CarPlayBrowse.audiobookSections(
            books: [remote, book("untouched"), book("a", touched: 5), book("b", touched: 9)],
            limit: 3,
        )
        #expect(titles(sections) == [["b", "a", "All Audiobooks (4)"]])
        let all = CarPlayBrowse.audiobookSections(books: [book("x", touched: 1), book("y", touched: 2)], limit: 3)
        #expect(titles(all) == [["y", "x"]])
        #expect(CarPlayBrowse.orderedAudiobooks([remote, book("untouched"), book("a", touched: 5)]).map(\.title)
            == ["a", "untouched", "remote"])
    }

    @Test func podcastsUpNextThenShowsWithinOneBudget() {
        let upNext = (1...20).map { episode("q\($0)") }
        let shows = (1...20).map { show("s\($0)") }
        let both = CarPlayBrowse.podcastSections(upNext: upNext + [episode("q1")], shows: shows, limit: 12)
        #expect(both.map(\.header) == ["Up Next", "Shows"])
        #expect(rowCount(both) == 12)
        #expect(titles(both)[0].last == "All Up Next (20)")
        #expect(titles(both)[1].last == "All Shows (20)")

        // Short queue: shows take the remaining rows.
        let short = CarPlayBrowse.podcastSections(upNext: [episode("q1"), episode("q2")], shows: shows, limit: 12)
        #expect(titles(short)[0] == ["q1", "q2"])
        #expect(titles(short)[1].count == 10)
        #expect(rowCount(short) == 12)

        // Few shows keep all their rows even with a long queue.
        let few = CarPlayBrowse.podcastSections(upNext: upNext, shows: [show("a"), show("b")], limit: 12)
        #expect(titles(few)[1] == ["show:a", "show:b"])
        #expect(rowCount(few) == 12)

        #expect(titles(CarPlayBrowse.podcastSections(upNext: [], shows: [show("a")], limit: 12)) == [["show:a"]])
        #expect(CarPlayBrowse.podcastSections(upNext: [], shows: [], limit: 12).isEmpty)
    }

    @Test func downloadedOnlyLocal() {
        let sections = CarPlayBrowse.downloadedSections(
            items: [episode("stream"), episode("saved", touched: 3, local: true), book("book", touched: 1)],
            limit: 12,
        )
        #expect(titles(sections) == [["saved", "book"]])
        #expect(CarPlayBrowse.downloadedSections(items: [episode("stream")], limit: 12).isEmpty)
        let many = (1...30).map { book("b\($0)", touched: TimeInterval($0)) }
        let paged = CarPlayBrowse.downloadedSections(items: many, limit: 12)
        #expect(rowCount(paged) == 12)
        #expect(titles(paged)[0].last == "All Downloaded (30)")
        #expect(CarPlayBrowse.orderedDownloaded(many).count == 30)
    }

    @Test func pagesKeepEveryRowReachableWithinLimit() {
        #expect(CarPlayBrowse.pageCount(count: 0, limit: 12) == 1)
        #expect(CarPlayBrowse.pageRange(0, count: 0, limit: 12) == 0..<0)
        #expect(CarPlayBrowse.pageCount(count: 12, limit: 12) == 1)
        #expect(CarPlayBrowse.pageCount(count: 13, limit: 12) == 2)
        #expect(CarPlayBrowse.pageRange(1, count: 13, limit: 12) == 12..<13)
        #expect(CarPlayBrowse.pageRange(-3, count: 30, limit: 12) == 0..<12)
        #expect(CarPlayBrowse.pageRange(99, count: 30, limit: 12) == 24..<30)
        for count in [1, 11, 12, 13, 50, 145, 2000] {
            let pages = (0..<CarPlayBrowse.pageCount(count: count, limit: 12)).map {
                CarPlayBrowse.pageRange($0, count: count, limit: 12)
            }
            #expect(pages.allSatisfy { $0.count <= 12 && !$0.isEmpty })
            #expect(pages.reduce(0) { $0 + $1.count } == count)
            #expect(zip(pages, pages.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
        }
        // Chapters open on the page holding the current chapter.
        #expect(CarPlayBrowse.page(containing: 30, count: 80, limit: 12) == 2)
        #expect(CarPlayBrowse.page(containing: nil, count: 80, limit: 12) == 0)
        #expect(CarPlayBrowse.page(containing: 500, count: 80, limit: 12) == 6)
    }

    @Test func progressIsClamped() {
        #expect(book("x", progress: 1.4).progress == 1)
        #expect(book("x", progress: -2).progress == 0)
    }

    @Test func isoDatesWithAndWithoutFractions() {
        #expect(CarPlayBrowse.date(fromISO8601: "2026-11-02T10:00:00Z") != nil)
        #expect(CarPlayBrowse.date(fromISO8601: "2026-11-02T10:00:00.123Z") != nil)
        #expect(CarPlayBrowse.date(fromISO8601: "garbage") == nil)
        #expect(CarPlayBrowse.date(fromISO8601: nil) == nil)
    }

    @Test func matchesOnlyTheLiveSessionOfTheSameKind() {
        let id = BookID(sourceID: "src", uuid: "b")
        #expect(book("b", .audio).matches(.audiobook(id)))
        #expect(!book("b", .audio).matches(.readaloud(id)))
        #expect(book("b", .synced).matches(.readaloud(id)))
        #expect(episode("ep").matches(.podcast("ep")))
        #expect(!episode("ep").matches(.podcast("other")))
        #expect(!episode("ep").matches(nil))
    }

    @Test func nowPlayingButtonsPerKind() {
        let id = BookID(sourceID: "src", uuid: "b")
        #expect(CarPlayBrowse.nowPlayingActions(for: .audiobook(id)) == [.rate, .chapters, .markSpot])
        #expect(CarPlayBrowse.nowPlayingActions(for: .readaloud(id)) == [.rate, .chapters])
        #expect(CarPlayBrowse.nowPlayingActions(for: .podcast("ep")) == [.rate])
        #expect(CarPlayBrowse.upNextEnabled(for: .podcast("ep")))
        #expect(!CarPlayBrowse.upNextEnabled(for: .audiobook(id)))
        #expect(CarPlayBrowse.remoteSkipSeconds == 30)
        #expect(CarPlayBrowse.markedSpotFeedbackSeconds == 2)
        #expect(CarPlayBrowse.playbackRates.count <= CarPlayBrowse.itemCap)
    }

    @Test func markedSpotIsAKeptMilestone() {
        #expect(!AudiobookProgressConflict.isRoutineListeningMilestoneReason(.userMarkedSpot))
    }
}
