//
//  ManualDownloadIntake.swift
//  SilveranKit
//
//  Thin share / Shortcuts intake for magnets and .torrent files.
//  Classification only — Deluge routing stays in NASAcquisitionHandler / PR71.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What a shared item resolved to before media-type selection.
public enum ManualDownloadIntakeKind: String, Codable, Sendable, Equatable {
    case magnet
    case torrentFile
}

public enum ManualDownloadIntakeSource: String, Codable, Sendable, Equatable {
    case shareExtension
    case appIntent
    case inApp
}

public enum ManualDownloadIntakeError: Error, Equatable, Sendable {
    case unsupportedItem
    case webpageNotMagnetOrTorrent
    case malformedMagnet
    case inaccessibleTorrent
    case unsupportedFile
    case mediaTypeRequired
    case handoffUnavailable
    case emptyPayload

    public var message: String {
        switch self {
            case .unsupportedItem:
                "This item isn’t a magnet link or .torrent file."
            case .webpageNotMagnetOrTorrent:
                "Share the specific magnet link or .torrent file instead of the whole webpage."
            case .malformedMagnet:
                "This magnet link is malformed."
            case .inaccessibleTorrent:
                "Couldn’t read the .torrent file."
            case .unsupportedFile:
                "Only .torrent files are supported here."
            case .mediaTypeRequired:
                "Choose eBook or Audiobook."
            case .handoffUnavailable:
                "Couldn’t hand off to ink+amp. Open the app and try again."
            case .emptyPayload:
                "Nothing to send."
        }
    }
}

/// Result of classifying a shared URL, text, or file path before UI confirmation.
public enum ManualDownloadIntakeClassification: Equatable, Sendable {
    case magnet(url: URL, displayTitle: String)
    case torrent(filename: String, displayTitle: String)
    case rejected(ManualDownloadIntakeError)
}

public enum ManualDownloadIntake {
    /// Classify a shared string (URL or plain magnet text).
    public static func classify(text: String) -> ManualDownloadIntakeClassification {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejected(.emptyPayload) }
        if let url = URL(string: trimmed) {
            return classify(url: url)
        }
        // Plain magnet without URL parsing (spaces already trimmed).
        if trimmed.lowercased().hasPrefix("magnet:") {
            guard let url = URL(string: trimmed), NASMagnetValidation.isValid(url) else {
                return .rejected(.malformedMagnet)
            }
            return .magnet(url: url, displayTitle: magnetDisplayTitle(url))
        }
        return .rejected(.unsupportedItem)
    }

    public static func classify(url: URL) -> ManualDownloadIntakeClassification {
        let scheme = (url.scheme ?? "").lowercased()
        if scheme == "magnet" {
            guard NASMagnetValidation.isValid(url) else { return .rejected(.malformedMagnet) }
            return .magnet(url: url, displayTitle: magnetDisplayTitle(url))
        }
        if scheme == "http" || scheme == "https" {
            let path = url.path.lowercased()
            if path.hasSuffix(".torrent") {
                let name = url.lastPathComponent
                return .torrent(
                    filename: ManualDownloadStaging.safeFilename(name, fallback: "download.torrent"),
                    displayTitle: displayTitle(fromFilename: name),
                )
            }
            return .rejected(.webpageNotMagnetOrTorrent)
        }
        if scheme == "file" {
            return classifyTorrentFile(url: url)
        }
        return .rejected(.unsupportedItem)
    }

    public static func classifyTorrentFile(url: URL) -> ManualDownloadIntakeClassification {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        guard ext == "torrent" || name.lowercased().hasSuffix(".torrent") else {
            return .rejected(.unsupportedFile)
        }
        return .torrent(
            filename: ManualDownloadStaging.safeFilename(name, fallback: "download.torrent"),
            displayTitle: displayTitle(fromFilename: name),
        )
    }

    public static func magnetDisplayTitle(_ url: URL) -> String {
        let raw = url.absoluteString
        for pair in raw.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            guard key == "dn" || key.hasSuffix("dn") else { continue }
            let decoded = parts[1].removingPercentEncoding ?? parts[1]
            let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "+", with: " ")
            if !trimmed.isEmpty { return trimmed }
        }
        if let hash = TorrentHash.fromMagnet(raw) {
            return "Magnet \(hash.prefix(8))"
        }
        return "Magnet link"
    }

    public static func displayTitle(fromFilename raw: String) -> String {
        let last = (raw as NSString).lastPathComponent
        var base = last
        if base.lowercased().hasSuffix(".torrent") {
            base = String(base.dropLast(".torrent".count))
        }
        let cleaned = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Torrent file" : cleaned
    }

    /// Stable fingerprint for duplicate-handoff suppression (same magnet/hash + media).
    public static func fingerprint(
        kind: ManualDownloadIntakeKind,
        magnetURI: String?,
        torrentByteCount: Int64?,
        torrentFilename: String?,
        mediaType: NASMediaKind,
    ) -> String {
        switch kind {
            case .magnet:
                let hash = magnetURI.flatMap(TorrentHash.fromMagnet) ?? (magnetURI ?? "")
                return "magnet:\(hash.lowercased()):\(mediaType.rawValue)"
            case .torrentFile:
                let name = (torrentFilename ?? "download.torrent").lowercased()
                let size = torrentByteCount.map(String.init) ?? "0"
                return "torrent:\(name):\(size):\(mediaType.rawValue)"
        }
    }
}

/// Persisted handoff record written by the Share Extension / App Intent.
public struct ManualDownloadIntakePayload: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: ManualDownloadIntakeKind
    public var mediaType: NASMediaKind
    public var source: ManualDownloadIntakeSource
    public var displayTitle: String
    public var magnetURI: String?
    /// Path relative to the App Group intake root (torrent bytes only).
    public var stagedTorrentRelativePath: String?
    public var stagedTorrentByteCount: Int64?
    public var stagedTorrentFilename: String?
    public var fingerprint: String
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        kind: ManualDownloadIntakeKind,
        mediaType: NASMediaKind,
        source: ManualDownloadIntakeSource,
        displayTitle: String,
        magnetURI: String? = nil,
        stagedTorrentRelativePath: String? = nil,
        stagedTorrentByteCount: Int64? = nil,
        stagedTorrentFilename: String? = nil,
        fingerprint: String,
        createdAt: Date = Date(),
    ) {
        self.id = id
        self.kind = kind
        self.mediaType = mediaType
        self.source = source
        self.displayTitle = displayTitle
        self.magnetURI = magnetURI
        self.stagedTorrentRelativePath = stagedTorrentRelativePath
        self.stagedTorrentByteCount = stagedTorrentByteCount
        self.stagedTorrentFilename = stagedTorrentFilename
        self.fingerprint = fingerprint
        self.createdAt = createdAt
    }

    public static func magnet(
        url: URL,
        mediaType: NASMediaKind,
        source: ManualDownloadIntakeSource,
        displayTitle: String? = nil,
    ) -> ManualDownloadIntakePayload {
        let title = displayTitle ?? ManualDownloadIntake.magnetDisplayTitle(url)
        let uri = url.absoluteString
        return ManualDownloadIntakePayload(
            kind: .magnet,
            mediaType: mediaType,
            source: source,
            displayTitle: title,
            magnetURI: uri,
            fingerprint: ManualDownloadIntake.fingerprint(
                kind: .magnet,
                magnetURI: uri,
                torrentByteCount: nil,
                torrentFilename: nil,
                mediaType: mediaType,
            ),
        )
    }

    public static func torrent(
        mediaType: NASMediaKind,
        source: ManualDownloadIntakeSource,
        displayTitle: String,
        relativePath: String,
        filename: String,
        byteCount: Int64,
    ) -> ManualDownloadIntakePayload {
        ManualDownloadIntakePayload(
            kind: .torrentFile,
            mediaType: mediaType,
            source: source,
            displayTitle: displayTitle,
            stagedTorrentRelativePath: relativePath,
            stagedTorrentByteCount: byteCount,
            stagedTorrentFilename: filename,
            fingerprint: ManualDownloadIntake.fingerprint(
                kind: .torrentFile,
                magnetURI: nil,
                torrentByteCount: byteCount,
                torrentFilename: filename,
                mediaType: mediaType,
            ),
        )
    }
}

extension ManualDownloadIntakePayload {
    /// Build a Manual Search–compatible candidate. Caller supplies a resolved
    /// local torrent URL when `kind == .torrentFile`.
    public func makeCandidate(localTorrentFileURL: URL? = nil) -> Result<
        ManualAcquisitionCandidate, ManualDownloadIntakeError
    > {
        let requested: ManualSearchMediaType =
            mediaType == .audiobook ? .audiobook : .ebook
        let metadata = ManualSearchBookContext(
            title: displayTitle,
            authors: [],
            requestedMediaType: requested,
        )
        switch kind {
            case .magnet:
                guard let magnetURI, let url = URL(string: magnetURI),
                    NASMagnetValidation.isValid(url)
                else {
                    return .failure(.malformedMagnet)
                }
                return .success(
                    ManualAcquisitionCandidate(
                        sourceURL: url,
                        detectedType: .magnet,
                        sourceHost: url.host,
                        bookMetadata: metadata,
                    )
                )
            case .torrentFile:
                guard let local = localTorrentFileURL, ManualDownloadStaging.exists(local) else {
                    return .failure(.inaccessibleTorrent)
                }
                let name = stagedTorrentFilename ?? local.lastPathComponent
                return .success(
                    ManualAcquisitionCandidate(
                        sourceURL: local,
                        detectedType: .torrent,
                        filename: name,
                        sourceHost: "share",
                        bookMetadata: metadata,
                        localTorrentFileURL: local,
                    )
                )
        }
    }
}
