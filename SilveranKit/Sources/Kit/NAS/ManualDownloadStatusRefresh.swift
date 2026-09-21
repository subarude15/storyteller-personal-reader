//
//  ManualDownloadStatusRefresh.swift
//  SilveranKit
//
//  Lightweight qBittorrent / Deluge status refresh. Poll failures become
//  Unknown, never Failed.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct ManualDownloadStatusRefresh: Sendable {
    public var environment: any NASHandoffEnvironment
    public var qbittorrent: QBittorrentClient
    public var deluge: DelugeWebClient
    public var jobs: any ManualDownloadJobStoring

    public init(
        environment: any NASHandoffEnvironment,
        qbittorrent: QBittorrentClient = QBittorrentClient(),
        deluge: DelugeWebClient = DelugeWebClient(),
        jobs: any ManualDownloadJobStoring = ManualDownloadJobStore.shared,
    ) {
        self.environment = environment
        self.qbittorrent = qbittorrent
        self.deluge = deluge
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
        return updated
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
                    guard let hash = TorrentHash.normalized(job.backendJobID),
                        let snapshot = index.torrent(id: hash) ?? index.byID[hash.lowercased()]
                    else {
                        let next = ManualDownloadStatusMapping.markUnknown(job)
                        await jobs.record(next)
                        changed.append(next)
                        continue
                    }
                    let live = ManualTorrentLiveStatus(
                        status: ManualDownloadStatusMapping.deluge(
                            state: snapshot.state,
                            progress: snapshot.progress,
                            isFinished: snapshot.isFinished,
                        ),
                        progress: snapshot.progress,
                        downloadRate: snapshot.downloadRate,
                        totalSize: snapshot.totalSize,
                        completedSize: snapshot.completedSize,
                    )
                    let next = ManualDownloadStatusMapping.apply(live, to: job)
                    await jobs.record(next)
                    changed.append(next)
                }
                return changed
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
