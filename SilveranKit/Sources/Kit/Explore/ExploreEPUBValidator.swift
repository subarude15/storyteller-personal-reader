import Foundation
import ZIPFoundation

/// Validates downloaded EPUB payloads before Read now / import.
public enum ExploreEPUBValidator {
    public static let maxDownloadBytes: Int64 = 200 * 1024 * 1024  // 200 MB

    public static func validateEPUB(at fileURL: URL, declaredMIME: String?) throws {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        if let size = values.fileSize, Int64(size) > maxDownloadBytes {
            throw ExploreCatalogError.downloadTooLarge
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 512) ?? Data()

        if looksLikeHTML(prefix) || looksLikeJSON(prefix) {
            throw ExploreCatalogError.validationFailed(
                "Download looked like a web page or error response, not an EPUB."
            )
        }

        guard hasZIPMagic(prefix) else {
            throw ExploreCatalogError.validationFailed("File is not a valid ZIP/EPUB archive.")
        }

        if let mime = declaredMIME?.lowercased(),
            !mime.isEmpty,
            !mime.contains("epub"),
            !mime.contains("zip"),
            !mime.contains("octet-stream")
        {
            throw ExploreCatalogError.validationFailed(
                "Unexpected content type for EPUB download."
            )
        }

        let archive: Archive
        do {
            archive = try Archive(url: fileURL, accessMode: .read)
        } catch {
            throw ExploreCatalogError.validationFailed("Could not open EPUB archive.")
        }

        let hasContainer = archive.contains {
            $0.path == "META-INF/container.xml" || $0.path.hasSuffix("/META-INF/container.xml")
        }
        guard hasContainer else {
            throw ExploreCatalogError.validationFailed(
                "EPUB is missing META-INF/container.xml."
            )
        }
    }

    public static func hasZIPMagic(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        // PK\x03\x04 local file header, or PK\x05\x06 empty archive, or PK\x07\x08 spanned
        return data[0] == 0x50 && data[1] == 0x4B
            && (data[2] == 0x03 || data[2] == 0x05 || data[2] == 0x07)
    }

    public static func looksLikeHTML(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else { return false }
        return text.hasPrefix("<!doctype html")
            || text.hasPrefix("<html")
            || text.contains("<html")
            || text.contains("login") && text.contains("<form")
    }

    public static func looksLikeJSON(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return text.hasPrefix("{") || text.hasPrefix("[")
    }
}

/// Lightweight OPF metadata extraction for direct EPUB links.
public enum ExploreEPUBMetadataExtractor {
    public static func extractTitleAndAuthors(from epubURL: URL) -> (title: String?, authors: [String]) {
        guard let archive = try? Archive(url: epubURL, accessMode: .read) else {
            return (nil, [])
        }
        guard let containerEntry = archive["META-INF/container.xml"] else {
            return (nil, [])
        }
        var containerData = Data()
        _ = try? archive.extract(containerEntry) { containerData.append($0) }
        guard let opfPath = findOPFPath(in: containerData),
            let opfEntry = archive[opfPath]
        else {
            return (nil, [])
        }
        var opfData = Data()
        _ = try? archive.extract(opfEntry) { opfData.append($0) }
        return parseOPF(opfData)
    }

    private static func findOPFPath(in containerData: Data) -> String? {
        guard let xml = String(data: containerData, encoding: .utf8) else { return nil }
        // full-path="..."
        guard let range = xml.range(of: #"full-path\s*=\s*"([^"]+)""#, options: .regularExpression)
        else { return nil }
        let match = String(xml[range])
        guard let quote1 = match.firstIndex(of: "\""),
            let quote2 = match.lastIndex(of: "\""),
            quote1 < quote2
        else { return nil }
        let path = String(match[match.index(after: quote1)..<quote2])
        return path.isEmpty ? nil : path
    }

    private static func parseOPF(_ data: Data) -> (title: String?, authors: [String]) {
        let delegate = OPFMetaDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return (delegate.title, delegate.authors)
    }
}

private final class OPFMetaDelegate: NSObject, XMLParserDelegate {
    var title: String?
    var authors: [String] = []
    private var current = ""
    private var text = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        current = elementName
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if local == "title", title == nil, !value.isEmpty {
            title = value
        }
        if local == "creator", !value.isEmpty {
            authors.append(value)
        }
        text = ""
    }
}
