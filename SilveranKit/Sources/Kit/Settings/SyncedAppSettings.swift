//
//  SyncedAppSettings.swift
//  SilveranKit
//
//  Account-level settings stored in the private Storyteller collection
//  `.inkamp.settings.v1` (same auth and collection-description blob as
//  Stats / podcast sync). Last-write-wins per value, matching
//  PodcastSyncMerge's newer-`updatedAt` rule. One merge implementation.
//
//  Shape (only populated sections are written):
//  schemaVersion
//  integrations
//    lazyLibrarian   enabled, baseURL
//    manualSearch    providers, openInAppBrowser
//    shelfarr        (future)
//  playback            (future)
//  podcastPreferences  (future)
//  libraryPreferences  (future)
//  uiPreferences       (future)
//
//  Device-local, never written here: Keychain credentials, downloads,
//  caches, notification authorization, playback sessions, audio route,
//  storage paths, diagnostics.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// One synced value plus the time it was last changed on any device.
public struct TimestampedSetting<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var value: Value
    public var modifiedAt: Date

    public init(value: Value, modifiedAt: Date) {
        self.value = value
        self.modifiedAt = modifiedAt
    }
}

/// Non-secret LazyLibrarian preferences that already exist in Settings.
public struct LazyLibrarianLocalSettings: Equatable, Sendable {
    public var enabled: Bool
    public var baseURL: String

    public init(enabled: Bool, baseURL: String) {
        self.enabled = enabled
        self.baseURL = baseURL
    }

    public static let unset = LazyLibrarianLocalSettings(enabled: false, baseURL: "")
}

/// Versioned account settings blob. Credentials are not fields on this type.
public struct SyncedAppSettings: Codable, Equatable, Sendable {
    public static let schemaVersion = 2
    /// Hidden private collection, same prefix as `.inkamp.podcastSync.v1`.
    public static let collectionName = ".inkamp.settings.v1"

    public var schemaVersion: Int
    public var integrations: Integrations

    public init(
        schemaVersion: Int = SyncedAppSettings.schemaVersion,
        integrations: Integrations = Integrations(),
    ) {
        self.schemaVersion = schemaVersion
        self.integrations = integrations
    }

    public var hasAnySetting: Bool {
        integrations.lazyLibrarian.enabled != nil
            || integrations.lazyLibrarian.baseURL != nil
            || integrations.manualSearch.providers != nil
            || integrations.manualSearch.openInAppBrowser != nil
    }

    public struct Integrations: Codable, Equatable, Sendable {
        public var lazyLibrarian: LazyLibrarian
        public var manualSearch: ManualSearch
        // Shelfarr and later integrations: add a timestamped group here.
        // Bump `SyncedAppSettings.schemaVersion` so older apps refuse to rewrite the blob.

        public init(
            lazyLibrarian: LazyLibrarian = LazyLibrarian(),
            manualSearch: ManualSearch = ManualSearch(),
        ) {
            self.lazyLibrarian = lazyLibrarian
            self.manualSearch = manualSearch
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            lazyLibrarian =
                (try container.decodeIfPresent(LazyLibrarian.self, forKey: .lazyLibrarian))
                ?? LazyLibrarian()
            manualSearch =
                (try container.decodeIfPresent(ManualSearch.self, forKey: .manualSearch))
                ?? ManualSearch()
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(lazyLibrarian, forKey: .lazyLibrarian)
            try container.encode(manualSearch, forKey: .manualSearch)
        }

        private enum CodingKeys: String, CodingKey {
            case lazyLibrarian
            case manualSearch
        }
    }

    public struct LazyLibrarian: Codable, Equatable, Sendable {
        public var enabled: TimestampedSetting<Bool>?
        public var baseURL: TimestampedSetting<String>?

        public init(
            enabled: TimestampedSetting<Bool>? = nil,
            baseURL: TimestampedSetting<String>? = nil,
        ) {
            self.enabled = enabled
            self.baseURL = baseURL
        }
    }

    public struct ManualSearch: Codable, Equatable, Sendable {
        public var providers: TimestampedSetting<[ManualSearchProvider]>?
        public var openInAppBrowser: TimestampedSetting<Bool>?

        public init(
            providers: TimestampedSetting<[ManualSearchProvider]>? = nil,
            openInAppBrowser: TimestampedSetting<Bool>? = nil,
        ) {
            self.providers = providers
            self.openInAppBrowser = openInAppBrowser
        }
    }
}

public enum SettingsSyncClock {
    /// Whole seconds so ISO-8601 round-trips compare equal.
    public static func stamp(_ date: Date = Date()) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    }
}

public enum SettingsPayloadInspection: Equatable, Sendable {
    case empty
    case document(SyncedAppSettings)
    case malformed(String)
    case unsupportedSchema(Int)
}

public enum SettingsSyncCodec {
    public static func encode(_ document: SyncedAppSettings) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        guard let string = String(data: data, encoding: .utf8) else {
            throw SettingsSyncStoreError.utf8
        }
        return string
    }

    public static func inspect(_ raw: String) -> SettingsPayloadInspection {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        guard let data = trimmed.data(using: .utf8) else {
            return .malformed("utf8")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .malformed("json")
        }
        guard let version = object["schemaVersion"] as? Int else {
            return .malformed("schemaVersion")
        }
        if version > SyncedAppSettings.schemaVersion {
            return .unsupportedSchema(version)
        }
        if version < 1 {
            return .malformed("schemaVersion")
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return .document(try decoder.decode(SyncedAppSettings.self, from: data))
        } catch {
            return .malformed("decode")
        }
    }
}

/// Per-value last-write-wins. Equal timestamps use a canonical encoding so both
/// devices pick the same winner (preferring "local" would diverge).
public enum SettingsSyncMerge {
    public static func latest<Value: Codable & Equatable>(
        _ local: TimestampedSetting<Value>?,
        _ remote: TimestampedSetting<Value>?,
    ) -> TimestampedSetting<Value>? {
        switch (local, remote) {
            case (nil, nil):
                return nil
            case (let value?, nil), (nil, let value?):
                return value
            case (let local?, let remote?):
                if local.modifiedAt != remote.modifiedAt {
                    return local.modifiedAt > remote.modifiedAt ? local : remote
                }
                if local.value == remote.value { return local }
                let left = canonical(local.value)
                let right = canonical(remote.value)
                return left >= right ? local : remote
        }
    }

    public static func merge(local: SyncedAppSettings, remote: SyncedAppSettings) -> SyncedAppSettings {
        SyncedAppSettings(
            integrations: SyncedAppSettings.Integrations(
                lazyLibrarian: SyncedAppSettings.LazyLibrarian(
                    enabled: latest(
                        local.integrations.lazyLibrarian.enabled,
                        remote.integrations.lazyLibrarian.enabled,
                    ),
                    baseURL: latest(
                        local.integrations.lazyLibrarian.baseURL,
                        remote.integrations.lazyLibrarian.baseURL,
                    ),
                ),
                manualSearch: SyncedAppSettings.ManualSearch(
                    providers: latest(
                        local.integrations.manualSearch.providers,
                        remote.integrations.manualSearch.providers,
                    ),
                    openInAppBrowser: latest(
                        local.integrations.manualSearch.openInAppBrowser,
                        remote.integrations.manualSearch.openInAppBrowser,
                    ),
                ),
            ),
        )
    }

    /// Stamp only values that actually changed so an unrelated edit cannot win later.
    public static func applyLocalEdit(
        _ document: SyncedAppSettings,
        enabled: Bool,
        baseURL: String,
        at date: Date,
    ) -> SyncedAppSettings {
        var updated = document
        let stamped = SettingsSyncClock.stamp(date)
        if updated.integrations.lazyLibrarian.enabled?.value != enabled {
            updated.integrations.lazyLibrarian.enabled = TimestampedSetting(
                value: enabled,
                modifiedAt: stamped,
            )
        }
        if updated.integrations.lazyLibrarian.baseURL?.value != baseURL {
            updated.integrations.lazyLibrarian.baseURL = TimestampedSetting(
                value: baseURL,
                modifiedAt: stamped,
            )
        }
        return updated
    }

    public static func applyManualSearchEdit(
        _ document: SyncedAppSettings,
        providers: [ManualSearchProvider],
        openInAppBrowser: Bool,
        at date: Date,
    ) -> SyncedAppSettings {
        var updated = document
        let stamped = SettingsSyncClock.stamp(date)
        if updated.integrations.manualSearch.providers?.value != providers {
            updated.integrations.manualSearch.providers = TimestampedSetting(
                value: providers,
                modifiedAt: stamped,
            )
        }
        if updated.integrations.manualSearch.openInAppBrowser?.value != openInAppBrowser {
            updated.integrations.manualSearch.openInAppBrowser = TimestampedSetting(
                value: openInAppBrowser,
                modifiedAt: stamped,
            )
        }
        return updated
    }

    private static func canonical<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value),
            let string = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return string
    }
}

public enum SettingsSyncMigration {
    /// Legacy config has no per-field clock. Epoch is older than any real edit,
    /// so an existing remote value wins. `SilveranGlobalConfig.json`'s mtime is
    /// not evidence these fields changed — unrelated saves rewrite that file.
    public static let unversionedModifiedAt = Date(timeIntervalSince1970: 0)

    /// First-launch seed. Defaults are omitted so an untouched install cannot
    /// clobber another device. A saved URL with enabled=false is explicit.
    /// `configModifiedAt` is accepted and ignored so a newer file mtime cannot
    /// be mistaken for a newer LazyLibrarian value.
    public static func initialDocument(
        settings: LazyLibrarianLocalSettings,
        configModifiedAt: Date? = nil,
    ) -> SyncedAppSettings {
        _ = configModifiedAt
        var document = SyncedAppSettings()
        let url = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let configured = settings.enabled || !url.isEmpty
        guard configured else { return document }
        let stamped = unversionedModifiedAt
        if settings.enabled || !url.isEmpty {
            document.integrations.lazyLibrarian.enabled = TimestampedSetting(
                value: settings.enabled,
                modifiedAt: stamped,
            )
        }
        if !url.isEmpty {
            document.integrations.lazyLibrarian.baseURL = TimestampedSetting(
                value: url,
                modifiedAt: stamped,
            )
        }
        return document
    }
}

public enum SettingsRemoteSnapshot: Equatable, Sendable {
    case unreachable
    case empty
    case malformed
    case unsupportedSchema(Int)
    case document(SyncedAppSettings)
}

public struct SettingsSyncResolution: Equatable, Sendable {
    public var document: SyncedAppSettings
    public var push: Bool
    public var status: SettingsSyncResolutionStatus

    public init(
        document: SyncedAppSettings,
        push: Bool,
        status: SettingsSyncResolutionStatus,
    ) {
        self.document = document
        self.push = push
        self.status = status
    }
}

public enum SettingsSyncResolutionStatus: Equatable, Sendable {
    case synced
    case offlineWillSyncLater
    case syncError
    case schemaMismatch(Int)
}

public enum SettingsSyncApply {
    /// Fields missing from the blob keep the on-device value. Synced fields replace it.
    public static func lazyLibrarian(
        document: SyncedAppSettings,
        config: LazyLibrarianLocalSettings,
    ) -> LazyLibrarianLocalSettings {
        let lazyLibrarian = document.integrations.lazyLibrarian
        return LazyLibrarianLocalSettings(
            enabled: lazyLibrarian.enabled?.value ?? config.enabled,
            baseURL: lazyLibrarian.baseURL?.value ?? config.baseURL,
        )
    }

    public static func manualSearch(
        document: SyncedAppSettings,
        current: ManualSearchSettingsSnapshot = ManualSearchSettingsSnapshot(),
    ) -> ManualSearchSettingsSnapshot {
        let section = document.integrations.manualSearch
        let providers: [ManualSearchProvider]
        if let synced = section.providers?.value {
            providers = ManualSearchCatalog.resolve(synced: synced)
        } else {
            providers = current.providers
        }
        return ManualSearchSettingsSnapshot(
            providers: providers,
            openInAppBrowser: section.openInAppBrowser?.value ?? current.openInAppBrowser,
        )
    }
}

public enum SettingsSyncEngine {
    /// Merge plan. Does not touch disk or the network. Malformed and newer
    /// schemas leave `local` unchanged and do not request a push.
    public static func resolve(
        local: SyncedAppSettings,
        remote: SettingsRemoteSnapshot,
    ) -> SettingsSyncResolution {
        switch remote {
            case .unreachable:
                return SettingsSyncResolution(
                    document: local,
                    push: false,
                    status: .offlineWillSyncLater,
                )
            case .malformed:
                return SettingsSyncResolution(
                    document: local,
                    push: false,
                    status: .syncError,
                )
            case .unsupportedSchema(let version):
                return SettingsSyncResolution(
                    document: local,
                    push: false,
                    status: .schemaMismatch(version),
                )
            case .empty:
                return SettingsSyncResolution(
                    document: local,
                    push: local.hasAnySetting,
                    status: .synced,
                )
            case .document(let remoteDocument):
                let merged = SettingsSyncMerge.merge(local: local, remote: remoteDocument)
                return SettingsSyncResolution(
                    document: merged,
                    push: merged != remoteDocument,
                    status: .synced,
                )
        }
    }
}

public enum SettingsSyncStoreError: Error, Equatable, Sendable {
    case utf8
    case unsupportedSchema(Int)
}

public enum SettingsSyncKeys {
    public static let migrationCompleted = "inkamp.settings.migrationCompleted.v1"
    public static let needsSync = "inkamp.settings.needsSync.v1"
    public static let lastSuccessfulSyncAt = "inkamp.settings.lastSuccessfulSyncAt.v1"
}

/// Local copy of the settings blob plus the one-shot migration flag.
public struct SettingsSyncJournal {
    public var fileURL: URL
    public var defaults: UserDefaults

    public init(fileURL: URL, defaults: UserDefaults) {
        self.fileURL = fileURL
        self.defaults = defaults
    }

    public static func live() -> SettingsSyncJournal {
        let base = SilveranPlatform.applicationSupportDirectory(fileManager: .default)
        let url = base
            .appendingPathComponent("Config", isDirectory: true)
            .appendingPathComponent("inkamp.settings.v1.json", isDirectory: false)
        return SettingsSyncJournal(fileURL: url, defaults: .standard)
    }

    public var migrationCompleted: Bool {
        get { defaults.bool(forKey: SettingsSyncKeys.migrationCompleted) }
        nonmutating set { defaults.set(newValue, forKey: SettingsSyncKeys.migrationCompleted) }
    }

    public var needsSync: Bool {
        get { defaults.bool(forKey: SettingsSyncKeys.needsSync) }
        nonmutating set { defaults.set(newValue, forKey: SettingsSyncKeys.needsSync) }
    }

    public func load() -> SyncedAppSettings? {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        switch SettingsSyncCodec.inspect(raw) {
            case .document(let document):
                return document
            case .empty:
                return SyncedAppSettings()
            case .malformed(let detail):
                debugLog("[SettingsSync] failure local document \(detail)")
                return nil
            case .unsupportedSchema(let version):
                debugLog("[SettingsSync] schema mismatch local=\(version)")
                return nil
        }
    }

    public func save(_ document: SyncedAppSettings) throws {
        if let existing = try? String(contentsOf: fileURL, encoding: .utf8),
            case .unsupportedSchema(let version) = SettingsSyncCodec.inspect(existing)
        {
            debugLog("[SettingsSync] schema mismatch local=\(version) save skipped")
            throw SettingsSyncStoreError.unsupportedSchema(version)
        }
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let encoded = try SettingsSyncCodec.encode(document)
        guard let data = encoded.data(using: .utf8) else { throw SettingsSyncStoreError.utf8 }
        try data.write(to: fileURL, options: [.atomic])
    }

    /// Idempotent. A completed migration returns the saved document unchanged.
    /// `configModifiedAt` does not affect the seed clock.
    @discardableResult
    public func migrateIfNeeded(
        settings: LazyLibrarianLocalSettings,
        configModifiedAt: Date? = nil,
    ) throws -> SyncedAppSettings {
        if migrationCompleted, let existing = load() {
            return existing
        }
        let seeded = SettingsSyncMigration.initialDocument(
            settings: settings,
            configModifiedAt: configModifiedAt,
        )
        let merged: SyncedAppSettings
        if let existing = load() {
            merged = SettingsSyncMerge.merge(local: seeded, remote: existing)
        } else {
            merged = seeded
        }
        try save(merged)
        migrationCompleted = true
        if merged.hasAnySetting {
            needsSync = true
        }
        let fields = syncedFieldNames(merged)
        debugLog("[SettingsSync] migration fields=\(fields)")
        return merged
    }

    /// Seeds any not-yet-migrated legacy values, then stamps only the fields
    /// this edit actually changed. Unchanged legacy fields stay unversioned.
    @discardableResult
    public func recordLazyLibrarianChange(
        enabled: Bool,
        baseURL: String,
        previousEnabled: Bool,
        previousBaseURL: String,
        at date: Date,
    ) throws -> SyncedAppSettings {
        let migrated = try migrateIfNeeded(
            settings: LazyLibrarianLocalSettings(
                enabled: previousEnabled,
                baseURL: previousBaseURL,
            ),
        )
        let edited = SettingsSyncMerge.applyLocalEdit(
            migrated,
            enabled: enabled,
            baseURL: baseURL,
            at: date,
        )
        guard edited != migrated else { return migrated }
        try save(edited)
        needsSync = true
        return edited
    }

    @discardableResult
    public func recordManualSearchChange(
        providers: [ManualSearchProvider],
        openInAppBrowser: Bool,
        at date: Date,
    ) throws -> SyncedAppSettings {
        // Do not call migrateIfNeeded(.unset) here — that would mark
        // LazyLibrarian migration complete without seeding existing config.
        let current = load() ?? SyncedAppSettings()
        let edited = SettingsSyncMerge.applyManualSearchEdit(
            current,
            providers: providers,
            openInAppBrowser: openInAppBrowser,
            at: date,
        )
        guard edited != current else { return current }
        try save(edited)
        needsSync = true
        return edited
    }

    private func syncedFieldNames(_ document: SyncedAppSettings) -> String {
        var names: [String] = []
        if document.integrations.lazyLibrarian.enabled != nil {
            names.append("lazyLibrarian.enabled")
        }
        if document.integrations.lazyLibrarian.baseURL != nil {
            names.append("lazyLibrarian.baseURL")
        }
        if document.integrations.manualSearch.providers != nil {
            names.append("manualSearch.providers")
        }
        if document.integrations.manualSearch.openInAppBrowser != nil {
            names.append("manualSearch.openInAppBrowser")
        }
        return names.isEmpty ? "none" : names.joined(separator: ",")
    }
}

public enum SettingsSyncStatus: Equatable, Sendable {
    case synced
    case syncing
    case offlineWillSyncLater
    case syncError

    public var label: String {
        switch self {
            case .synced: "Synced"
            case .syncing: "Syncing…"
            case .offlineWillSyncLater: "Offline — will sync later"
            case .syncError: "Sync error"
        }
    }
}
