import Foundation
import Observation

/// Persists user-added Explore catalog sources (built-in Standard Ebooks is always present).
public struct ExploreSourceStore: Sendable {
    private static let defaultsKey = "punkRally.exploreCatalogSources.v1"
    private static let selectedKey = "punkRally.exploreSelectedSourceID.v1"

    public static let shared = ExploreSourceStore()

    /// Optional UserDefaults suite for tests; nil uses app group / standard.
    private let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        if let suiteName, let suite = UserDefaults(suiteName: suiteName) {
            return suite
        }
        if let group = UserDefaults(suiteName: "group.com.punkrally.reader") {
            return group
        }
        return .standard
    }

    public func loadSources() -> [ExploreCatalogSource] {
        var sources = [ExploreCatalogSource.standardEbooks, ExploreCatalogSource.playtorio]
        if let data = defaults.data(forKey: Self.defaultsKey),
            let decoded = try? JSONDecoder().decode([ExploreCatalogSource].self, from: data)
        {
            for source in decoded where !source.isBuiltIn {
                if !sources.contains(where: { $0.id == source.id }) {
                    sources.append(source)
                }
            }
        }
        return sources
    }

    public func saveSources(_ sources: [ExploreCatalogSource]) {
        let custom = sources.filter { !$0.isBuiltIn }
        guard let data = try? JSONEncoder().encode(custom) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    public func selectedSourceID() -> String {
        defaults.string(forKey: Self.selectedKey) ?? ExploreCatalogSource.standardEbooks.id
    }

    public func setSelectedSourceID(_ id: String) {
        defaults.set(id, forKey: Self.selectedKey)
    }
}

/// Observable catalog coordinator for the Explore UI.
@MainActor
@Observable
public final class ExploreCatalogStore {
    public private(set) var sources: [ExploreCatalogSource] = []
    public private(set) var selectedSourceID: String = ExploreCatalogSource.standardEbooks.id
    public private(set) var books: [ExploreBook] = []
    public private(set) var filteredBooks: [ExploreBook] = []
    public private(set) var searchText: String = ""
    public private(set) var isLoading = false
    public private(set) var isLoadingMore = false
    public private(set) var errorMessage: String?
    public private(set) var isShowingCachedResults = false
    public private(set) var nextURL: URL?

    private let sourceStore: ExploreSourceStore
    private let session: URLSession
    private var pageCache: [String: ExploreCatalogPage] = [:]
    private var loadTask: Task<Void, Never>?

    public init(
        sourceStore: ExploreSourceStore = .shared,
        session: URLSession = .shared
    ) {
        self.sourceStore = sourceStore
        self.session = session
        refreshSourcesFromDisk()
    }

    public var selectedSource: ExploreCatalogSource {
        sources.first { $0.id == selectedSourceID } ?? .standardEbooks
    }

    public func refreshSourcesFromDisk() {
        sources = sourceStore.loadSources()
        selectedSourceID = sourceStore.selectedSourceID()
        if !sources.contains(where: { $0.id == selectedSourceID }) {
            selectedSourceID = ExploreCatalogSource.standardEbooks.id
            sourceStore.setSelectedSourceID(selectedSourceID)
        }
    }

    public func selectSource(id: String) {
        guard sources.contains(where: { $0.id == id }) else { return }
        selectedSourceID = id
        sourceStore.setSelectedSourceID(id)
        searchText = ""
        Task { await reload(forceNetwork: true) }
    }

    public func setSearchText(_ text: String) {
        searchText = text
        applyLocalFilter()
    }

    public func addSource(name: String, feedURL: URL) async throws {
        guard let scheme = feedURL.scheme?.lowercased(), scheme == "https" else {
            throw ExploreCatalogError.httpsRequired
        }
        try await ExploreOPDSFeedValidator.validate(url: feedURL, session: session)
        let id = ExploreBookIdentity.sanitize(feedURL.host.map { "\($0)-\(feedURL.path)" } ?? name)
        var uniqueID = id
        var suffix = 2
        while sources.contains(where: { $0.id == uniqueID }) {
            uniqueID = "\(id)-\(suffix)"
            suffix += 1
        }
        let source = ExploreCatalogSource(
            id: uniqueID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (feedURL.host ?? "OPDS Catalog")
                : name.trimmingCharacters(in: .whitespacesAndNewlines),
            feedURL: feedURL,
            kind: .userOPDS,
            isBuiltIn: false
        )
        var next = sources
        next.append(source)
        sourceStore.saveSources(next)
        refreshSourcesFromDisk()
        selectSource(id: source.id)
    }

    public func renameSource(id: String, name: String) {
        guard let index = sources.firstIndex(where: { $0.id == id && !$0.isBuiltIn }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sources[index].name = trimmed
        sourceStore.saveSources(sources)
    }

    public func removeSource(id: String) {
        guard let source = sources.first(where: { $0.id == id }), !source.isBuiltIn else { return }
        let next = sources.filter { $0.id != id }
        sourceStore.saveSources(next)
        if selectedSourceID == id {
            selectedSourceID = ExploreCatalogSource.standardEbooks.id
            sourceStore.setSelectedSourceID(selectedSourceID)
        }
        refreshSourcesFromDisk()
        Task { await reload(forceNetwork: true) }
    }

    public func reload(forceNetwork: Bool = true) async {
        loadTask?.cancel()
        let source = selectedSource
        isLoading = true
        errorMessage = nil
        isShowingCachedResults = false
        if !forceNetwork, let cached = pageCache[source.id] {
            apply(page: cached, appending: false, markStale: true)
            isLoading = false
            return
        }

        loadTask = Task { @MainActor in
            do {
                let provider = makeProvider(for: source)
                let page = try await provider.loadPage(at: nil)
                guard !Task.isCancelled else { return }
                pageCache[source.id] = page
                apply(page: page, appending: false, markStale: false)
                isLoading = false
            } catch is CancellationError {
                isLoading = false
            } catch let error as ExploreCatalogError {
                if let cached = pageCache[source.id], !cached.books.isEmpty {
                    apply(page: cached, appending: false, markStale: true)
                    errorMessage = nil
                } else {
                    errorMessage = error.localizedDescription
                }
                isLoading = false
            } catch {
                if let cached = pageCache[source.id], !cached.books.isEmpty {
                    apply(page: cached, appending: false, markStale: true)
                } else {
                    errorMessage = error.localizedDescription
                }
                isLoading = false
            }
        }
        await loadTask?.value
    }

    public func loadMoreIfNeeded() async {
        guard let nextURL, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let provider = makeProvider(for: selectedSource)
            let page = try await provider.loadPage(at: nextURL)
            apply(page: page, appending: true, markStale: false)
            if var cached = pageCache[selectedSource.id] {
                cached = ExploreCatalogPage(
                    books: books,
                    selfURL: page.selfURL,
                    startURL: page.startURL,
                    nextURL: page.nextURL,
                    fetchedAt: page.fetchedAt,
                    isStaleCache: false
                )
                pageCache[selectedSource.id] = cached
            }
        } catch {
            // Non-destructive: keep current results; surface a soft error.
            errorMessage = (error as? ExploreCatalogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }

    public func makeDirectEPUBBook(url: URL) async throws -> ExploreBook {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
            throw ExploreCatalogError.httpsRequired
        }
        let itemID = ExploreBookIdentity.sanitize(url.absoluteString)
        let fileURL = try await ExploreBookCache.shared.downloadEPUB(
            sourceID: ExploreBookIdentity.directLinkSourceID,
            itemID: itemID,
            from: url
        )
        let meta = ExploreEPUBMetadataExtractor.extractTitleAndAuthors(from: fileURL)
        let fallbackTitle =
            url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let title = (meta.title?.isEmpty == false ? meta.title! : fallbackTitle)
        let authors = meta.authors.map { ExploreBookAuthor(name: $0) }
        return ExploreBook(
            itemID: itemID,
            sourceID: ExploreBookIdentity.directLinkSourceID,
            sourceName: "Direct EPUB",
            title: title.isEmpty ? "EPUB" : title,
            authors: authors,
            summary: nil,
            coverURL: nil,
            epubURL: url,
            language: nil,
            subjects: [],
            publishedAt: nil,
            updatedAt: nil,
            rights: nil,
            webpageURL: url
        )
    }

    // MARK: - Private

    private func makeProvider(for source: ExploreCatalogSource) -> any ExploreCatalogProvider {
        switch source.kind {
        case .standardEbooks:
            return StandardEbooksCatalogProvider(source: source, session: session)
        case .userOPDS, .directEPUB:
            return OPDSCatalogProvider(source: source, session: session)
        case .playtorio:
            return PlaytorioCatalogProvider(source: source)
        }
    }

    private func apply(page: ExploreCatalogPage, appending: Bool, markStale: Bool) {
        if appending {
            let existing = Set(books.map(\.id))
            books.append(contentsOf: page.books.filter { !existing.contains($0.id) })
        } else {
            books = page.books
        }
        nextURL = page.nextURL
        isShowingCachedResults = markStale || page.isStaleCache
        applyLocalFilter()
    }

    private func applyLocalFilter() {
        let query = normalized(searchText)
        guard !query.isEmpty else {
            filteredBooks = books
            return
        }
        filteredBooks = books.filter { book in
            normalized(book.title).contains(query)
                || book.authors.contains { normalized($0.name).contains(query) }
        }
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }
}
