import Foundation

/// Catalog discovery only — acquisition (download/import) stays separate.
public protocol ExploreCatalogProvider: Sendable {
    var source: ExploreCatalogSource { get }
    func loadPage(at url: URL?) async throws -> ExploreCatalogPage
}

/// Validates that a URL returns a recognizable Atom/OPDS document before saving.
public enum ExploreOPDSFeedValidator {
    public static func validate(url: URL, session: URLSession = .shared) async throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
            throw ExploreCatalogError.httpsRequired
        }
        var request = URLRequest(url: url)
        request.setValue("application/atom+xml, application/xml;q=0.9, */*;q=0.1", forHTTPHeaderField: "Accept")
        request.setValue("ink+amp-explore/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ExploreCatalogError.network("No HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ExploreCatalogError.httpStatus(http.statusCode)
        }
        guard OPDSFeedParser.looksLikeAtomOrOPDS(data) else {
            throw ExploreCatalogError.notOPDS
        }
        // Ensure at least the root parses without throwing.
        _ = try OPDSFeedParser.parse(
            data: data,
            responseURL: http.url ?? url,
            source: ExploreCatalogSource(
                id: "validation",
                name: "Validation",
                feedURL: url,
                kind: .userOPDS,
                isBuiltIn: false
            )
        )
    }
}
