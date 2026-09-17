import Foundation
import Testing
@testable import PlaytorioFetcher

// MARK: - metadata_sources correctness (Wave 2 preamble)
// Definitive sources come from NormalizedBook.metadata_sources (no adapterId on
// .definitive). Enrichment sources come from adapterId via appendSource.

@Test func testMetadataSourcesIncludesDefinitiveAndEnrichments() {
    let definitive = AdapterResult.definitive(
        NormalizedBook(
            title: "The Martian",
            author: "Andy Weir",
            narrator: "R. C. Bray",
            asin: "B00EMXBDMA",
            isbn: "",
            duration_min: 653,
            cover_url: "https://example.com/a.jpg",
            sample_audio_url: "",
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
                size_mb: 1.0
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
    #expect(
        merged?.metadata_sources == [
            "audible-metadata",
            "libgen-catalog",
            "openlibrary-normalizer",
        ]
    )
}

@Test func testMetadataSourcesDedupesWithoutReordering() {
    let definitive = AdapterResult.definitive(
        NormalizedBook(
            title: "The Martian",
            author: "Andy Weir",
            narrator: "",
            asin: "B00EMXBDMA",
            isbn: "",
            duration_min: 1,
            cover_url: "",
            sample_audio_url: "",
            formats: [],
            metadata_sources: ["audible-metadata"]
        )
    )
    let enrichmentA = AdapterResult.enrichment(
        formats: [
            BookFormat(
                source: "libgen",
                format: "epub",
                url: "https://example.com/a.epub",
                size_mb: 1
            )
        ],
        cover_url: nil,
        sample_audio_url: nil,
        adapterId: "audible-metadata"
    )
    let enrichmentB = AdapterResult.enrichment(
        formats: [
            BookFormat(
                source: "libgen",
                format: "mp3",
                url: "https://example.com/b.mp3",
                size_mb: 2
            )
        ],
        cover_url: nil,
        sample_audio_url: nil,
        adapterId: "audible-metadata"
    )
    let inputs = [definitive, enrichmentA, enrichmentB]

    for _ in 0..<10 {
        let merged = BookNormalizer.merge(inputs)
        #expect(merged?.metadata_sources == ["audible-metadata"])
    }
}

@Test func testMetadataSourcesOrderIsStableAcrossRuns() {
    let definitive = AdapterResult.definitive(
        NormalizedBook(
            title: "The Martian",
            author: "Andy Weir",
            narrator: "",
            asin: "B00EMXBDMA",
            isbn: "",
            duration_min: 1,
            cover_url: "",
            sample_audio_url: "",
            formats: [],
            metadata_sources: ["audible-metadata"]
        )
    )
    let enrichmentA = AdapterResult.enrichment(
        formats: [
            BookFormat(
                source: "libgen",
                format: "epub",
                url: "https://example.com/a.epub",
                size_mb: 1
            )
        ],
        cover_url: nil,
        sample_audio_url: nil,
        adapterId: "audible-metadata"
    )
    let enrichmentB = AdapterResult.enrichment(
        formats: [
            BookFormat(
                source: "libgen",
                format: "mp3",
                url: "https://example.com/b.mp3",
                size_mb: 2
            )
        ],
        cover_url: nil,
        sample_audio_url: nil,
        adapterId: "audible-metadata"
    )
    let inputs = [definitive, enrichmentA, enrichmentB]

    let first = BookNormalizer.merge(inputs)?.metadata_sources
    #expect(first == ["audible-metadata"])
    for _ in 0..<10 {
        let again = BookNormalizer.merge(inputs)?.metadata_sources
        #expect(again == first)
    }
}

// MARK: - Orchestrator / library / API

@Test func testDryRunListsEnabledAdaptersByPriority() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("playtorio-dry-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let settings = AdapterSettings(directory: dir)
    var configs = AdapterSettings.defaultConfigs
    for i in configs.indices {
        if configs[i].id == "libgen-catalog" || configs[i].id == "ravebooksearch" {
            configs[i].enabled = false
        }
    }
    try settings.save(configs)

    let service = FetcherService(
        settings: settings,
        cache: BookCache(databasePath: dir.appendingPathComponent("cache.sqlite")),
        library: PlaytorioLibraryStore(databasePath: dir.appendingPathComponent("library.sqlite"))
    )
    let planned = try service.plannedAdapters()
    #expect(planned.map(\.id) == ["audible-metadata", "openlibrary-normalizer"])
    let description = try service.dryRunDescription()
    #expect(description.contains("audible-metadata"))
    #expect(description.contains("openlibrary-normalizer"))
    #expect(!description.contains("libgen-catalog"))
    #expect(!description.contains("ravebooksearch"))
}

@Test func testLibraryPersistSurfacesIngestedBook() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("playtorio-lib-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let html = try MockHTTPClient.fixtureData("audible-sample.html")
    let robots = Data("User-agent: *\nDisallow:\n".utf8)
    let ol = try MockHTTPClient.fixtureData("openlibrary-sample.json")
    let client = MockHTTPClient(responses: [
        (match: "robots.txt", data: robots, status: 200),
        (match: "audible.com", data: html, status: 200),
        (match: "openlibrary.org", data: ol, status: 200),
    ])

    let settings = AdapterSettings(directory: dir)
    var configs = AdapterSettings.defaultConfigs
    for i in configs.indices {
        if configs[i].id == "libgen-catalog" || configs[i].id == "ravebooksearch" {
            configs[i].enabled = false
        }
    }
    try settings.save(configs)

    let libraryPath = dir.appendingPathComponent("library.sqlite")
    let service = FetcherService(
        settings: settings,
        cache: BookCache(databasePath: dir.appendingPathComponent("cache.sqlite")),
        library: PlaytorioLibraryStore(databasePath: libraryPath),
        http: client
    )

    let book = try await service.fetch(query: "B00EMXBDMA", persist: true)
    #expect(book?.asin == "B00EMXBDMA")
    let stored = PlaytorioLibraryStore(databasePath: libraryPath).allBooks()
    #expect(stored.count == 1)
    #expect(stored.first?.asin == "B00EMXBDMA")
}

@Test func testAPISettingsAdaptersRoundTrip() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("playtorio-api-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let service = FetcherService(
        settings: AdapterSettings(directory: dir),
        cache: BookCache(databasePath: dir.appendingPathComponent("cache.sqlite")),
        library: PlaytorioLibraryStore(databasePath: dir.appendingPathComponent("library.sqlite"))
    )
    let api = PlaytorioAPIServer(service: service)

    var configs = AdapterSettings.defaultConfigs
    if let idx = configs.firstIndex(where: { $0.id == "audible-metadata" }) {
        configs[idx].priority = 15
    }
    if let idx = configs.firstIndex(where: { $0.id == "libgen-catalog" }) {
        configs[idx].enabled = false
    }
    let body = try JSONEncoder().encode(configs)
    let (putStatus, putData, _) = try await api.handle(
        method: "PUT",
        path: "/api/settings/adapters",
        query: [:],
        body: body
    )
    #expect(putStatus == 200)

    let (getStatus, getData, _) = try await api.handle(
        method: "GET",
        path: "/api/settings/adapters",
        query: [:],
        body: nil
    )
    #expect(getStatus == 200)
    let loaded = try JSONDecoder().decode([AdapterConfig].self, from: getData)
    #expect(loaded.first { $0.id == "audible-metadata" }?.priority == 15)
    #expect(loaded.first { $0.id == "libgen-catalog" }?.enabled == false)
    _ = putData
}
