//
//  ManualSearchProviderTests.swift
//  SilveranTests
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit
import Testing

@Suite("Manual Search provider model")
struct ManualSearchProviderTests {
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func journal() throws -> SettingsSyncJournal {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inkamp-manual-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = try #require(
            UserDefaults(suiteName: "inkamp.manual-search.tests.\(UUID().uuidString)")
        )
        return SettingsSyncJournal(
            fileURL: directory.appendingPathComponent("inkamp.settings.v1.json"),
            defaults: defaults,
        )
    }

    private var customProvider: ManualSearchProvider {
        ManualSearchProvider(
            id: "custom-anna",
            name: "My Index",
            searchURLTemplate: "https://index.example/search?q={query}",
            supportedMediaTypes: [.ebook],
            symbolName: "globe",
            sortOrder: 10,
            isBuiltIn: false,
        )
    }

    @Test func customProviderSaveAndLoad() throws {
        let store = try journal()
        var providers = ManualSearchCatalog.builtIn
        providers.append(customProvider)
        let edited = try store.recordManualSearchChange(
            providers: providers,
            openInAppBrowser: true,
            at: date(20),
        )
        #expect(store.needsSync)
        let loaded = try #require(store.load())
        #expect(loaded == edited)
        let applied = SettingsSyncApply.manualSearch(document: loaded)
        #expect(applied.providers.contains { $0.id == "custom-anna" && $0.name == "My Index" })
        #expect(applied.openInAppBrowser)
    }

    @Test func enableDisableSurvivesResolve() {
        var disabled = ManualSearchCatalog.builtIn
        disabled[0].enabled = false
        let resolved = ManualSearchCatalog.resolve(synced: disabled)
        #expect(resolved.first { $0.id == "open-library" }?.enabled == false)
        #expect(resolved.first { $0.id == "internet-archive" }?.enabled == true)
    }

    @Test func orderingIsPreserved() {
        let reordered = ManualSearchCatalog.reindex([
            ManualSearchCatalog.builtIn[2],
            ManualSearchCatalog.builtIn[0],
            customProvider,
        ])
        #expect(reordered.map(\.id) == ["project-gutenberg", "open-library", "custom-anna"])
        #expect(reordered.map(\.sortOrder) == [0, 1, 2])
        let resolved = ManualSearchCatalog.resolve(synced: reordered)
        #expect(resolved.first?.id == "project-gutenberg")
        #expect(resolved.contains { $0.id == "librivox" })
    }

    @Test func syncedSerializationRoundTrip() throws {
        var document = SyncedAppSettings()
        document.integrations.manualSearch.providers = TimestampedSetting(
            value: ManualSearchCatalog.builtIn + [customProvider],
            modifiedAt: date(15),
        )
        document.integrations.manualSearch.openInAppBrowser = TimestampedSetting(
            value: true,
            modifiedAt: date(15),
        )
        let raw = try SettingsSyncCodec.encode(document)
        guard case .document(let decoded) = SettingsSyncCodec.inspect(raw) else {
            Issue.record("decode failed")
            return
        }
        #expect(decoded == document)
        #expect(!raw.contains("apiKey"))
        #expect(!raw.contains("password"))
        #expect(raw.contains("custom-anna"))
    }

    @Test func malformedProviderURLRejected() {
        #expect(
            ManualSearchProviderValidation.validateTemplate("javascript:alert(1)") == .failure(.unsupportedScheme)
        )
        #expect(ManualSearchProviderValidation.validateTemplate("") == .failure(.emptyTemplate))
        #expect(ManualSearchProviderValidation.validateTemplate("notaurl") == .failure(.malformedTemplate))
        let bad = ManualSearchProvider(
            id: "x",
            name: "Bad",
            searchURLTemplate: "ftp://example.com/{query}",
            sortOrder: 0,
            isBuiltIn: false,
        )
        #expect(ManualSearchProviderValidation.validateForSave(bad) == .unsupportedScheme)
    }

    @Test func newerProviderListWinsPerField() {
        var local = SyncedAppSettings()
        local.integrations.manualSearch.providers = TimestampedSetting(
            value: [customProvider],
            modifiedAt: date(30),
        )
        var remote = SyncedAppSettings()
        remote.integrations.manualSearch.providers = TimestampedSetting(
            value: ManualSearchCatalog.builtIn,
            modifiedAt: date(10),
        )
        remote.integrations.manualSearch.openInAppBrowser = TimestampedSetting(
            value: false,
            modifiedAt: date(40),
        )
        let merged = SettingsSyncMerge.merge(local: local, remote: remote)
        #expect(merged.integrations.manualSearch.providers?.value.first?.id == "custom-anna")
        #expect(merged.integrations.manualSearch.openInAppBrowser?.value == false)
    }

    @Test func manualSearchEditDoesNotBlockLazyLibrarianMigration() throws {
        let store = try journal()
        _ = try store.recordManualSearchChange(
            providers: [customProvider],
            openInAppBrowser: true,
            at: date(20),
        )
        #expect(!store.migrationCompleted)
        let migrated = try store.migrateIfNeeded(
            settings: LazyLibrarianLocalSettings(enabled: true, baseURL: "https://ll.home"),
        )
        #expect(migrated.integrations.lazyLibrarian.baseURL?.value == "https://ll.home")
        #expect(migrated.integrations.manualSearch.providers?.value.contains { $0.id == "custom-anna" } == true)
    }

    @Test func v1SettingsDocumentStillDecodes() throws {
        let raw = """
            {"schemaVersion":1,"integrations":{"lazyLibrarian":{"enabled":{"value":true,"modifiedAt":"2024-01-01T00:00:00Z"}}}}
            """
        guard case .document(let document) = SettingsSyncCodec.inspect(raw) else {
            Issue.record("v1 document should decode")
            return
        }
        #expect(document.integrations.lazyLibrarian.enabled?.value == true)
        #expect(document.integrations.manualSearch.providers == nil)
        let applied = SettingsSyncApply.manualSearch(document: document)
        #expect(applied.providers.map(\.id) == ManualSearchCatalog.builtIn.map(\.id))
    }
}
