import Foundation

/// Generic OPDS/Atom catalog provider for user-added public HTTPS feeds.
public struct OPDSCatalogProvider: ExploreCatalogProvider {
    public let source: ExploreCatalogSource
    private let session: URLSession

    public init(source: ExploreCatalogSource, session: URLSession = .shared) {
        self.source = source
        self.session = session
    }

    public func loadPage(at url: URL?) async throws -> ExploreCatalogPage {
        let target = url ?? source.feedURL
        guard let scheme = target.scheme?.lowercased(), scheme == "https" else {
            throw ExploreCatalogError.httpsRequired
        }

        var request = URLRequest(url: target)
        request.setValue(
            "application/atom+xml;profile=opds-catalog, application/atom+xml, application/xml;q=0.9, */*;q=0.1",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("ink+amp-explore/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw ExploreCatalogError.cancelled
        } catch {
            throw ExploreCatalogError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ExploreCatalogError.network("No HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ExploreCatalogError.httpStatus(http.statusCode)
        }

        return try OPDSFeedParser.parse(
            data: data,
            responseURL: http.url ?? target,
            source: source
        )
    }
}

/// Built-in Standard Ebooks provider.
///
/// Starts from the configured OPDS root and follows advertised public catalog
/// links. When the full OPDS catalog requires patronage, falls back to the
/// publicly documented Atom new-releases feed (open to everyone) which includes
/// EPUB enclosure acquisition links.
public struct StandardEbooksCatalogProvider: ExploreCatalogProvider {
    public let source: ExploreCatalogSource
    private let session: URLSession

    /// Public Atom feed advertised as open to everyone on Standard Ebooks' feed page.
    public static let publicNewReleasesURL = URL(
        string: "https://standardebooks.org/feeds/atom/new-releases"
    )!

    public init(
        source: ExploreCatalogSource = .standardEbooks,
        session: URLSession = .shared
    ) {
        self.source = source
        self.session = session
    }

    public func loadPage(at url: URL?) async throws -> ExploreCatalogPage {
        if let url {
            return try await fetchCatalog(at: url)
        }
        return try await loadRootCatalog()
    }

    private func loadRootCatalog() async throws -> ExploreCatalogPage {
        // 1) Try configured OPDS root / historical all-books endpoints.
        let candidates = [
            source.feedURL,
            URL(string: "https://standardebooks.org/feeds/opds")!,
            URL(string: "https://standardebooks.org/opds/all")!,
            URL(string: "https://standardebooks.org/feeds/opds/all")!,
            Self.publicNewReleasesURL,
        ]

        var lastError: ExploreCatalogError = .notOPDS
        for candidate in candidates {
            do {
                let page = try await fetchCatalog(at: candidate)
                if !page.books.isEmpty || page.nextURL != nil {
                    return page
                }
                // Empty but valid — keep looking for a richer feed.
                lastError = .emptyCatalog
            } catch let error as ExploreCatalogError {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    private func fetchCatalog(at url: URL) async throws -> ExploreCatalogPage {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
            throw ExploreCatalogError.httpsRequired
        }

        var request = URLRequest(url: url)
        request.setValue(
            "application/atom+xml;profile=opds-catalog, application/atom+xml, application/xml;q=0.9, */*;q=0.1",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("ink+amp-explore/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw ExploreCatalogError.cancelled
        } catch {
            throw ExploreCatalogError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ExploreCatalogError.network("No HTTP response.")
        }

        // Auth-walled OPDS HTML/401 → try public new-releases if this was a root probe.
        if http.statusCode == 401 || !OPDSFeedParser.looksLikeAtomOrOPDS(data) {
            if url != Self.publicNewReleasesURL {
                throw ExploreCatalogError.httpStatus(http.statusCode == 401 ? 401 : 406)
            }
            throw ExploreCatalogError.notOPDS
        }

        guard (200..<300).contains(http.statusCode) else {
            throw ExploreCatalogError.httpStatus(http.statusCode)
        }

        var page = try OPDSFeedParser.parse(
            data: data,
            responseURL: http.url ?? url,
            source: source
        )

        // Prefer entries that actually have EPUB acquisition links for Read now.
        let withEPUB = page.books.filter { $0.epubURL != nil }
        if !withEPUB.isEmpty {
            page = ExploreCatalogPage(
                books: withEPUB,
                selfURL: page.selfURL,
                startURL: page.startURL,
                nextURL: page.nextURL,
                fetchedAt: page.fetchedAt,
                isStaleCache: page.isStaleCache
            )
        }
        return page
    }
}
