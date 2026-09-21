//
//  ManualDownloadStaging.swift
//  SilveranKit
//
//  File-backed staging for Manual Search direct downloads.
//  Never loads the file body into memory.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ManualStagedFile: Equatable, Sendable {
    public var jobID: String
    public var fileURL: URL
    public var filename: String
    public var byteCount: Int64

    public init(jobID: String, fileURL: URL, filename: String, byteCount: Int64) {
        self.jobID = jobID
        self.fileURL = fileURL
        self.filename = filename
        self.byteCount = byteCount
    }
}

public enum ManualDownloadStaging {
    public static func root(fileManager: FileManager = .default) -> URL {
        SilveranPlatform.applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("ManualDownloads", isDirectory: true)
            .appendingPathComponent("Staging", isDirectory: true)
    }

    public static func directory(jobID: String, fileManager: FileManager = .default) -> URL {
        root(fileManager: fileManager).appendingPathComponent(jobID, isDirectory: true)
    }

    public static func prepare(
        jobID: String,
        filename: String,
        fileManager: FileManager = .default,
    ) throws -> URL {
        let safe = safeFilename(filename)
        let folder = directory(jobID: jobID, fileManager: fileManager)
        if !fileManager.fileExists(atPath: folder.path) {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder.appendingPathComponent(safe, isDirectory: false)
    }

    public static func exists(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        let present = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return present && !isDirectory.boolValue
    }

    public static func remove(_ url: URL, fileManager: FileManager = .default) {
        let folder = url.deletingLastPathComponent()
        try? fileManager.removeItem(at: url)
        if let remaining = try? fileManager.contentsOfDirectory(atPath: folder.path), remaining.isEmpty {
            try? fileManager.removeItem(at: folder)
        }
    }

    public static func safeFilename(_ raw: String, fallback: String = "download.bin") -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = (trimmed as NSString).lastPathComponent
        let cleaned = NASPathSafety.sanitizeComponent(last)
        if cleaned.isEmpty || cleaned == "Magnet link" { return fallback }
        return cleaned
    }

    /// Destination for a browser-captured `.torrent` (tiny metadata file, not book media).
    public static func prepareTorrent(
        suggestedFilename: String,
        jobID: String = UUID().uuidString,
        fileManager: FileManager = .default,
    ) throws -> URL {
        var name = safeFilename(suggestedFilename, fallback: "download.torrent")
        if !name.lowercased().hasSuffix(".torrent") {
            name += ".torrent"
        }
        return try prepare(jobID: jobID, filename: name, fileManager: fileManager)
    }
}

public protocol ManualFileDownloadTransport: Sendable {
    func downloadToFile(request: URLRequest, destination: URL) async throws -> (
        fileURL: URL, status: Int, suggestedFilename: String?, byteCount: Int64
    )
}

public struct LiveManualFileDownloadTransport: ManualFileDownloadTransport {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func downloadToFile(request: URLRequest, destination: URL) async throws -> (
        fileURL: URL, status: Int, suggestedFilename: String?, byteCount: Int64
    ) {
        let (temp, response) = try await session.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let name = response.suggestedFilename
        let destDir = destination.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: destDir.path) {
            try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temp, to: destination)
        let size =
            (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?
            .int64Value ?? 0
        return (destination, status, name, size)
    }
}

public struct ManualFileDownloader: Sendable {
    public var transport: any ManualFileDownloadTransport

    public init(transport: any ManualFileDownloadTransport = LiveManualFileDownloadTransport()) {
        self.transport = transport
    }

    public func download(
        candidate: ManualAcquisitionCandidate,
        jobID: String,
        staging: (String, String) throws -> URL = { try ManualDownloadStaging.prepare(jobID: $0, filename: $1) },
    ) async throws -> ManualStagedFile {
        let filename = ManualDownloadStaging.safeFilename(
            candidate.filename ?? candidate.displayFilename
        )
        let destination: URL
        do {
            destination = try staging(jobID, filename)
        } catch {
            throw NASHandoffError.insufficientStorage
        }
        var request = URLRequest(url: candidate.sourceURL)
        request.httpMethod = "GET"
        if let cookie = candidate.cookieHeader, !cookie.isEmpty {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let referer = candidate.referer, !referer.isEmpty {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        let downloaded: (fileURL: URL, status: Int, suggestedFilename: String?, byteCount: Int64)
        do {
            downloaded = try await transport.downloadToFile(request: request, destination: destination)
        } catch let error as URLError where error.code == .timedOut {
            ManualDownloadStaging.remove(destination)
            throw NASHandoffError.downloadFailed
        } catch let error as URLError
            where error.code == .cannotCreateFile || error.code == .cannotWriteToFile
        {
            ManualDownloadStaging.remove(destination)
            throw NASHandoffError.insufficientStorage
        } catch {
            ManualDownloadStaging.remove(destination)
            throw NASHandoffError.downloadFailed
        }
        if downloaded.status >= 400 || downloaded.status == 0 {
            ManualDownloadStaging.remove(downloaded.fileURL)
            throw NASHandoffError.downloadFailed
        }
        if downloaded.byteCount <= 0 {
            ManualDownloadStaging.remove(downloaded.fileURL)
            throw NASHandoffError.downloadFailed
        }
        let finalName = ManualDownloadStaging.safeFilename(
            downloaded.suggestedFilename ?? filename
        )
        var fileURL = downloaded.fileURL
        if finalName != fileURL.lastPathComponent {
            let renamed = fileURL.deletingLastPathComponent().appendingPathComponent(finalName)
            try? FileManager.default.removeItem(at: renamed)
            try? FileManager.default.moveItem(at: fileURL, to: renamed)
            if FileManager.default.fileExists(atPath: renamed.path) {
                fileURL = renamed
            }
        }
        return ManualStagedFile(
            jobID: jobID,
            fileURL: fileURL,
            filename: fileURL.lastPathComponent,
            byteCount: downloaded.byteCount,
        )
    }
}
