#if os(iOS)
import CarPlay
import OSLog
import SilveranKit
import UIKit

/// Continue / Audiobooks / Podcasts / Downloaded browse plus the shared Now Playing
/// template. Transport, skip and metadata come from MPNowPlayingInfoCenter and
/// MPRemoteCommandCenter via AudioSessionActor; this only adds browse and buttons.
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPNowPlayingTemplateObserver {
    nonisolated private static var logger: Logger { CarPlayCoordinator.logger }
    /// CarPlay audio apps may stack at most five templates, root included.
    private static let maximumTemplateDepth = 5

    private var interfaceController: CPInterfaceController?
    /// Bumped on every connect/disconnect so work resumed after an await can tell it is stale.
    private var generation = 0
    private var reconcileTask: Task<Void, Never>?
    private var snapshotObserverID: UUID?
    private var snapshot: AudioSessionSnapshot?
    private var lastSessionID: String?
    private var lastIsPlaying = false

    private var tabTemplates: [CarPlayBrowseTab: CPListTemplate] = [:]
    private var bookItems: [CarPlayBrowseItem] = []
    private var booksByItemID: [String: BookMetadata] = [:]
    private var recentItems: [CarPlayBrowseItem] = []
    private var upNextItems: [CarPlayBrowseItem] = []
    private var shows: [CarPlayPodcastShow] = []
    private var downloadedItems: [CarPlayBrowseItem] = []
    // ponytail: in-memory caches live for one CarPlay connection; fine for a drive's worth of rows.
    private var showEpisodes: [URL: [CarPlayBrowseItem]] = [:]
    private var bookCovers: [BookID: UIImage] = [:]
    private var podcastCovers: [URL: UIImage] = [:]
    private var coverWaiters: [String: [(UIImage) -> Void]] = [:]
    private var failedCovers: Set<String> = []

    private var isLoading = false
    private var spotMarked = false
    private var spotResetTask: Task<Void, Never>?

    private var itemLimit: Int {
        CarPlayBrowse.itemLimit(maximumItemCount: CPListTemplate.maximumItemCount)
    }

    // MARK: - Lifecycle

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
    ) {
        Self.logger.notice("connected")
        generation += 1
        let connection = generation
        self.interfaceController = interfaceController
        CarPlayCoordinator.shared.carPlayOwner = ObjectIdentifier(self)
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.add(self)
        nowPlaying.upNextTitle = "Up Next"
        updateNowPlayingButtons()
        reconcile()

        Task { @MainActor in
            guard await SilveranRuntime.start(), self.generation == connection else { return }
            await self.setupAndShowRootTemplate(connection: connection)
        }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController,
    ) {
        Self.logger.notice("disconnected")
        generation += 1
        self.interfaceController = nil
        CPNowPlayingTemplate.shared.remove(self)
        let coordinator = CarPlayCoordinator.shared
        // A newer scene delegate owns the global CarPlay state after a reconnect.
        if coordinator.carPlayOwner == ObjectIdentifier(self) {
            coordinator.carPlayOwner = nil
            coordinator.onLibraryUpdated = nil
            coordinator.onChaptersUpdated = nil
        }
        tabTemplates = [:]
        showEpisodes = [:]
        spotResetTask?.cancel()
        reconcile()
    }

    /// Global side effects go through the coordinator's single runner; this delegate's own
    /// snapshot observer is reconciled one step at a time from its state at execution time,
    /// so a slow connect can never land after a later disconnect.
    private func reconcile() {
        CarPlayCoordinator.shared.reconcileCarPlayConnection()
        let previous = reconcileTask
        reconcileTask = Task { @MainActor in
            await previous?.value
            guard await SilveranRuntime.start() else { return }
            let connected = self.interfaceController != nil
            if !connected, let id = self.snapshotObserverID {
                self.snapshotObserverID = nil
                await AudioSessionActor.shared.removeSnapshotObserver(id: id)
            }
            if connected, self.snapshotObserverID == nil {
                self.snapshotObserverID = await AudioSessionActor.shared.addSnapshotObserver { [weak self] snapshot in
                    Task { @MainActor [weak self] in
                        self?.apply(snapshot)
                    }
                }
                self.apply(await AudioSessionActor.shared.currentSnapshot())
            }
        }
    }

    /// Refreshes rows and buttons only when the session or play state changes (not on ticks).
    private func apply(_ snapshot: AudioSessionSnapshot?) {
        guard interfaceController != nil else { return }
        self.snapshot = snapshot
        let sessionID = snapshot?.kind.sessionID
        let isPlaying = snapshot?.isPlaying ?? false
        guard sessionID != lastSessionID || isPlaying != lastIsPlaying else { return }
        let sessionChanged = sessionID != lastSessionID
        lastSessionID = sessionID
        lastIsPlaying = isPlaying
        if sessionChanged {
            spotMarked = false
            if case .audiobook(let bookID)? = snapshot?.kind {
                Task { await CarPlayCoordinator.shared.adoptAudiobookSession(bookID) }
            }
        }
        updateNowPlayingButtons()
        Task { await refreshLists() }
    }

    // MARK: - Browse

    private func setupAndShowRootTemplate(connection: Int) async {
        CarPlayCoordinator.shared.onLibraryUpdated = { [weak self] in
            Task { @MainActor in
                await self?.refreshLists()
            }
        }

        var templates: [CPTemplate] = []
        for tab in CarPlayBrowse.tabs(maximumTabCount: CPTabBarTemplate.maximumTabCount) {
            let template = CPListTemplate(title: tab.title, sections: [])
            template.tabTitle = tab.title
            template.tabImage = UIImage(systemName: tab.systemImage)
            tabTemplates[tab] = template
            templates.append(template)
        }
        guard generation == connection else { return }
        interfaceController?.setRootTemplate(
            CPTabBarTemplate(templates: templates),
            animated: false,
            completion: nil,
        )
        await refreshLists()
    }

    private func refreshLists() async {
        guard !tabTemplates.isEmpty else { return }
        let connection = generation
        await reloadBooks()
        guard generation == connection else { return }
        let provider = CarPlayPodcastProvider.current
        recentItems = CarPlayBrowse.orderedRecent(books: bookItems, podcasts: provider?.recentEpisodes() ?? [])
        upNextItems = CarPlayPodcastProvider.upNextItems()
        shows = provider?.subscribedShows() ?? []
        downloadedItems = bookItems + CarPlayPodcastProvider.downloadedItems()

        let limit = itemLimit
        for (tab, template) in tabTemplates {
            let sections: [CarPlayBrowseSection]
            switch tab {
                case .continueListening:
                    sections = CarPlayBrowse.continueSections(
                        books: recentItems,
                        podcasts: [],
                        live: liveContinueItem(),
                        limit: limit,
                    )
                case .audiobooks:
                    sections = CarPlayBrowse.audiobookSections(books: bookItems, limit: limit)
                case .podcasts:
                    sections = CarPlayBrowse.podcastSections(upNext: upNextItems, shows: shows, limit: limit)
                case .downloaded:
                    sections = CarPlayBrowse.downloadedSections(items: downloadedItems, limit: limit)
            }
            let listSections = sections.enumerated().map { index, section in
                CPListSection(
                    items: section.rows.map { row in
                        templateItem(row, featured: tab == .continueListening && index == 0)
                    },
                    header: section.header,
                    sectionIndexTitle: nil,
                )
            }
            template.updateSections(listSections)
            template.emptyViewTitleVariants = sections.isEmpty ? [emptyTitle(for: tab)] : []
            template.emptyViewSubtitleVariants = sections.isEmpty ? ["Play or download on your iPhone first"] : []
        }
    }

    private func liveContinueItem() -> CarPlayBrowseItem? {
        let kind = snapshot?.kind
        if let known = (bookItems + downloadedItems + upNextItems).first(where: { $0.matches(kind) }) {
            return known
        }
        let episode = PodcastPlayerPresenter.shared.episode.map {
            PodcastPlaybackQueueItem(
                episodeID: $0.id,
                title: $0.title,
                showTitle: $0.showTitle,
                summary: $0.summary,
                audioURL: $0.audioURL,
                durationSeconds: $0.duration,
                coverURL: $0.coverURL,
                mediaKindRaw: $0.isVideo ? "video" : "audio",
                youtubeURL: $0.youtubeURL,
            )
        }
        return CarPlayBrowse.liveItem(
            snapshot,
            episode: episode,
            episodeIsLocal: episode.map { PodcastDownloadStore.shared.localAudioURL(for: $0.episodeID) != nil } ?? false,
        )
    }

    private func reloadBooks() async {
        let coordinator = CarPlayCoordinator.shared
        var items: [CarPlayBrowseItem] = []
        var metadata: [String: BookMetadata] = [:]
        for category in [LocalMediaCategory.audio, .synced] {
            for book in await coordinator.getDownloadedBooks(category: category) {
                let item = CarPlayBrowseItem(
                    source: .book(book.id, category),
                    title: book.title,
                    detail: book.authors?.first?.name,
                    progress: book.progress,
                    lastTouched: CarPlayBrowse.date(fromISO8601: book.position?.updatedAt),
                    isLocal: true,
                )
                items.append(item)
                metadata[item.id] = book
            }
        }
        bookItems = items
        booksByItemID = metadata
    }

    private func emptyTitle(for tab: CarPlayBrowseTab) -> String {
        switch tab {
            case .continueListening: return "Nothing to Continue"
            case .audiobooks: return "No Audiobooks"
            case .podcasts: return "No Podcasts"
            case .downloaded: return "Nothing Downloaded"
        }
    }

    private func templateItem(_ row: CarPlayBrowseRow, featured: Bool = false) -> CPListTemplateItem {
        switch row {
            case .item(let item):
                if featured, #available(iOS 26.0, *) {
                    return continueCard(item)
                }
                return listItem(item)
            case .show(let show):
                return showItem(show)
            case .more(let overflow, let count):
                let item = CPListItem(text: overflow.title, detailText: "\(count)")
                item.accessoryType = .disclosureIndicator
                item.handler = { [weak self] _, completion in
                    self?.showOverflow(overflow)
                    completion()
                }
                return item
        }
    }

    private func statusText(for item: CarPlayBrowseItem) -> String? {
        guard item.matches(snapshot?.kind) else { return item.detail }
        return snapshot?.isPlaying == true ? "Now Playing" : "Paused"
    }

    private func listItem(_ item: CarPlayBrowseItem) -> CPListItem {
        let cached = cachedCover(for: item)
        let row = CPListItem(text: item.title, detailText: statusText(for: item), image: cached ?? placeholder(for: item))
        if let progress = item.progress, progress > 0 {
            row.playbackProgress = CGFloat(progress)
        }
        row.isPlaying = item.matches(snapshot?.kind) && snapshot?.isPlaying == true
        row.handler = { [weak self] _, completion in
            guard let self else {
                completion()
                return
            }
            self.select(item, completion: completion)
        }
        if cached == nil {
            whenCoverLoads(item) { [weak row] image in row?.setImage(image) }
        }
        return row
    }

    /// iOS 26 large Continue card; earlier systems use the regular row.
    @available(iOS 26.0, *)
    private func continueCard(_ item: CarPlayBrowseItem) -> CPListTemplateItem {
        let cached = cachedCover(for: item)
        let progress = item.progress.map { "\(Int(($0 * 100).rounded()))%" }
        let subtitle = [statusText(for: item), progress].compactMap { $0 }.joined(separator: " · ")
        let element = CPListImageRowItemCardElement(
            image: cached ?? placeholder(for: item) ?? UIImage(),
            showsImageFullHeight: true,
            title: item.title,
            subtitle: subtitle.isEmpty ? nil : subtitle,
            tintColor: nil,
        )
        let card = CPListImageRowItem(text: "Continue", cardElements: [element], allowsMultipleLines: false)
        card.handler = { [weak self] _, completion in
            guard let self else {
                completion()
                return
            }
            self.select(item, completion: completion)
        }
        card.listImageRowHandler = { [weak self] _, _, completion in
            guard let self else {
                completion()
                return
            }
            self.select(item, completion: completion)
        }
        if cached == nil {
            whenCoverLoads(item) { [weak self] _ in
                Task { await self?.refreshLists() }
            }
        }
        return card
    }

    private func showItem(_ show: CarPlayPodcastShow) -> CPListItem {
        let row = CPListItem(text: show.title, detailText: nil, image: UIImage(systemName: "mic.fill"))
        row.accessoryType = .disclosureIndicator
        row.handler = { [weak self] _, completion in
            guard let self else {
                completion()
                return
            }
            Task { @MainActor in
                let episodes = await self.episodes(for: show)
                self.pushItems(title: show.title, episodes, emptyTitle: "No Playable Episodes")
                completion()
            }
        }
        return row
    }

    private func episodes(for show: CarPlayPodcastShow) async -> [CarPlayBrowseItem] {
        if let cached = showEpisodes[show.feedURL] { return cached }
        let episodes = await CarPlayPodcastProvider.current?.showEpisodes(show) ?? []
        if !episodes.isEmpty { showEpisodes[show.feedURL] = episodes }
        return episodes
    }

    private func showOverflow(_ overflow: CarPlayBrowseOverflow) {
        switch overflow {
            case .recent:
                pushItems(title: overflow.title, recentItems)
            case .audiobooks:
                pushItems(title: overflow.title, CarPlayBrowse.orderedAudiobooks(bookItems))
            case .upNext:
                pushItems(title: overflow.title, CarPlayBrowse.orderedUpNext(upNextItems))
            case .downloaded:
                pushItems(title: overflow.title, CarPlayBrowse.orderedDownloaded(downloadedItems))
            case .shows:
                let shows = self.shows
                pushList(title: overflow.title, count: shows.count) { [weak self] in
                    self?.showItem(shows[$0]) ?? CPListItem(text: shows[$0].title, detailText: nil)
                }
        }
    }

    private func pushItems(title: String, _ items: [CarPlayBrowseItem], emptyTitle: String? = nil) {
        pushList(title: title, count: items.count, emptyTitle: emptyTitle) { [weak self] in
            self?.listItem(items[$0]) ?? CPListItem(text: items[$0].title, detailText: nil)
        }
    }

    /// Pushes one template of `count` rows built on demand. Longer lists page in place with
    /// Prev/Next bar buttons, so the stack stays shallow and every row stays reachable.
    private func pushList(
        title: String,
        count: Int,
        highlighted: Int? = nil,
        emptyTitle: String? = nil,
        row: @escaping (Int) -> CPListItem,
    ) {
        let template = CPListTemplate(title: title, sections: [])
        if let emptyTitle { template.emptyViewTitleVariants = [emptyTitle] }
        let pager = CarPlayListPager(template: template, count: count, limit: itemLimit, highlighted: highlighted, row: row)
        template.userInfo = pager
        pager.show()
        push(template)
    }

    private func push(_ template: CPTemplate) {
        guard let controller = interfaceController else { return }
        guard controller.templates.count < Self.maximumTemplateDepth else {
            Self.logger.error("template depth limit reached")
            return
        }
        controller.pushTemplate(template, animated: true, completion: nil)
    }

    private func select(_ item: CarPlayBrowseItem, completion: @escaping () -> Void) {
        Task { @MainActor in
            defer { completion() }
            if item.matches(snapshot?.kind) {
                if snapshot?.isPlaying != true {
                    try? await AudioSessionActor.shared.transport(.play)
                }
                showNowPlaying()
                return
            }
            guard !isLoading else { return }
            isLoading = true
            defer { isLoading = false }
            switch item.source {
                case .book(_, let category):
                    guard let book = booksByItemID[item.id] else { return }
                    do {
                        try await CarPlayCoordinator.shared.loadAndPlayBook(book, category: category)
                    } catch {
                        Self.logger.error("book open failed")
                        return
                    }
                case .podcast(let episode):
                    guard await CarPlayCoordinator.shared.playPodcast(episode) else { return }
            }
            showNowPlaying()
        }
    }

    private func showNowPlaying() {
        guard let controller = interfaceController else { return }
        let nowPlaying = CPNowPlayingTemplate.shared
        if controller.topTemplate === nowPlaying { return }
        if controller.templates.contains(where: { $0 === nowPlaying }) {
            controller.pop(to: nowPlaying, animated: true, completion: nil)
            return
        }
        if controller.templates.count >= Self.maximumTemplateDepth {
            controller.popToRootTemplate(animated: false, completion: nil)
        }
        controller.pushTemplate(nowPlaying, animated: true) { _, error in
            if error != nil { Self.logger.error("now playing push failed") }
        }
    }

    // MARK: - Covers

    private func placeholder(for item: CarPlayBrowseItem) -> UIImage? {
        UIImage(systemName: item.isPodcast ? "mic.fill" : "book.closed.fill")
    }

    private func cachedCover(for item: CarPlayBrowseItem) -> UIImage? {
        switch item.source {
            case .book(let id, _): return bookCovers[id]
            case .podcast(let episode): return episode.coverURL.flatMap { podcastCovers[$0] }
        }
    }

    /// One load per item; every row showing that item gets the image.
    private func whenCoverLoads(_ item: CarPlayBrowseItem, _ apply: @escaping (UIImage) -> Void) {
        guard !failedCovers.contains(item.id) else { return }
        if coverWaiters[item.id] != nil {
            coverWaiters[item.id]?.append(apply)
            return
        }
        coverWaiters[item.id] = [apply]
        Task { @MainActor in
            let image = await self.loadCover(for: item)
            let waiters = self.coverWaiters.removeValue(forKey: item.id) ?? []
            guard let image else {
                self.failedCovers.insert(item.id)
                return
            }
            waiters.forEach { $0(image) }
        }
    }

    private func loadCover(for item: CarPlayBrowseItem) async -> UIImage? {
        switch item.source {
            case .book(let id, _):
                guard let cover = await CarPlayCoordinator.shared.getCoverImage(for: id) else { return nil }
                let image = resizeCover(cover)
                bookCovers[id] = image
                return image
            case .podcast(let episode):
                guard let url = episode.coverURL, url.scheme == "https" || url.scheme == "http",
                    let result = try? await URLSession.shared.data(from: url),
                    let cover = UIImage(data: result.0)
                else { return nil }
                let image = resizeCover(cover)
                podcastCovers[url] = image
                return image
        }
    }

    private func resizeCover(_ image: UIImage) -> UIImage {
        let targetSize = CPListItem.maximumImageSize
        return UIGraphicsImageRenderer(size: targetSize).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    // MARK: - Now Playing buttons

    private func updateNowPlayingButtons() {
        let nowPlaying = CPNowPlayingTemplate.shared
        let kind = snapshot?.kind
        nowPlaying.isUpNextButtonEnabled = CarPlayBrowse.upNextEnabled(for: kind)
        let buttons = CarPlayBrowse.nowPlayingActions(for: kind).compactMap { action -> CPNowPlayingButton? in
            switch action {
                case .rate:
                    return CPNowPlayingPlaybackRateButton { [weak self] _ in self?.showSpeedList() }
                case .chapters:
                    return imageButton("list.bullet") { [weak self] in self?.showChaptersList() }
                case .markSpot:
                    return imageButton(spotMarked ? "pin.fill" : "pin") { [weak self] in self?.markSpot() }
            }
        }
        nowPlaying.updateNowPlayingButtons(buttons)
    }

    private func imageButton(_ systemName: String, action: @escaping () -> Void) -> CPNowPlayingButton? {
        guard let image = UIImage(systemName: systemName) else { return nil }
        return CPNowPlayingImageButton(image: image) { _ in action() }
    }

    /// Saves a Previous Positions milestone; the filled pin is the only confirmation.
    private func markSpot() {
        Task { @MainActor in
            guard await AudioSessionActor.shared.markListeningSpot() else {
                Self.logger.error("mark spot not saved")
                return
            }
            spotMarked = true
            updateNowPlayingButtons()
            spotResetTask?.cancel()
            spotResetTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(CarPlayBrowse.markedSpotFeedbackSeconds))
                guard !Task.isCancelled, let self else { return }
                self.spotMarked = false
                self.updateNowPlayingButtons()
            }
        }
    }

    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor in
            self.pushItems(
                title: "Up Next",
                CarPlayBrowse.orderedUpNext(CarPlayPodcastProvider.upNextItems()),
                emptyTitle: "Up Next is Empty",
            )
        }
    }

    private func showChaptersList() {
        let coordinator = CarPlayCoordinator.shared
        let chapters = coordinator.chapters
        guard !chapters.isEmpty else { return }
        let current = coordinator.currentChapterSectionIndex
        pushList(
            title: "Chapters",
            count: chapters.count,
            highlighted: chapters.firstIndex { $0.sectionIndex == current },
        ) { [weak self] in
            self?.chapterListItem(for: chapters[$0], currentSectionIndex: current)
                ?? CPListItem(text: chapters[$0].label, detailText: nil)
        }
    }

    private func chapterListItem(for chapter: CarPlayChapter, currentSectionIndex: Int?) -> CPListItem {
        let isCurrent = chapter.sectionIndex == currentSectionIndex
        let item = CPListItem(text: chapter.label, detailText: isCurrent ? "Now Playing" : nil)
        item.isPlaying = isCurrent
        item.handler = { [weak self] _, completion in
            Task { @MainActor in
                CarPlayCoordinator.shared.selectChapter(sectionIndex: chapter.sectionIndex)
            }
            self?.interfaceController?.pop(to: CPNowPlayingTemplate.shared, animated: true, completion: nil)
            completion()
        }
        return item
    }

    private func showSpeedList() {
        let currentRate = snapshot?.playbackRate ?? CarPlayCoordinator.shared.currentPlaybackRate
        let rates = CarPlayBrowse.playbackRates
        pushList(title: "Playback Speed", count: rates.count) { [weak self] index in
            let speed = rates[index]
            let isCurrent = abs(speed - currentRate) < 0.01
            let item = CPListItem(text: formatSpeedPickerLabel(speed), detailText: isCurrent ? "Current" : nil)
            item.isPlaying = isCurrent
            item.handler = { _, completion in
                Task { @MainActor in
                    await CarPlayCoordinator.shared.setPlaybackRate(speed)
                }
                self?.interfaceController?.popTemplate(animated: true, completion: nil)
                completion()
            }
            return item
        }
    }
}

/// Page state for one pushed list; owned by the template's `userInfo`.
@MainActor
private final class CarPlayListPager {
    private weak var template: CPListTemplate?
    private let count: Int
    private let limit: Int
    private let row: (Int) -> CPListItem
    private var page: Int
    private var previous: CPBarButton?
    private var next: CPBarButton?

    init(template: CPListTemplate, count: Int, limit: Int, highlighted: Int?, row: @escaping (Int) -> CPListItem) {
        self.template = template
        self.count = count
        self.limit = limit
        self.row = row
        page = CarPlayBrowse.page(containing: highlighted, count: count, limit: limit)
        guard CarPlayBrowse.pageCount(count: count, limit: limit) > 1 else { return }
        let previous = CPBarButton(title: "Prev") { [weak self] _ in self?.move(by: -1) }
        let next = CPBarButton(title: "Next") { [weak self] _ in self?.move(by: 1) }
        self.previous = previous
        self.next = next
        template.trailingNavigationBarButtons = [previous, next]
    }

    func show() {
        let range = CarPlayBrowse.pageRange(page, count: count, limit: limit)
        let header = previous == nil ? nil : "\(range.lowerBound + 1)–\(range.upperBound) of \(count)"
        template?.updateSections(
            range.isEmpty ? [] : [CPListSection(items: range.map(row), header: header, sectionIndexTitle: nil)]
        )
        previous?.isEnabled = range.lowerBound > 0
        next?.isEnabled = range.upperBound < count
    }

    private func move(by delta: Int) {
        page = CarPlayBrowse.clampedPage(page + delta, count: count, limit: limit)
        show()
    }
}
#endif
