//
//  RemoteMediaTransfer.swift
//  SilveranKit
//
//  Provider-independent NAS-side transfer. Sources supply URLs; the NAS pulls bytes.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct RemoteDownloadSource: Equatable, Sendable {
    public var url: URL
    public var filename: String
    public var expectedSize: Int64?
    public var relativePath: String

    public init(url: URL, filename: String, expectedSize: Int64? = nil, relativePath: String? = nil) {
        self.url = url
        self.filename = filename
        self.expectedSize = expectedSize
        self.relativePath = relativePath ?? filename
    }
}

public struct NASTransferDestination: Equatable, Sendable {
    /// Volume path such as `/volume1/data/media/books/audiobooks/Author/Title`.
    public var volumePath: String

    public init(volumePath: String) {
        self.volumePath = volumePath
    }
}

public enum RemoteTransferFileStatus: String, Codable, Sendable, Equatable {
    case pending
    case started
    case complete
    case failed
}

public struct RemoteTransferFileState: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var filename: String
    public var relativePath: String
    public var expectedSize: Int64?
    public var nasTaskID: String?
    public var remotePath: String?
    public var status: RemoteTransferFileStatus
    public var lastError: String?

    public init(
        id: String,
        filename: String,
        relativePath: String,
        expectedSize: Int64? = nil,
        nasTaskID: String? = nil,
        remotePath: String? = nil,
        status: RemoteTransferFileStatus = .pending,
        lastError: String? = nil,
    ) {
        self.id = id
        self.filename = filename
        self.relativePath = relativePath
        self.expectedSize = expectedSize
        self.nasTaskID = nasTaskID
        self.remotePath = remotePath
        self.status = status
        self.lastError = lastError
    }
}

public struct TransferResult: Equatable, Sendable {
    public var files: [RemoteTransferFileState]
    public var destination: String
    public var allComplete: Bool

    public init(files: [RemoteTransferFileState], destination: String, allComplete: Bool) {
        self.files = files
        self.destination = destination
        self.allComplete = allComplete
    }
}

public enum RemoteTransferError: Error, Equatable, Sendable {
    case nasUnreachable
    case nasUnauthorized
    case nasTimeout
    case destinationMissing
    case destinationInvalid
    case storageFull
    case rejected
    case sourceUnavailable
    case linkExpired
    case noSelectableFiles
    case unsupportedArchivesOnly
    case partialFailure
    /// Download finished but the output filename could not be safely identified.
    case outputUnidentified

    public var message: String {
        switch self {
            case .nasUnreachable:
                "Could not reach the NAS.\nThe TorBox download is still safe in the cloud."
            case .nasUnauthorized:
                "The NAS rejected the credentials.\nCheck Synology settings. The TorBox download is still safe in the cloud."
            case .nasTimeout:
                "The NAS timed out.\nThe TorBox download is still safe in the cloud."
            case .destinationMissing:
                "The destination folder is not available.\nCheck NAS Downloads settings."
            case .destinationInvalid:
                "The destination path is invalid.\nCheck NAS Downloads settings."
            case .storageFull:
                "NAS storage is full.\nFree some space and retry."
            case .rejected:
                "The NAS rejected the download request.\nThe TorBox download is still safe in the cloud."
            case .sourceUnavailable:
                "TorBox no longer has this file available."
            case .linkExpired:
                "TorBox download link expired.\nRetrying with a fresh link…"
            case .noSelectableFiles:
                "No transferable ebook/audiobook files were found in this TorBox torrent."
            case .unsupportedArchivesOnly:
                "This TorBox torrent only contains archives.\nArchive extraction is not supported yet."
            case .partialFailure:
                "Some files failed to transfer to the NAS.\nRetry to finish the remaining files."
            case .outputUnidentified:
                "The NAS finished downloading, but the output file could not be identified safely.\nNothing else in the folder was renamed. Retry the transfer."
        }
    }
}

public protocol RemoteMediaTransferring: Sendable {
    func ensureDestination(_ destination: NASTransferDestination) async throws
    func remoteFileExists(
        destination: NASTransferDestination,
        filename: String,
        expectedSize: Int64?,
    ) async throws -> Bool
    func startDownload(
        source: RemoteDownloadSource,
        destination: NASTransferDestination,
    ) async throws -> String?
    func taskSnapshot(taskID: String) async throws -> SynologyDownloadTaskSnapshot?
    /// Locate an already-created Download Station task without creating another.
    func findMatchingTask(
        destination: NASTransferDestination,
        expectedFilename: String,
        expectedSize: Int64?,
    ) async throws -> SynologyDownloadTaskSnapshot?
    func listDestinationFilenames(destination: NASTransferDestination) async throws -> [String]
    func renameInDestination(
        destination: NASTransferDestination,
        from: String,
        to: String,
    ) async throws
    func verifyFile(
        destination: NASTransferDestination,
        filename: String,
        expectedSize: Int64?,
    ) async throws -> Bool
}

public struct SynologyRemoteMediaTransfer: RemoteMediaTransferring {
    public var fileStation: SynologyFileStationClient
    public var downloadStation: SynologyDownloadStationClient
    public var baseURL: String
    public var username: String
    public var password: String

    public init(
        fileStation: SynologyFileStationClient = SynologyFileStationClient(),
        downloadStation: SynologyDownloadStationClient = SynologyDownloadStationClient(),
        baseURL: String,
        username: String,
        password: String,
    ) {
        self.fileStation = fileStation
        self.downloadStation = downloadStation
        self.baseURL = baseURL
        self.username = username
        self.password = password
    }

    public func ensureDestination(_ destination: NASTransferDestination) async throws {
        do {
            try await fileStation.ensureFolder(
                baseURL: baseURL,
                username: username,
                password: password,
                volumePath: destination.volumePath,
            )
        } catch let error as SynologyClientError {
            throw map(error)
        } catch let error as NASHandoffError {
            throw mapHandoff(error)
        }
    }

    public func remoteFileExists(
        destination: NASTransferDestination,
        filename: String,
        expectedSize: Int64?,
    ) async throws -> Bool {
        do {
            let size = try await fileStation.remoteFileSize(
                baseURL: baseURL,
                username: username,
                password: password,
                volumeDirectory: destination.volumePath,
                filename: filename,
            )
            guard let size, size > 0 else { return false }
            if let expectedSize, expectedSize > 0 {
                // Allow small variance for container metadata; require non-empty match-ish.
                return size == expectedSize || abs(size - expectedSize) < 64
            }
            return true
        } catch let error as SynologyClientError {
            if error == .verificationFailed { return false }
            throw map(error)
        } catch let error as NASHandoffError {
            throw mapHandoff(error)
        }
    }

    public func startDownload(
        source: RemoteDownloadSource,
        destination: NASTransferDestination,
    ) async throws -> String? {
        guard
            let dsDest = SynologyDownloadStationClient.downloadStationDestination(
                fromVolumePath: destination.volumePath
            )
        else {
            throw RemoteTransferError.destinationInvalid
        }
        do {
            return try await downloadStation.createURLTask(
                baseURL: baseURL,
                username: username,
                password: password,
                sourceURL: source.url,
                destination: dsDest,
                expectedFilename: source.filename,
            )
        } catch let error as SynologyClientError {
            throw map(error)
        }
    }

    public func taskSnapshot(taskID: String) async throws -> SynologyDownloadTaskSnapshot? {
        do {
            let tasks = try await downloadStation.taskInfo(
                baseURL: baseURL,
                username: username,
                password: password,
                taskIDs: [taskID],
            )
            return tasks.first
        } catch let error as SynologyClientError {
            throw map(error)
        }
    }

    public func findMatchingTask(
        destination: NASTransferDestination,
        expectedFilename: String,
        expectedSize: Int64?,
    ) async throws -> SynologyDownloadTaskSnapshot? {
        guard
            let dsDest = SynologyDownloadStationClient.downloadStationDestination(
                fromVolumePath: destination.volumePath
            )
        else {
            throw RemoteTransferError.destinationInvalid
        }
        do {
            return try await downloadStation.findTask(
                baseURL: baseURL,
                username: username,
                password: password,
                destination: dsDest,
                expectedFilename: expectedFilename,
                expectedSize: expectedSize,
            )
        } catch let error as SynologyClientError {
            throw map(error)
        }
    }

    public func listDestinationFilenames(destination: NASTransferDestination) async throws -> [String] {
        do {
            return try await fileStation.listFilenames(
                baseURL: baseURL,
                username: username,
                password: password,
                volumeDirectory: destination.volumePath,
            )
        } catch let error as SynologyClientError {
            throw map(error)
        } catch let error as NASHandoffError {
            throw mapHandoff(error)
        }
    }

    public func renameInDestination(
        destination: NASTransferDestination,
        from: String,
        to: String,
    ) async throws {
        guard from != to else { return }
        do {
            try await fileStation.renameFile(
                baseURL: baseURL,
                username: username,
                password: password,
                volumeDirectory: destination.volumePath,
                fromFilename: from,
                toFilename: to,
            )
        } catch let error as SynologyClientError {
            throw map(error)
        } catch let error as NASHandoffError {
            throw mapHandoff(error)
        }
    }

    public func verifyFile(
        destination: NASTransferDestination,
        filename: String,
        expectedSize: Int64?,
    ) async throws -> Bool {
        try await remoteFileExists(
            destination: destination,
            filename: filename,
            expectedSize: expectedSize,
        )
    }

    private func map(_ error: SynologyClientError) -> RemoteTransferError {
        switch error {
            case .cannotReachServer: .nasUnreachable
            case .authenticationFailed: .nasUnauthorized
            case .timeout: .nasTimeout
            case .invalidURL: .destinationInvalid
            case .rejected, .invalidResponse, .verificationFailed: .rejected
        }
    }

    private func mapHandoff(_ error: NASHandoffError) -> RemoteTransferError {
        switch error {
            case .emptyDestination, .invalidDestination: .destinationMissing
            case .unreachable: .nasUnreachable
            case .authenticationFailed: .nasUnauthorized
            case .timeout: .nasTimeout
            case .insufficientStorage: .storageFull
            case .backendNotConfigured, .torrentClientNotSelected, .mediaTypeUnresolved,
                .malformedMagnet, .unsupportedAcquisition, .rejected, .invalidURL,
                .downloadFailed, .uploadRejected, .uploadInterrupted, .stagedFileMissing:
                .rejected
        }
    }
}
