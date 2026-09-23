//
//  SettingsSyncTests.swift
//  SilveranTests
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit
import Testing

@Suite("Settings sync")
struct SettingsSyncTests {
    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func ll(
        enabled: Bool? = nil,
        enabledAt: TimeInterval? = nil,
        baseURL: String? = nil,
        baseURLAt: TimeInterval? = nil,
    ) -> SyncedAppSettings {
        var document = SyncedAppSettings()
        if let enabled, let enabledAt {
            document.integrations.lazyLibrarian.enabled = TimestampedSetting(
                value: enabled,
                modifiedAt: date(enabledAt),
            )
        }
        if let baseURL, let baseURLAt {
            document.integrations.lazyLibrarian.baseURL = TimestampedSetting(
                value: baseURL,
                modifiedAt: date(baseURLAt),
            )
        }
        return document
    }

    private func journal() throws -> SettingsSyncJournal {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inkamp-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = try #require(
            UserDefaults(suiteName: "inkamp.settings.tests.\(UUID().uuidString)")
        )
        return SettingsSyncJournal(
            fileURL: directory.appendingPathComponent("inkamp.settings.v1.json"),
            defaults: defaults,
        )
    }

    @Test func migrationKeepsExistingLazyLibrarianSettings() {
        let document = SettingsSyncMigration.initialDocument(
            settings: LazyLibrarianLocalSettings(enabled: true, baseURL: " https://ll.home:5299 "),
            configModifiedAt: date(1_700_000_000),
        )
        #expect(document.integrations.lazyLibrarian.enabled?.value == true)
        #expect(document.integrations.lazyLibrarian.baseURL?.value == "https://ll.home:5299")
        #expect(
            document.integrations.lazyLibrarian.enabled?.modifiedAt
                == SettingsSyncMigration.unversionedModifiedAt
        )
        #expect(
            document.integrations.lazyLibrarian.baseURL?.modifiedAt
                == SettingsSyncMigration.unversionedModifiedAt
        )
    }

    @Test func migrationOmitsUntouchedDefaults() {
        let document = SettingsSyncMigration.initialDocument(
            settings: .unset,
            configModifiedAt: date(1_700_000_000),
        )
        #expect(document.hasAnySetting == false)
    }

    @Test func migrationKeepsDisabledIntegrationWhenURLWasSaved() {
        let document = SettingsSyncMigration.initialDocument(
            settings: LazyLibrarianLocalSettings(enabled: false, baseURL: "https://ll.home"),
            configModifiedAt: date(50),
        )
        #expect(document.integrations.lazyLibrarian.enabled?.value == false)
        #expect(document.integrations.lazyLibrarian.baseURL?.value == "https://ll.home")
    }

    @Test func migrationIsIdempotent() throws {
        let store = try journal()
        let first = try store.migrateIfNeeded(
            settings: LazyLibrarianLocalSettings(enabled: true, baseURL: "https://phone"),
            configModifiedAt: date(10),
        )
        let second = try store.migrateIfNeeded(
            settings: LazyLibrarianLocalSettings(enabled: false, baseURL: "https://should-not-replace"),
            configModifiedAt: date(99_000),
        )
        #expect(second == first)
        #expect(second.integrations.lazyLibrarian.baseURL?.value == "https://phone")
        #expect(
            second.integrations.lazyLibrarian.baseURL?.modifiedAt
                == SettingsSyncMigration.unversionedModifiedAt
        )
        #expect(store.migrationCompleted)
    }

    @Test func staleLocalWithNewerConfigMtimeDoesNotOverwriteRemote() throws {
        let store = try journal()
        let legacy = try store.migrateIfNeeded(
            settings: LazyLibrarianLocalSettings(enabled: true, baseURL: "https://stale"),
            configModifiedAt: date(9_000),
        )
        #expect(
            legacy.integrations.lazyLibrarian.baseURL?.modifiedAt
                == SettingsSyncMigration.unversionedModifiedAt
        )
        let remote = ll(enabled: true, enabledAt: 100, baseURL: "https://correct", baseURLAt: 200)
        let plan = SettingsSyncEngine.resolve(local: legacy, remote: .document(remote))
        #expect(plan.document.integrations.lazyLibrarian.baseURL?.value == "https://correct")
        #expect(plan.document.integrations.lazyLibrarian.baseURL?.modifiedAt == date(200))
        #expect(plan.document.integrations.lazyLibrarian.enabled?.value == true)
        #expect(plan.push == false)
    }

    @Test func missingRemoteSeedsLocalLazyLibrarian() throws {
        let store = try journal()
        let legacy = try store.migrateIfNeeded(
            settings: LazyLibrarianLocalSettings(enabled: false, baseURL: "https://ll.home"),
            configModifiedAt: date(9_000),
        )
        let plan = SettingsSyncEngine.resolve(local: legacy, remote: .empty)
        #expect(plan.push)
        #expect(plan.status == .synced)
        #expect(plan.document.integrations.lazyLibrarian.baseURL?.value == "https://ll.home")
        #expect(plan.document.integrations.lazyLibrarian.enabled?.value == false)
    }

    @Test func explicitEditAfterMigrationKeepsPerFieldLastWriteWins() throws {
        let store = try journal()
        _ = try store.migrateIfNeeded(
            settings: LazyLibrarianLocalSettings(enabled: true, baseURL: "https://old"),
            configModifiedAt: date(9_000),
        )
        let edited = try store.recordLazyLibrarianChange(
            enabled: true,
            baseURL: "https://new",
            previousEnabled: true,
            previousBaseURL: "https://old",
            at: date(300),
        )
        #expect(
            edited.integrations.lazyLibrarian.enabled?.modifiedAt
                == SettingsSyncMigration.unversionedModifiedAt
        )
        #expect(edited.integrations.lazyLibrarian.baseURL?.value == "https://new")
        #expect(edited.integrations.lazyLibrarian.baseURL?.modifiedAt == date(300))
        let remote = ll(enabled: false, enabledAt: 250, baseURL: "https://remote", baseURLAt: 100)
        let merged = SettingsSyncMerge.merge(local: edited, remote: remote)
        #expect(merged.integrations.lazyLibrarian.baseURL?.value == "https://new")
        #expect(merged.integrations.lazyLibrarian.enabled?.value == false)
    }

    @Test func firstDeviceCreatesRemoteFromLocalSettings() {
        let local = ll(enabled: true, enabledAt: 10, baseURL: "https://ll", baseURLAt: 10)
        let plan = SettingsSyncEngine.resolve(local: local, remote: .empty)
        #expect(plan.push)
        #expect(plan.document == local)
        #expect(plan.status == .synced)
    }

    @Test func missingSyncedFieldDoesNotClearLocalConfig() {
        let document = ll(enabled: true, enabledAt: 10)
        let applied = SettingsSyncApply.lazyLibrarian(
            document: document,
            config: LazyLibrarianLocalSettings(enabled: false, baseURL: "https://keep"),
        )
        #expect(applied.enabled == true)
        #expect(applied.baseURL == "https://keep")
    }

    @Test func secondDeviceAppliesRemoteSettings() {
        let remote = ll(enabled: true, enabledAt: 10, baseURL: "https://ll", baseURLAt: 10)
        let plan = SettingsSyncEngine.resolve(local: SyncedAppSettings(), remote: .document(remote))
        #expect(plan.push == false)
        #expect(plan.document == remote)
        let applied = SettingsSyncApply.lazyLibrarian(document: plan.document, config: .unset)
        #expect(applied == LazyLibrarianLocalSettings(enabled: true, baseURL: "https://ll"))
    }

    @Test func newerLocalValueBeatsOlderRemote() {
        let local = ll(baseURL: "https://new", baseURLAt: 20)
        let remote = ll(baseURL: "https://old", baseURLAt: 10)
        let merged = SettingsSyncMerge.merge(local: local, remote: remote)
        #expect(merged.integrations.lazyLibrarian.baseURL?.value == "https://new")
    }

    @Test func newerRemoteValueBeatsOlderLocal() {
        let local = ll(baseURL: "https://old", baseURLAt: 10)
        let remote = ll(baseURL: "https://new", baseURLAt: 20)
        let merged = SettingsSyncMerge.merge(local: local, remote: remote)
        #expect(merged.integrations.lazyLibrarian.baseURL?.value == "https://new")
    }

    @Test func independentChangesBothSurvive() {
        let phone = ll(baseURL: "https://from-phone", baseURLAt: 10)
        let pad = ll(enabled: true, enabledAt: 12)
        let merged = SettingsSyncMerge.merge(local: phone, remote: pad)
        let reversed = SettingsSyncMerge.merge(local: pad, remote: phone)
        #expect(merged == reversed)
        #expect(merged.integrations.lazyLibrarian.baseURL?.value == "https://from-phone")
        #expect(merged.integrations.lazyLibrarian.enabled?.value == true)
    }

    @Test func equalTimestampsPickTheSameValueOnBothDevices() {
        let left = ll(baseURL: "https://a", baseURLAt: 10)
        let right = ll(baseURL: "https://b", baseURLAt: 10)
        #expect(
            SettingsSyncMerge.merge(local: left, remote: right)
                == SettingsSyncMerge.merge(local: right, remote: left)
        )
    }

    @Test func editingOneSettingDoesNotRefreshTheOtherTimestamp() {
        let existing = ll(enabled: true, enabledAt: 10, baseURL: "https://ll", baseURLAt: 10)
        let edited = SettingsSyncMerge.applyLocalEdit(
            existing,
            enabled: true,
            baseURL: "https://ll-2",
            at: date(40),
        )
        #expect(edited.integrations.lazyLibrarian.enabled?.modifiedAt == date(10))
        #expect(edited.integrations.lazyLibrarian.baseURL?.value == "https://ll-2")
        #expect(edited.integrations.lazyLibrarian.baseURL?.modifiedAt == date(40))
    }

    @Test func offlineEditPersistsAndSyncsLater() throws {
        let store = try journal()
        let edited = try store.recordLazyLibrarianChange(
            enabled: true,
            baseURL: "https://offline",
            previousEnabled: false,
            previousBaseURL: "",
            at: date(30),
        )
        #expect(store.needsSync)
        let parked = SettingsSyncEngine.resolve(local: edited, remote: .unreachable)
        #expect(parked.push == false)
        #expect(parked.status == .offlineWillSyncLater)
        #expect(parked.document.integrations.lazyLibrarian.baseURL?.value == "https://offline")

        let later = SettingsSyncEngine.resolve(local: parked.document, remote: .empty)
        #expect(later.push)
        #expect(later.document.integrations.lazyLibrarian.baseURL?.value == "https://offline")
        #expect(later.document.integrations.lazyLibrarian.enabled?.value == true)
    }

    @Test func malformedRemoteDoesNotWipeLocalSettings() {
        let local = ll(enabled: true, enabledAt: 10, baseURL: "https://kept", baseURLAt: 10)
        let plan = SettingsSyncEngine.resolve(local: local, remote: .malformed)
        #expect(plan.document == local)
        #expect(plan.push == false)
        #expect(plan.status == .syncError)
        let applied = SettingsSyncApply.lazyLibrarian(
            document: plan.document,
            config: LazyLibrarianLocalSettings(enabled: true, baseURL: "https://kept"),
        )
        #expect(applied.baseURL == "https://kept")
        #expect(applied.enabled == true)
    }

    @Test func unsupportedSchemaDoesNotPushOverRemote() {
        let local = ll(baseURL: "https://local", baseURLAt: 5)
        let plan = SettingsSyncEngine.resolve(local: local, remote: .unsupportedSchema(9))
        #expect(plan.document == local)
        #expect(plan.push == false)
        #expect(plan.status == .schemaMismatch(9))
    }

    @Test func corruptPayloadDoesNotDecodeAsEmpty() {
        #expect(SettingsSyncCodec.inspect("{") == .malformed("json"))
        #expect(SettingsSyncCodec.inspect("{\"schemaVersion\":9}") == .unsupportedSchema(9))
        #expect(SettingsSyncCodec.inspect("") == .empty)
    }

    @Test func schema1ManualSearchEditPromotesToCurrent() throws {
        let store = try journal()
        var v1 = SyncedAppSettings(schemaVersion: 1)
        v1.integrations.lazyLibrarian.enabled = TimestampedSetting(value: true, modifiedAt: date(10))
        v1.integrations.lazyLibrarian.baseURL = TimestampedSetting(
            value: "https://ll.home",
            modifiedAt: date(10),
        )
        try store.save(v1)
        store.migrationCompleted = true
        #expect(store.load()?.schemaVersion == 1)

        let provider = ManualSearchProvider(
            id: "custom-anna",
            name: "My Index",
            searchURLTemplate: "https://index.example/search?q={query}",
            sortOrder: 0,
            isBuiltIn: false,
        )
        let edited = try store.recordManualSearchChange(
            providers: [provider],
            openInAppBrowser: true,
            at: date(40),
        )
        #expect(edited.schemaVersion == 2)
        #expect(edited.integrations.lazyLibrarian.enabled?.value == true)
        #expect(edited.integrations.lazyLibrarian.baseURL?.value == "https://ll.home")
        #expect(edited.integrations.lazyLibrarian.baseURL?.modifiedAt == date(10))
        #expect(edited.integrations.manualSearch.providers?.value.first?.id == "custom-anna")

        let raw = try SettingsSyncCodec.encode(edited)
        guard case .document(let decoded) = SettingsSyncCodec.inspect(raw) else {
            Issue.record("promoted document should round-trip")
            return
        }
        #expect(decoded == edited)
        #expect(decoded.schemaVersion == 2)
        #expect(raw.contains("\"schemaVersion\":2"))
    }

    @Test func schema1LazyLibrarianEditDoesNotPromote() throws {
        let store = try journal()
        var v1 = SyncedAppSettings(schemaVersion: 1)
        v1.integrations.lazyLibrarian.enabled = TimestampedSetting(value: true, modifiedAt: date(10))
        v1.integrations.lazyLibrarian.baseURL = TimestampedSetting(
            value: "https://ll.home",
            modifiedAt: date(10),
        )
        try store.save(v1)
        store.migrationCompleted = true
        let edited = try store.recordLazyLibrarianChange(
            enabled: false,
            baseURL: "https://ll.home",
            previousEnabled: true,
            previousBaseURL: "https://ll.home",
            at: date(40),
        )
        #expect(edited.schemaVersion == 1)
        #expect(edited.integrations.manualSearch.providers == nil)
        #expect(edited.integrations.lazyLibrarian.enabled?.value == false)
        let merged = SettingsSyncMerge.merge(local: edited, remote: v1)
        #expect(merged.schemaVersion == 1)
    }

    @Test func promoteDoesNotDowngradeNewerSchema() {
        var newer = SyncedAppSettings(schemaVersion: 9)
        newer.integrations.manualSearch.openInAppBrowser = TimestampedSetting(
            value: true,
            modifiedAt: date(10),
        )
        #expect(SettingsSyncMerge.promoteSchemaIfNeeded(newer).schemaVersion == 9)
    }

    @Test func roundTripPreservesValuesAndDropsNothing() throws {
        let document = ll(enabled: false, enabledAt: 15, baseURL: "https://ll", baseURLAt: 15)
        let raw = try SettingsSyncCodec.encode(document)
        guard case .document(let decoded) = SettingsSyncCodec.inspect(raw) else {
            Issue.record("decode failed")
            return
        }
        #expect(decoded == document)
        #expect(decoded.schemaVersion == document.schemaVersion)
        #expect(decoded.schemaVersion == SyncedAppSettings.baselineSchemaVersion)
    }

    @Test func credentialsAreNotSerialized() throws {
        let apiKey = "ll-secret-api-key-should-not-appear"
        let document = SettingsSyncMigration.initialDocument(
            settings: LazyLibrarianLocalSettings(enabled: true, baseURL: "https://ll.example:5299"),
            configModifiedAt: date(10),
        )
        let raw = try SettingsSyncCodec.encode(document)
        #expect(!raw.contains(apiKey))
        let json = try JSONSerialization.jsonObject(with: Data(raw.utf8))
        let keys = keyNames(in: json)
        let forbidden = ["apiKey", "api_key", "password", "token", "secret", "authorization", "shelfarrAPIToken"]
        for key in forbidden {
            #expect(!keys.contains(key))
        }
        #expect(keys.contains("enabled"))
        #expect(keys.contains("baseURL"))
        #expect(!keys.contains("lazyLibrarianAPIKey"))
    }

    @Test func nasDownloadsPromoteSchema2To3AndRoundTripFolders() throws {
        let store = try journal()
        var v2 = SyncedAppSettings(schemaVersion: 2)
        v2.integrations.manualSearch.openInAppBrowser = TimestampedSetting(
            value: true,
            modifiedAt: date(10),
        )
        try store.save(v2)
        store.migrationCompleted = true

        let settings = NASDownloadSettingsSnapshot(
            torrentClient: .qbittorrent,
            qbittorrentBaseURL: "http://qb.example:8080",
            qbittorrentUsername: "admin",
            delugeBaseURL: "http://deluge.example:8112",
            synologyBaseURL: "http://nas.example:5000",
            synologyUsername: "josh",
            audiobookFolder: "/volume1/media/books/audiobooks",
            ebookFolder: "/volume1/media/books/books",
            startAutomatically: true,
            createTitleAuthorSubfolders: false,
        )
        let edited = try store.recordNASDownloadsChange(settings, at: date(40))
        #expect(edited.schemaVersion == 3)
        #expect(
            edited.integrations.nasDownloads.audiobookFolder?.value
                == "/volume1/data/media/books/audiobooks"
        )
        #expect(
            edited.integrations.nasDownloads.ebookFolder?.value
                == "/volume1/data/media/books/books"
        )
        #expect(edited.integrations.nasDownloads.torrentClient?.value == .qbittorrent)
        #expect(edited.integrations.manualSearch.openInAppBrowser?.modifiedAt == date(10))

        let raw = try SettingsSyncCodec.encode(edited)
        #expect(raw.contains("\"schemaVersion\":3"))
        #expect(!raw.contains("password"))
        #expect(!raw.contains("secret"))
        #expect(!raw.contains("qbittorrentPassword"))
        #expect(!raw.contains("synologyPassword"))
        #expect(!raw.contains("sid"))
        guard case .document(let decoded) = SettingsSyncCodec.inspect(raw) else {
            Issue.record("NAS document should round-trip")
            return
        }
        #expect(decoded.schemaVersion == 3)
        let applied = SettingsSyncApply.nasDownloads(document: decoded)
        #expect(applied.audiobookFolder == "/volume1/data/media/books/audiobooks")
        #expect(applied.ebookFolder == "/volume1/data/media/books/books")
        #expect(applied.qbittorrentBaseURL == "http://qb.example:8080")
        #expect(applied.synologyBaseURL == "http://nas.example:5000")
        #expect(applied.synologyUsername == "josh")
    }

    @Test func nasCredentialsDoNotSerializeIntoSyncJSON() throws {
        let secret = "nas-super-secret-password"
        var document = SyncedAppSettings(schemaVersion: 3)
        document.integrations.nasDownloads.qbittorrentBaseURL = TimestampedSetting(
            value: "http://qb.example:8080",
            modifiedAt: date(10),
        )
        let raw = try SettingsSyncCodec.encode(document)
        #expect(!raw.contains(secret))
        let json = try JSONSerialization.jsonObject(with: Data(raw.utf8))
        let keys = keyNames(in: json)
        for key in ["password", "token", "secret", "apiKey", "qbittorrentPassword", "synologyPassword"] {
            #expect(!keys.contains(key))
        }
        #expect(keys.contains("qbittorrentBaseURL"))
        #expect(keys.contains("nasDownloads"))
    }

    @Test func nasMissingFieldDoesNotClearLocalFolders() {
        var document = SyncedAppSettings(schemaVersion: 3)
        document.integrations.nasDownloads.audiobookFolder = TimestampedSetting(
            value: "/media/audiobooks",
            modifiedAt: date(10),
        )
        let applied = SettingsSyncApply.nasDownloads(
            document: document,
            current: NASDownloadSettingsSnapshot(
                ebookFolder: "/media/books",
                createTitleAuthorSubfolders: true,
            ),
        )
        #expect(applied.audiobookFolder == "/media/audiobooks")
        #expect(applied.ebookFolder == "/media/books")
        #expect(applied.createTitleAuthorSubfolders == true)
    }

    @Test func explicitEmptyDelugeURLClearsLocalAndStopsFallback() {
        var remote = SyncedAppSettings(schemaVersion: 3)
        remote.integrations.nasDownloads.delugeBaseURL = TimestampedSetting(
            value: "",
            modifiedAt: date(40),
        )
        var local = SyncedAppSettings(schemaVersion: 3)
        local.integrations.nasDownloads.delugeBaseURL = TimestampedSetting(
            value: "http://deluge.example:8112",
            modifiedAt: date(10),
        )
        let merged = SettingsSyncMerge.merge(local: local, remote: remote)
        #expect(merged.integrations.nasDownloads.delugeBaseURL?.value == "")
        let applied = SettingsSyncApply.nasDownloads(
            document: merged,
            current: NASDownloadSettingsSnapshot(delugeBaseURL: "http://deluge.example:8112"),
        )
        #expect(applied.delugeBaseURL == "")
        #expect(SettingsSyncApply.delugeBaseURLToApply(document: merged) == "")
        #expect(applied.resolvedDelugeBaseURL(configURL: "") == "")
        #expect(applied.resolvedDelugeBaseURL(configURL: "   ") == "")
        var reopened = applied
        let resurrected = reopened.resolvedDelugeBaseURL(configURL: "")
        if reopened.trimmedDelugeBaseURL.isEmpty, !resurrected.isEmpty {
            reopened.delugeBaseURL = resurrected
        }
        #expect(reopened.delugeBaseURL == "")
    }

    @Test func missingDelugeURLLeavesLocalConfig() {
        var document = SyncedAppSettings(schemaVersion: 3)
        document.integrations.nasDownloads.torrentClient = TimestampedSetting(
            value: .qbittorrent,
            modifiedAt: date(20),
        )
        let current = NASDownloadSettingsSnapshot(delugeBaseURL: "http://keep.example:8112")
        let applied = SettingsSyncApply.nasDownloads(document: document, current: current)
        #expect(applied.delugeBaseURL == "http://keep.example:8112")
        #expect(SettingsSyncApply.delugeBaseURLToApply(document: document) == nil)
        #expect(
            NASDownloadSettingsSnapshot(delugeBaseURL: "").resolvedDelugeBaseURL(
                configURL: "http://keep.example:8112"
            ) == "http://keep.example:8112"
        )
    }

    @Test func nonEmptyDelugeURLStillSyncs() {
        var remote = SyncedAppSettings(schemaVersion: 3)
        remote.integrations.nasDownloads.delugeBaseURL = TimestampedSetting(
            value: "http://new.example:8112",
            modifiedAt: date(20),
        )
        let applied = SettingsSyncApply.nasDownloads(
            document: remote,
            current: NASDownloadSettingsSnapshot(delugeBaseURL: "http://old.example:8112"),
        )
        #expect(applied.delugeBaseURL == "http://new.example:8112")
        #expect(SettingsSyncApply.delugeBaseURLToApply(document: remote) == "http://new.example:8112")
    }

    @Test func freshDocumentStaysOnBaselineSchema() {
        let empty = SyncedAppSettings()
        #expect(empty.schemaVersion == SyncedAppSettings.baselineSchemaVersion)
        #expect(empty.schemaVersion != 3)
        #expect(SettingsSyncMerge.hasSchema2Fields(empty) == false)
        #expect(SettingsSyncMerge.hasSchema3Fields(empty) == false)
        #expect(SettingsSyncMerge.requiredSchemaVersion(for: empty) == 1)
    }

    @Test func emptyDocumentPlusManualSearchEditIsSchema2() throws {
        let store = try journal()
        store.migrationCompleted = true
        let edited = try store.recordManualSearchChange(
            providers: [],
            openInAppBrowser: true,
            at: date(10),
        )
        #expect(edited.schemaVersion == 2)
        #expect(SettingsSyncMerge.hasSchema3Fields(edited) == false)
    }

    @Test func emptyDocumentPlusNASEditIsSchema3() throws {
        let store = try journal()
        store.migrationCompleted = true
        let edited = try store.recordNASDownloadsChange(
            NASDownloadSettingsSnapshot(delugeBaseURL: "http://deluge.example:8112"),
            at: date(10),
        )
        #expect(edited.schemaVersion == 3)
        #expect(edited.integrations.nasDownloads.delugeBaseURL?.value == "http://deluge.example:8112")
    }

    @Test func emptyLocalPlusSchema2RemoteStaysSchema2() {
        var remote = SyncedAppSettings(schemaVersion: 2)
        remote.integrations.manualSearch.openInAppBrowser = TimestampedSetting(
            value: true,
            modifiedAt: date(10),
        )
        let merged = SettingsSyncMerge.merge(local: SyncedAppSettings(), remote: remote)
        #expect(merged.schemaVersion == 2)
        #expect(SettingsSyncMerge.hasSchema3Fields(merged) == false)
    }

    @Test func schema2RemotePlusLocalNASFieldsIsSchema3() {
        var local = SyncedAppSettings(schemaVersion: 2)
        local.integrations.nasDownloads.audiobookFolder = TimestampedSetting(
            value: "/volume1/media/books/audiobooks",
            modifiedAt: date(20),
        )
        var remote = SyncedAppSettings(schemaVersion: 2)
        remote.integrations.manualSearch.openInAppBrowser = TimestampedSetting(
            value: true,
            modifiedAt: date(10),
        )
        let merged = SettingsSyncMerge.merge(local: local, remote: remote)
        #expect(merged.schemaVersion == 3)
        #expect(merged.integrations.nasDownloads.audiobookFolder?.value == "/volume1/media/books/audiobooks")
        #expect(merged.integrations.manualSearch.openInAppBrowser?.value == true)
    }

    @Test func lazyLibrarianOnlyRemainsSchema1() {
        let document = ll(enabled: true, enabledAt: 10, baseURL: "https://ll", baseURLAt: 10)
        #expect(document.schemaVersion == 1)
        #expect(SettingsSyncMerge.requiredSchemaVersion(for: document) == 1)
        #expect(SettingsSyncMerge.promoteSchemaIfNeeded(document).schemaVersion == 1)
    }

    @Test func schema2ManualSearchMergeDoesNotInventNASFields() {
        var local = SyncedAppSettings(schemaVersion: 2)
        local.integrations.manualSearch.openInAppBrowser = TimestampedSetting(
            value: true,
            modifiedAt: date(10),
        )
        var remote = SyncedAppSettings(schemaVersion: 2)
        remote.integrations.manualSearch.providers = TimestampedSetting(
            value: [],
            modifiedAt: date(12),
        )
        let merged = SettingsSyncMerge.merge(local: local, remote: remote)
        #expect(merged.schemaVersion == 2)
        #expect(SettingsSyncMerge.hasSchema3Fields(merged) == false)
    }

    private func keyNames(in json: Any) -> Set<String> {
        var names = Set<String>()
        if let object = json as? [String: Any] {
            for (key, value) in object {
                names.insert(key)
                names.formUnion(keyNames(in: value))
            }
        } else if let list = json as? [Any] {
            for value in list {
                names.formUnion(keyNames(in: value))
            }
        }
        return names
    }
}
