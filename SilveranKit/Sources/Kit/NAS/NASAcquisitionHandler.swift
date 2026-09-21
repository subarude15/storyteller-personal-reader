//
//  NASAcquisitionHandler.swift
//  SilveranKit
//
//  Torrents go to qBittorrent or Deluge. Direct files download to
//  device staging, then upload through NASFileUploading.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct NASBackendCredentials: Sendable, Equatable {
    public var qbittorrentPassword: String
    public var delugePassword: String
    public var synologyPassword: String

    public init(
        qbittorrentPassword: String = "",
        delugePassword: String = "",
        synologyPassword: String = "",
    ) {
        self.qbittorrentPassword = qbittorrentPassword
        self.delugePassword = delugePassword
        self.synologyPassword = synologyPassword
    }
}

public struct NASHandoffContext: Sendable {
    public var settings: NASDownloadSettingsSnapshot
    public var credentials: NASBackendCredentials

    public init(
        settings: NASDownloadSettingsSnapshot,
        credentials: NASBackendCredentials = NASBackendCredentials(),
    ) {
        self.settings = settings
        self.credentials = credentials
    }
}

public protocol NASHandoffEnvironment: Sendable {
    func load() async -> NASHandoffContext
}

public struct StaticNASHandoffEnvironment: NASHandoffEnvironment {
    public var context: NASHandoffContext

    public init(context: NASHandoffContext) {
        self.context = context
    }

    public func load() async -> NASHandoffContext {
        context
    }
}

public struct LiveNASHandoffEnvironment: NASHandoffEnvironment {
    public init() {}

    public func load() async -> NASHandoffContext {
        var settings = await MainActor.run { NASDownloadSettingsStore.shared.snapshot }
        let configURL = await SettingsActor.shared.config.delugeBaseURL
        settings.delugeBaseURL = settings.resolvedDelugeBaseURL(configURL: configURL)
        return NASHandoffContext(
            settings: settings,
            credentials: NASBackendCredentials(
                qbittorrentPassword: (try? await AuthenticationActor.shared.loadQBittorrentPassword()) ?? "",
                delugePassword: (try? await AuthenticationActor.shared.loadDelugePassword()) ?? "",
                synologyPassword: (try? await AuthenticationActor.shared.loadSynologyPassword()) ?? "",
            ),
        )
    }
}

public struct NASAcquisitionHandler: ManualAcquisitionHandling {
    public var environment: any NASHandoffEnvironment
    public var qbittorrent: QBittorrentClient
    public var deluge: DelugeWebClient
    public var downloader: ManualFileDownloader
    public var uploaderFactory: @Sendable (NASHandoffContext) -> any NASFileUploading
    public var jobs: any ManualDownloadJobStoring

    public init(
        environment: any NASHandoffEnvironment,
        qbittorrent: QBittorrentClient = QBittorrentClient(),
        deluge: DelugeWebClient = DelugeWebClient(),
        downloader: ManualFileDownloader = ManualFileDownloader(),
        uploaderFactory: @escaping @Sendable (NASHandoffContext) -> any NASFileUploading = {
            SynologyNASFileUploader(
                baseURL: $0.settings.trimmedSynologyBaseURL,
                username: $0.settings.trimmedSynologyUsername,
                password: $0.credentials.synologyPassword,
            )
        },
        jobs: any ManualDownloadJobStoring = ManualDownloadJobStore.shared,
    ) {
        self.environment = environment
        self.qbittorrent = qbittorrent
        self.deluge = deluge
        self.downloader = downloader
        self.uploaderFactory = uploaderFactory
        self.jobs = jobs
    }

    public static func live() -> NASAcquisitionHandler {
        NASAcquisitionHandler(environment: LiveNASHandoffEnvironment())
    }

    public func handle(_ candidate: ManualAcquisitionCandidate) async -> ManualAcquisitionHandoffResult {
        await acquire(candidate, replacing: nil)
    }

    public func retryUpload(job: ManualDownloadJob) async -> ManualAcquisitionHandoffResult {
        guard let staged = job.stagedFileURL, ManualDownloadStaging.exists(staged) else {
            return .failed(message: NASHandoffError.stagedFileMissing.message)
        }
        let context = await environment.load()
        var updated = job
        updated.status = .uploading
        updated.lastError = nil
        await jobs.record(updated)
        return await finishUpload(job: updated, stagedURL: staged, context: context)
    }

    public func retryDownload(job: ManualDownloadJob) async -> ManualAcquisitionHandoffResult {
        if let current = await jobs.job(id: job.id), current.status != .failed {
            return outcome(for: current)
        }
        guard let source = job.sourceURL, let url = URL(string: source) else {
            return .failed(message: NASHandoffError.downloadFailed.message)
        }
        let candidate = ManualAcquisitionCandidate(
            sourceURL: url,
            detectedType: TorrentHash.retryDetectedType(sourceURL: source, mediaType: job.mediaType),
            filename: job.filename,
            sourceHost: job.sourceHost,
            bookMetadata: ManualSearchBookContext(
                title: job.title,
                authors: job.author.isEmpty ? [] : [job.author],
                requestedMediaType: job.mediaType == .audiobook ? .audiobook : .ebook,
            ),
        )
        return await acquire(candidate, replacing: job)
    }

    public func deleteLocalCopy(job: ManualDownloadJob) async {
        if let url = job.stagedFileURL {
            ManualDownloadStaging.remove(url)
        }
        var updated = job
        updated.stagedFilePath = nil
        if updated.status != .complete {
            updated.status = .failed
            updated.lastError = NASHandoffError.stagedFileMissing.message
        }
        await jobs.record(updated)
    }

    private struct Plan {
        var media: NASMediaKind
        var destination: String
        var backend: NASDownloadBackend
        var context: NASHandoffContext
    }

    private func prepare(_ candidate: ManualAcquisitionCandidate) async -> Result<Plan, NASHandoffError> {
        let context = await environment.load()
        if candidate.transportKind == .magnet, !NASMagnetValidation.isValid(candidate.sourceURL) {
            return .failure(.malformedMagnet)
        }
        let media: NASMediaKind
        switch NASDestinationRouting.mediaKind(for: candidate) {
            case .resolved(let kind): media = kind
            case .needsChoice: return .failure(.mediaTypeUnresolved)
        }
        let destination: String
        switch NASDestinationRouting.destination(for: candidate, kind: media, settings: context.settings) {
            case .success(let path): destination = path
            case .failure(.emptyDestination): return .failure(.emptyDestination)
            case .failure: return .failure(.invalidDestination)
        }
        switch NASBackendRouting.backend(transport: candidate.transportKind, settings: context.settings) {
            case .success(let backend):
                return .success(Plan(media: media, destination: destination, backend: backend, context: context))
            case .failure(let error):
                return .failure(error)
        }
    }

    private func acquire(
        _ candidate: ManualAcquisitionCandidate,
        replacing: ManualDownloadJob?,
    ) async -> ManualAcquisitionHandoffResult {
        let prepared = await prepare(candidate)
        switch prepared {
            case .failure(let error):
                return .failed(message: error.message)
            case .success(let plan):
                switch plan.backend {
                    case .qbittorrent, .deluge:
                        return await submitTorrent(candidate, plan: plan, replacing: replacing)
                    case .synology:
                        return await downloadAndUpload(candidate, plan: plan, replacing: replacing)
                }
        }
    }

    private func outcome(for job: ManualDownloadJob) -> ManualAcquisitionHandoffResult {
        switch job.status {
            case .complete:
                return .completed(message: NASHandoffMessages.uploaded())
            case .failed:
                return .failed(message: job.lastError ?? NASHandoffError.downloadFailed.message)
            case .submitted, .queued, .downloading, .downloaded, .uploading, .unknown:
                return .submitted(message: NASHandoffMessages.submitted(backend: job.backend))
        }
    }

    private func submitTorrent(
        _ candidate: ManualAcquisitionCandidate,
        plan: Plan,
        replacing: ManualDownloadJob?,
    ) async -> ManualAcquisitionHandoffResult {
        do {
            let jobID = try await submitToTorrentClient(candidate, plan: plan)
            await jobs.record(
                makeJob(
                    candidate,
                    plan: plan,
                    status: .submitted,
                    backendJobID: jobID,
                    replacing: replacing,
                )
            )
            return .submitted(message: NASHandoffMessages.submitted(backend: plan.backend))
        } catch let error as QBittorrentClientError {
            return await recordFailure(candidate, plan: plan, error: error.handoff, replacing: replacing)
        } catch let error as DelugeClientError {
            return await recordFailure(candidate, plan: plan, error: error.handoff, replacing: replacing)
        } catch let error as NASHandoffError {
            return await recordFailure(candidate, plan: plan, error: error, replacing: replacing)
        } catch {
            return await recordFailure(
                candidate,
                plan: plan,
                error: .rejected(plan.backend),
                replacing: replacing,
            )
        }
    }

    private func downloadAndUpload(
        _ candidate: ManualAcquisitionCandidate,
        plan: Plan,
        replacing: ManualDownloadJob?,
    ) async -> ManualAcquisitionHandoffResult {
        var job = makeJob(candidate, plan: plan, status: .downloading, replacing: replacing)
        await jobs.record(job)
        let staged: ManualStagedFile
        do {
            staged = try await downloader.download(candidate: candidate, jobID: job.id)
        } catch let error as NASHandoffError {
            job.status = .failed
            job.lastError = error.message
            await jobs.record(job)
            return .failed(message: error.message)
        } catch {
            job.status = .failed
            job.lastError = NASHandoffError.downloadFailed.message
            await jobs.record(job)
            return .failed(message: NASHandoffError.downloadFailed.message)
        }
        job.status = .downloaded
        job.stagedFilePath = staged.fileURL.path
        job.filename = staged.filename
        job.byteCount = staged.byteCount
        job.lastError = nil
        await jobs.record(job)
        return await finishUpload(job: job, stagedURL: staged.fileURL, context: plan.context)
    }

    private func finishUpload(
        job: ManualDownloadJob,
        stagedURL: URL,
        context: NASHandoffContext,
    ) async -> ManualAcquisitionHandoffResult {
        var updated = job
        updated.status = .uploading
        await jobs.record(updated)
        let filename = job.filename ?? stagedURL.lastPathComponent
        do {
            let result = try await uploaderFactory(context).upload(
                localFile: stagedURL,
                destination: NASUploadDestination(volumePath: job.destination, filename: filename),
            )
            if !result.verified, result.byteCount == nil {
                throw NASHandoffError.uploadRejected
            }
            ManualDownloadStaging.remove(stagedURL)
            updated.status = .complete
            updated.stagedFilePath = nil
            updated.lastError = nil
            await jobs.record(updated)
            return .completed(message: NASHandoffMessages.uploaded())
        } catch let error as SynologyClientError {
            return await recordUploadFailure(updated, error: error.handoff)
        } catch let error as NASHandoffError {
            return await recordUploadFailure(updated, error: error)
        } catch {
            return await recordUploadFailure(updated, error: .uploadRejected)
        }
    }

    private func recordUploadFailure(
        _ job: ManualDownloadJob,
        error: NASHandoffError,
    ) async -> ManualAcquisitionHandoffResult {
        var updated = job
        updated.status = .failed
        updated.lastError = error.message
        await jobs.record(updated)
        return .failed(message: error.message)
    }

    private func recordFailure(
        _ candidate: ManualAcquisitionCandidate,
        plan: Plan,
        error: NASHandoffError,
        replacing: ManualDownloadJob?,
    ) async -> ManualAcquisitionHandoffResult {
        await jobs.record(
            makeJob(
                candidate,
                plan: plan,
                status: .failed,
                lastError: error.message,
                replacing: replacing,
            )
        )
        return .failed(message: error.message)
    }

    private func makeJob(
        _ candidate: ManualAcquisitionCandidate,
        plan: Plan,
        status: ManualDownloadJobStatus,
        backendJobID: String? = nil,
        lastError: String? = nil,
        replacing: ManualDownloadJob? = nil,
    ) -> ManualDownloadJob {
        ManualDownloadJob(
            id: replacing?.id ?? UUID().uuidString,
            title: candidate.bookMetadata.title,
            author: candidate.bookMetadata.authorDisplay,
            sourceURL: candidate.sourceURL.absoluteString,
            sourceHost: candidate.displayHost,
            filename: candidate.filename,
            backend: plan.backend,
            mediaType: plan.media,
            destination: plan.destination,
            submittedAt: replacing?.submittedAt ?? Date(),
            backendJobID: TorrentHash.normalized(backendJobID)
                ?? TorrentHash.fromMagnet(candidate.sourceURL.absoluteString),
            status: status,
            lastError: lastError,
            lastStatusAt: Date(),
        )
    }

    private func submitToTorrentClient(
        _ candidate: ManualAcquisitionCandidate,
        plan: Plan,
    ) async throws -> String? {
        let settings = plan.context.settings
        let credentials = plan.context.credentials
        let start = settings.startAutomatically
        switch plan.backend {
            case .qbittorrent:
                switch candidate.transportKind {
                    case .magnet:
                        let added = try await qbittorrent.addMagnet(
                            baseURL: settings.trimmedQBittorrentBaseURL,
                            username: settings.qbittorrentUsername,
                            password: credentials.qbittorrentPassword,
                            uri: candidate.sourceURL.absoluteString,
                            savePath: plan.destination,
                            start: start,
                        )
                        return TorrentHash.normalized(added.jobID)
                            ?? TorrentHash.fromMagnet(candidate.sourceURL.absoluteString)
                    case .torrent:
                        return try await qbittorrent.addTorrentURL(
                            baseURL: settings.trimmedQBittorrentBaseURL,
                            username: settings.qbittorrentUsername,
                            password: credentials.qbittorrentPassword,
                            url: candidate.sourceURL.absoluteString,
                            savePath: plan.destination,
                            start: start,
                        ).jobID
                    case .directHTTP:
                        throw NASHandoffError.unsupportedAcquisition
                }
            case .deluge:
                switch candidate.transportKind {
                    case .magnet:
                        return try await deluge.addMagnet(
                            baseURL: settings.trimmedDelugeBaseURL,
                            password: credentials.delugePassword,
                            uri: candidate.sourceURL.absoluteString,
                            downloadLocation: plan.destination,
                            start: start,
                        )
                    case .torrent:
                        return try await deluge.addTorrentURL(
                            baseURL: settings.trimmedDelugeBaseURL,
                            password: credentials.delugePassword,
                            url: candidate.sourceURL.absoluteString,
                            downloadLocation: plan.destination,
                            start: start,
                        )
                    case .directHTTP:
                        throw NASHandoffError.unsupportedAcquisition
                }
            case .synology:
                throw NASHandoffError.unsupportedAcquisition
        }
    }
}

extension ManualAcquisitionRouter {
    public static func nasLive() -> ManualAcquisitionRouter {
        ManualAcquisitionRouter(handler: NASAcquisitionHandler.live())
    }
}
