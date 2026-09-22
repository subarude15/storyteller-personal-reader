//
//  ManualDownloadAttemptIdentity.swift
//  SilveranKit
//
//  Stable identity for manual download attempts so failures upsert instead of
//  spawning duplicate history rows for the same magnet/torrent + media type.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum ManualDownloadAttemptIdentity {
    /// Fingerprint-compatible key for a candidate about to be submitted.
    public static func key(
        for candidate: ManualAcquisitionCandidate,
        mediaType: NASMediaKind,
    ) -> String {
        let source = candidate.sourceURL.absoluteString
        if candidate.transportKind == .magnet || source.lowercased().hasPrefix("magnet:") {
            return ManualDownloadIntake.fingerprint(
                kind: .magnet,
                magnetURI: source,
                torrentByteCount: nil,
                torrentFilename: nil,
                mediaType: mediaType,
            )
        }
        let filename =
            candidate.filename
            ?? candidate.localTorrentFileURL?.lastPathComponent
            ?? candidate.sourceURL.lastPathComponent
        let size: Int64?
        if let local = candidate.localTorrentFileURL,
            let attrs = try? FileManager.default.attributesOfItem(atPath: local.path),
            let number = attrs[.size] as? NSNumber
        {
            size = number.int64Value
        } else {
            size = nil
        }
        return ManualDownloadIntake.fingerprint(
            kind: .torrentFile,
            magnetURI: nil,
            torrentByteCount: size,
            torrentFilename: filename,
            mediaType: mediaType,
        )
    }

    /// Fingerprint-compatible key for a persisted job.
    public static func key(for job: ManualDownloadJob) -> String {
        if let source = job.sourceURL, source.lowercased().hasPrefix("magnet:") {
            return ManualDownloadIntake.fingerprint(
                kind: .magnet,
                magnetURI: source,
                torrentByteCount: nil,
                torrentFilename: nil,
                mediaType: job.mediaType,
            )
        }
        if let hash = job.providerInfoHash ?? TorrentHash.canonicalInfoHash(job.backendJobID ?? ""),
            !hash.isEmpty
        {
            return "magnet:\(hash.lowercased()):\(job.mediaType.rawValue)"
        }
        return ManualDownloadIntake.fingerprint(
            kind: .torrentFile,
            magnetURI: nil,
            torrentByteCount: job.byteCount ?? job.totalSize,
            torrentFilename: job.filename,
            mediaType: job.mediaType,
        )
    }
}

extension ManualDownloadJob {
    public var attemptIdentityKey: String {
        ManualDownloadAttemptIdentity.key(for: self)
    }
}
