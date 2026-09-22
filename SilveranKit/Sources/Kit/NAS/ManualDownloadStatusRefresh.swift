//
//  ManualDownloadStatusRefresh.swift
//  SilveranKit
//
//  Lightweight qBittorrent / Deluge status refresh. Poll failures become
//  Unknown, never Failed — except Deluge final-route move_storage errors.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct ManualDownloadStatusRefresh: Sendable {
    public var environment: any NASHandoffEnvironment
    public var qbittorrent: QBittorrentClient
    public var deluge: DelugeWebClient
    public var torbox: TorBoxClient
    public var jobs: any ManualDownloadJobStoring

    public init(
        environment: any NASHandoffEnvironment,
        qbittorrent: QBittorrentClient = QBittorrentClient(),
        deluge: DelugeWebClient = DelugeWebClient(),
        torbox: TorBoxClient = TorBoxClient(),
        jobs: any ManualDownloadJobStoring = ManualDownloadJobStore.shared,
    ) {
        self.environment = environment
        self.qbittorrent = qbittorrent
        self.deluge = deluge
        self.torbox = torbox
        self.jobs = jobs
    }

    public static func live() -> ManualDownloadStatusRefresh {
        ManualDownloadStatusRefresh(environment: LiveNASHandoffEnvironment())
    }

    @discardableResult
    public func refresh() async -> [ManualDownloadJob] {
        let context = await environment.load()
        let current = await jobs.allJobs()
        var updated: [ManualDownloadJob] = []
        updated.append(contentsOf: await refreshQBittorrent(current, context: context))
        updated.append(contentsOf: await refreshDeluge(current, context: context))
        updated.append(contentsOf: await refreshTorBox(current, context: context))
        // Phase 2: poll NAS Download Station + auto-start Ready TorBox jobs.
        let transfer = TorBoxNASTransferService(
            environment: environment,
            torbox: torbox,
            jobs: jobs,
        )
        updated.append(contentsOf: await transfer.reconcile(autoStartReady: true))
        return updated
    }

    /// Retry a failed Deluge final-route move without re-submitting the torrent.
    @discardableResult
    public func retryRouting(job: ManualDownloadJob) async -> ManualDownloadJob {
        guard job.canRetryRoutingNow,
            let hash = TorrentHash.normalized(job.backendJobID)
        else {
            return job
        }
        var pending = job
        pending.status = .readyToRoute
        pending.markDelugeFinalRoutingIfNeeded(force: true)
        pending.lastError = nil
        pending.lastStatusAt = Date()
        await jobs.record(pending)
        let context = await environment.load()
        return await routeDelugeJob(pending, hash: hash, context: context)
    }

    private func refreshQBittorrent(
        _ current: [ManualDownloadJob],
        context: NASHandoffContext,
    ) async -> [ManualDownloadJob] {
        let targets = current.filter {
            $0.backend == .qbittorrent && $0.status.isActive && !($0.backendJobID ?? "").isEmpty
        }
        guard !targets.isEmpty else { return [] }
        let hashes = targets.compactMap { TorrentHash.normalized($0.backendJobID) }
        do {
            let snapshots = try await qbittorrent.torrentStatuses(
                baseURL: context.settings.trimmedQBittorrentBaseURL,
                username: context.settings.qbittorrentUsername,
                password: context.credentials.qbittorrentPassword,
                hashes: hashes,
            )
            var changed: [ManualDownloadJob] = []
            for job in targets {
                guard let hash = TorrentHash.normalized(job.backendJobID)?.lowercased(),
                    let snapshot = snapshots[hash]
                else {
                    let next = ManualDownloadStatusMapping.markUnknown(job)
                    await jobs.record(next)
                    changed.append(next)
                    continue
                }
                let next = ManualDownloadStatusMapping.apply(snapshot.liveStatus, to: job)
                await jobs.record(next)
                changed.append(next)
            }
            return changed
        } catch {
            return await markUnknown(targets)
        }
    }

    private func refreshDeluge(
        _ current: [ManualDownloadJob],
        context: NASHandoffContext,
    ) async -> [ManualDownloadJob] {
        let targets = current.filter {
            $0.backend == .deluge && $0.status.isActive && !($0.backendJobID ?? "").isEmpty
        }
        guard !targets.isEmpty else { return [] }
        let result = await deluge.fetchTorrentIndex(
            baseURL: context.settings.trimmedDelugeBaseURL,
            password: context.credentials.delugePassword,
        )
        switch result {
            case .failure:
                return await markUnknown(targets)
            case .success(let index):
                var changed: [ManualDownloadJob] = []
                for job in targets {
                    guard let hash = TorrentHash.normalized(job.backendJobID) else {
                        let next = ManualDownloadStatusMapping.markUnknown(job)
                        await jobs.record(next)
                        changed.append(next)
                        continue
                    }
                    let snapshot = index.torrent(id: hash) ?? index.byID[hash.lowercased()]
                    let next = await reconcileDelugeJob(job, hash: hash, snapshot: snapshot, context: context)
                    changed.append(next)
                }
                return changed
        }
    }

    private func reconcileDelugeJob(
        _ job: ManualDownloadJob,
        hash: String,
        snapshot: DelugeTorrentSnapshot?,
        context: NASHandoffContext,
    ) async -> ManualDownloadJob {
        let settings = context.settings
        let decision = DelugeManualRouting.evaluate(
            snapshot: snapshot,
            finalDestination: job.destination,
            incomingFolder: settings.trimmedDelugeIncomingFolder,
            completedFolder: settings.trimmedDelugeCompletedFolder,
        )

        switch decision {
            case .torrentMissing:
                let next = ManualDownloadStatusMapping.markFailed(
                    job,
                    message: "That torrent is no longer in Deluge.",
                )
                await jobs.record(next)
                return next

            case .alreadyAtDestination:
                let next = ManualDownloadStatusMapping.markComplete(job)
                await jobs.record(next)
                return next

            case .observe(let status), .waitForDelugeCompleted(let status):
                var live = ManualTorrentLiveStatus(
                    status: status,
                    progress: snapshot?.progress,
                    downloadRate: snapshot?.downloadRate,
                    totalSize: snapshot?.totalSize,
                    completedSize: snapshot?.completedSize,
                )
                // Keep routing label while Deluge is still relocating after our request.
                if job.status == .routing, status == .delugeFinishing || status == .readyToRoute {
                    live.status = .routing
                }
                let next = ManualDownloadStatusMapping.apply(live, to: job)
                await jobs.record(next)
                return next

            case .requestMove:
                return await routeDelugeJob(job, hash: hash, context: context, snapshot: snapshot)
        }
    }

    private func routeDelugeJob(
        _ job: ManualDownloadJob,
        hash: String,
        context: NASHandoffContext,
        snapshot: DelugeTorrentSnapshot? = nil,
    ) async -> ManualDownloadJob {
        // Idempotent: if a prior move already landed, complete without calling again.
        if let snapshot,
            DelugeManualRouting.path(snapshot.savePath, isUnder: job.destination)
        {
            let next = ManualDownloadStatusMapping.markComplete(job)
            await jobs.record(next)
            return next
        }

        var routing = job
        routing.status = .routing
        routing.markDelugeFinalRoutingIfNeeded(force: true)
        routing.progress = snapshot?.progress ?? job.progress ?? 1
        routing.downloadRate = snapshot?.downloadRate
        routing.totalSize = snapshot?.totalSize ?? job.totalSize
        if let completed = snapshot?.completedSize {
            routing.byteCount = completed
        }
        routing.lastError = nil
        routing.lastStatusAt = Date()
        await jobs.record(routing)

        do {
            try await deluge.moveStorage(
                baseURL: context.settings.trimmedDelugeBaseURL,
                password: context.credentials.delugePassword,
                torrentIDs: [hash],
                destination: job.destination,
            )
            // Success means Deluge accepted the move. Stay in `.routing` until a
            // later refresh sees the torrent under the final destination.
            return routing
        } catch let error as DelugeClientError {
            let next = ManualDownloadStatusMapping.markFailed(routing, message: error.routeFailureMessage)
            await jobs.record(next)
            return next
        } catch {
            let next = ManualDownloadStatusMapping.markFailed(
                routing,
                message: DelugeClientError.rejected.routeFailureMessage,
            )
            await jobs.record(next)
            return next
        }
    }

    private func refreshTorBox(
        _ current: [ManualDownloadJob],
        context: NASHandoffContext,
    ) async -> [ManualDownloadJob] {
        let targets = current.filter {
            $0.backend == .torbox
                && $0.viaTorBoxarr != true
                && $0.status.isActive
                && $0.status != .transferring
                && !($0.backendJobID ?? "").isEmpty
        }
        guard !targets.isEmpty else { return [] }
        let key = context.credentials.torboxAPIKey
        guard !key.isEmpty else { return await markUnknown(targets) }
        var changed: [ManualDownloadJob] = []
        for job in targets {
            guard let id = job.backendJobID else {
                let next = ManualDownloadStatusMapping.markUnknown(job)
                await jobs.record(next)
                changed.append(next)
                continue
            }
            do {
                let info = try await torbox.getTorrent(apiKey: key, id: id, bypassCache: true)
                let next = TorBoxStatusMapping.apply(info, to: job)
                await jobs.record(next)
                changed.append(next)
            } catch let error as TorBoxClientError {
                switch error {
                    case .rejected(let detail)
                    where detail.lowercased().contains("not found")
                        || detail.lowercased().contains("no torrent"):
                        let next = ManualDownloadStatusMapping.markFailed(
                            job,
                            message: "That torrent is no longer in TorBox.",
                        )
                        await jobs.record(next)
                        changed.append(next)
                    default:
                        let next = ManualDownloadStatusMapping.markUnknown(job)
                        await jobs.record(next)
                        changed.append(next)
                }
            } catch {
                let next = ManualDownloadStatusMapping.markUnknown(job)
                await jobs.record(next)
                changed.append(next)
            }
        }
        return changed
    }

    /// Remove a TorBox cloud torrent when the user deletes a Downloads row.
    public func deleteRemoteIfNeeded(job: ManualDownloadJob) async {
        guard job.backend == .torbox, job.viaTorBoxarr != true, let id = job.backendJobID, !id.isEmpty else {
            return
        }
        let context = await environment.load()
        let key = context.credentials.torboxAPIKey
        guard !key.isEmpty else { return }
        do {
            try await torbox.deleteTorrent(apiKey: key, id: id)
        } catch {
            debugLog("[TorBox] delete remote failed id=\(id)")
        }
    }

    private func markUnknown(_ jobs: [ManualDownloadJob]) async -> [ManualDownloadJob] {
        var changed: [ManualDownloadJob] = []
        for job in jobs {
            let next = ManualDownloadStatusMapping.markUnknown(job)
            await self.jobs.record(next)
            changed.append(next)
        }
        return changed
    }
}

extension DelugeClientError {
    fileprivate var routeFailureMessage: String {
        switch self {
            case .authenticationFailed:
                "Deluge rejected the credentials while moving the torrent.\nFiles were left where Deluge has them."
            case .cannotReachServer, .timeout:
                "Couldn’t reach Deluge to move the torrent.\nFiles were left where Deluge has them."
            case .invalidURL:
                "The Deluge URL is invalid.\nFiles were left where Deluge has them."
            case .notConnectedToDaemon:
                "Deluge is not connected to its daemon.\nFiles were left where Deluge has them."
            case .rejected, .invalidResponse:
                "Deluge rejected move_storage.\nFiles were left where Deluge has them."
        }
    }
}
