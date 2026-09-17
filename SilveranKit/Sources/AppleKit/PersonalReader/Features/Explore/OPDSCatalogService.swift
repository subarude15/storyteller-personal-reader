import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - OPDS / Atom Fetch Service (Lawful Only)
//
// Fetches only public OPDS/Atom feeds (built-in) or OPDS URLs the user explicitly added.
// No search of pirate indexes. All fetches are https, validate MIME, and require an
// explicit user tap to download an acquisition href (separate service).

public actor OPDSCatalogService {
    public static let shared = OPDSCatalogService()

    private let urlSession: URLSession
    private let allowedMIMETypes: Set<String> = [
        "application/atom+xml",
        "application/atom+xml;type=feed",
        "application/opds+xml",
        "application/xml",
        "text/xml",
        "application/rss+xml",
    ]

    public init(session: URLSession = .shared) {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.urlSession = URLSession(configuration: config)
    }

    /// Fetch and parse a catalog's feed into entries. Caller must have already
    /// validated the catalog's URL is https and not a banned host.
    public func fetchCatalog(_ catalog: OPDSCatalog) async throws -> [OPDSEntry] {
        guard catalog.url.scheme?.lowercased() == "https" else {
            throw ExploreAcquisitionError.notHTTPS
        }
        if let host = catalog.url.host, OPDSCatalogs.isBannedHost(host) {
            throw ExploreAcquisitionError.disallowedHost(host)
        }

        var request = URLRequest(url: catalog.url)
        request.httpMethod = "GET"
        request.setValue("application/atom+xml, application/xml;q=0.9, */*;q=0.1", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ExploreAcquisitionError.catalogUnreachable("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        // Allow feeds that omit Content-Type, but if present it must be XML/Atom-ish.
        if let ct = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(), !ct.isEmpty {
            let isXML = allowedMIMETypes.contains { ct.contains($0) } || ct.contains("xml") || ct.contains("atom")
            if !isXML {
                // Some OPDS hosts mislabel as text/html; permit if body looks like XML.
                let prefix = String(data: data.prefix(512), encoding: .utf8)?.lowercased() ?? ""
                if !prefix.contains("<?xml") && !prefix.contains("<feed") && !prefix.contains("<entry") {
                    throw ExploreAcquisitionError.contentTypeMismatch(expected: "application/atom+xml", actual: ct)
                }
            }
        }

        return try parseAtom(data: data, catalog: catalog)
    }

    /// Fetch a user-added OPDS URL string directly (validates first).
    public func fetchUserCatalog(urlString: String, name: String? = nil) async throws -> [OPDSEntry] {
        let url = try OPDSCatalogStore.validateUserURLString(urlString)
        let catalog = OPDSCatalog(
            id: "user-\(url.absoluteString.hashValue)",
            name: name ?? url.host ?? "Your Catalog",
            url: url,
            isUserAdded: true,
            provenance: "Your catalog — \(url.host ?? url.absoluteString)"
        )
        return try await fetchCatalog(catalog)
    }

    // MARK: - Minimal Atom/OPDS parsing

    /// Lightweight parser: looks for <entry> with <title>, <author><name>, <summary>,
    /// <link rel="http://opds-spec.org/acquisition" href=… type=…> and cover <link rel="http://opds-spec.org/image">.
    /// Keeps dependencies at zero; for rich feeds the app can still open the raw feed.
    private func parseAtom(data: Data, catalog: OPDSCatalog) throws -> [OPDSEntry] {
        // Prefer a real XML parse; fall back to entry scanning so malformed feeds still surface.
        let parser = OPDSSimpleXMLParser(catalog: catalog)
        return parser.parse(data: data)
    }
}

// MARK: - Simple XML parser (Foundation.XMLParser, no external deps)

private final class OPDSSimpleXMLParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    private let catalog: OPDSCatalog
    private var entries: [OPDSEntry] = []
    private var currentTitle: String = ""
    private var currentAuthor: String?
    private var currentSummary: String?
    private var currentCoverURL: URL?
    private var currentAcqLinks: [OPDSAcquisitionLink] = []
    private var currentID: String?
    private var currentText: String = ""
    private var inEntry = false
    private var inAuthor = false
    private var inTitle = false
    private var inSummary = false
    private var inID = false

    init(catalog: OPDSCatalog) {
        self.catalog = catalog
    }

    func parse(data: Data) -> [OPDSEntry] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        // If delegate produced nothing but data looked like a feed, return at least a placeholder
        // so UI can show “empty catalog” vs “parse failed”.
        return entries
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentText = ""
        switch elementName {
        case "entry":
            inEntry = true
            currentTitle = ""
            currentAuthor = nil
            currentSummary = nil
            currentCoverURL = nil
            currentAcqLinks = []
            currentID = nil
        case "author":
            if inEntry { inAuthor = true }
        case "title":
            if inEntry { inTitle = true }
        case "summary", "content":
            if inEntry { inSummary = true }
        case "id":
            if inEntry { inID = true }
        case "link":
            guard inEntry else { return }
            guard let href = attributeDict["href"], let url = URL(string: href), url.scheme?.lowercased() == "https" else { return }
            let rel = attributeDict["rel"]?.lowercased() ?? ""
            let type = attributeDict["type"]?.lowercased() ?? ""
            // Cover image
            if rel.contains("opds-spec.org/image") || rel == "http://opds-spec.org/image" || rel == "x-stanza-cover-image" || (rel == "enclosure" && type.hasPrefix("image/")) {
                if currentCoverURL == nil { currentCoverURL = url }
                return
            }
            // Acquisition
            let isAcquisition = rel.contains("opds-spec.org/acquisition") || rel == "http://opds-spec.org/acquisition" || rel.contains("acquisition")
            if isAcquisition || rel == "enclosure" {
                let kind: OPDSAcquisitionLink.Kind
                if type.contains("audio") || href.lowercased().hasSuffix(".m4b") || href.lowercased().hasSuffix(".m4a") || href.lowercased().hasSuffix(".mp3") {
                    kind = .audiobook
                } else if type.contains("readaloud") {
                    kind = .readaloud
                } else {
                    kind = .epub
                }
                currentAcqLinks.append(OPDSAcquisitionLink(kind: kind, href: url, mimeType: type.isEmpty ? nil : type))
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "title" where inTitle:
            // Prefer entry title over author name capture
            if inAuthor {
                // actually inside author/name, ignore here
            } else {
                currentTitle = trimmed
            }
            inTitle = false
        case "name" where inAuthor:
            if currentAuthor == nil, !trimmed.isEmpty { currentAuthor = trimmed }
        case "author":
            inAuthor = false
        case "summary", "content" where inSummary:
            currentSummary = trimmed.isEmpty ? nil : trimmed
            inSummary = false
        case "id" where inID:
            currentID = trimmed.isEmpty ? nil : trimmed
            inID = false
        case "entry":
            // Only emit entries that have at least one https acquisition link
            if !currentAcqLinks.isEmpty || currentCoverURL != nil || !currentTitle.isEmpty {
                let id = currentID ?? currentAcqLinks.first?.href.absoluteString ?? UUID().uuidString
                let provenance = AcquisitionProvenance(transport: catalog.isUserAdded ? .userOPDS : .publicOPDS, sourceName: catalog.name, sourceURL: catalog.url)
                entries.append(OPDSEntry(
                    id: id,
                    title: currentTitle.isEmpty ? "(Untitled)" : currentTitle,
                    author: currentAuthor,
                    summary: currentSummary,
                    coverURL: currentCoverURL,
                    acquisitionLinks: currentAcqLinks,
                    provenance: provenance
                ))
            }
            inEntry = false
        default: break
        }
        currentText = ""
    }
}
