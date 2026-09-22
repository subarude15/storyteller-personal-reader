//
//  NASAcquisitionHandler.swift
//  SilveranKit
//
//  Torrents go to TorBox, qBittorrent, or Deluge. Direct files download to
//  device staging, then upload through NASFileUploading.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct NASBackendCredentials: Sendable, Equatable {
    public var qbittorrentPassword: String
    public var delugePassword: String
    public var synologyPassword: String
    public var torboxAPIKey: String
    public var torboxarrPassword: String

    public init(
        qbittorrentPassword: String = "",
        delugePassword: String = "",
        synologyPassword: String = "",
        torboxAPIKey: String = "",
        torboxarrPassword: String = "",
    ) {
        self.qbittorrentPassword = qbittorrentPassword
        self.delugePassword = delugePassword
        self.synologyPassword = synologyPassword
        self.torboxAPIKey = torboxAPIKey
        self.torboxarrPassword = torboxarrPassword
    }
}

public struct NASHandoffContext: Sendable {
    public var settings: NASDownloadSettingsSnapshot
    public var credentials: NASBackendCredentials
    public var torboxarr: TorBoxarrConnectionSettings

    public init(
        settings: NASDownloadSettingsSnapshot,
        credentials: NASBackendCredentials = NASBackendCredentials(),
        torboxarr: TorBoxarrConnectionSettings = TorBoxarrConnectionSettings(),
    ) {
        self.settings = settings
        self.credentials = credentials
        self.torboxarr = torboxarr
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
                torboxAPIKey: (try? await AuthenticationActor.shared.loadTorBoxAPIKey()) ?? "",
                torboxarrPassword: (try? await AuthenticationActor.shared.loadTorBoxarrPassword()) ?? "",
            ),
            torboxarr: TorBoxarrConnectionSettings.current(),
        )
    }
}

public struct NASAcquisitionHandler: ManualAcquisitionHandling {
    public var environment: any NASHandoffEnvironment
    public var qbittorrent: QBittorrentClient
    public var deluge: DelugeWebClient
    public var torbox: TorBoxClient
    public var downloader: ManualFileDownloader
    public var uploaderFactory: @Sendable (NASHandoffContext) -> any NASFileUploading
    public var jobs: any ManualDownloadJobStoring

    public init(
        environment: any NASHandoffEnvironment,
        qbittorrent: QBittorrentClient = QBittorrentClient(),
        deluge: DelugeWebClient = DelugeWebClient(),
        torbox: TorBoxClient = TorBoxClient(),
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
        self.torbox = torbox
        self.downloader = downloader
        self.uploaderFactory = uploaderFactory
        self.jobs = jobs
    }

    public static func live() -> NASAcquisitionHandler {
        NASAcquisitionHandler(environment: LiveNASHandoffEnvironment())
    }

    public func handle(_ candidate: ManualAcquisitionCandidate) async -> ManualAcquisitionHandoffResult {
        await handle(candidate, manualBackend: nil)
    }

    /// Manual magnet screen. `manualBackend` overrides the global torrent provider
    /// for this submission only. Nil keeps the existing provider routing.
    public func handle(
        _ candidate: ManualAcquisitionCandidate,
        manualBackend: ManualDownloadBackend?,
    ) async -> ManualAcquisitionHandoffResult {
        await acquire(candidate, replacing: nil, manualBackend: manualBackend)
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

    public func retryDownload(
        job: ManualDownloadJob,
        manualBackend: ManualDownloadBackend? = nil,
    ) async -> ManualAcquisitionHandoffResult {
        if let current = await jobs.job(id: job.id), current.status != .failed {
            return outcome(for: current)
        }
        let sourceString = job.sourceURL
        let sourceURL = sourceString.flatMap(URL.init(string:))
            ?? job.stagedFileURL
            ?? URL(string: "https://invalid.local/missing")!
        var candidate = ManualAcquisitionCandidate(
            sourceURL: sourceURL,
            detectedType: TorrentHash.retryDetectedType(
                sourceURL: sourceString ?? job.stagedFileURL?.absoluteString ?? "",
                mediaType: job.mediaType,
            ),
            filename: job.filename,
            sourceHost: job.sourceHost,
            bookMetadata: ManualSearchBookContext(
                title: job.title,
                authors: job.author.isEmpty ? [] : [job.author],
                requestedMediaType: job.mediaType == .audiobook ? .audiobook : .ebook,
            ),
        )
        if let staged = job.stagedFileURL,
            ManualDownloadStaging.exists(staged),
            job.backend == .qbittorrent || job.backend == .deluge || job.backend == .torbox
        {
            candidate.detectedType = .torrent
            candidate.localTorrentFileURL = staged
            if candidate.filename == nil || candidate.filename?.isEmpty == true {
                candidate.filename = staged.lastPathComponent
            }
        } else if sourceString == nil {
            return .failed(message: NASHandoffError.downloadFailed.message)
        }
        return await acquire(candidate, replacing: job, manualBackend: manualBackend)
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
        /// Manual TorBox choice: qBittorrent bridge, not the TorBox cloud API.
        var viaTorBoxarr: Bool
    }

    private func prepare(
        _ candidate: ManualAcquisitionCandidate,
        manualBackend: ManualDownloadBackend? = nil,
    ) async -> Result<Plan, NASHandoffError> {
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
        if let manualBackend, candidate.transportKind == .magnet || candidate.transportKind == .torrent {
            switch manualBackend {
                case .torBox:
                    return .success(
                        Plan(
                            media: media,
                            destination: destination,
                            backend: .torbox,
                            context: context,
                            viaTorBoxarr: true,
                        )
                    )
                case .deluge:
                    if context.settings.trimmedDelugeBaseURL.isEmpty {
                        return .failure(.backendNotConfigured(.deluge))
                    }
                    return .success(
                        Plan(
                            media: media,
                            destination: destination,
                            backend: .deluge,
                            context: context,
                            viaTorBoxarr: false,
                        )
                    )
            }
        }
        switch NASBackendRouting.backend(transport: candidate.transportKind, settings: context.settings) {
            case .success(let backend):
                return .success(
                    Plan(
                        media: media,
                        destination: destination,
                        backend: backend,
                        context: context,
                        viaTorBoxarr: false,
                    )
                )
            case .failure(let error):
                return .failure(error)
        }
    }

    private func acquire(
        _ candidate: ManualAcquisitionCandidate,
        replacing: ManualDownloadJob?,
        manualBackend: ManualDownloadBackend? = nil,
    ) async -> ManualAcquisitionHandoffResult {
        let prepared = await prepare(candidate, manualBackend: manualBackend)
        switch prepared {
            case .failure(let error):
                return .failed(message: error.message)
            case .success(let plan):
                let resolvedReplacing = await resolveReplacing(
                    candidate,
                    plan: plan,
                    explicit: replacing,
                )
                switch plan.backend {
                    case .qbittorrent, .deluge, .torbox:
                        return await submitTorrent(
                            candidate,
                            plan: plan,
                            replacing: resolvedReplacing,
                        )
                    case .synology:
                        return await downloadAndUpload(
                            candidate,
                            plan: plan,
                            replacing: resolvedReplacing,
                        )
                }
        }
    }

    /// Prefer an explicit retry target; otherwise reuse any existing attempt for the
    /// same magnet/torrent identity so intake reprocessing cannot spam history.
    private func resolveReplacing(
        _ candidate: ManualAcquisitionCandidate,
        plan: Plan,
        explicit: ManualDownloadJob?,
    ) async -> ManualDownloadJob? {
        if let explicit { return explicit }
        let key = ManualDownloadAttemptIdentity.key(for: candidate, mediaType: plan.media)
        return await jobs.jobMatchingAttemptIdentity(key)
    }

    private func outcome(for job: ManualDownloadJob) -> ManualAcquisitionHandoffResult {
        switch job.status {
            case .submitted, .queued, .downloading, .processing, .delugeFinishing, .readyToRoute,
                .routing, .downloaded, .uploading, .ready, .transferring, .unknown:
                return .submitted(message: NASHandoffMessages.submitted(backend: job.backend))
            case .complete:
                return .completed(message: NASHandoffMessages.uploaded())
            case .failed:
                return .failed(message: job.lastError ?? NASHandoffError.downloadFailed.message)
        }
    }

    private func submitTorrent(
        _ candidate: ManualAcquisitionCandidate,
        plan: Plan,
        replacing: ManualDownloadJob?,
    ) async -> ManualAcquisitionHandoffResult {
        do {
            let submitted = try await submitToTorrentClient(candidate, plan: plan)
            if let staged = candidate.localTorrentFileURL {
                ManualDownloadStaging.remove(staged)
            }
            var job = makeJob(
                candidate,
                plan: plan,
                status: .submitted,
                backendJobID: submitted.jobID,
                replacing: replacing,
                keepStagedTorrent: false,
                viaTorBoxarr: plan.viaTorBoxarr,
            )
            job.providerInfoHash = submitted.infoHash
            job.providerAuthID = submitted.authID
            job.viaTorBoxarr = plan.viaTorBoxarr ? true : nil
            // Cached TorBox torrents can become ready immediately after create.
            if plan.backend == .torbox, !plan.viaTorBoxarr, let id = submitted.jobID {
                if let info = try? await torbox.getTorrent(
                    apiKey: plan.context.credentials.torboxAPIKey,
                    id: id,
                    bypassCache: true,
                ) {
                    job = TorBoxStatusMapping.apply(info, to: job)
                }
            }
            await jobs.record(job)
            let message =
                plan.viaTorBoxarr
                ? ManualMagnetCopy.accepted(.torBox)
                : NASHandoffMessages.submitted(backend: plan.backend)
            return .submitted(message: message)
        } catch let error as QBittorrentClientError {
            let handoff = plan.viaTorBoxarr ? Self.torboxarrHandoff(error) : error.handoff
            return await recordFailure(candidate, plan: plan, error: handoff, replacing: replacing)
        } catch let error as DelugeClientError {
            return await recordFailure(candidate, plan: plan, error: error.handoff, replacing: replacing)
        } catch let error as TorBoxClientError {
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
                keepStagedTorrent: true,
                viaTorBoxarr: plan.viaTorBoxarr,
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
        keepStagedTorrent: Bool = false,
        viaTorBoxarr: Bool = false,
    ) -> ManualDownloadJob {
        let stagedPath: String?
        if keepStagedTorrent, let url = candidate.localTorrentFileURL, ManualDownloadStaging.exists(url) {
            stagedPath = url.path
        } else {
            stagedPath = nil
        }
        return ManualDownloadJob(
            id: replacing?.id ?? UUID().uuidString,
            title: candidate.bookMetadata.title,
            author: candidate.bookMetadata.authorDisplay,
            sourceURL: candidate.sourceURL.absoluteString,
            sourceHost: candidate.displayHost,
            filename: candidate.filename ?? candidate.localTorrentFileURL?.lastPathComponent,
            backend: plan.backend,
            mediaType: plan.media,
            destination: plan.destination,
            stagedFilePath: stagedPath,
            submittedAt: replacing?.submittedAt ?? Date(),
            backendJobID: TorrentHash.normalized(backendJobID)
                ?? TorrentHash.fromMagnet(candidate.sourceURL.absoluteString),
            status: status,
            lastError: lastError,
            lastStatusAt: Date(),
            viaTorBoxarr: viaTorBoxarr ? true : nil,
        )
    }

    private struct TorrentSubmitRef {
        var jobID: String?
        var infoHash: String?
        var authID: String?
    }

    private func submitToTorrentClient(
        _ candidate: ManualAcquisitionCandidate,
        plan: Plan,
    ) async throws -> TorrentSubmitRef {
        let settings = plan.context.settings
        let credentials = plan.context.credentials
        let start = settings.startAutomatically
        switch plan.backend {
            case .torbox:
                if plan.viaTorBoxarr {
                    return try await submitTorBoxarr(candidate, plan: plan, start: start)
                }
                let key = credentials.torboxAPIKey
                guard !key.isEmpty, settings.torboxEnabled else {
                    throw NASHandoffError.backendNotConfigured(.torbox)
                }
                let created: TorBoxCreateResult
                switch candidate.transportKind {
                    case .magnet:
                        created = try await torbox.addMagnet(
                            apiKey: key,
                            magnet: candidate.sourceURL.absoluteString,
                            name: candidate.bookMetadata.title,
                        )
                    case .torrent:
                        if let local = candidate.localTorrentFileURL, ManualDownloadStaging.exists(local)
                        {
                            let data = try Data(contentsOf: local)
                            created = try await torbox.addTorrentFile(
                                apiKey: key,
                                data: data,
                                filename: candidate.filename ?? local.lastPathComponent,
                                name: candidate.bookMetadata.title,
                            )
                        } else if candidate.sourceURL.isFileURL {
                            let data = try Data(contentsOf: candidate.sourceURL)
                            created = try await torbox.addTorrentFile(
                                apiKey: key,
                                data: data,
                                filename: candidate.filename ?? candidate.sourceURL.lastPathComponent,
                                name: candidate.bookMetadata.title,
                            )
                        } else {
                            // Remote .torrent URL: fetch once, then upload file bytes to TorBox.
                            let (data, _) = try await URLSession.shared.data(from: candidate.sourceURL)
                            created = try await torbox.addTorrentFile(
                                apiKey: key,
                                data: data,
                                filename: candidate.filename
                                    ?? candidate.sourceURL.lastPathComponent,
                                name: candidate.bookMetadata.title,
                            )
                        }
                    case .directHTTP:
                        throw NASHandoffError.unsupportedAcquisition
                }
                return TorrentSubmitRef(
                    jobID: created.jobID,
                    infoHash: created.hash,
                    authID: created.authID,
                )
            case .qbittorrent:
                let jobID: String?
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
                        jobID = TorrentHash.normalized(added.jobID)
                            ?? TorrentHash.fromMagnet(candidate.sourceURL.absoluteString)
                    case .torrent:
                        if let local = candidate.localTorrentFileURL, ManualDownloadStaging.exists(local) {
                            jobID = try await qbittorrent.addTorrentFile(
                                baseURL: settings.trimmedQBittorrentBaseURL,
                                username: settings.qbittorrentUsername,
                                password: credentials.qbittorrentPassword,
                                fileURL: local,
                                filename: candidate.filename ?? local.lastPathComponent,
                                savePath: plan.destination,
                                start: start,
                            ).jobID
                        } else {
                            jobID = try await qbittorrent.addTorrentURL(
                                baseURL: settings.trimmedQBittorrentBaseURL,
                                username: settings.qbittorrentUsername,
                                password: credentials.qbittorrentPassword,
                                url: candidate.sourceURL.absoluteString,
                                savePath: plan.destination,
                                start: start,
                            ).jobID
                        }
                    case .directHTTP:
                        throw NASHandoffError.unsupportedAcquisition
                }
                return TorrentSubmitRef(jobID: jobID)
            case .deluge:
                let staging = plan.context.settings.trimmedDelugeIncomingFolder
                guard !staging.isEmpty else { throw NASHandoffError.emptyDestination }
                let jobID: String?
                switch candidate.transportKind {
                    case .magnet:
                        jobID = try await deluge.addMagnet(
                            baseURL: settings.trimmedDelugeBaseURL,
                            password: credentials.delugePassword,
                            uri: candidate.sourceURL.absoluteString,
                            downloadLocation: staging,
                            start: start,
                        )
                    case .torrent:
                        if let local = candidate.localTorrentFileURL, ManualDownloadStaging.exists(local) {
                            jobID = try await deluge.addTorrentFile(
                                baseURL: settings.trimmedDelugeBaseURL,
                                password: credentials.delugePassword,
                                fileURL: local,
                                filename: candidate.filename ?? local.lastPathComponent,
                                downloadLocation: staging,
                                start: start,
                            )
                        } else {
                            jobID = try await deluge.addTorrentURL(
                                baseURL: settings.trimmedDelugeBaseURL,
                                password: credentials.delugePassword,
                                url: candidate.sourceURL.absoluteString,
                                downloadLocation: staging,
                                start: start,
                            )
                        }
                    case .directHTTP:
                        throw NASHandoffError.unsupportedAcquisition
                }
                return TorrentSubmitRef(jobID: jobID)
            case .synology:
                throw NASHandoffError.unsupportedAcquisition
        }
    }

    /// TorBoxarr speaks qBittorrent WebAPI. The library folder stays on the job;
    /// the magnet itself is saved under TorBoxarr’s completed directory.
    private func submitTorBoxarr(
        _ candidate: ManualAcquisitionCandidate,
        plan: Plan,
        start: Bool,
    ) async throws -> TorrentSubmitRef {
        let bridge = plan.context.torboxarr
        let password = plan.context.credentials.torboxarrPassword
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = bridge.baseURL, !password.isEmpty else {
            throw NASHandoffError.backendNotConfigured(.torbox)
        }
        let username = bridge.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { throw NASHandoffError.backendNotConfigured(.torbox) }
        let savePath = TorBoxarrConnectionSettings.completedFolder
        let jobID: String?
        switch candidate.transportKind {
            case .magnet:
                let added = try await qbittorrent.addMagnet(
                    baseURL: baseURL,
                    username: username,
                    password: password,
                    uri: candidate.sourceURL.absoluteString,
                    savePath: savePath,
                    start: start,
                )
                jobID = TorrentHash.normalized(added.jobID)
                    ?? TorrentHash.fromMagnet(candidate.sourceURL.absoluteString)
            case .torrent:
                if let local = candidate.localTorrentFileURL, ManualDownloadStaging.exists(local) {
                    jobID = try await qbittorrent.addTorrentFile(
                        baseURL: baseURL,
                        username: username,
                        password: password,
                        fileURL: local,
                        filename: candidate.filename ?? local.lastPathComponent,
                        savePath: savePath,
                        start: start,
                    ).jobID
                } else {
                    jobID = try await qbittorrent.addTorrentURL(
                        baseURL: baseURL,
                        username: username,
                        password: password,
                        url: candidate.sourceURL.absoluteString,
                        savePath: savePath,
                        start: start,
                    ).jobID
                }
            case .directHTTP:
                throw NASHandoffError.unsupportedAcquisition
        }
        return TorrentSubmitRef(jobID: jobID)
    }

    private static func torboxarrHandoff(_ error: QBittorrentClientError) -> NASHandoffError {
        switch error {
            case .invalidURL: .invalidURL(.torbox)
            case .cannotReachServer: .unreachable(.torbox)
            case .authenticationFailed: .authenticationFailed(.torbox)
            case .timeout: .timeout(.torbox)
            case .invalidResponse, .rejected: .rejected(.torbox)
        }
    }

}

extension ManualAcquisitionRouter {
    public static func nasLive() -> ManualAcquisitionRouter {
        ManualAcquisitionRouter(handler: NASAcquisitionHandler.live())
    }
}
