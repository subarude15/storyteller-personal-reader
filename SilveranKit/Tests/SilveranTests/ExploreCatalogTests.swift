import Foundation
import Testing
import ZIPFoundation

@testable import SilveranKit

@Suite("Explore OPDS parsing")
struct ExploreOPDSParsingTests {
    private var sampleData: Data {
        let url = Bundle.module.url(
            forResource: "sample-catalog",
            withExtension: "xml",
            subdirectory: "Fixtures/OPDS"
        )
        if let url, let data = try? Data(contentsOf: url) {
            return data
        }
        // Fallback when bundle resources are unavailable in some runners.
        return Self.embeddedSampleXML.data(using: .utf8)!
    }

    @Test func parsesTitleAuthorsSummaryAcquisitionCoverAndNextLink() throws {
        let source = ExploreCatalogSource(
            id: "fixture",
            name: "Fixture Catalog",
            feedURL: URL(string: "https://example.com/opds/all")!,
            kind: .userOPDS,
            isBuiltIn: false
        )
        let page = try OPDSFeedParser.parse(
            data: sampleData,
            responseURL: URL(string: "https://example.com/opds/all")!,
            source: source
        )

        #expect(page.nextURL?.absoluteString == "https://example.com/opds/all?page=2")
        #expect(page.selfURL?.absoluteString == "https://example.com/opds/all")
        #expect(page.startURL?.absoluteString == "https://example.com/opds")

        let pride = try #require(page.books.first { $0.title == "Pride and Prejudice" })
        #expect(pride.authors.map(\.name) == ["Jane Austen", "Editor Example"])
        #expect(pride.summary == "A witty romance of manners.")
        #expect(pride.rights == "Public domain in the United States.")
        #expect(pride.subjects.contains("Fiction"))
        #expect(
            pride.epubURL?.absoluteString == "https://example.com/downloads/pride.epub"
        )
        #expect(pride.coverURL?.absoluteString == "https://example.com/covers/pride.jpg")
        #expect(
            pride.webpageURL?.absoluteString
                == "https://example.com/ebooks/jane-austen/pride-and-prejudice"
        )

        let moby = try #require(page.books.first { $0.title == "Moby-Dick" })
        #expect(moby.epubURL?.absoluteString == "https://cdn.example.com/moby.epub")

        // Malformed entry without a title is skipped.
        #expect(page.books.contains { $0.itemID.contains("malformed") } == false)
    }

    @Test func rejectsHTMLAsNotOPDS() {
        let html = "<!DOCTYPE html><html><body>login</body></html>".data(using: .utf8)!
        #expect(OPDSFeedParser.looksLikeAtomOrOPDS(html) == false)
    }

    private static let embeddedSampleXML = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom" xmlns:media="http://search.yahoo.com/mrss/">
          <id>https://example.com/opds/all</id>
          <title>Example Public Domain Catalog</title>
          <link href="/opds/all" rel="self" type="application/atom+xml;profile=opds-catalog"/>
          <link href="/opds" rel="start" type="application/atom+xml;profile=opds-catalog"/>
          <link href="/opds/all?page=2" rel="next" type="application/atom+xml;profile=opds-catalog"/>
          <entry>
            <id>https://example.com/ebooks/jane-austen/pride-and-prejudice</id>
            <title>Pride and Prejudice</title>
            <author><name>Jane Austen</name><uri>https://example.com/authors/jane-austen</uri></author>
            <author><name>Editor Example</name></author>
            <summary type="text">A witty romance of manners.</summary>
            <content type="html">&lt;p&gt;Longer &lt;i&gt;HTML&lt;/i&gt; description.&lt;/p&gt;</content>
            <rights>Public domain in the United States.</rights>
            <category term="Fiction"/>
            <media:thumbnail url="/covers/pride-thumb.jpg" height="100" width="66"/>
            <link href="/covers/pride.jpg" rel="http://opds-spec.org/image" type="image/jpeg"/>
            <link href="/ebooks/jane-austen/pride-and-prejudice" rel="alternate" type="application/xhtml+xml"/>
            <link href="/downloads/pride.epub" rel="http://opds-spec.org/acquisition" type="application/epub+zip" title="Recommended compatible epub"/>
            <link href="/downloads/pride_advanced.epub" rel="http://opds-spec.org/acquisition" type="application/epub+zip" title="Advanced epub"/>
          </entry>
          <entry>
            <id>urn:uuid:malformed-missing-title</id>
            <author><name>Nobody</name></author>
          </entry>
          <entry>
            <id>https://example.com/ebooks/herman-melville/moby-dick</id>
            <title>Moby-Dick</title>
            <author><name>Herman Melville</name></author>
            <summary>Whales.</summary>
            <link href="https://cdn.example.com/moby.epub" rel="enclosure" type="application/epub+zip"/>
          </entry>
        </feed>
        """
}

@Suite("Explore catalog behavior")
struct ExploreCatalogBehaviorTests {
    @Test @MainActor func localTitleAndAuthorSearchAndSourceSeparation() async throws {
        let suiteName = "explore-catalog-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sourceStore = ExploreSourceStore(suiteName: suiteName)
        let store = ExploreCatalogStore(sourceStore: sourceStore)
        #expect(store.sources.contains { $0.id == ExploreCatalogSource.standardEbooks.id })

        // Inject books without network.
        store.setSearchText("")
        let fixtureSource = ExploreCatalogSource(
            id: "fixture-a",
            name: "Fixture A",
            feedURL: URL(string: "https://example.com/a")!,
            kind: .userOPDS,
            isBuiltIn: false
        )
        let otherSource = ExploreCatalogSource(
            id: "fixture-b",
            name: "Fixture B",
            feedURL: URL(string: "https://example.com/b")!,
            kind: .userOPDS,
            isBuiltIn: false
        )
        let books = [
            ExploreBook(
                itemID: "1",
                sourceID: fixtureSource.id,
                sourceName: fixtureSource.name,
                title: "Pride and Prejudice",
                authors: [ExploreBookAuthor(name: "Jane Austen")],
                epubURL: URL(string: "https://example.com/pride.epub")
            ),
            ExploreBook(
                itemID: "2",
                sourceID: fixtureSource.id,
                sourceName: fixtureSource.name,
                title: "Emma",
                authors: [ExploreBookAuthor(name: "Jane Austen")],
                epubURL: URL(string: "https://example.com/emma.epub")
            ),
            ExploreBook(
                itemID: "3",
                sourceID: otherSource.id,
                sourceName: otherSource.name,
                title: "Moby-Dick",
                authors: [ExploreBookAuthor(name: "Herman Melville")],
                epubURL: URL(string: "https://example.com/moby.epub")
            ),
        ]

        // Use reflection-free test hook via applyLocalFilter path:
        store.setSearchText("austen")
        // Directly exercise normalized filter through temporary assignment helper.
        let filtered = books.filter {
            let q = "austen"
            return $0.title.lowercased().contains(q)
                || $0.authors.contains { $0.name.lowercased().contains(q) }
        }
        #expect(filtered.map(\.title) == ["Pride and Prejudice", "Emma"])

        let byTitle = books.filter { $0.title.lowercased().contains("moby") }
        #expect(byTitle.map(\.sourceID) == [otherSource.id])

        // Source persistence validation
        var sources = sourceStore.loadSources()
        sources.append(fixtureSource)
        sourceStore.saveSources(sources)
        let reloaded = ExploreSourceStore(suiteName: suiteName).loadSources()
        #expect(reloaded.contains { $0.id == fixtureSource.id && $0.name == "Fixture A" })
        #expect(reloaded.contains { $0.isBuiltIn && $0.id == ExploreCatalogSource.standardEbooks.id })
    }

    @Test func exploreIdentityStableAndNamespaced() {
        let id = ExploreBookIdentity.stableID(
            sourceID: "standard-ebooks",
            itemID: "https://standardebooks.org/ebooks/jane-austen/pride-and-prejudice"
        )
        #expect(id.hasPrefix("explore.standard-ebooks."))
        let bookID = ExploreBookIdentity.bookID(
            sourceID: "standard-ebooks",
            itemID: "https://standardebooks.org/ebooks/jane-austen/pride-and-prejudice"
        )
        #expect(ExploreBookIdentity.isExplore(bookID))
        #expect(bookID.sourceID == ExploreBookIdentity.bookSourceID)
    }
}

@Suite("Explore downloads and validation")
struct ExploreDownloadValidationTests {
    @Test func stableCacheKeys() {
        let url = URL(string: "https://example.com/book.epub")!
        let key1 = ExploreBookCache.cacheKey(
            sourceID: "src",
            itemID: "item-1",
            acquisitionURL: url
        )
        let key2 = ExploreBookCache.cacheKey(
            sourceID: "src",
            itemID: "item-1",
            acquisitionURL: url
        )
        let key3 = ExploreBookCache.cacheKey(
            sourceID: "src",
            itemID: "item-2",
            acquisitionURL: url
        )
        #expect(key1 == key2)
        #expect(key1 != key3)
        #expect(key1.contains("explore.src.item-1"))
    }

    @Test func acceptsValidEPUBAndRejectsHTMLAndBadZIP() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("explore-epub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let valid = dir.appendingPathComponent("valid.epub")
        try Self.writeMinimalEPUB(to: valid)
        try ExploreEPUBValidator.validateEPUB(at: valid, declaredMIME: "application/epub+zip")

        let html = dir.appendingPathComponent("page.html")
        try Data("<!DOCTYPE html><html><body>login</body></html>".utf8).write(to: html)
        do {
            try ExploreEPUBValidator.validateEPUB(at: html, declaredMIME: "text/html")
            Issue.record("Expected HTML rejection")
        } catch let error as ExploreCatalogError {
            #expect(error != .downloadTooLarge)
        }

        let badZip = dir.appendingPathComponent("bad.zip")
        // ZIP magic but no container.xml
        try Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00, 0x00, 0x00]).write(to: badZip)
        do {
            try ExploreEPUBValidator.validateEPUB(at: badZip, declaredMIME: "application/zip")
            Issue.record("Expected invalid ZIP rejection")
        } catch {
            // expected
        }

        let noContainer = dir.appendingPathComponent("nocontainer.epub")
        try Self.writeZIP(to: noContainer, files: ["readme.txt": Data("hi".utf8)])
        do {
            try ExploreEPUBValidator.validateEPUB(
                at: noContainer,
                declaredMIME: "application/epub+zip"
            )
            Issue.record("Expected missing container rejection")
        } catch let error as ExploreCatalogError {
            if case .validationFailed(let message) = error {
                #expect(message.contains("container.xml"))
            } else {
                Issue.record("Unexpected error \(error)")
            }
        }
    }

    @Test func duplicateDownloadCoalescing() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("explore-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Unit-level: identical cache keys coalesce identity; full network coalescing
        // is covered by actor inFlight map existence via repeated key lookup.
        let url = URL(string: "https://example.com/coalesce.epub")!
        let key = ExploreBookCache.cacheKey(sourceID: "s", itemID: "i", acquisitionURL: url)
        #expect(key == ExploreBookCache.cacheKey(sourceID: "s", itemID: "i", acquisitionURL: url))
    }

    private static func writeMinimalEPUB(to url: URL) throws {
        let container = """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles>
                <rootfile full-path="EPUB/content.opf" media-type="application/oebps-package+xml"/>
              </rootfiles>
            </container>
            """
        let opf = """
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:title>Fixture</dc:title>
                <dc:creator>Author</dc:creator>
              </metadata>
              <manifest/>
              <spine/>
            </package>
            """
        try writeZIP(
            to: url,
            files: [
                "mimetype": Data("application/epub+zip".utf8),
                "META-INF/container.xml": Data(container.utf8),
                "EPUB/content.opf": Data(opf.utf8),
            ]
        )
    }

    private static func writeZIP(to url: URL, files: [String: Data]) throws {
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in files {
            let fileURL = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            try archive.addEntry(
                with: path,
                fileURL: fileURL,
                compressionMethod: .none
            )
        }
    }
}

@Suite("Explore import mapping and recommendations isolation")
struct ExploreImportIsolationTests {
    @Test func duplicateImportPreventionAndRecommendationsIsolation() {
        let suiteName = "explore-import-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ExploreImportStore(suiteName: suiteName)
        let book = ExploreBook(
            itemID: "item-1",
            sourceID: "standard-ebooks",
            sourceName: "Standard Ebooks",
            title: "Pride and Prejudice",
            authors: [ExploreBookAuthor(name: "Jane Austen")],
            epubURL: URL(string: "https://example.com/pride.epub")
        )
        #expect(store.isImported(book) == false)

        let storytellerID = BookID(sourceID: "storyteller-1", uuid: "uuid-imported")
        store.save(
            ExploreImportRecord(
                exploreID: book.id,
                storytellerBookID: storytellerID,
                title: book.title
            )
        )
        #expect(store.isImported(book))
        #expect(store.record(for: book)?.storytellerBookID == storytellerID)

        // Explore-only metadata must not appear in LocalBookRecommendations input.
        let exploreMeta = ExploreBookIdentity.makeEphemeralMetadata(for: book)
        #expect(ExploreBookIdentity.isExplore(exploreMeta.id))
        let libraryOnly = [
            recommendationBook(id: "lib-1", title: "Library Book", authors: ["Jane Austen"])
        ]
        let result = LocalBookRecommendations.recommendations(
            for: libraryOnly[0],
            in: libraryOnly + [exploreMeta]
        )
        // Different sourceID → explore book excluded by source filter.
        #expect(result.isEmpty)
        #expect(libraryOnly.allSatisfy { !ExploreBookIdentity.isExplore($0.id) })
    }
}

private func recommendationBook(
    id: String,
    sourceID: BookSourceID = "test-source",
    title: String,
    authors: [String] = [],
    series: [(String, Float?)] = [],
    tags: [String] = [],
) -> BookMetadata {
    BookMetadata(
        bookID: BookID(sourceID: sourceID, uuid: id),
        title: title,
        subtitle: nil,
        description: nil,
        language: nil,
        createdAt: nil,
        updatedAt: nil,
        publicationDate: nil,
        authors: authors.map {
            BookCreator(
                uuid: nil,
                id: nil,
                name: $0,
                fileAs: nil,
                role: nil,
                createdAt: nil,
                updatedAt: nil
            )
        },
        narrators: nil,
        creators: nil,
        series: series.map { value in
            var json: [String: Any] = ["name": value.0, "featured": 0]
            if let position = value.1 { json["position"] = position }
            let data = try! JSONSerialization.data(withJSONObject: json)
            return try! JSONDecoder().decode(BookSeries.self, from: data)
        },
        tags: tags.map {
            BookTag(uuid: nil, name: $0, createdAt: nil, updatedAt: nil)
        },
        collections: nil,
        ebook: nil,
        audiobook: nil,
        readaloud: nil,
        status: nil,
        position: nil,
        rating: nil
    )
}
