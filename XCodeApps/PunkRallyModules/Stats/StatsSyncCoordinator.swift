//
//  StatsSyncCoordinator.swift
//  ink+amp
//
//  Pull/push Stats via Storyteller private collection (same auth as place sync).
//  Footer: Synced across your devices · Syncing… · Offline · local only
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Observation
import SilveranKit

/// Health of cross-device Stats sync for footer / Settings.
enum StatsSyncStatus: Equatable, Sendable {
    case synced
    case syncing
    case offlineLocalOnly

    var footerLabel: String {
        switch self {
            case .synced: return "Synced across your devices"
            case .syncing: return "Syncing…"
            case .offlineLocalOnly: return "Offline · local only"
        }
    }

    var footerSymbol: String {
        switch self {
            case .synced: return "checkmark.icloud.fill"
            case .syncing: return "arrow.triangle.2.circlepath.icloud"
            case .offlineLocalOnly: return "iphone"
        }
    }
}

/// Coordinates SessionTracker ↔ Storyteller Stats blob. Local recording always works offline.
@MainActor
@Observable
final class StatsSyncCoordinator {
    static let shared = StatsSyncCoordinator()

    private static let lastSyncKey = InkampStatsSyncDefaults.lastSuccessfulSyncAtKey
    private static let collectionUUIDKey = "punkRally.stats.collectionUUID.v1"

    private(set) var status: StatsSyncStatus = .offlineLocalOnly
    private(set) var lastSuccessfulSyncAt: Date?
    private(set) var revision: Int = 0

    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    private init() {
        lastSuccessfulSyncAt = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date
        if lastSuccessfulSyncAt != nil {
            status = .synced
        }
    }

    /// Debounced sync after local session writes.
    func scheduleSyncAfterLocalChange() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            await self?.syncNow(reason: "localChange")
        }
    }

    /// Immediate sync (Stats tab appear, app foreground).
    func syncNow(reason: String) async {
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { @MainActor in
            await self.performSync(reason: reason)
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func performSync(reason: String) async {
        status = .syncing
        revision &+= 1

        let canReach = await StorytellerActor.shared.canReachStorytellerForStatsSync()
        guard canReach else {
            status = .offlineLocalOnly
            revision &+= 1
            return
        }

        let localDoc = SessionTracker.shared.exportSyncDocument()
        let fetch = await StorytellerActor.shared.fetchInkampStatsDocument()

        let merged: InkampStatsSyncDocument
        switch fetch {
            case .unavailable:
                status = .offlineLocalOnly
                revision &+= 1
                return
            case .empty:
                merged = localDoc
            case .document(let remoteDoc):
                merged = StatsSyncMerge.mergeDocuments(local: localDoc, remote: remoteDoc)
        }

        SessionTracker.shared.applyMergedSyncDocument(merged)

        let pushed = await StorytellerActor.shared.pushInkampStatsDocument(merged)
        if pushed {
            let now = Date()
            lastSuccessfulSyncAt = now
            UserDefaults.standard.set(now, forKey: Self.lastSyncKey)
            status = .synced
        } else {
            status = .offlineLocalOnly
        }
        revision &+= 1
        debugLog("[StatsSync] reason=\(reason) pushed=\(pushed) sessions=\(merged.sessions.count)")
    }
}
