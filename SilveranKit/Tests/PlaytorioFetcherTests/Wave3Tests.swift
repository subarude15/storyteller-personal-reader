import Foundation
import Testing
@testable import PlaytorioFetcher

// MARK: - RaveBookSearch

@Test func testRaveBookSearchParsesJSONFixture() async throws {
    let json = try MockHTTPClient.fixtureData("ravebooksearch-sample.json")
    let client = MockHTTPClient(responses: [
        (match: "search/all", data: json, status: 200),
    ])
    let adapter = RaveBookSearchAdapter(http: client)
    let result = try await adapter.fetch(query: "Project Hail Mary")
    guard case .definitive(let book) = result else {
        Issue.record("expected definitive, got \(result)")
        return
    }
    #expect(book.title == "Project Hail Mary")
    #expect(book.author == "Andy Weir")
    #expect(book.isbn == "9780593135211")
    #expect(book.cover_url.contains("hail-mary.jpg"))
    #expect(book.metadata_sources == ["ravebooksearch"])
    #expect(book.formats.count >= 2)
    #expect(book.formats.contains { $0.format == "epub" && $0.url.contains("hail-mary-direct.epub") })
    #expect(book.formats.contains { $0.url.contains("hail-mary-alt.epub") })
}

@Test func testRaveBookSearchParsesHTMLFixture() {
    let html = String(data: try! MockHTTPClient.fixtureData("ravebooksearch-sample.html"), encoding: .utf8)!
    let book = RaveBookSearchAdapter.parseWorkerHTML(html)
    #expect(book?.title == "The Martian")
    #expect(book?.author == "Andy Weir")
    #expect(book?.isbn == "9780804139021")
    #expect(book?.formats.count == 2)
    #expect(book?.formats.map(\.format).sorted() == ["epub", "pdf"])
    #expect(book?.formats.contains { $0.url.contains("martian-direct.epub") } == true)
}

@Test func testRaveBookSearchMalformedBaseURLThrows() {
    let config = AdapterConfig(
        id: "ravebooksearch",
        name: "Rave",
        enabled: true,
        type: "catalog",
        priority: 5,
        config: ["baseURL": "not a url"]
    )
    #expect(throws: AdapterConfigurationError.self) {
        try RaveBookSearchAdapter.buildSearchURL(query: "dune", config: config)
    }
}

// MARK: - User source CRUD persistence

@Test func testUserSourceCRUDPersistsAcrossReload() throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("playtorio-crud-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let settings = AdapterSettings(directory: dir)
    var configs = AdapterSettings.defaultConfigs
    let dummy = AdapterConfig(
        id: "user-dummy01",
        name: "Dummy Source",
        enabled: true,
        type: "custom",
        priority: 40,
        config: ["baseURL": "https://example.com/search"]
    )
    configs.append(dummy)
    try settings.save(configs)

    var loaded = try AdapterSettings(directory: dir).load()
    #expect(loaded.contains { $0.id == "user-dummy01" && $0.name == "Dummy Source" })

    // Edit name
    if let idx = loaded.firstIndex(where: { $0.id == "user-dummy01" }) {
        loaded[idx].name = "Dummy Source Renamed"
    }
    try AdapterSettings(directory: dir).save(loaded)

    let afterEdit = try AdapterSettings(directory: dir).load()
    #expect(afterEdit.first { $0.id == "user-dummy01" }?.name == "Dummy Source Renamed")

    // Delete
    let afterDelete = afterEdit.filter { $0.id != "user-dummy01" }
    try AdapterSettings(directory: dir).save(afterDelete)
    let final = try AdapterSettings(directory: dir).load()
    #expect(!final.contains { $0.id == "user-dummy01" })
}

@Test func testMakeAdapterRejectsCustomWithoutBaseURL() {
    let service = FetcherService()
    let bad = AdapterConfig(
        id: "user-bad",
        name: "Bad",
        enabled: true,
        type: "custom",
        priority: 99,
        config: [:]
    )
    #expect(throws: AdapterConfigurationError.self) {
        try service.makeAdapter(for: bad)
    }
}

@Test func testFetchSurfacesSourceConfigurationError() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("playtorio-cfgerr-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let settings = AdapterSettings(directory: dir)
    // Only a broken custom source enabled.
    let configs = [
        AdapterConfig(
            id: "user-broken",
            name: "Broken",
            enabled: true,
            type: "custom",
            priority: 1,
            config: ["baseURL": "ftp://not-supported.example"]
        )
    ]
    try settings.save(configs)

    let service = FetcherService(
        settings: settings,
        cache: BookCache(databasePath: dir.appendingPathComponent("cache.sqlite")),
        library: PlaytorioLibraryStore(databasePath: dir.appendingPathComponent("library.sqlite"))
    )

    do {
        _ = try await service.fetch(query: "anything", persist: false)
        Issue.record("expected Source configuration error")
    } catch let error as AdapterConfigurationError {
        #expect(error.localizedDescription == "Source configuration error")
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test func testDynamicReloadPicksUpNewUserSource() async throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("playtorio-dyn-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let json = try MockHTTPClient.fixtureData("ravebooksearch-sample.json")
    let client = MockHTTPClient(responses: [
        (match: "example.com", data: json, status: 200),
    ])
    let settings = AdapterSettings(directory: dir)
    // Start with nothing enabled.
    try settings.save([
        AdapterConfig(
            id: "audible-metadata",
            name: "Audible Metadata",
            enabled: false,
            type: "metadata",
            priority: 10,
            config: [:]
        )
    ])

    let service = FetcherService(
        settings: settings,
        cache: BookCache(databasePath: dir.appendingPathComponent("cache.sqlite")),
        library: PlaytorioLibraryStore(databasePath: dir.appendingPathComponent("library.sqlite")),
        http: client
    )
    #expect(try await service.fetch(query: "Project Hail Mary", persist: false) == nil)

    // Add a user Rave-style source; next fetch must pick it up without recreating FetcherService.
    try settings.save([
        AdapterConfig(
            id: "user-rave",
            name: "My Rave",
            enabled: true,
            type: "rave",
            priority: 5,
            config: [
                "baseURL": "https://example.com",
                "searchPath": "/search/all",
                "mode": "ebooks",
            ]
        )
    ])

    let book = try await service.fetch(query: "Project Hail Mary", persist: true)
    #expect(book?.title == "Project Hail Mary")
    #expect(book?.author == "Andy Weir")
    #expect(book?.formats.isEmpty == false)
    #expect(service.library.count() == 1)
}
