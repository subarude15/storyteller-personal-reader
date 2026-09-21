//
//  NASHandoffMessages.swift
//  SilveranKit
//
//  User-facing NAS errors. Secrets are never included.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum NASHandoffError: Error, Equatable, Sendable {
    case backendNotConfigured(NASDownloadBackend)
    case torrentClientNotSelected
    case mediaTypeUnresolved
    case emptyDestination
    case invalidDestination
    case malformedMagnet
    case unsupportedAcquisition
    case unreachable(NASDownloadBackend)
    case timeout(NASDownloadBackend)
    case authenticationFailed(NASDownloadBackend)
    case rejected(NASDownloadBackend)
    case invalidURL(NASDownloadBackend)
    case downloadFailed
    case insufficientStorage
    case uploadRejected
    case uploadInterrupted
    case stagedFileMissing

    public var title: String {
        switch self {
            case .downloadFailed, .insufficientStorage:
                "Couldn’t download file"
            case .uploadRejected, .uploadInterrupted, .unreachable(.synology),
                .authenticationFailed(.synology), .timeout(.synology), .invalidURL(.synology),
                .backendNotConfigured(.synology), .stagedFileMissing:
                "Couldn’t upload to NAS"
            case .backendNotConfigured, .torrentClientNotSelected, .mediaTypeUnresolved,
                .emptyDestination, .invalidDestination, .malformedMagnet, .unsupportedAcquisition,
                .unreachable, .timeout, .authenticationFailed, .rejected, .invalidURL:
                "Couldn’t send to NAS"
        }
    }

    public var message: String {
        switch self {
            case .backendNotConfigured(.synology):
                "Synology File Station is not configured.\nCheck the Synology connection in Settings."
            case .backendNotConfigured(let backend):
                "\(backend.label) is not configured.\nCheck the \(backend.label) connection in Settings."
            case .torrentClientNotSelected:
                "No torrent client is selected.\nChoose qBittorrent or Deluge in Settings."
            case .mediaTypeUnresolved:
                "Choose eBook or Audiobook so the file can be saved in the right folder."
            case .emptyDestination:
                "The destination folder is empty.\nSet the audiobook and eBook folders in Settings."
            case .invalidDestination:
                "The destination path is invalid."
            case .malformedMagnet:
                "This magnet link is malformed."
            case .unsupportedAcquisition:
                "This download type is not supported."
            case .unreachable(.synology):
                "Couldn’t upload to NAS.\nThe file is still saved on this device.\nRetry the upload when the NAS is reachable."
            case .unreachable(let backend):
                "Couldn’t reach \(backend.label).\nThe NAS may be on a local network only. You can retry later."
            case .timeout(.synology):
                "The NAS upload timed out.\nThe file is still saved on this device."
            case .timeout(let backend):
                "\(backend.label) timed out.\nCheck the \(backend.label) connection in Settings."
            case .authenticationFailed(.synology):
                "Synology rejected the credentials.\nThe file is still saved on this device."
            case .authenticationFailed(let backend):
                "\(backend.label) rejected the credentials.\nCheck the \(backend.label) connection in Settings."
            case .rejected(let backend):
                "\(backend.label) rejected the request.\nCheck the \(backend.label) connection in Settings."
            case .invalidURL(.synology):
                "The Synology URL is invalid.\nCheck the Synology connection in Settings."
            case .invalidURL(let backend):
                "The \(backend.label) URL is invalid.\nCheck the \(backend.label) connection in Settings."
            case .downloadFailed:
                "Couldn’t download file.\nNo NAS upload was attempted."
            case .insufficientStorage:
                "There isn’t enough storage on this device to download the file.\nNo NAS upload was attempted."
            case .uploadRejected:
                "Couldn’t upload to NAS.\nThe file is still saved on this device.\nRetry the upload when the NAS is reachable."
            case .uploadInterrupted:
                "The upload was interrupted.\nThe file is still saved on this device."
            case .stagedFileMissing:
                "The local file is no longer available.\nDownload it again to retry."
        }
    }
}

public enum NASHandoffMessages {
    public static func submitted(backend: NASDownloadBackend) -> String {
        "The download was added to \(backend.label)."
    }

    public static func uploaded() -> String {
        "The file was uploaded to the NAS. The temporary local copy was removed."
    }

    public static func redact(_ text: String, secrets: [String]) -> String {
        var result = text
        for secret in secrets {
            let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            result = result.replacingOccurrences(of: trimmed, with: "••••")
        }
        return result
    }
}

public struct NASHandoffPreview: Equatable, Sendable {
    public var mediaKind: NASMediaKind?
    public var needsMediaTypeChoice: Bool
    public var destination: String
    public var backend: NASDownloadBackend?
    public var backendLabel: String
    public var methodNote: String?
    public var blockingMessage: String?
    public var canSubmit: Bool

    public init(
        mediaKind: NASMediaKind?,
        needsMediaTypeChoice: Bool,
        destination: String,
        backend: NASDownloadBackend?,
        backendLabel: String,
        methodNote: String? = nil,
        blockingMessage: String?,
        canSubmit: Bool,
    ) {
        self.mediaKind = mediaKind
        self.needsMediaTypeChoice = needsMediaTypeChoice
        self.destination = destination
        self.backend = backend
        self.backendLabel = backendLabel
        self.methodNote = methodNote
        self.blockingMessage = blockingMessage
        self.canSubmit = canSubmit
    }

    public static func make(
        candidate: ManualAcquisitionCandidate,
        override: NASMediaKind? = nil,
        settings: NASDownloadSettingsSnapshot,
    ) -> NASHandoffPreview {
        let resolution = NASDestinationRouting.mediaKind(for: candidate, override: override)
        let mediaKind: NASMediaKind?
        let needsChoice: Bool
        switch resolution {
            case .resolved(let kind):
                mediaKind = kind
                needsChoice = false
            case .needsChoice:
                mediaKind = nil
                needsChoice = true
        }

        var destination = ""
        var blocking: String?
        if let mediaKind {
            switch NASDestinationRouting.destination(
                for: candidate,
                kind: mediaKind,
                settings: settings,
            ) {
                case .success(let path):
                    destination = path
                case .failure(.emptyDestination):
                    blocking = NASHandoffError.emptyDestination.message
                case .failure(.invalidBase), .failure(.escapedRoot):
                    blocking = NASHandoffError.invalidDestination.message
            }
        } else if needsChoice {
            blocking = NASHandoffError.mediaTypeUnresolved.message
        }

        let backendResult = NASBackendRouting.backend(
            transport: candidate.transportKind,
            settings: settings,
        )
        let backend: NASDownloadBackend?
        let backendLabel: String
        var methodNote: String?
        switch backendResult {
            case .success(let value):
                backend = value
                backendLabel = value.methodLabel
                if value == .synology {
                    methodNote = "Temporary local copy will be removed after successful upload."
                }
            case .failure(let error):
                backend = nil
                backendLabel = "—"
                if blocking == nil {
                    blocking = error.message
                }
        }

        return NASHandoffPreview(
            mediaKind: mediaKind,
            needsMediaTypeChoice: needsChoice,
            destination: destination,
            backend: backend,
            backendLabel: backendLabel,
            methodNote: methodNote,
            blockingMessage: blocking,
            canSubmit: blocking == nil && backend != nil && !destination.isEmpty,
        )
    }
}
