//
//  RaveBSDAcquisition.swift
//  SilveranKit
//
//  Map a RaveBSD row onto ManualAcquisitionCandidate so NAS / TorBoxarr
//  routing stays in one place. Never auto-starts a download.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum RaveBSDAcquisitionError: Error, Equatable, Sendable {
    case unsupportedLink(String)
    case resolveFailed(String)
    case missingDownload

    public var message: String {
        switch self {
            case .unsupportedLink(let detail), .resolveFailed(let detail):
                detail
            case .missingDownload:
                "RaveBSD did not return a magnet or direct download link"
        }
    }
}

public enum RaveBSDAcquisition {
    public static let providerID = "ravebsd"

    public static func merge(resolve: RaveBSDResolveResponse, into result: RaveBSDSearchResult) -> RaveBSDSearchResult {
        var copy = result
        if !resolve.directURL.isEmpty { copy.directURL = resolve.directURL }
        if !resolve.magnet.isEmpty { copy.magnet = resolve.magnet }
        if !resolve.infoHash.isEmpty { copy.infoHash = resolve.infoHash }
        if !resolve.downloadURL.isEmpty { copy.downloadURL = resolve.downloadURL }
        if !resolve.format.isEmpty { copy.format = resolve.format }
        if resolve.filesize > 0 { copy.filesize = resolve.filesize }
        if !resolve.directFrom.isEmpty { copy.directFrom = resolve.directFrom }
        if !copy.normalizedDirectURL.isEmpty || !copy.normalizedMagnet.isEmpty {
            copy.directReady = true
        }
        return copy
    }

    /// Build a handoff candidate from an already-resolved result.
    public static func candidate(
        from result: RaveBSDSearchResult,
        book: ManualSearchBookContext,
        localTorrentFileURL: URL? = nil,
    ) throws -> ManualAcquisitionCandidate {
        if let magnet = URL(string: result.normalizedMagnet), magnet.scheme?.lowercased() == "magnet" {
            return ManualAcquisitionCandidate(
                sourceURL: magnet,
                detectedType: .magnet,
                filename: filenameHint(result: result, fallback: "Magnet link"),
                sourceHost: result.source.isEmpty ? "RaveBSD" : result.source,
                bookMetadata: bookWithResult(book, result),
                providerID: providerID,
                localTorrentFileURL: localTorrentFileURL,
            )
        }

        if let torrentURL = localTorrentFileURL {
            return ManualAcquisitionCandidate(
                sourceURL: torrentURL,
                detectedType: .torrent,
                filename: torrentURL.lastPathComponent,
                sourceHost: result.source.isEmpty ? "RaveBSD" : result.source,
                mimeType: "application/x-bittorrent",
                bookMetadata: bookWithResult(book, result),
                providerID: providerID,
                localTorrentFileURL: torrentURL,
            )
        }

        let direct = result.normalizedDirectURL
        guard !direct.isEmpty, let url = URL(string: direct) else {
            throw RaveBSDAcquisitionError.missingDownload
        }

        let detected =
            ManualAcquisitionDetection.typeFromFilename(filenameHint(result: result, fallback: url.lastPathComponent))
            ?? ManualAcquisitionDetection.typeFromPath(url)
            ?? fallbackType(for: result)

        guard let detected else {
            throw RaveBSDAcquisitionError.unsupportedLink(
                "Unsupported download type\(result.formatDisplay.map { " (\($0))" } ?? "")"
            )
        }

        return ManualAcquisitionCandidate(
            sourceURL: url,
            detectedType: detected,
            filename: filenameHint(result: result, fallback: url.lastPathComponent),
            sourceHost: result.source.isEmpty ? url.host : result.source,
            bookMetadata: bookWithResult(book, result),
            providerID: providerID,
        )
    }

    /// Resolve if needed, optionally fetch a .torrent for magnets, then build a candidate.
    public static func prepareCandidate(
        result: RaveBSDSearchResult,
        book: ManualSearchBookContext,
        baseURL: String,
        client: RaveBSDClient,
        preferTorrentFile: Bool = false,
    ) async throws -> ManualAcquisitionCandidate {
        var working = result
        if working.normalizedMagnet.isEmpty, working.normalizedDirectURL.isEmpty {
            do {
                let resolved = try await client.resolve(baseURL: baseURL, id: working.id)
                working = merge(resolve: resolved, into: working)
            } catch let error as RaveBSDClientError {
                throw RaveBSDAcquisitionError.resolveFailed(error.message)
            }
        }

        var stagedTorrent: URL?
        if preferTorrentFile,
            !working.normalizedMagnet.isEmpty,
            !working.id.hasPrefix("local-")
        {
            if let data = try? await client.downloadTorrent(baseURL: baseURL, id: working.id),
                !data.isEmpty
            {
                let dest = try ManualDownloadStaging.prepareTorrent(
                    suggestedFilename: filenameHint(result: working, fallback: "download") + ".torrent"
                )
                try data.write(to: dest, options: .atomic)
                stagedTorrent = dest
            }
        }

        do {
            return try candidate(from: working, book: book, localTorrentFileURL: stagedTorrent)
        } catch {
            if let stagedTorrent {
                ManualDownloadStaging.remove(stagedTorrent)
            }
            throw error
        }
    }

    private static func bookWithResult(
        _ book: ManualSearchBookContext,
        _ result: RaveBSDSearchResult,
    ) -> ManualSearchBookContext {
        var copy = book
        if copy.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.title = result.title
        }
        if copy.authors.isEmpty {
            let author = result.author.trimmingCharacters(in: .whitespacesAndNewlines)
            if !author.isEmpty { copy.authors = [author] }
        }
        return copy
    }

    private static func filenameHint(result: RaveBSDSearchResult, fallback: String) -> String {
        let base = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = base.isEmpty ? fallback : base
        if let format = result.formatDisplay {
            let lower = name.lowercased()
            if lower.hasSuffix(".\(format.lowercased())") { return name }
            return "\(name).\(format.lowercased())"
        }
        return name
    }

    private static func fallbackType(for result: RaveBSDSearchResult) -> ManualAcquisitionDetectedType? {
        guard let format = result.formatDisplay?.lowercased() else { return nil }
        return ManualAcquisitionDetection.fileExtensions[format]
    }
}
