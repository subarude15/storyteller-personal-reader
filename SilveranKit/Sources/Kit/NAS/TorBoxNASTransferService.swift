//
//  TorBoxNASTransferService.swift
//  SilveranKit
//
//  Phase 2: when TorBox is Ready, ask the NAS (Download Station) to pull
//  TorBox file URLs into the configured media destination. iOS never pipes
//  multi-GB payloads. Signed TorBox URLs are never persisted or logged.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public actor TorBoxTransferGate {
    public static let shared = TorBoxTransferGate()
    private var inFlight = Set<String>()

    public init() {}

    public func begin(_ jobID: String) -> Bool {
        if inFlight.contains(jobID) { return false }
        inFlight.insert(jobID)
        return true
    }

    public func end(_ jobID: String) {
        inFlight.remove(jobID)
    }
}

public struct TorBoxNASTransferService: Sendable {
    public var environment: any NASHandoffEnvironment
    public var torbox: TorBoxClient
    public var jobs: any ManualDownloadJobStoring
    public var transferFactory: @Sendable (NASHandoffContext) -> any RemoteMediaTransferring
    public var gate: TorBoxTransferGate

    public init(
        environment: any NASHandoffEnvironment,
        torbox: TorBoxClient = TorBoxClient(),
        jobs: any ManualDownloadJobStoring = ManualDownloadJobStore.shared,
        transferFactory: @escaping @Sendable (NASHandoffContext) -> any RemoteMediaTransferring = {
            SynologyRemoteMediaTransfer(
                baseURL: $0.settings.trimmedSynologyBaseURL,
                username: $0.settings.trimmedSynologyUsername,
                password: $0.credentials.synologyPassword,
            )
        },
        gate: TorBoxTransferGate = .shared,
    ) {
        self.environment = environment
        self.torbox = torbox
        self.jobs = jobs
        self.transferFactory = transferFactory
        self.gate = gate
    }

    public static func live() -> TorBoxNASTransferService {
        TorBoxNASTransferService(environment: LiveNASHandoffEnvironment())
    }

    /// Start or resume NAS transfer for a Ready / failed-transfer TorBox job.
    @discardableResult
    public func transfer(job: ManualDownloadJob, force: Bool = false) async -> ManualDownloadJob {
        guard job.backend == .torbox, job.viaTorBoxarr != true else { return job }
        guard job.status == .ready || job.canRetryTransferNow || job.status == .transferring else {
            return job
        }
        guard await gate.begin(job.id) else { return job }
        // Await end before returning so a follow-up transfer/reconcile on the same
        // job id is not rejected by a still-held in-flight gate (fire-and-forget Task races).
        let result = await transferUnderGate(job: job, force: force)
        await gate.end(job.id)
        return result
    }

    private func transferUnderGate(job: ManualDownloadJob, force: Bool) async -> ManualDownloadJob {
        let context = await environment.load()
        guard context.settings.isSynologyConfigured else {
            return await fail(job, error: .destinationMissing)
        }
        guard !context.credentials.torboxAPIKey.isEmpty else {
            return await fail(job, error: .sourceUnavailable)
        }

        var working = job
        if working.transferFiles == nil || working.transferFiles?.isEmpty == true || force {
            working = prepareTransferPlan(for: working)
        }
        guard let plan = working.transferFiles, !plan.isEmpty else {
            let archives = TorBoxMediaFileSelection.unsupportedArchiveNames(
                in: working.providerFiles ?? []
            )
            if !archives.isEmpty {
                return await fail(working, error: .unsupportedArchivesOnly)
            }
            return await fail(working, error: .noSelectableFiles)
        }

        working.status = .transferring
        working.lastError = nil
        working.lastStatusAt = Date()
        await jobs.record(working)

        let transfer = transferFactory(context)
        let destination = NASTransferDestination(volumePath: working.destination)
        do {
            try await transfer.ensureDestination(destination)
        } catch let error as RemoteTransferError {
            return await fail(working, error: error)
        } catch {
            return await fail(working, error: .nasUnreachable)
        }

        var files = plan
        for index in files.indices {
            if files[index].status == .complete { continue }
            // Explicit transfer/retry of a failed file: clear the dead task and resubmit once.
            if files[index].status == .failed {
                files[index].status = .pending
                files[index].nasTaskID = nil
                files[index].lastError = nil
            }
            files[index] = await transferOne(
                files[index],
                job: working,
                context: context,
                transfer: transfer,
                destination: destination,
            )
            // Fresh TorBox URL on expiry within the same pass.
            if files[index].status == .pending,
                files[index].lastError == RemoteTransferError.linkExpired.message
            {
                files[index] = await transferOne(
                    files[index],
                    job: working,
                    context: context,
                    transfer: transfer,
                    destination: destination,
                )
            }
            working.transferFiles = files
            working.progress = progress(of: files)
            working.lastStatusAt = Date()
            if files[index].status == .failed {
                working.lastError = files[index].lastError ?? RemoteTransferError.partialFailure.message
            }
            await jobs.record(working)
        }

        return await finalize(working, files: files)
    }

    /// Poll NAS Download Station for in-flight TorBox transfers and auto-start Ready jobs.
    @discardableResult
    public func reconcile(autoStartReady: Bool) async -> [ManualDownloadJob] {
        let context = await environment.load()
        let current = await jobs.allJobs()
        var changed: [ManualDownloadJob] = []

        for job in current where job.backend == .torbox && job.viaTorBoxarr != true {
            if job.status == .transferring {
                let updated = await pollInFlight(job, context: context)
                if updated != job {
                    await jobs.record(updated)
                    changed.append(updated)
                }
                continue
            }
            if autoStartReady, context.settings.torboxAutoTransferToNAS, job.status == .ready {
                guard context.settings.isSynologyConfigured,
                    !context.credentials.torboxAPIKey.isEmpty,
                    !context.credentials.synologyPassword.isEmpty
                else { continue }
                let updated = await transfer(job: job)
                changed.append(updated)
            }
        }
        return changed
    }

    // MARK: - Internals

    private func prepareTransferPlan(for job: ManualDownloadJob) -> ManualDownloadJob {
        var updated = job
        let selected = TorBoxMediaFileSelection.select(
            files: job.providerFiles ?? [],
            mediaType: job.mediaType,
        )
        // Preserve completed file rows from a prior partial attempt.
        var priorByID: [String: RemoteTransferFileState] = [:]
        for file in job.transferFiles ?? [] {
            priorByID[file.id] = file
        }
        updated.transferFiles = selected.map { file in
            if let prior = priorByID[file.id], prior.status == .complete {
                return prior
            }
            return RemoteTransferFileState(
                id: file.id,
                filename: file.name,
                relativePath: file.relativePath,
                expectedSize: file.size,
                status: .pending,
            )
        }
        return updated
    }

    private func transferOne(
        _ file: RemoteTransferFileState,
        job: ManualDownloadJob,
        context: NASHandoffContext,
        transfer: any RemoteMediaTransferring,
        destination: NASTransferDestination,
    ) async -> RemoteTransferFileState {
        var state = file
        let fileDestination = Self.destination(for: destination, relativePath: state.relativePath)
        do {
            try await transfer.ensureDestination(fileDestination)

            // Already started (possibly without a task ID): never create another DS task.
            if state.status == .started {
                return try await reconcileStarted(
                    state,
                    transfer: transfer,
                    destination: fileDestination,
                )
            }

            if try await transfer.remoteFileExists(
                destination: fileDestination,
                filename: state.filename,
                expectedSize: state.expectedSize,
            ) {
                state.status = .complete
                state.lastError = nil
                state.remotePath = fileDestination.volumePath + "/" + state.filename
                debugLog("[TorBoxTransfer] already on NAS file=\(state.filename)")
                return state
            }

            if let taskID = state.nasTaskID, !taskID.isEmpty {
                if let snap = try await transfer.taskSnapshot(taskID: taskID) {
                    return try await reconcileTask(
                        snap,
                        state: state,
                        transfer: transfer,
                        destination: fileDestination,
                    )
                }
            }

            guard let torrentID = Int(job.backendJobID ?? ""), let fileID = Int(state.id) else {
                state.status = .failed
                state.lastError = RemoteTransferError.sourceUnavailable.message
                return state
            }

            let url: URL
            do {
                url = try await torbox.requestDownloadURL(
                    apiKey: context.credentials.torboxAPIKey,
                    torrentID: torrentID,
                    fileID: fileID,
                )
            } catch let error as TorBoxClientError {
                state.status = .failed
                state.lastError = mapTorBox(error).message
                return state
            }

            debugLog("[TorBoxTransfer] starting NAS pull file=\(state.filename)")
            let taskID = try await transfer.startDownload(
                source: RemoteDownloadSource(
                    url: url,
                    filename: state.filename,
                    expectedSize: state.expectedSize,
                    relativePath: state.relativePath,
                ),
                destination: fileDestination,
            )
            state.nasTaskID = taskID
            state.status = .started
            state.lastError = nil

            return try await reconcileStarted(
                state,
                transfer: transfer,
                destination: fileDestination,
            )
        } catch let error as RemoteTransferError {
            if error == .linkExpired {
                // Clear task and leave pending for outer retry with a fresh URL.
                state.nasTaskID = nil
                state.status = .pending
                state.lastError = error.message
                return state
            }
            state.status = .failed
            state.lastError = error.message
            return state
        } catch {
            state.status = .failed
            state.lastError = RemoteTransferError.nasUnreachable.message
            return state
        }
    }

    /// Reconcile a `.started` file without submitting another Download Station task.
    private func reconcileStarted(
        _ state: RemoteTransferFileState,
        transfer: any RemoteMediaTransferring,
        destination: NASTransferDestination,
    ) async throws -> RemoteTransferFileState {
        var updated = state
        updated.status = .started

        if try await transfer.remoteFileExists(
            destination: destination,
            filename: updated.filename,
            expectedSize: updated.expectedSize,
        ) {
            updated.status = .complete
            updated.lastError = nil
            updated.remotePath = destination.volumePath + "/" + updated.filename
            return updated
        }

        if let taskID = updated.nasTaskID, !taskID.isEmpty {
            if let snap = try await transfer.taskSnapshot(taskID: taskID) {
                return try await reconcileTask(
                    snap,
                    state: updated,
                    transfer: transfer,
                    destination: destination,
                )
            }
        }

        if let snap = try await transfer.findMatchingTask(
            destination: destination,
            expectedFilename: updated.filename,
            expectedSize: updated.expectedSize,
        ) {
            updated.nasTaskID = snap.id
            return try await reconcileTask(
                snap,
                state: updated,
                transfer: transfer,
                destination: destination,
            )
        }

        // Still in flight (or ID not yet discoverable). Do not resubmit.
        return updated
    }

    /// Preserve nested torrent folders under the job destination (multi-track audiobooks).
    private static func destination(
        for root: NASTransferDestination,
        relativePath: String,
    ) -> NASTransferDestination {
        let parent = (relativePath as NSString).deletingLastPathComponent
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !parent.isEmpty, parent != "." else { return root }
        var path = root.volumePath
        while path.hasSuffix("/") { path.removeLast() }
        return NASTransferDestination(volumePath: path + "/" + parent)
    }

    private func reconcileTask(
        _ snap: SynologyDownloadTaskSnapshot,
        state: RemoteTransferFileState,
        transfer: any RemoteMediaTransferring,
        destination: NASTransferDestination,
    ) async throws -> RemoteTransferFileState {
        var updated = state
        updated.nasTaskID = snap.id
        if snap.status.isTerminalFailure {
            updated.status = .failed
            updated.lastError = RemoteTransferError.rejected.message
            return updated
        }
        if snap.status.isTerminalSuccess {
            if try await transfer.remoteFileExists(
                destination: destination,
                filename: updated.filename,
                expectedSize: updated.expectedSize,
            ) {
                updated.status = .complete
                updated.lastError = nil
                updated.remotePath = destination.volumePath + "/" + updated.filename
                return updated
            }
            // Only rename the file this Download Station task reports — never an
            // arbitrary directory entry (destination may already hold other books).
            guard let outputName = SynologyDownloadStationClient.outputFilename(from: snap) else {
                updated.status = .failed
                updated.lastError = RemoteTransferError.outputUnidentified.message
                return updated
            }
            if outputName != updated.filename {
                let names = try await transfer.listDestinationFilenames(destination: destination)
                guard names.contains(outputName) else {
                    updated.status = .failed
                    updated.lastError = RemoteTransferError.outputUnidentified.message
                    return updated
                }
                do {
                    try await transfer.renameInDestination(
                        destination: destination,
                        from: outputName,
                        to: updated.filename,
                    )
                } catch {
                    updated.status = .failed
                    updated.lastError = RemoteTransferError.outputUnidentified.message
                    return updated
                }
            }
            let ok = try await transfer.verifyFile(
                destination: destination,
                filename: updated.filename,
                expectedSize: updated.expectedSize,
            )
            if ok {
                updated.status = .complete
                updated.lastError = nil
                updated.remotePath = destination.volumePath + "/" + updated.filename
            } else {
                updated.status = .failed
                updated.lastError = RemoteTransferError.outputUnidentified.message
            }
            return updated
        }
        updated.status = .started
        return updated
    }

    private func pollInFlight(
        _ job: ManualDownloadJob,
        context: NASHandoffContext,
    ) async -> ManualDownloadJob {
        guard await gate.begin(job.id) else { return job }
        let result = await pollInFlightUnderGate(job, context: context)
        await gate.end(job.id)
        return result
    }

    private func pollInFlightUnderGate(
        _ job: ManualDownloadJob,
        context: NASHandoffContext,
    ) async -> ManualDownloadJob {
        guard context.settings.isSynologyConfigured else {
            return await fail(job, error: .destinationMissing)
        }
        let transfer = transferFactory(context)
        let destination = NASTransferDestination(volumePath: job.destination)
        var files = job.transferFiles ?? []
        guard !files.isEmpty else { return job }
        for index in files.indices {
            if files[index].status == .complete { continue }
            switch files[index].status {
                case .started:
                    // Never treat missing nasTaskID as permission to create another task.
                    do {
                        let fileDestination = Self.destination(
                            for: destination,
                            relativePath: files[index].relativePath,
                        )
                        files[index] = try await reconcileStarted(
                            files[index],
                            transfer: transfer,
                            destination: fileDestination,
                        )
                    } catch let error as RemoteTransferError {
                        files[index].status = .failed
                        files[index].lastError = error.message
                    } catch {
                        files[index].status = .failed
                        files[index].lastError = RemoteTransferError.nasUnreachable.message
                    }
                case .pending:
                    files[index] = await transferOne(
                        files[index],
                        job: job,
                        context: context,
                        transfer: transfer,
                        destination: destination,
                    )
                case .failed, .complete:
                    break
            }
        }
        var working = job
        working.transferFiles = files
        working.progress = progress(of: files)
        working.lastStatusAt = Date()
        return await finalize(working, files: files)
    }

    private func finalize(
        _ job: ManualDownloadJob,
        files: [RemoteTransferFileState],
    ) async -> ManualDownloadJob {
        var updated = job
        updated.transferFiles = files
        updated.progress = progress(of: files)
        updated.lastStatusAt = Date()
        let completeCount = files.filter { $0.status == .complete }.count
        let failedCount = files.filter { $0.status == .failed }.count
        let activeCount = files.filter { $0.status == .started || $0.status == .pending }.count
        if completeCount == files.count, !files.isEmpty {
            updated.status = .complete
            updated.lastError = nil
            updated.progress = 1
            debugLog("[TorBoxTransfer] complete job=\(job.id) files=\(files.count)")
        } else if failedCount > 0, activeCount == 0 {
            updated.status = .failed
            updated.lastError =
                files.first(where: { $0.status == .failed })?.lastError
                ?? RemoteTransferError.partialFailure.message
        } else {
            updated.status = .transferring
        }
        await jobs.record(updated)
        return updated
    }

    private func fail(_ job: ManualDownloadJob, error: RemoteTransferError) async -> ManualDownloadJob {
        var updated = job
        updated.status = .failed
        updated.lastError = error.message
        updated.lastStatusAt = Date()
        await jobs.record(updated)
        return updated
    }

    private func progress(of files: [RemoteTransferFileState]) -> Double? {
        guard !files.isEmpty else { return nil }
        let done = files.filter { $0.status == .complete }.count
        return Double(done) / Double(files.count)
    }

    private func mapTorBox(_ error: TorBoxClientError) -> RemoteTransferError {
        switch error {
            case .invalidAPIKey, .unauthorized, .missingAPIKey: .sourceUnavailable
            case .rateLimited, .timeout, .cannotReachServer, .serverUnavailable: .sourceUnavailable
            case .rejected, .invalidResponse, .malformedMagnet: .sourceUnavailable
        }
    }
}
