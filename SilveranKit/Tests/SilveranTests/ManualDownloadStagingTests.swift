//
//  ManualDownloadStagingTests.swift
//  SilveranTests
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit
import Testing

@Suite("Manual download staging")
struct ManualDownloadStagingTests {
    private let book = ManualSearchBookContext(title: "The Hobbit", authors: ["J.R.R. Tolkien"])

    @Test func epubStagesToDiskNotAsInMemoryOnlyResult() async throws {
        let transport = StagingDownloadScript(bytes: Data("epub-on-disk".utf8))
        let downloader = ManualFileDownloader(transport: transport)
        let staged = try await downloader.download(
            candidate: ManualAcquisitionCandidate(
                sourceURL: URL(string: "https://files.example/hobbit.epub")!,
                detectedType: .epub,
                filename: "The Hobbit.epub",
                bookMetadata: book,
            ),
            jobID: "job-epub",
        )
        #expect(FileManager.default.fileExists(atPath: staged.fileURL.path))
        #expect(try Data(contentsOf: staged.fileURL) == Data("epub-on-disk".utf8))
        #expect(staged.filename == "The Hobbit.epub")
        #expect(transport.wroteDirectlyToDestination)
        ManualDownloadStaging.remove(staged.fileURL)
    }

    @Test func m4bStagesToDisk() async throws {
        let transport = StagingDownloadScript(bytes: Data("m4b-on-disk".utf8))
        let staged = try await ManualFileDownloader(transport: transport).download(
            candidate: ManualAcquisitionCandidate(
                sourceURL: URL(string: "https://files.example/hobbit.m4b")!,
                detectedType: .m4b,
                filename: "The Hobbit.m4b",
                bookMetadata: book,
            ),
            jobID: "job-m4b",
        )
        #expect(FileManager.default.fileExists(atPath: staged.fileURL.path))
        #expect(staged.byteCount == 11)
        ManualDownloadStaging.remove(staged.fileURL)
    }

    @Test func httpFailureIsNotMarkedComplete() async {
        let transport = StagingDownloadScript(bytes: Data("partial".utf8), status: 500)
        do {
            _ = try await ManualFileDownloader(transport: transport).download(
                candidate: ManualAcquisitionCandidate(
                    sourceURL: URL(string: "https://files.example/hobbit.epub")!,
                    detectedType: .epub,
                    filename: "The Hobbit.epub",
                    bookMetadata: book,
                ),
                jobID: "job-fail",
            )
            Issue.record("download should fail")
        } catch let error as NASHandoffError {
            #expect(error == .downloadFailed)
        } catch {
            Issue.record("unexpected \(error)")
        }
        let leftover = ManualDownloadStaging.directory(jobID: "job-fail")
            .appendingPathComponent("The Hobbit.epub")
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
    }

    @Test func cookieAndRefererAreForwarded() async throws {
        let transport = StagingDownloadScript(bytes: Data("authed".utf8))
        let staged = try await ManualFileDownloader(transport: transport).download(
            candidate: ManualAcquisitionCandidate(
                sourceURL: URL(string: "https://files.example/hobbit.epub")!,
                detectedType: .epub,
                filename: "The Hobbit.epub",
                bookMetadata: book,
                cookieHeader: "session=abc",
                referer: "https://files.example/page",
            ),
            jobID: "job-cookie",
        )
        #expect(transport.lastRequest?.value(forHTTPHeaderField: "Cookie") == "session=abc")
        #expect(transport.lastRequest?.value(forHTTPHeaderField: "Referer") == "https://files.example/page")
        ManualDownloadStaging.remove(staged.fileURL)
    }

    @Test func suggestedFilenameIsPreserved() async throws {
        let transport = StagingDownloadScript(
            bytes: Data("named".utf8),
            suggestedFilename: "The-Hobbit.epub",
        )
        let staged = try await ManualFileDownloader(transport: transport).download(
            candidate: ManualAcquisitionCandidate(
                sourceURL: URL(string: "https://files.example/download")!,
                detectedType: .epub,
                filename: "download",
                bookMetadata: book,
            ),
            jobID: "job-name",
        )
        #expect(staged.filename == "The-Hobbit.epub")
        ManualDownloadStaging.remove(staged.fileURL)
    }
}

private final class StagingDownloadScript: ManualFileDownloadTransport, @unchecked Sendable {
    var bytes: Data
    var status: Int
    var suggestedFilename: String?
    var wroteDirectlyToDestination = false

    init(bytes: Data, status: Int = 200, suggestedFilename: String? = nil) {
        self.bytes = bytes
        self.status = status
        self.suggestedFilename = suggestedFilename
    }

    var lastRequest: URLRequest?

    func downloadToFile(request: URLRequest, destination: URL) async throws -> (
        fileURL: URL, status: Int, suggestedFilename: String?, byteCount: Int64
    ) {
        lastRequest = request
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try bytes.write(to: destination)
        wroteDirectlyToDestination = true
        return (destination, status, suggestedFilename, Int64(bytes.count))
    }
}
