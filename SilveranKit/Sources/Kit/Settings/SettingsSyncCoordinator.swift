//
//  SettingsSyncCoordinator.swift
//  SilveranKit
//
//  Pull/push `.inkamp.settings.v1` when Storyteller auth is available.
//  Local settings stay readable and editable offline. A failed sync never
//  clears the on-device config.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

extension Notification.Name {
    public static let inkampSettingsSyncStatusDidChange = Notification.Name(
        "inkampSettingsSyncStatusDidChange"
    )
}

/// Coordinates the local settings journal with the Storyteller private blob.
@MainActor
public final class SettingsSyncCoordinator {
    public static let shared = SettingsSyncCoordinator()

    public private(set) var status: SettingsSyncStatus = .offlineWillSyncLater

    private var journal: SettingsSyncJournal
    private var document: SyncedAppSettings
    private var inFlight: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var lastSuccessfulSyncAt: Date?

    public init(journal: SettingsSyncJournal = .live()) {
        self.journal = journal
        document = journal.load() ?? SyncedAppSettings()
        if let stored = journal.defaults.object(forKey: SettingsSyncKeys.lastSuccessfulSyncAt) as? Date {
            lastSuccessfulSyncAt = stored
            status = .synced
        }
    }

    /// Debounced push after a synced preference changes.
    public func scheduleSyncAfterLocalChange() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            await self?.syncNow(reason: "localChange")
        }
    }

    /// Immediate pull/push. Coalesces with a sync already in flight, then runs
    /// again if a local edit landed during that attempt.
    public func syncNow(reason: String) async {
        if reason == "settings",
            !journal.needsSync,
            status == .synced,
            let lastSuccessfulSyncAt,
            Date().timeIntervalSince(lastSuccessfulSyncAt) < 20
        {
            return
        }

        if let inFlight {
            await inFlight.value
            if journal.needsSync {
                await syncNow(reason: reason)
            }
            return
        }

        let task = Task { @MainActor in
            await self.performSync(reason: reason)
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    public func syncPendingOnBackground() {
        guard journal.needsSync else { return }
        Task { await syncNow(reason: "background") }
    }

    public func noteLocalLazyLibrarianChange(enabled: Bool, baseURL: String, at date: Date) {
        do {
            document = try journal.recordLazyLibrarianChange(
                enabled: enabled,
                baseURL: baseURL,
                at: date,
                migrationModifiedAt: date,
            )
        } catch {
            debugLog("[SettingsSync] failure journal save")
            return
        }
        guard journal.needsSync else { return }
        debugLog("[SettingsSync] local edit lazyLibrarian")
        scheduleSyncAfterLocalChange()
    }

    private func performSync(reason: String) async {
        status = .syncing
        publish()

        let snapshot = await SettingsActor.shared.lazyLibrarianSyncSnapshot()
        let migrationDate = SettingsSyncClock.stamp(snapshot.configModifiedAt ?? Date())
        do {
            document = try journal.migrateIfNeeded(
                settings: LazyLibrarianLocalSettings(
                    enabled: snapshot.enabled,
                    baseURL: snapshot.baseURL,
                ),
                modifiedAt: migrationDate,
            )
        } catch {
            debugLog("[SettingsSync] failure migration")
            status = .syncError
            publish()
            return
        }

        let reachable = await BookServiceActor.shared.canReachStorytellerForStatsSync()
        guard reachable else {
            debugLog("[SettingsSync] pull reason=\(reason) result=offline")
            status = .offlineWillSyncLater
            publish()
            return
        }

        let fetched = await BookServiceActor.shared.fetchInkampSettingsDocument()
        let remote = Self.remoteSnapshot(fetched)
        // Edits made while the fetch was in flight are already in `document`.
        let resolution = SettingsSyncEngine.resolve(local: document, remote: remote)
        logResolution(reason: reason, remote: remote, resolution: resolution)

        switch resolution.status {
            case .offlineWillSyncLater:
                status = .offlineWillSyncLater
                publish()
                return
            case .syncError, .schemaMismatch:
                status = .syncError
                publish()
                return
            case .synced:
                break
        }

        document = resolution.document
        do {
            try journal.save(document)
        } catch {
            debugLog("[SettingsSync] failure journal save")
            status = .syncError
            publish()
            return
        }
        await applyToConfig(document)

        guard resolution.push else {
            journal.needsSync = false
            markSynced()
            return
        }

        let pushing = document
        let pushed = await BookServiceActor.shared.pushInkampSettingsDocument(pushing)
        if document != pushing {
            journal.needsSync = true
            debugLog("[SettingsSync] push skipped stale reason=\(reason)")
            status = .synced
            publish()
            return
        }
        switch pushed {
            case .success:
                journal.needsSync = false
                markSynced()
                debugLog("[SettingsSync] push reason=\(reason) ok=true")
            case .failure(let failure):
                journal.needsSync = true
                status = .syncError
                publish()
                debugLog("[SettingsSync] failure push reason=\(reason) detail=\(failure)")
        }
    }

    private func markSynced() {
        let now = Date()
        lastSuccessfulSyncAt = now
        journal.defaults.set(now, forKey: SettingsSyncKeys.lastSuccessfulSyncAt)
        status = .synced
        publish()
    }

    private func applyToConfig(_ document: SyncedAppSettings) async {
        let config = await SettingsActor.shared.config
        let applied = SettingsSyncApply.lazyLibrarian(
            document: document,
            config: LazyLibrarianLocalSettings(
                enabled: config.lazyLibrarianEnabled,
                baseURL: config.lazyLibrarianBaseURL,
            ),
        )
        do {
            try await SettingsActor.shared.applySyncedLazyLibrarian(
                enabled: applied.enabled,
                baseURL: applied.baseURL,
            )
        } catch {
            debugLog("[SettingsSync] failure apply local config")
        }
    }

    private func publish() {
        NotificationCenter.default.post(name: .inkampSettingsSyncStatusDidChange, object: nil)
    }

    private func logResolution(
        reason: String,
        remote: SettingsRemoteSnapshot,
        resolution: SettingsSyncResolution,
    ) {
        switch remote {
            case .malformed:
                debugLog("[SettingsSync] failure remote malformed reason=\(reason)")
            case .unsupportedSchema(let version):
                debugLog(
                    "[SettingsSync] schema mismatch remote=\(version) supported=\(SyncedAppSettings.schemaVersion)"
                )
            case .unreachable:
                debugLog("[SettingsSync] pull reason=\(reason) result=offline")
            case .empty:
                debugLog("[SettingsSync] pull reason=\(reason) result=empty push=\(resolution.push)")
            case .document:
                debugLog(
                    "[SettingsSync] pull reason=\(reason) result=document push=\(resolution.push)"
                )
                debugLog("[SettingsSync] merge push=\(resolution.push)")
        }
    }

    private static func remoteSnapshot(
        _ fetched: StorytellerActor.InkampSettingsFetchResult,
    ) -> SettingsRemoteSnapshot {
        switch fetched {
            case .unavailable:
                return .unreachable
            case .empty:
                return .empty
            case .malformed:
                return .malformed
            case .unsupportedSchema(let version):
                return .unsupportedSchema(version)
            case .document(let document):
                return .document(document)
        }
    }
}
