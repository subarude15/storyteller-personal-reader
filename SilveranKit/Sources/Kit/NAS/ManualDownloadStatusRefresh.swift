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

    /// Retry a failed final-route move without re-submitting the torrent/magnet.
    @discardableResult
    public func retryRouting(job: ManualDownloadJob) async -> ManualDownloadJob {
        guard job.canRetryRoutingNow else { return job }
        if job.backend == .deluge {
            guard let hash = TorrentHash.normalized(job.backendJobID) else { return job }
            var pending = job
            pending.status = .readyToRoute
            pending.markDelugeFinalRoutingIfNeeded(force: true)
            pending.lastError = nil
            pending.lastStatusAt = Date()
            await jobs.record(pending)
            let context = await environment.load()
            return await routeDelugeJob(pending, hash: hash, context: context)
        }
        if job.backend == .torbox, job.viaTorBoxarr == true {
            var pending = job
            pending.status = .readyToRoute
            pending.fileStationMoveTaskID = nil
            pending.markFileStationFinalRoutingIfNeeded(force: true)
            pending.lastError = nil
            pending.lastStatusAt = Date()
            await jobs.record(pending)
            let context = await environment.load()
            return await retryTorBoxarrRouting(pending, context: context)
        }
        return job
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
                        || $0.hasActiveFileStationMove
                )
        }
        guard !targets.isEmpty else { return [] }
        guard let baseURL = context.torboxarr.baseURL else {
            return await reconcileTorBoxarrWithoutBridge(targets, context: context)
        }
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
                return await reconcileTorBoxarrWithoutBridge(targets, context: context)
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

            // Bridge miss while a File Station move is already running — resume that task.
            if job.hasActiveFileStationMove {
                changed.append(await routeTorBoxarr(job, live: routingLive(job), payloads: [], context: context))
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
                if job.hasActiveFileStationMove {
                    changed.append(
                        await routeTorBoxarr(job, live: routingLive(job), payloads: [], context: context)
                    )
                } else {
                    changed.append(await store(ManualDownloadStatusMapping.markUnknown(job)))
                }
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
                    } else if updated.hasActiveFileStationMove {
                        changed.append(
                            await routeTorBoxarr(
                                updated,
                                live: routingLive(updated),
                                payloads: [],
                                context: context,
                            )
                        )
                    } else {
                        changed.append(await store(ManualDownloadStatusMapping.markUnknown(updated)))
                    }
                case .notFound:
                    if job.hasActiveFileStationMove {
                        changed.append(
                            await routeTorBoxarr(job, live: routingLive(job), payloads: [], context: context)
                        )
                    } else if (job.backendJobID ?? "").isEmpty {
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

    /// Bridge unreachable: keep observing any persisted File Station move; otherwise Unknown.
    private func reconcileTorBoxarrWithoutBridge(
        _ targets: [ManualDownloadJob],
        context: NASHandoffContext,
    ) async -> [ManualDownloadJob] {
        var changed: [ManualDownloadJob] = []
        for job in targets {
            if job.hasActiveFileStationMove || (job.status == .routing && job.hasReachedFileStationFinalRouting) {
                changed.append(await routeTorBoxarr(job, live: routingLive(job), payloads: [], context: context))
            } else {
                changed.append(await store(ManualDownloadStatusMapping.markUnknown(job)))
            }
        }
        return changed
    }

    private func retryTorBoxarrRouting(
        _ job: ManualDownloadJob,
        context: NASHandoffContext,
    ) async -> ManualDownloadJob {
        guard let baseURL = context.torboxarr.baseURL else {
            return await routeTorBoxarr(job, live: routingLive(job), payloads: payloadsFromJob(job), context: context)
        }
        let hash = TorrentHash.normalized(job.backendJobID)
        if let hash {
            do {
                let snapshots = try await qbittorrent.torrentStatuses(
                    baseURL: baseURL,
                    username: context.torboxarr.username,
                    password: context.credentials.torboxarrPassword,
                    hashes: [hash],
                )
                if let snapshot = snapshots[hash.lowercased()] {
                    return await reconcileTorBoxarr(job, hash: hash.lowercased(), snapshot: snapshot, context: context)
                }
            } catch {
                // Fall through to File Station-only retry using persisted payload name.
            }
        }
        return await routeTorBoxarr(job, live: routingLive(job), payloads: payloadsFromJob(job), context: context)
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
            || job.hasActiveFileStationMove
        if payloads.isEmpty, live.status == .complete || awaitingRoute {
            guard let baseURL = context.torboxarr.baseURL else {
                if job.hasActiveFileStationMove {
                    return await routeTorBoxarr(job, live: live, payloads: payloadsFromJob(job), context: context)
                }
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
                if job.hasActiveFileStationMove {
                    return await routeTorBoxarr(job, live: live, payloads: payloadsFromJob(job), context: context)
                }
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
    ///
    /// CopyMove is asynchronous: start persists `fileStationMoveTaskID` and leaves the
    /// job `.routing`. Later refreshes reconcile the DSM task — never start a duplicate.
    private func routeTorBoxarr(
        _ job: ManualDownloadJob,
        live: ManualTorrentLiveStatus,
        payloads: [TorBoxarrPayloadLocator.Item],
        context: NASHandoffContext,
    ) async -> ManualDownloadJob {
        var effectivePayloads = payloads
        if effectivePayloads.isEmpty {
            effectivePayloads = payloadsFromJob(job)
        }
        debugLog("[TorBoxarrRoute] complete detected job=\(job.id)")
        for item in effectivePayloads {
            debugLog("[TorBoxarrRoute] source=\(Self.safePath(item.sourceVolumePath))")
        }
        debugLog("[TorBoxarrRoute] destination=\(Self.safePath(job.destination))")
        if let name = effectivePayloads.first?.name ?? job.filename {
            debugLog("[TorBoxarrRoute] payload=\(name)")
        }

        guard !effectivePayloads.isEmpty || job.hasActiveFileStationMove || !(job.filename ?? "").isEmpty else {
            var pending = routed(live, job: job, status: .readyToRoute)
            pending.markFileStationFinalRoutingIfNeeded(force: true)
            pending.lastError =
                "Couldn’t tell which completed files belong to this download.\nNothing was moved."
            debugLog("[TorBoxarrRoute] failure stage=payload error=unidentified")
            return await store(pending)
        }
        guard context.settings.isSynologyConfigured, !context.credentials.synologyPassword.isEmpty else {
            var pending = routed(live, job: job, status: .routing)
            pending.markFileStationFinalRoutingIfNeeded(force: true)
            pending.lastError =
                "Synology isn’t configured, so this download can’t be moved into the library yet."
            debugLog("[TorBoxarrRoute] failure stage=auth error=synology-not-configured")
            return await store(pending)
        }
        let baseURL = context.settings.trimmedSynologyBaseURL
        let username = context.settings.trimmedSynologyUsername
        let password = context.credentials.synologyPassword
        var routing = routed(live, job: job, status: .routing)
        routing.markFileStationFinalRoutingIfNeeded(force: true)
        if let name = effectivePayloads.first?.name, (routing.filename ?? "").isEmpty {
            routing.filename = name
        }
        // Preserve an in-flight task id across the routed() mapping.
        routing.fileStationMoveTaskID = job.fileStationMoveTaskID
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
            let checkPayloads = effectivePayloads.isEmpty
                ? payloadsFromNames([routing.filename].compactMap { $0 })
                : effectivePayloads
            let filenamePresent = routing.filename.map { present.contains($0) } ?? false
            let alreadyThere = Self.destinationHas(checkPayloads, names: present) || filenamePresent
            debugLog("[TorBoxarrRoute] destination check present=\(alreadyThere)")
            if alreadyThere {
                debugLog("[TorBoxarrRoute] destination verified")
                debugLog("[TorBoxarrRoute] complete")
                return await store(ManualDownloadStatusMapping.markComplete(routing))
            }

            if let taskID = routing.fileStationMoveTaskID,
                !taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return await reconcileFileStationMove(
                    routing,
                    taskID: taskID,
                    payloads: checkPayloads,
                    baseURL: baseURL,
                    username: username,
                    password: password,
                )
            }

            let toMove = checkPayloads.filter { !present.contains($0.name) }
            guard let item = toMove.first else {
                debugLog("[TorBoxarrRoute] destination verified")
                debugLog("[TorBoxarrRoute] complete")
                return await store(ManualDownloadStatusMapping.markComplete(routing))
            }
            debugLog("[TorBoxarrRoute] source=\(Self.safePath(item.sourceVolumePath))")
            debugLog("[TorBoxarrRoute] payload=\(item.name)")
            debugLog("[TorBoxarrRoute] starting CopyMove")
            let taskID = try await fileStation.startMoveItem(
                baseURL: baseURL,
                username: username,
                password: password,
                sourceVolumePath: item.sourceVolumePath,
                destinationVolumeDirectory: job.destination,
            )
            routing.fileStationMoveTaskID = taskID
            routing.filename = item.name
            routing.lastError = nil
            routing.lastStatusAt = Date()
            debugLog("[TorBoxarrRoute] CopyMove started task=\(taskID)")
            // Stay Routing — normal Downloads refresh reconciles the DSM task.
            return await store(routing)
        } catch {
            let stage = Self.torboxarrFailureStage(error)
            let message = Self.torboxarrRouteFailure(error)
            debugLog("[TorBoxarrRoute] failure stage=\(stage) error=\(Self.sanitizeError(message))")
            // Hard failures become Failed so Retry Move appears; keep recoverable
            // routing when a task id already exists and the NAS was only briefly unreachable.
            if routing.hasActiveFileStationMove, Self.isTemporaryNASFailure(error) {
                routing.lastError = nil
                routing.lastStatusAt = Date()
                return await store(routing)
            }
            var failed = ManualDownloadStatusMapping.markFailed(routing, message: message)
            failed.fileStationMoveTaskID = routing.fileStationMoveTaskID
            failed.markFileStationFinalRoutingIfNeeded(force: true)
            return await store(failed)
        }
    }

    private func reconcileFileStationMove(
        _ job: ManualDownloadJob,
        taskID: String,
        payloads: [TorBoxarrPayloadLocator.Item],
        baseURL: String,
        username: String,
        password: String,
    ) async -> ManualDownloadJob {
        debugLog("[TorBoxarrRoute] reconciling task=\(taskID)")
        do {
            let status = try await fileStation.moveTaskStatus(
                baseURL: baseURL,
                username: username,
                password: password,
                taskID: taskID,
            )
            switch status {
                case .running:
                    debugLog("[TorBoxarrRoute] task running")
                    var running = job
                    running.status = .routing
                    running.fileStationMoveTaskID = taskID
                    running.lastError = nil
                    running.lastStatusAt = Date()
                    return await store(running)
                case .finished:
                    debugLog("[TorBoxarrRoute] task finished")
                    let arrived = try await fileStation.listFilenames(
                        baseURL: baseURL,
                        username: username,
                        password: password,
                        volumeDirectory: job.destination,
                    )
                    let filenamePresent = job.filename.map { arrived.contains($0) } ?? false
                    let verified = Self.destinationHas(payloads, names: arrived) || filenamePresent
                    debugLog("[TorBoxarrRoute] destination check present=\(verified)")
                    if verified {
                        debugLog("[TorBoxarrRoute] destination verified")
                        debugLog("[TorBoxarrRoute] complete")
                        return await store(ManualDownloadStatusMapping.markComplete(job))
                    }
                    debugLog("[TorBoxarrRoute] failure stage=verify error=destination-missing")
                    var failed = ManualDownloadStatusMapping.markFailed(
                        job,
                        message: Self.torboxarrVerifyFailure,
                    )
                    failed.fileStationMoveTaskID = nil
                    failed.markFileStationFinalRoutingIfNeeded(force: true)
                    return await store(failed)
                case .failed:
                    debugLog("[TorBoxarrRoute] failure stage=task error=copymove-failed")
                    var failed = ManualDownloadStatusMapping.markFailed(
                        job,
                        message: Self.torboxarrTaskFailure,
                    )
                    // Keep task id so Retry Move clears it explicitly; do not auto-restart.
                    failed.fileStationMoveTaskID = taskID
                    failed.markFileStationFinalRoutingIfNeeded(force: true)
                    return await store(failed)
            }
        } catch {
            // Temporary status lookup failure — keep Routing + task id, do not start another move.
            if Self.isTemporaryNASFailure(error) {
                debugLog("[TorBoxarrRoute] failure stage=status error=temporary-unreachable")
                var running = job
                running.status = .routing
                running.fileStationMoveTaskID = taskID
                running.lastError = nil
                running.lastStatusAt = Date()
                return await store(running)
            }
            let stage = Self.torboxarrFailureStage(error)
            let message = Self.torboxarrRouteFailure(error)
            debugLog("[TorBoxarrRoute] failure stage=\(stage) error=\(Self.sanitizeError(message))")
            var failed = ManualDownloadStatusMapping.markFailed(job, message: message)
            failed.fileStationMoveTaskID = taskID
            failed.markFileStationFinalRoutingIfNeeded(force: true)
            return await store(failed)
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

    private func routingLive(_ job: ManualDownloadJob) -> ManualTorrentLiveStatus {
        ManualTorrentLiveStatus(
            status: .routing,
            progress: job.progress ?? 1,
            downloadRate: nil,
            totalSize: job.totalSize,
            completedSize: job.byteCount,
        )
    }

    private func payloadsFromJob(_ job: ManualDownloadJob) -> [TorBoxarrPayloadLocator.Item] {
        payloadsFromNames([job.filename].compactMap { $0 })
    }

    private func payloadsFromNames(_ names: [String]) -> [TorBoxarrPayloadLocator.Item] {
        let hostRoot = TorBoxarrConnectionSettings.hostCompletedFolder
        return names.compactMap { name -> TorBoxarrPayloadLocator.Item? in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let source = hostRoot + "/" + trimmed
            let item = TorBoxarrPayloadLocator.Item(name: trimmed, sourceVolumePath: source)
            guard Self.isScopedPayload(item, completedFolder: hostRoot) else { return nil }
            return item
        }
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

    private static let torboxarrTaskFailure =
        "The NAS CopyMove task failed while moving the download into the library.\nFiles were left in the TorBox completed folder."
    private static let torboxarrVerifyFailure =
        "The NAS finished the move, but the files are not in the library folder.\nFiles may still be in the TorBox completed folder."

    private static func torboxarrRouteFailure(_ error: Error) -> String {
        let left = "Files were left in the TorBox completed folder."
        if let synology = error as? SynologyClientError {
            switch synology {
                case .authenticationFailed:
                    return "NAS authentication failed while moving the download.\n\(left)"
                case .cannotReachServer:
                    return "Couldn’t reach the NAS to move the download.\n\(left)"
                case .timeout:
                    return "The NAS timed out while moving the download.\n\(left)"
                case .rejected:
                    return "The NAS rejected the CopyMove request.\n\(left)"
                case .invalidURL, .invalidResponse, .verificationFailed:
                    return "The NAS rejected the move into the library folder.\n\(left)"
            }
        }
        if let handoff = error as? NASHandoffError {
            switch handoff {
                case .emptyDestination, .invalidDestination:
                    return "The source payload path is missing or invalid.\n\(left)"
                case .backendNotConfigured, .torrentClientNotSelected, .mediaTypeUnresolved,
                    .malformedMagnet, .unsupportedAcquisition, .unreachable, .timeout,
                    .authenticationFailed, .rejected, .invalidURL, .downloadFailed,
                    .insufficientStorage, .uploadRejected, .uploadInterrupted, .stagedFileMissing:
                    break
            }
        }
        return "The NAS rejected the move into the library folder.\n\(left)"
    }

    private static func torboxarrFailureStage(_ error: Error) -> String {
        if let synology = error as? SynologyClientError {
            switch synology {
                case .authenticationFailed: return "auth"
                case .cannotReachServer, .timeout: return "unreachable"
                case .rejected: return "copymove-rejected"
                case .invalidURL, .invalidResponse, .verificationFailed: return "nas-response"
            }
        }
        if error is NASHandoffError { return "source" }
        return "unknown"
    }

    private static func isTemporaryNASFailure(_ error: Error) -> Bool {
        guard let synology = error as? SynologyClientError else { return false }
        switch synology {
            case .cannotReachServer, .timeout: return true
            case .authenticationFailed, .invalidURL, .invalidResponse, .rejected, .verificationFailed:
                return false
        }
    }

    private static func safePath(_ path: String) -> String {
        // Volume paths only — strip query-like fragments; never log credentials.
        path.split(separator: "?").first.map(String.init) ?? path
    }

    private static func sanitizeError(_ message: String) -> String {
        message
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
