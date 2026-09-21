//
//  ManualAcquisitionCandidate.swift
//  SilveranKit
//
//  A possible download the in-app browser recognized. PR 68 routes this
//  object to a NAS backend; this PR only produces it.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// How NAS handoff should send this file.
public enum ManualAcquisitionTransportKind: String, Codable, Sendable {
    case magnet
    case torrent
    case directHTTP
}

public enum ManualAcquisitionDetectedType: String, Codable, Sendable, CaseIterable {
    case magnet
    case torrent
    case epub
    case pdf
    case mobi
    case azw
    case azw3
    case cbz
    case cbr
    case zip
    case m4b
    case mp3
    case m4a
    case flac

    public var label: String {
        switch self {
            case .magnet, .torrent: "Torrent"
            case .epub, .pdf, .mobi, .azw, .azw3: "eBook"
            case .cbz, .cbr: "Comic"
            case .zip: "Archive"
            case .m4b, .mp3, .m4a, .flac: "Audiobook"
        }
    }

    public var fileExtension: String {
        switch self {
            case .magnet: "magnet"
            case .torrent: "torrent"
            case .epub: "epub"
            case .pdf: "pdf"
            case .mobi: "mobi"
            case .azw: "azw"
            case .azw3: "azw3"
            case .cbz: "cbz"
            case .cbr: "cbr"
            case .zip: "zip"
            case .m4b: "m4b"
            case .mp3: "mp3"
            case .m4a: "m4a"
            case .flac: "flac"
        }
    }

    /// Future NAS routing: magnets/torrents vs direct HTTP(S) files.
    public var transportKind: ManualAcquisitionTransportKind {
        switch self {
            case .magnet: .magnet
            case .torrent: .torrent
            case .epub, .pdf, .mobi, .azw, .azw3, .cbz, .cbr, .zip, .m4b, .mp3, .m4a, .flac:
                .directHTTP
        }
    }
}

/// Enough information to pick a backend without re-inspecting the page.
public struct ManualAcquisitionCandidate: Equatable, Sendable, Hashable {
    public var sourceURL: URL
    public var detectedType: ManualAcquisitionDetectedType
    public var filename: String?
    public var sourceHost: String?
    public var mimeType: String?
    public var bookMetadata: ManualSearchBookContext
    public var providerID: String?
    /// Session cookies from the in-app browser. Not persisted.
    public var cookieHeader: String?
    public var referer: String?
    /// Ephemeral staged `.torrent` from WKDownload. Not a media file.
    public var localTorrentFileURL: URL?

    public init(
        sourceURL: URL,
        detectedType: ManualAcquisitionDetectedType,
        filename: String? = nil,
        sourceHost: String? = nil,
        mimeType: String? = nil,
        bookMetadata: ManualSearchBookContext,
        providerID: String? = nil,
        cookieHeader: String? = nil,
        referer: String? = nil,
        localTorrentFileURL: URL? = nil,
    ) {
        self.sourceURL = sourceURL
        self.detectedType = detectedType
        self.filename = filename
        self.sourceHost = sourceHost
        self.mimeType = mimeType
        self.bookMetadata = bookMetadata
        self.providerID = providerID
        self.cookieHeader = cookieHeader
        self.referer = referer
        self.localTorrentFileURL = localTorrentFileURL
    }

    public var displayFilename: String {
        if let filename, !filename.isEmpty { return filename }
        if let localTorrentFileURL {
            let last = localTorrentFileURL.lastPathComponent
            if !last.isEmpty { return last }
        }
        if detectedType == .magnet { return "Magnet link" }
        let last = sourceURL.lastPathComponent
        if !last.isEmpty, last != "/" { return last }
        return "Unknown file"
    }

    public var displayHost: String {
        if let sourceHost, !sourceHost.isEmpty { return sourceHost }
        return sourceURL.host ?? "unknown host"
    }

    public var transportKind: ManualAcquisitionTransportKind {
        detectedType.transportKind
    }

    public var hasStagedTorrentFile: Bool {
        guard let localTorrentFileURL else { return false }
        return ManualDownloadStaging.exists(localTorrentFileURL)
    }

    /// Drop a WK-staged `.torrent` that is not owned by a retryable job yet.
    public func discardStagedTorrentFile() {
        guard let localTorrentFileURL else { return }
        ManualDownloadStaging.remove(localTorrentFileURL)
    }
}
