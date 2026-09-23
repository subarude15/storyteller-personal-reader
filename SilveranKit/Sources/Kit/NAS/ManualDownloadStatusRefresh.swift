//
//  ManualDownloadStatusRefresh.swift
//  SilveranKit
//
//  Lightweight qBittorrent / Deluge / TorBoxarr status refresh. Poll failures
//  become Unknown, never Failed — except a torrent that is actually gone, and
//  except a final-route move that File Station or Deluge rejects.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct ManualDownloadStatusRefresh: Sendable {
    public var environment: any NASHandoffEnvironment
    public var qbittorrent: QBittorrentClient
    public var deluge: DelugeWebClient
    public var torbox: TorBoxClient
    public var fileStation: SynologyFileStationClient
    public var jobs: any ManualDownloadJobStoring

    public init(
        environment: any NASHandoffEnvironment,
        qbittorrent: QBittorrentClient = QBittorrentClient(),
        deluge: DelugeWebClient = DelugeWebClient(),
        torbox: TorBoxClient = TorBoxClient(),
        fileStation: SynologyFileStationClient = SynologyFileStationClient(),
        jobs: any ManualDownloadJobStoring = ManualDownloadJobStore.shared,
    ) {
        self.environment = environment
        self.qbittorrent = qbittorrent
        self.deluge = deluge
        self.torbox = torbox
        self.fileStation = fileStation
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
        updated.append(contentsOf: await refreshTorBoxarr(current, context: context))
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

    /// TorBoxarr jobs use the qBittorrent bridge, then File Station for the library move.
    /// The TorBox cloud API and `TorBoxNASTransferService` do not see these jobs.
    ///
    /// `backendJobID` must be TorBoxarr’s PublicID (`hash` from torrents/info), not the
    /// magnet BTIH. When the ID is missing or the hash poll misses, rematch via `magnet_uri`.
    private func refreshTorBoxarr(
        _ current: [ManualDownloadJob],
        context: NASHandoffContext,
    ) async -> [ManualDownloadJob] {
        let targets = current.filter {
            $0.backend == .torbox
                && $0.viaTorBoxarr == true
                && $0.status.isActive
                && (
                    !($0.backendJobID ?? "").isEmpty
                        || ($0.sourceURL.flatMap(TorrentHash.fromMagnet) != nil)
                )
        }
        guard !targets.isEmpty else { return [] }
        guard let baseURL = context.torboxarr.baseURL else { return await markUnknown(targets) }
        let username = context.torboxarr.username
        let password = context.credentials.torboxarrPassword

        let withIDs = targets.filter { !($0.backendJobID ?? "").isEmpty }
        var byHash: [String: QBittorrentTorrentSnapshot] = [:]
        if !withIDs.isEmpty {
            let hashes = withIDs.compactMap { TorrentHash.normalized($0.backendJobID) }
            do {
                byHash = try await qbittorrent.torrentStatuses(
                    baseURL: baseURL,
                    username: username,
                    password: password,
                    hashes: hashes,
                )
            } catch {
                return await markUnknown(targets)
            }
        }

        var listed: [QBittorrentTorrentSnapshot]?
        func allTorrents() async throws -> [QBittorrentTorrentSnapshot] {
            if let listed { return listed }
            let value = try await qbittorrent.listTorrents(
                baseURL: baseURL,
                username: username,
                password: password,
            )
            listed = value
            return value
        }

        var changed: [ManualDownloadJob] = []
        for job in targets {
            if let hash = TorrentHash.normalized(job.backendJobID)?.lowercased(),
                let snapshot = byHash[hash]
            {
                changed.append(
                    await reconcileTorBoxarr(job, hash: hash, snapshot: snapshot, context: context)
                )
                continue
            }

            guard let magnet = job.sourceURL, TorrentHash.fromMagnet(magnet) != nil else {
                if (job.backendJobID ?? "").isEmpty {
                    changed.append(await store(ManualDownloadStatusMapping.markUnknown(job)))
                } else {
                    let next = ManualDownloadStatusMapping.markFailed(
                        job,
                        message: "That torrent is no longer in TorBox.",
                    )
                    changed.append(await store(next))
                }
                continue
            }

            let list: [QBittorrentTorrentSnapshot]
            do {
                list = try await allTorrents()
            } catch {
                changed.append(await store(ManualDownloadStatusMapping.markUnknown(job)))
                continue
            }

            switch TorBoxarrJobIdentity.resolve(torrents: list, magnetURI: magnet) {
                case .resolved(let publicID):
                    var updated = job
                    updated.backendJobID = TorrentHash.normalized(publicID) ?? publicID
                    if updated.providerInfoHash == nil {
                        updated.providerInfoHash = TorrentHash.fromMagnet(magnet)
                    }
                    updated.lastError = nil
                    let key = publicID.lowercased()
                    if let snapshot = list.first(where: { $0.hash.lowercased() == key }) {
                        changed.append(
                            await reconcileTorBoxarr(
                                updated,
                                hash: key,
                                snapshot: snapshot,
                                context: context,
                            )
                        )
                    } else {
                        changed.append(await store(ManualDownloadStatusMapping.markUnknown(updated)))
                    }
                case .notFound:
                    if (job.backendJobID ?? "").isEmpty {
                        // Still waiting for TorBoxarr to expose the accepted job.
                        changed.append(await store(ManualDownloadStatusMapping.markUnknown(job)))
                    } else {
                        let next = ManualDownloadStatusMapping.markFailed(
                            job,
                            message: "That torrent is no longer in TorBox.",
                        )
                        changed.append(await store(next))
                    }
                case .ambiguous:
                    var next = ManualDownloadStatusMapping.markUnknown(job)
                    next.lastError = ManualMagnetCopy.torBoxarrAmbiguousMatch
                    changed.append(await store(next))
            }
        }
        return changed
    }

    private func reconcileTorBoxarr(
        _ job: ManualDownloadJob,
        hash: String,
        snapshot: QBittorrentTorrentSnapshot,
        context: NASHandoffContext,
    ) async -> ManualDownloadJob {
        let live = snapshot.liveStatus
        let apiRoot = TorBoxarrPayloadLocator.apiCompletedRoot(
            savePath: snapshot.savePath,
            contentPath: snapshot.contentPath,
        )
        let hostRoot = TorBoxarrConnectionSettings.hostCompletedFolder
        var payloads = TorBoxarrPayloadLocator.items(
            contentPath: snapshot.contentPath,
            savePath: snapshot.savePath,
            torrentName: snapshot.name,
            fileNames: [],
            apiCompletedFolder: apiRoot,
            hostCompletedFolder: hostRoot,
        )
        let awaitingRoute = job.status == .routing || job.status == .readyToRoute
        if payloads.isEmpty, live.status == .complete || awaitingRoute {
            guard let baseURL = context.torboxarr.baseURL else {
                return await store(ManualDownloadStatusMapping.markUnknown(job))
            }
            do {
                let files = try await qbittorrent.torrentFiles(
                    baseURL: baseURL,
                    username: context.torboxarr.username,
                    password: context.credentials.torboxarrPassword,
                    hash: hash,
                )
                payloads = TorBoxarrPayloadLocator.items(
                    contentPath: snapshot.contentPath,
                    savePath: snapshot.savePath,
                    torrentName: snapshot.name,
                    fileNames: files,
                    apiCompletedFolder: apiRoot,
                    hostCompletedFolder: hostRoot,
                )
            } catch {
                return await store(ManualDownloadStatusMapping.markUnknown(job))
            }
        }
        payloads = payloads.filter { Self.isScopedPayload($0, completedFolder: hostRoot) }
        if live.status != .complete, !awaitingRoute {
            return await store(ManualDownloadStatusMapping.apply(live, to: job))
        }
        return await routeTorBoxarr(job, live: live, payloads: payloads, context: context)
    }

    /// qBittorrent setLocation is not used. TorBoxarr is only assumed to write the
    /// completed folder; File Station moves that one payload onto the library share.
    private func routeTorBoxarr(
        _ job: ManualDownloadJob,
        live: ManualTorrentLiveStatus,
        payloads: [TorBoxarrPayloadLocator.Item],
        context: NASHandoffContext,
    ) async -> ManualDownloadJob {
        guard !payloads.isEmpty else {
            var pending = routed(live, job: job, status: .readyToRoute)
            pending.lastError =
                "Couldn’t tell which completed files belong to this download.\nNothing was moved."
            return await store(pending)
        }
        guard context.settings.isSynologyConfigured, !context.credentials.synologyPassword.isEmpty else {
            var pending = routed(live, job: job, status: .routing)
            pending.lastError =
                "Synology isn’t configured, so this download can’t be moved into the library yet."
            return await store(pending)
        }
        let baseURL = context.settings.trimmedSynologyBaseURL
        let username = context.settings.trimmedSynologyUsername
        let password = context.credentials.synologyPassword
        var routing = routed(live, job: job, status: .routing)
        routing = await store(routing)
        do {
            try await fileStation.ensureFolder(
                baseURL: baseURL,
                username: username,
                password: password,
                volumePath: job.destination,
            )
            let present = try await fileStation.listFilenames(
                baseURL: baseURL,
                username: username,
                password: password,
                volumeDirectory: job.destination,
            )
            if Self.destinationHas(payloads, names: present) {
                return await store(ManualDownloadStatusMapping.markComplete(routing))
            }
            for item in payloads where !present.contains(item.name) {
                try await fileStation.moveItem(
                    baseURL: baseURL,
                    username: username,
                    password: password,
                    sourceVolumePath: item.sourceVolumePath,
                    destinationVolumeDirectory: job.destination,
                )
            }
            let arrived = try await fileStation.listFilenames(
                baseURL: baseURL,
                username: username,
                password: password,
                volumeDirectory: job.destination,
            )
            if Self.destinationHas(payloads, names: arrived) {
                return await store(ManualDownloadStatusMapping.markComplete(routing))
            }
            routing.lastError =
                "The download finished, but the files are not in the library folder yet."
            routing.lastStatusAt = Date()
            return await store(routing)
        } catch {
            routing.lastError = Self.torboxarrRouteFailure(error)
            routing.lastStatusAt = Date()
            return await store(routing)
        }
    }

    private func routed(
        _ live: ManualTorrentLiveStatus,
        job: ManualDownloadJob,
        status: ManualDownloadJobStatus,
    ) -> ManualDownloadJob {
        ManualDownloadStatusMapping.apply(
            ManualTorrentLiveStatus(
                status: status,
                progress: live.progress,
                downloadRate: live.downloadRate,
                totalSize: live.totalSize,
                completedSize: live.completedSize,
            ),
            to: job,
        )
    }

    private static func destinationHas(
        _ payloads: [TorBoxarrPayloadLocator.Item],
        names: [String],
    ) -> Bool {
        guard !payloads.isEmpty else { return false }
        return payloads.allSatisfy { names.contains($0.name) }
    }

    private static func isScopedPayload(
        _ item: TorBoxarrPayloadLocator.Item,
        completedFolder: String,
    ) -> Bool {
        guard let source = NASPathSafety.normalizeBase(item.sourceVolumePath),
            let root = NASPathSafety.normalizeBase(completedFolder),
            source != root,
            NASPathSafety.staysWithin(root: root, path: source),
            !item.name.isEmpty,
            !item.name.contains("/"),
            item.name != ".",
            item.name != "..",
            (source as NSString).lastPathComponent == item.name
        else { return false }
        return true
    }

    private static func torboxarrRouteFailure(_ error: Error) -> String {
        let left = "Files were left in the TorBox completed folder."
        guard let synology = error as? SynologyClientError else {
            return "The NAS rejected the move into the library folder.\n\(left)"
        }
        switch synology {
            case .authenticationFailed:
                return "The NAS rejected the credentials while moving the download.\n\(left)"
            case .cannotReachServer, .timeout:
                return "Couldn’t reach the NAS to move the download.\n\(left)"
            case .invalidURL, .invalidResponse, .rejected, .verificationFailed:
                return "The NAS rejected the move into the library folder.\n\(left)"
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

    private func store(_ job: ManualDownloadJob) async -> ManualDownloadJob {
        await jobs.record(job)
        return job
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
