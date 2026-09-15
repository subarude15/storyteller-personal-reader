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
/// Network steps are timeout-bounded and must never sit on the audio start path.
@MainActor
@Observable
final class StatsSyncCoordinator {
    static let shared = StatsSyncCoordinator()

    private static let lastSyncKey = InkampStatsSyncDefaults.lastSuccessfulSyncAtKey
    private static let collectionUUIDKey = "punkRally.stats.collectionUUID.v1"
    /// Per-step soft timeout so a hung Storyteller auth/fetch cannot stall forever.
    private static let networkTimeoutSeconds: TimeInterval = 8
    /// Whole-sync ceiling (reach + fetch + push); lands Offline if exceeded.
    private static let overallTimeoutSeconds: TimeInterval = 18

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
        publishUI()
    }

    /// Debounced sync after local session writes (never on the audio start path).
    func scheduleSyncAfterLocalChange() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            await self?.syncNow(reason: "localChange")
        }
    }

    /// Immediate sync (Stats tab, app foreground, Settings/footer Retry).
    /// Callers that must not block UI (app-active) wrap in `Task { await … }`.
    func syncNow(reason: String) async {
        // Flip to Syncing… immediately so Settings/footer never sit on "Not yet".
        status = .syncing
        revision &+= 1
        publishUI()

        if let inFlight {
            await inFlight.value
            // A coalesced waiter still needs the latest UI after the in-flight ends.
            publishUI()
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
        let finished = await Self.withTimeout(seconds: Self.overallTimeoutSeconds) {
            await Self.runNetworkSync()
        }

        guard let finished else {
            status = .offlineLocalOnly
            revision &+= 1
            publishUI()
            debugLog("[StatsSync] reason=\(reason) pushed=false detail=overallTimeout")
            return
        }

        switch finished {
            case .synced(let now, let sessionCount):
                lastSuccessfulSyncAt = now
                UserDefaults.standard.set(now, forKey: Self.lastSyncKey)
                status = .synced
                revision &+= 1
                publishUI()
                debugLog(
                    "[StatsSync] reason=\(reason) pushed=true sessions=\(sessionCount)"
                )
            case .offline(let detail):
                status = .offlineLocalOnly
                revision &+= 1
                publishUI()
                debugLog("[StatsSync] reason=\(reason) pushed=false detail=\(detail)")
        }
    }

    private enum SyncOutcome: Sendable {
        case synced(Date, sessionCount: Int)
        case offline(String)
    }

    /// Network body isolated from MainActor so timeouts can cancel cleanly.
    private static func runNetworkSync() async -> SyncOutcome {
        let canReach =
            await withTimeout(seconds: networkTimeoutSeconds) {
                await BookServiceActor.shared.canReachStorytellerForStatsSync()
            }
        guard let canReach else {
            return .offline("reach timeout")
        }
        guard canReach else {
            return .offline("auth/unreachable")
        }

        let localDoc = await MainActor.run {
            SessionTracker.shared.exportSyncDocument()
        }
        let fetch =
            await withTimeout(seconds: networkTimeoutSeconds) {
                await BookServiceActor.shared.fetchInkampStatsDocument()
            }
        guard let fetch else {
            return .offline("fetch timeout")
        }

        let merged: InkampStatsSyncDocument
        switch fetch {
            case .unavailable(let detail):
                return .offline("fetch unavailable: \(detail)")
            case .empty:
                merged = localDoc
            case .document(let remoteDoc):
                merged = StatsSyncMerge.mergeDocuments(local: localDoc, remote: remoteDoc)
        }

        await MainActor.run {
            SessionTracker.shared.applyMergedSyncDocument(merged)
        }

        let push =
            await withTimeout(seconds: networkTimeoutSeconds) {
                await BookServiceActor.shared.pushInkampStatsDocument(merged)
            }
        guard let push else {
            return .offline("push timeout")
        }
        switch push {
            case .success:
                return .synced(Date(), sessionCount: merged.sessions.count)
            case .failure(let detail):
                return .offline(detail)
        }
    }

    private func publishUI() {
        var info: [String: Any] = [
            "isSyncing": status == .syncing,
            "footerLabel": status.footerLabel,
        ]
        if let lastSuccessfulSyncAt {
            info["lastSuccessfulSyncAt"] = lastSuccessfulSyncAt
        }
        NotificationCenter.default.post(
            name: .punkRallyStatsSyncUIDidChange,
            object: nil,
            userInfo: info
        )
    }

    /// Returns `nil` when `seconds` elapse before `operation` completes.
    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: TimeoutRace<T>.self) { group in
            group.addTask { .value(await operation()) }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return .timedOut
            }
            defer { group.cancelAll() }
            guard let first = await group.next() else { return nil }
            switch first {
                case .value(let value):
                    return value
                case .timedOut:
                    return nil
            }
        }
    }

    private enum TimeoutRace<T: Sendable>: Sendable {
        case value(T)
        case timedOut
    }
}
