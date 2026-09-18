//
//  YouTubePlayheadSyncCoordinator.swift
//  ink+amp
//
//  Pull/push YouTube playheads via Storyteller private collection
//  `.inkamp.youtubePlayheads.v1` (same auth as Stats / progress sync).
//  Settings: Synced / Syncing… / Offline · local only
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Observation
import SilveranAppleKit
import SilveranKit

/// Health of cross-device YouTube playhead sync for Settings (match Stats UX).
enum YouTubePlayheadSyncStatus: Equatable, Sendable {
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
}

/// Coordinates YouTubePlayheadStore ↔ Storyteller blob. Local resume always works offline.
/// Network steps are timeout-bounded and must never sit forever on the Play path.
@MainActor
@Observable
final class YouTubePlayheadSyncCoordinator {
    static let shared = YouTubePlayheadSyncCoordinator()

    private static let lastSyncKey = InkampYouTubePlayheadSyncDefaults.lastSuccessfulSyncAtKey
    /// Default per-step soft timeout (appActive / localChange / Settings retry).
    private static let networkTimeoutSeconds: TimeInterval = 8
    private static let overallTimeoutSeconds: TimeInterval = 18
    /// Tighter bounds so Play in ink+amp is not stalled waiting on Storyteller.
    private static let beforePlayStepTimeoutSeconds: TimeInterval = 2
    private static let beforePlayOverallTimeoutSeconds: TimeInterval = 4

    private(set) var status: YouTubePlayheadSyncStatus = .offlineLocalOnly
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

    /// Debounced sync after local YouTube playhead writes (pause / seek / background).
    func scheduleSyncAfterLocalChange() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            await self?.syncNow(reason: "localChange")
        }
    }

    /// Immediate sync (app foreground, Settings retry, before Play).
    func syncNow(reason: String) async {
        status = .syncing
        revision &+= 1
        publishUI()

        if let inFlight {
            await inFlight.value
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
        let timeouts = Self.timeouts(for: reason)
        let finished = await Self.withTimeout(seconds: timeouts.overall) {
            await Self.runNetworkSync(stepTimeout: timeouts.step)
        }

        guard let finished else {
            status = .offlineLocalOnly
            revision &+= 1
            publishUI()
            debugLog("[YouTubePlayheadSync] reason=\(reason) pushed=false detail=overallTimeout")
            notifySyncFailedIfUserFacing(reason: reason)
            return
        }

        switch finished {
            case .synced(let now, let count):
                lastSuccessfulSyncAt = now
                UserDefaults.standard.set(now, forKey: Self.lastSyncKey)
                status = .synced
                revision &+= 1
                publishUI()
                debugLog(
                    "[YouTubePlayheadSync] reason=\(reason) pushed=true playheads=\(count)"
                )
            case .offline(let detail):
                status = .offlineLocalOnly
                revision &+= 1
                publishUI()
                debugLog("[YouTubePlayheadSync] reason=\(reason) pushed=false detail=\(detail)")
                notifySyncFailedIfUserFacing(reason: reason)
        }
    }

    private func notifySyncFailedIfUserFacing(reason: String) {
        switch reason {
            case "settingsRetry":
                NotificationCenter.default.post(
                    name: .punkRallyYouTubePlayheadSyncFailed,
                    object: nil
                )
            default:
                break
        }
    }

    private enum SyncOutcome: Sendable {
        case synced(Date, playheadCount: Int)
        case offline(String)
    }

    private static func timeouts(for reason: String) -> (step: TimeInterval, overall: TimeInterval) {
        if reason == "beforePlay" {
            return (beforePlayStepTimeoutSeconds, beforePlayOverallTimeoutSeconds)
        }
        return (networkTimeoutSeconds, overallTimeoutSeconds)
    }

    private static func runNetworkSync(stepTimeout: TimeInterval) async -> SyncOutcome {
        let canReach =
            await withTimeout(seconds: stepTimeout) {
                await BookServiceActor.shared.canReachStorytellerForStatsSync()
            }
        guard let canReach else {
            return .offline("reach timeout")
        }
        guard canReach else {
            return .offline("auth/unreachable")
        }

        let localDoc = await MainActor.run {
            YouTubePlayheadStore.shared.exportSyncDocument()
        }
        let fetch =
            await withTimeout(seconds: stepTimeout) {
                await BookServiceActor.shared.fetchInkampYouTubePlayheadsDocument()
            }
        guard let fetch else {
            return .offline("fetch timeout")
        }

        let merged: InkampYouTubePlayheadSyncDocument
        switch fetch {
            case .unavailable(let detail):
                return .offline("fetch unavailable: \(detail)")
            case .empty:
                merged = localDoc
            case .document(let remoteDoc):
                merged = YouTubePlayheadSyncMerge.mergeDocuments(
                    local: localDoc,
                    remote: remoteDoc
                )
        }

        await MainActor.run {
            YouTubePlayheadStore.shared.applyMergedSyncDocument(merged)
        }

        let push =
            await withTimeout(seconds: stepTimeout) {
                await BookServiceActor.shared.pushInkampYouTubePlayheadsDocument(merged)
            }
        guard let push else {
            return .offline("push timeout")
        }
        switch push {
            case .success:
                return .synced(Date(), playheadCount: merged.playheads.count)
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
            name: .punkRallyYouTubePlayheadSyncUIDidChange,
            object: nil,
            userInfo: info
        )
    }

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
