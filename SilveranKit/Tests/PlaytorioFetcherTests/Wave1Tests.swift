import Foundation
import SQLite3
import Testing
@testable import PlaytorioFetcher

// MARK: - Normalizer

@Test func testNormalizerDefinitivePlusEnrichment() {
    let definitive = AdapterResult.definitive(
        NormalizedBook(
            title: "The Martian",
            author: "Andy Weir",
            narrator: "R. C. Bray",
            asin: "B00EMXBDMA",
            isbn: "",
            duration_min: 653,
            cover_url: "https://example.com/a.jpg",
            sample_audio_url: "https://example.com/a.mp3",
            formats: [],
            metadata_sources: ["audible-metadata"]
        )
    )
    let libgen = AdapterResult.enrichment(
        formats: [
            BookFormat(
                source: "libgen",
                format: "epub",
                url: "https://example.com/libgen/martian.epub",
                size_mb: 1.25
            )
        ],
        cover_url: nil,
        sample_audio_url: nil,
        adapterId: "libgen-catalog"
    )
    let openlibrary = AdapterResult.enrichment(
        formats: [],
        cover_url: "https://covers.openlibrary.org/b/id/1-L.jpg",
        sample_audio_url: nil,
        adapterId: "openlibrary-normalizer"
    )

    let merged = BookNormalizer.merge([definitive, libgen, openlibrary])
    #expect(merged != nil)
    #expect(merged?.asin == "B00EMXBDMA")
    #expect(merged?.formats.count == 1)
    #expect(merged?.formats.first?.url == "https://example.com/libgen/martian.epub")
    #expect(merged?.cover_url == "https://example.com/a.jpg") // empty-fill only; already set
    #expect(
        merged?.metadata_sources == [
            "audible-metadata",
            "libgen-catalog",
            "openlibrary-normalizer",
        ]
    )
}

@Test func testNormalizerTwoDefinitivesFirstWins() {
    let first = AdapterResult.definitive(
        NormalizedBook(
            title: "First",
            author: "A",
            narrator: "N1",
            asin: "B00FIRST01",
            isbn: "111",
            duration_min: 10,
            cover_url: "https://example.com/first.jpg",
            sample_audio_url: "",
            formats: [],
            metadata_sources: ["audible-metadata"]
        )
    )
    let second = AdapterResult.definitive(
        NormalizedBook(
            title: "Second",
            author: "B",
            narrator: "N2",
            asin: "B00SECOND2",
            isbn: "222",
            duration_min: 99,
            cover_url: "https://example.com/second.jpg",
            sample_audio_url: "https://example.com/second.mp3",
            formats: [],
            metadata_sources: ["other"]
        )
    )

    let merged = BookNormalizer.merge([first, second])
    #expect(merged?.title == "First")
    #expect(merged?.asin == "B00FIRST01")
    #expect(merged?.duration_min == 10)
    #expect(merged?.cover_url == "https://example.com/first.jpg")
    #expect(merged?.metadata_sources == ["audible-metadata"])
}

@Test func testNormalizerEnrichmentOnly() {
    let enrichment = AdapterResult.enrichment(
        formats: [
            BookFormat(
                source: "libgen",
                format: "epub",
                url: "https://example.com/only.epub",
                size_mb: 2
            )
        ],
        cover_url: nil,
        sample_audio_url: nil,
        adapterId: "libgen-catalog"
    )

    let merged = BookNormalizer.merge([enrichment])
    #expect(merged != nil)
    #expect(merged?.title == "")
    #expect(merged?.author == "")
    #expect(merged?.asin == "")
    #expect(merged?.formats.count == 1)
    #expect(merged?.metadata_sources == ["libgen-catalog"])
}

// MARK: - Settings

@Test func testSettingsSaveLoadRoundTrip() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("playtorio-settings-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = AdapterSettings(directory: dir)
    var configs = AdapterSettings.defaultConfigs
    if let idx = configs.firstIndex(where: { $0.id == "audible-metadata" }) {
        configs[idx].priority = 42
        configs[idx].config = ["region": "us"]
    }
    if let idx = configs.firstIndex(where: { $0.id == "libgen-catalog" }) {
        configs[idx].enabled = false
    }

    try store.save(configs)
    let loaded = try store.load()

    #expect(loaded.count == AdapterSettings.defaultConfigs.count)
    let audible = loaded.first { $0.id == "audible-metadata" }
    #expect(audible?.priority == 42)
    #expect(audible?.config["region"] == "us")
    #expect(loaded.first { $0.id == "libgen-catalog" }?.enabled == false)
    #expect(loaded.contains { $0.id == "ravebooksearch" })
}

// MARK: - Cache

@Test func testCacheHitAndExpiry() throws {
    let dbPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("playtorio-cache-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: dbPath) }

    let cache = BookCache(ttlSeconds: 3600, databasePath: dbPath)
    let book = NormalizedBook(
        title: "Cached",
        author: "Auth",
        narrator: "",
        asin: "B00CACHE01",
        isbn: "",
        duration_min: 1,
        cover_url: "",
        sample_audio_url: "",
        formats: [],
        metadata_sources: ["audible-metadata"]
    )

    cache.set(query: "  The Martian ", book: book)
    let hit = cache.get(query: "the martian")
    #expect(hit == book)

    // Age the row beyond TTL.
    var db: OpaquePointer?
    #expect(sqlite3_open(dbPath.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    let old = Int64(Date().timeIntervalSince1970) - 10_000
    let update = "UPDATE cache SET fetched_at = \(old);"
    #expect(sqlite3_exec(db, update, nil, nil, nil) == SQLITE_OK)

    let expired = cache.get(query: "the martian")
    #expect(expired == nil)
}

// MARK: - Adapters (fixtures only)

@Test func testAudibleAdapterParsesFixture() async throws {
    let html = try MockHTTPClient.fixtureData("audible-sample.html")
    let robots = Data("User-agent: *\nDisallow:\n".utf8)
    let client = MockHTTPClient(responses: [
        (match: "robots.txt", data: robots, status: 200),
        (match: "/pd/", data: html, status: 200),
    ])
    let adapter = AudibleAdapter(http: client)
    let result = try await adapter.fetch(query: "B00EMXBDMA")
    guard case .definitive(let book) = result else {
        Issue.record("expected definitive, got \(result)")
        return
    }
    #expect(book.asin == "B00EMXBDMA")
    #expect(book.title == "The Martian")
    #expect(book.author == "Andy Weir")
    #expect(book.narrator == "R. C. Bray")
    #expect(book.duration_min == 653)
}

@Test func testLibGenAdapterParsesFixture() async throws {
    let html = try MockHTTPClient.fixtureData("libgen-sample.html")
    let client = MockHTTPClient(responses: [
        (match: "libgen.is", data: html, status: 200),
    ])
    let adapter = LibGenAdapter(http: client)
    let result = try await adapter.fetch(query: "The Martian")
    guard case .enrichment(let formats, _, _, let adapterId) = result else {
        Issue.record("expected enrichment, got \(result)")
        return
    }
    #expect(adapterId == "libgen-catalog")
    #expect(formats.count == 2)
    #expect(formats.map(\.format).sorted() == ["epub", "mp3"])
    #expect(formats.allSatisfy { $0.source == "libgen" })
    #expect(formats.contains { $0.url.contains("martian.epub") })
}

@Test func testOpenLibraryAdapterParsesFixture() async throws {
    let json = try MockHTTPClient.fixtureData("openlibrary-sample.json")
    let client = MockHTTPClient(responses: [
        (match: "openlibrary.org", data: json, status: 200),
    ])
    let adapter = OpenLibraryAdapter(http: client)
    let result = try await adapter.fetch(query: "9780804139021")
    guard case .enrichment(let formats, let cover, _, let adapterId) = result else {
        Issue.record("expected enrichment, got \(result)")
        return
    }
    #expect(adapterId == "openlibrary-normalizer")
    #expect(formats.isEmpty)
    #expect(cover == "https://covers.openlibrary.org/b/id/8765432-L.jpg")
}
