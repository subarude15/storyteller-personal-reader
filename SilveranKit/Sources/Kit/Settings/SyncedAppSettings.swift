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
//    nasDownloads    torrent client, URLs, folders, routing prefs
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
    /// Highest schema this build understands. Used to refuse newer remotes.
    public static let schemaVersion = 3
    /// Fresh / empty documents start here. Promotion is field-sensitive.
    public static let baselineSchemaVersion = 1
    /// Hidden private collection, same prefix as `.inkamp.podcastSync.v1`.
    public static let collectionName = ".inkamp.settings.v1"

    public var schemaVersion: Int
    public var integrations: Integrations

    public init(
        schemaVersion: Int = SyncedAppSettings.baselineSchemaVersion,
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
            || SettingsSyncMerge.hasSchema3Fields(self)
    }

    public struct Integrations: Codable, Equatable, Sendable {
        public var lazyLibrarian: LazyLibrarian
        public var manualSearch: ManualSearch
        public var nasDownloads: NASDownloads
        // Shelfarr and later integrations: add a timestamped group here.
        // Bump `SyncedAppSettings.schemaVersion` so older apps refuse to rewrite the blob.

        public init(
            lazyLibrarian: LazyLibrarian = LazyLibrarian(),
            manualSearch: ManualSearch = ManualSearch(),
            nasDownloads: NASDownloads = NASDownloads(),
        ) {
            self.lazyLibrarian = lazyLibrarian
            self.manualSearch = manualSearch
            self.nasDownloads = nasDownloads
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            lazyLibrarian =
                (try container.decodeIfPresent(LazyLibrarian.self, forKey: .lazyLibrarian))
                ?? LazyLibrarian()
            manualSearch =
                (try container.decodeIfPresent(ManualSearch.self, forKey: .manualSearch))
                ?? ManualSearch()
            nasDownloads =
                (try container.decodeIfPresent(NASDownloads.self, forKey: .nasDownloads))
                ?? NASDownloads()
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(lazyLibrarian, forKey: .lazyLibrarian)
            try container.encode(manualSearch, forKey: .manualSearch)
            try container.encode(nasDownloads, forKey: .nasDownloads)
        }

        private enum CodingKeys: String, CodingKey {
            case lazyLibrarian
            case manualSearch
            case nasDownloads
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

    /// Non-secret NAS download preferences. Passwords are never fields here.
    public struct NASDownloads: Codable, Equatable, Sendable {
        public var torrentClient: TimestampedSetting<NASTorrentClient>?
        public var torboxEnabled: TimestampedSetting<Bool>?
        public var qbittorrentBaseURL: TimestampedSetting<String>?
        public var qbittorrentUsername: TimestampedSetting<String>?
        public var delugeBaseURL: TimestampedSetting<String>?
        public var synologyBaseURL: TimestampedSetting<String>?
        public var synologyUsername: TimestampedSetting<String>?
        public var audiobookFolder: TimestampedSetting<String>?
        public var ebookFolder: TimestampedSetting<String>?
        public var delugeIncomingFolder: TimestampedSetting<String>?
        public var delugeCompletedFolder: TimestampedSetting<String>?
        public var startAutomatically: TimestampedSetting<Bool>?
        public var createTitleAuthorSubfolders: TimestampedSetting<Bool>?

        public init(
            torrentClient: TimestampedSetting<NASTorrentClient>? = nil,
            torboxEnabled: TimestampedSetting<Bool>? = nil,
            qbittorrentBaseURL: TimestampedSetting<String>? = nil,
            qbittorrentUsername: TimestampedSetting<String>? = nil,
            delugeBaseURL: TimestampedSetting<String>? = nil,
            synologyBaseURL: TimestampedSetting<String>? = nil,
            synologyUsername: TimestampedSetting<String>? = nil,
            audiobookFolder: TimestampedSetting<String>? = nil,
            ebookFolder: TimestampedSetting<String>? = nil,
            delugeIncomingFolder: TimestampedSetting<String>? = nil,
            delugeCompletedFolder: TimestampedSetting<String>? = nil,
            startAutomatically: TimestampedSetting<Bool>? = nil,
            createTitleAuthorSubfolders: TimestampedSetting<Bool>? = nil,
        ) {
            self.torrentClient = torrentClient
            self.torboxEnabled = torboxEnabled
            self.qbittorrentBaseURL = qbittorrentBaseURL
            self.qbittorrentUsername = qbittorrentUsername
            self.delugeBaseURL = delugeBaseURL
            self.synologyBaseURL = synologyBaseURL
            self.synologyUsername = synologyUsername
            self.audiobookFolder = audiobookFolder
            self.ebookFolder = ebookFolder
            self.delugeIncomingFolder = delugeIncomingFolder
            self.delugeCompletedFolder = delugeCompletedFolder
            self.startAutomatically = startAutomatically
            self.createTitleAuthorSubfolders = createTitleAuthorSubfolders
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
            schemaVersion: resolvedSchemaVersion(local: local, remote: remote),
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
                nasDownloads: mergeNASDownloads(
                    local: local.integrations.nasDownloads,
                    remote: remote.integrations.nasDownloads,
                ),
            ),
        )
    }

    private static func mergeNASDownloads(
        local: SyncedAppSettings.NASDownloads,
        remote: SyncedAppSettings.NASDownloads,
    ) -> SyncedAppSettings.NASDownloads {
        SyncedAppSettings.NASDownloads(
            torrentClient: latest(local.torrentClient, remote.torrentClient),
            torboxEnabled: latest(local.torboxEnabled, remote.torboxEnabled),
            qbittorrentBaseURL: latest(local.qbittorrentBaseURL, remote.qbittorrentBaseURL),
            qbittorrentUsername: latest(local.qbittorrentUsername, remote.qbittorrentUsername),
            delugeBaseURL: latest(local.delugeBaseURL, remote.delugeBaseURL),
            synologyBaseURL: latest(local.synologyBaseURL, remote.synologyBaseURL),
            synologyUsername: latest(local.synologyUsername, remote.synologyUsername),
            audiobookFolder: latest(local.audiobookFolder, remote.audiobookFolder),
            ebookFolder: latest(local.ebookFolder, remote.ebookFolder),
            delugeIncomingFolder: latest(local.delugeIncomingFolder, remote.delugeIncomingFolder),
            delugeCompletedFolder: latest(local.delugeCompletedFolder, remote.delugeCompletedFolder),
            startAutomatically: latest(local.startAutomatically, remote.startAutomatically),
            createTitleAuthorSubfolders: latest(
                local.createTitleAuthorSubfolders,
                remote.createTitleAuthorSubfolders,
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
        return promoteSchemaIfNeeded(updated)
    }

    public static func applyNASDownloadsEdit(
        _ document: SyncedAppSettings,
        settings: NASDownloadSettingsSnapshot,
        at date: Date,
    ) -> SyncedAppSettings {
        var updated = document
        let stamped = SettingsSyncClock.stamp(date)
        var section = updated.integrations.nasDownloads
        stamp(&section.torrentClient, settings.torrentClient, at: stamped)
        stamp(&section.torboxEnabled, settings.torboxEnabled, at: stamped)
        stamp(&section.qbittorrentBaseURL, settings.qbittorrentBaseURL, at: stamped)
        stamp(&section.qbittorrentUsername, settings.qbittorrentUsername, at: stamped)
        stamp(&section.delugeBaseURL, settings.delugeBaseURL, at: stamped)
        stamp(&section.synologyBaseURL, settings.synologyBaseURL, at: stamped)
        stamp(&section.synologyUsername, settings.synologyUsername, at: stamped)
        stamp(&section.audiobookFolder, settings.audiobookFolder, at: stamped)
        stamp(&section.ebookFolder, settings.ebookFolder, at: stamped)
        stamp(&section.delugeIncomingFolder, settings.delugeIncomingFolder, at: stamped)
        stamp(&section.delugeCompletedFolder, settings.delugeCompletedFolder, at: stamped)
        stamp(&section.startAutomatically, settings.startAutomatically, at: stamped)
        stamp(&section.createTitleAuthorSubfolders, settings.createTitleAuthorSubfolders, at: stamped)
        updated.integrations.nasDownloads = section
        return promoteSchemaIfNeeded(updated)
    }

    /// Promote only as far as the fields present require.
    /// Never lowers an already-newer version.
    public static func promoteSchemaIfNeeded(_ document: SyncedAppSettings) -> SyncedAppSettings {
        let required = requiredSchemaVersion(for: document)
        guard document.schemaVersion < required else { return document }
        var updated = document
        updated.schemaVersion = required
        return updated
    }

    public static func requiredSchemaVersion(for document: SyncedAppSettings) -> Int {
        if hasSchema3Fields(document) { return max(document.schemaVersion, 3) }
        if hasSchema2Fields(document) { return max(document.schemaVersion, 2) }
        return document.schemaVersion
    }

    public static func resolvedSchemaVersion(local: SyncedAppSettings, remote: SyncedAppSettings) -> Int {
        let highest = max(local.schemaVersion, remote.schemaVersion)
        if hasSchema3Fields(local) || hasSchema3Fields(remote) {
            return max(highest, 3)
        }
        if hasSchema2Fields(local) || hasSchema2Fields(remote) {
            return max(highest, 2)
        }
        return highest
    }

    public static func hasSchema2Fields(_ document: SyncedAppSettings) -> Bool {
        document.integrations.manualSearch.providers != nil
            || document.integrations.manualSearch.openInAppBrowser != nil
    }

    public static func hasSchema3Fields(_ document: SyncedAppSettings) -> Bool {
        let nas = document.integrations.nasDownloads
        return nas.torrentClient != nil
            || nas.torboxEnabled != nil
            || nas.qbittorrentBaseURL != nil
            || nas.qbittorrentUsername != nil
            || nas.delugeBaseURL != nil
            || nas.synologyBaseURL != nil
            || nas.synologyUsername != nil
            || nas.audiobookFolder != nil
            || nas.ebookFolder != nil
            || nas.delugeIncomingFolder != nil
            || nas.delugeCompletedFolder != nil
            || nas.startAutomatically != nil
            || nas.createTitleAuthorSubfolders != nil
    }

    private static func stamp<Value: Equatable>(
        _ field: inout TimestampedSetting<Value>?,
        _ value: Value,
        at date: Date,
    ) {
        if field?.value != value {
            field = TimestampedSetting(value: value, modifiedAt: date)
        }
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

    public static func nasDownloads(
        document: SyncedAppSettings,
        current: NASDownloadSettingsSnapshot = NASDownloadSettingsSnapshot(),
    ) -> NASDownloadSettingsSnapshot {
        let section = document.integrations.nasDownloads
        return NASDownloadSettingsSnapshot(
            torrentClient: section.torrentClient?.value ?? current.torrentClient,
            torboxEnabled: section.torboxEnabled?.value ?? current.torboxEnabled,
            qbittorrentBaseURL: section.qbittorrentBaseURL?.value ?? current.qbittorrentBaseURL,
            qbittorrentUsername: section.qbittorrentUsername?.value ?? current.qbittorrentUsername,
            delugeBaseURL: section.delugeBaseURL?.value ?? current.delugeBaseURL,
            synologyBaseURL: section.synologyBaseURL?.value ?? current.synologyBaseURL,
            synologyUsername: section.synologyUsername?.value ?? current.synologyUsername,
            audiobookFolder: section.audiobookFolder?.value ?? current.audiobookFolder,
            ebookFolder: section.ebookFolder?.value ?? current.ebookFolder,
            delugeIncomingFolder: section.delugeIncomingFolder?.value ?? current.delugeIncomingFolder,
            delugeCompletedFolder: section.delugeCompletedFolder?.value ?? current.delugeCompletedFolder,
            startAutomatically: section.startAutomatically?.value ?? current.startAutomatically,
            createTitleAuthorSubfolders:
                section.createTitleAuthorSubfolders?.value ?? current.createTitleAuthorSubfolders,
        )
    }

    /// `nil` means the field was missing (leave config alone). `""` means cleared.
    public static func delugeBaseURLToApply(document: SyncedAppSettings) -> String? {
        document.integrations.nasDownloads.delugeBaseURL.map {
            $0.value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
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

    @discardableResult
    public func recordNASDownloadsChange(
        _ settings: NASDownloadSettingsSnapshot,
        at date: Date,
    ) throws -> SyncedAppSettings {
        let current = load() ?? SyncedAppSettings()
        let edited = SettingsSyncMerge.applyNASDownloadsEdit(
            current,
            settings: settings,
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
        if document.integrations.nasDownloads.torrentClient != nil {
            names.append("nasDownloads.torrentClient")
        }
        if document.integrations.nasDownloads.audiobookFolder != nil {
            names.append("nasDownloads.audiobookFolder")
        }
        if document.integrations.nasDownloads.ebookFolder != nil {
            names.append("nasDownloads.ebookFolder")
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
