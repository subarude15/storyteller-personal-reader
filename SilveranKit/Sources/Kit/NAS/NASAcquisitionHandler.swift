//
//  NASAcquisitionHandler.swift
//  SilveranKit
//
//  Routes a Manual Search candidate to qBittorrent, Deluge, or aria2.
//  Success means submitted, not downloaded.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct NASBackendCredentials: Sendable, Equatable {
    public var qbittorrentPassword: String
    public var delugePassword: String
    public var aria2Secret: String

    public init(
        qbittorrentPassword: String = "",
        delugePassword: String = "",
        aria2Secret: String = "",
    ) {
        self.qbittorrentPassword = qbittorrentPassword
        self.delugePassword = delugePassword
        self.aria2Secret = aria2Secret
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
        if settings.trimmedDelugeBaseURL.isEmpty {
            settings.delugeBaseURL = configURL
        }
        let qbPassword = (try? await AuthenticationActor.shared.loadQBittorrentPassword()) ?? ""
        let delugePassword = (try? await AuthenticationActor.shared.loadDelugePassword()) ?? ""
        let aria2Secret = (try? await AuthenticationActor.shared.loadAria2RPCSecret()) ?? ""
        return NASHandoffContext(
            settings: settings,
            credentials: NASBackendCredentials(
                qbittorrentPassword: qbPassword,
                delugePassword: delugePassword,
                aria2Secret: aria2Secret,
            ),
        )
    }
}

public struct NASAcquisitionHandler: ManualAcquisitionHandling {
    public var environment: any NASHandoffEnvironment
    public var qbittorrent: QBittorrentClient
    public var deluge: DelugeWebClient
    public var aria2: Aria2Client
    public var jobs: any ManualDownloadJobStoring

    public init(
        environment: any NASHandoffEnvironment,
        qbittorrent: QBittorrentClient = QBittorrentClient(),
        deluge: DelugeWebClient = DelugeWebClient(),
        aria2: Aria2Client = Aria2Client(),
        jobs: any ManualDownloadJobStoring = ManualDownloadJobStore.shared,
    ) {
        self.environment = environment
        self.qbittorrent = qbittorrent
        self.deluge = deluge
        self.aria2 = aria2
        self.jobs = jobs
    }

    public static func live() -> NASAcquisitionHandler {
        NASAcquisitionHandler(environment: LiveNASHandoffEnvironment())
    }

    public func handle(_ candidate: ManualAcquisitionCandidate) async -> ManualAcquisitionHandoffResult {
        let context = await environment.load()
        let settings = context.settings

        if candidate.transportKind == .magnet, !NASMagnetValidation.isValid(candidate.sourceURL) {
            return .failed(message: NASHandoffError.malformedMagnet.message)
        }

        let media: NASMediaKind
        switch NASDestinationRouting.mediaKind(for: candidate) {
            case .resolved(let kind):
                media = kind
            case .needsChoice:
                return .failed(message: NASHandoffError.mediaTypeUnresolved.message)
        }

        let destination: String
        switch NASDestinationRouting.destination(for: candidate, kind: media, settings: settings) {
            case .success(let path):
                destination = path
            case .failure(.emptyDestination):
                return .failed(message: NASHandoffError.emptyDestination.message)
            case .failure(.invalidBase), .failure(.escapedRoot):
                return .failed(message: NASHandoffError.invalidDestination.message)
        }

        let backend: NASDownloadBackend
        switch NASBackendRouting.backend(transport: candidate.transportKind, settings: settings) {
            case .success(let value):
                backend = value
            case .failure(let error):
                return .failed(message: error.message)
        }

        do {
            let jobID = try await submit(
                candidate,
                backend: backend,
                destination: destination,
                settings: settings,
                credentials: context.credentials,
            )
            await jobs.record(
                ManualDownloadJob(
                    title: candidate.bookMetadata.title,
                    author: candidate.bookMetadata.authorDisplay,
                    sourceHost: candidate.displayHost,
                    backend: backend,
                    mediaType: media,
                    destination: destination,
                    backendJobID: jobID,
                    status: .queued,
                )
            )
            return .submitted(message: NASHandoffMessages.submitted(backend: backend))
        } catch let error as QBittorrentClientError {
            return await recordFailure(
                candidate,
                backend: backend,
                media: media,
                destination: destination,
                error: error.handoff,
            )
        } catch let error as DelugeClientError {
            return await recordFailure(
                candidate,
                backend: backend,
                media: media,
                destination: destination,
                error: error.handoff,
            )
        } catch let error as Aria2ClientError {
            return await recordFailure(
                candidate,
                backend: backend,
                media: media,
                destination: destination,
                error: error.handoff,
            )
        } catch let error as NASHandoffError {
            return await recordFailure(
                candidate,
                backend: backend,
                media: media,
                destination: destination,
                error: error,
            )
        } catch {
            return await recordFailure(
                candidate,
                backend: backend,
                media: media,
                destination: destination,
                error: .rejected(backend),
            )
        }
    }

    private func recordFailure(
        _ candidate: ManualAcquisitionCandidate,
        backend: NASDownloadBackend,
        media: NASMediaKind,
        destination: String,
        error: NASHandoffError,
    ) async -> ManualAcquisitionHandoffResult {
        await jobs.record(
            ManualDownloadJob(
                title: candidate.bookMetadata.title,
                author: candidate.bookMetadata.authorDisplay,
                sourceHost: candidate.displayHost,
                backend: backend,
                mediaType: media,
                destination: destination,
                status: .failed,
                lastError: error.message,
            )
        )
        return .failed(message: error.message)
    }

    private func submit(
        _ candidate: ManualAcquisitionCandidate,
        backend: NASDownloadBackend,
        destination: String,
        settings: NASDownloadSettingsSnapshot,
        credentials: NASBackendCredentials,
    ) async throws -> String? {
        let start = settings.startAutomatically
        switch backend {
            case .qbittorrent:
                switch candidate.transportKind {
                    case .magnet:
                        let result = try await qbittorrent.addMagnet(
                            baseURL: settings.trimmedQBittorrentBaseURL,
                            username: settings.qbittorrentUsername,
                            password: credentials.qbittorrentPassword,
                            uri: candidate.sourceURL.absoluteString,
                            savePath: destination,
                            start: start,
                        )
                        return result.jobID
                    case .torrent:
                        let result = try await qbittorrent.addTorrentURL(
                            baseURL: settings.trimmedQBittorrentBaseURL,
                            username: settings.qbittorrentUsername,
                            password: credentials.qbittorrentPassword,
                            url: candidate.sourceURL.absoluteString,
                            savePath: destination,
                            start: start,
                        )
                        return result.jobID
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
                            downloadLocation: destination,
                            start: start,
                        )
                    case .torrent:
                        return try await deluge.addTorrentURL(
                            baseURL: settings.trimmedDelugeBaseURL,
                            password: credentials.delugePassword,
                            url: candidate.sourceURL.absoluteString,
                            downloadLocation: destination,
                            start: start,
                        )
                    case .directHTTP:
                        throw NASHandoffError.unsupportedAcquisition
                }
            case .aria2:
                switch candidate.transportKind {
                    case .directHTTP:
                        let filename = Aria2Client.outputFilename(candidate.filename ?? "")
                        let result = try await aria2.addURI(
                            rpcURL: settings.trimmedAria2RPCURL,
                            secret: credentials.aria2Secret,
                            uri: candidate.sourceURL.absoluteString,
                            directory: destination,
                            filename: filename,
                        )
                        return result.gid
                    case .magnet, .torrent:
                        throw NASHandoffError.unsupportedAcquisition
                }
        }
    }
}

extension ManualAcquisitionRouter {
    public static func nasLive() -> ManualAcquisitionRouter {
        ManualAcquisitionRouter(handler: NASAcquisitionHandler.live())
    }
}
