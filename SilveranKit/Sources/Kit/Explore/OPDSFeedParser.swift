import Foundation

/// Parses Atom / OPDS catalog documents into Explore catalog pages.
public enum OPDSFeedParser {
    public static func looksLikeAtomOrOPDS(_ data: Data) -> Bool {
        guard let head = String(data: data.prefix(2048), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else { return false }
        if head.hasPrefix("<!doctype html") || head.hasPrefix("<html") { return false }
        return head.contains("<feed") || head.contains("opds-catalog") || head.contains("xmlns=\"http://www.w3.org/2005/atom\"")
    }

    public static func parse(
        data: Data,
        responseURL: URL,
        source: ExploreCatalogSource
    ) throws -> ExploreCatalogPage {
        guard looksLikeAtomOrOPDS(data) else {
            throw ExploreCatalogError.notOPDS
        }
        let delegate = OPDSXMLDelegate(baseURL: responseURL, source: source)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else {
            throw ExploreCatalogError.notOPDS
        }
        return ExploreCatalogPage(
            books: delegate.books,
            selfURL: delegate.selfURL,
            startURL: delegate.startURL,
            nextURL: delegate.nextURL,
            fetchedAt: Date(),
            isStaleCache: false
        )
    }
}

private final class OPDSXMLDelegate: NSObject, XMLParserDelegate {
    private let baseURL: URL
    private let source: ExploreCatalogSource

    private(set) var books: [ExploreBook] = []
    private(set) var selfURL: URL?
    private(set) var startURL: URL?
    private(set) var nextURL: URL?

    private var inEntry = false
    private var currentElement = ""
    private var currentText = ""
    private var entryID = ""
    private var entryTitle = ""
    private var entrySummary = ""
    private var entryContent = ""
    private var entryRights = ""
    private var entryLanguage = ""
    private var entryPublished: Date?
    private var entryUpdated: Date?
    private var authors: [ExploreBookAuthor] = []
    private var subjects: [String] = []
    private var coverURL: URL?
    private var thumbnailURL: URL?
    private var epubURL: URL?
    private var webpageURL: URL?
    private var inAuthor = false
    private var authorName = ""
    private var authorURI: URL?
    private let dateParsers: [ISO8601DateFormatter] = {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return [withFractional, basic]
    }()

    init(baseURL: URL, source: ExploreCatalogSource) {
        self.baseURL = baseURL
        self.source = source
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let local = localName(elementName)
        currentElement = local
        currentText = ""

        switch local {
        case "entry":
            inEntry = true
            resetEntry()
        case "author":
            if inEntry {
                inAuthor = true
                authorName = ""
                authorURI = nil
            }
        case "link":
            handleLink(attributes: attributeDict)
        case "category":
            if inEntry, let term = attributeDict["term"], !term.isEmpty {
                subjects.append(term)
            }
        case "thumbnail" where elementName.contains("media"):
            if inEntry, let raw = attributeDict["url"], let url = resolve(raw) {
                thumbnailURL = url
            }
        default:
            break
        }

        // media:thumbnail arrives as local "thumbnail" when namespaces off, or qualified.
        if elementName == "media:thumbnail" || (local == "thumbnail" && namespaceURI?.contains("yahoo") == true) {
            if inEntry, let raw = attributeDict["url"], let url = resolve(raw) {
                thumbnailURL = url
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let local = localName(elementName)
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if inAuthor {
            switch local {
            case "name":
                authorName = text
            case "uri":
                authorURI = resolve(text)
            case "author":
                if !authorName.isEmpty {
                    authors.append(ExploreBookAuthor(name: authorName, uri: authorURI))
                }
                inAuthor = false
            default:
                break
            }
            currentText = ""
            return
        }

        if inEntry {
            switch local {
            case "id":
                entryID = text
            case "title":
                entryTitle = text
            case "summary":
                entrySummary = text
            case "content":
                entryContent = stripHTML(text)
            case "rights":
                entryRights = text
            case "language", "dc:language":
                entryLanguage = text
            case "published":
                entryPublished = parseDate(text)
            case "updated":
                entryUpdated = parseDate(text)
            case "entry":
                finishEntry()
                inEntry = false
            default:
                break
            }
        }

        currentText = ""
    }

    private func handleLink(attributes: [String: String]) {
        guard let href = attributes["href"], let url = resolve(href) else { return }
        let rel = (attributes["rel"] ?? "").lowercased()
        let type = (attributes["type"] ?? "").lowercased()
        let title = (attributes["title"] ?? "").lowercased()

        if !inEntry {
            if rel == "self" { selfURL = url }
            if rel == "start" { startURL = url }
            if rel == "next" { nextURL = url }
            return
        }

        if rel.contains("opds-spec.org/image/thumbnail") || rel.hasSuffix("/thumbnail") {
            thumbnailURL = url
            return
        }
        if rel.contains("opds-spec.org/image") && !rel.contains("thumbnail") {
            coverURL = url
            return
        }
        if rel == "alternate", type.contains("xhtml") || type.contains("html") {
            webpageURL = url
            return
        }

        let isAcquisition =
            rel.contains("opds-spec.org/acquisition")
            || rel == "enclosure"
            || rel.contains("acquisition")
        let isEPUB =
            type.contains("application/epub+zip")
            || href.lowercased().contains(".epub")
        if isAcquisition && isEPUB {
            let isRecommended = title.contains("recommended")
            let isDiscouraged = title.contains("advanced") || title.contains("kepub")
            if epubURL == nil {
                epubURL = url
            } else if isRecommended {
                epubURL = url
            } else if isDiscouraged {
                // Keep the existing acquisition link.
            } else if epubURL != nil {
                // Keep first non-discouraged link unless a recommended one arrives later.
            }
        }
    }

    private func finishEntry() {
        // Navigation-only entries (subsection) without an EPUB are skipped.
        guard !entryTitle.isEmpty else { return }
        let itemID: String
        if !entryID.isEmpty {
            itemID = entryID
        } else if let epubURL {
            itemID = epubURL.absoluteString
        } else {
            itemID = entryTitle
        }
        let summary = entrySummary.isEmpty ? (entryContent.isEmpty ? nil : entryContent) : entrySummary
        let book = ExploreBook(
            itemID: itemID,
            sourceID: source.id,
            sourceName: source.name,
            title: entryTitle,
            authors: authors,
            summary: summary,
            coverURL: coverURL ?? thumbnailURL,
            epubURL: epubURL,
            language: entryLanguage.isEmpty ? nil : entryLanguage,
            subjects: subjects,
            publishedAt: entryPublished,
            updatedAt: entryUpdated,
            rights: entryRights.isEmpty ? nil : entryRights,
            webpageURL: webpageURL
        )
        // Keep navigation feeds usable: include entries even without epub so
        // callers can still show something; Read/Import will require epubURL.
        books.append(book)
    }

    private func resetEntry() {
        entryID = ""
        entryTitle = ""
        entrySummary = ""
        entryContent = ""
        entryRights = ""
        entryLanguage = ""
        entryPublished = nil
        entryUpdated = nil
        authors = []
        subjects = []
        coverURL = nil
        thumbnailURL = nil
        epubURL = nil
        webpageURL = nil
    }

    private func resolve(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            return absolute
        }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
    }

    private func parseDate(_ text: String) -> Date? {
        for formatter in dateParsers {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private func localName(_ name: String) -> String {
        if let idx = name.lastIndex(of: ":") {
            return String(name[name.index(after: idx)...])
        }
        return name
    }

    private func stripHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
