//
//  ManualAcquisitionDetectionTests.swift
//  SilveranTests
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit
import Testing

@Suite("Manual Search candidate detection")
struct ManualAcquisitionDetectionTests {
    private let book = ManualSearchBookContext(
        title: "The Hobbit",
        authors: ["J.R.R. Tolkien"],
        openLibraryWorkID: "OL27479W",
        isbn: "9780547928227",
        requestedMediaType: .ebook,
    )

    @Test func magnetLink() throws {
        let url = try #require(URL(string: "magnet:?xt=urn:btih:abcdef&dn=The+Hobbit"))
        let candidate = try #require(
            ManualAcquisitionDetection.candidate(url: url, bookMetadata: book, providerID: "open-library")
        )
        #expect(candidate.detectedType == .magnet)
        #expect(candidate.transportKind == .magnet)
        #expect(candidate.providerID == "open-library")
        #expect(candidate.bookMetadata.title == "The Hobbit")
    }

    @Test func torrentExtension() throws {
        let url = try #require(URL(string: "https://files.example.com/The.Hobbit.torrent"))
        let candidate = try #require(ManualAcquisitionDetection.candidate(url: url, bookMetadata: book))
        #expect(candidate.detectedType == .torrent)
        #expect(candidate.transportKind == .torrent)
        #expect(candidate.displayFilename == "The.Hobbit.torrent")
        #expect(candidate.sourceHost == "files.example.com")
    }

    @Test func epubExtension() throws {
        let url = try #require(URL(string: "https://files.example.com/hobbit.epub"))
        let candidate = try #require(ManualAcquisitionDetection.candidate(url: url, bookMetadata: book))
        #expect(candidate.detectedType == .epub)
        #expect(candidate.detectedType.label == "eBook")
        #expect(candidate.transportKind == .directHTTP)
    }

    @Test func m4bExtension() throws {
        let url = try #require(URL(string: "https://files.example.com/hobbit.m4b"))
        let candidate = try #require(ManualAcquisitionDetection.candidate(url: url, bookMetadata: book))
        #expect(candidate.detectedType == .m4b)
        #expect(candidate.detectedType.label == "Audiobook")
    }

    @Test func zipExtension() throws {
        let url = try #require(URL(string: "https://files.example.com/hobbit.zip"))
        let candidate = try #require(ManualAcquisitionDetection.candidate(url: url, bookMetadata: book))
        #expect(candidate.detectedType == .zip)
    }

    @Test func mimeBasedDetection() throws {
        let url = try #require(URL(string: "https://files.example.com/download"))
        let candidate = try #require(
            ManualAcquisitionDetection.candidate(
                url: url,
                mimeType: "application/epub+zip",
                bookMetadata: book,
            )
        )
        #expect(candidate.detectedType == .epub)
        #expect(candidate.mimeType == "application/epub+zip")
    }

    @Test func contentDispositionFilename() throws {
        let url = try #require(URL(string: "https://files.example.com/get"))
        let candidate = try #require(
            ManualAcquisitionDetection.candidate(
                url: url,
                mimeType: "application/octet-stream",
                contentDisposition: "attachment; filename=\"The.Hobbit.epub\"",
                bookMetadata: book,
            )
        )
        #expect(candidate.detectedType == .epub)
        #expect(candidate.filename == "The.Hobbit.epub")
    }

    @Test func contentDispositionUTF8Filename() throws {
        let header = "attachment; filename*=UTF-8''The%20Hobbit.m4b"
        #expect(ManualAcquisitionDetection.filenameFromContentDisposition(header) == "The Hobbit.m4b")
    }

    @Test func htmlLinkIsNotADownload() {
        let url = URL(string: "https://example.com/book/the-hobbit")!
        let candidate = ManualAcquisitionDetection.candidate(
            url: url,
            mimeType: "text/html; charset=utf-8",
            bookMetadata: book,
        )
        #expect(candidate == nil)
    }

    @Test func htmlResponseObjectIsNotADownload() {
        let url = URL(string: "https://example.com/book/the-hobbit")!
        let response = URLResponse(
            url: url,
            mimeType: "text/html",
            expectedContentLength: 240,
            textEncodingName: "utf-8",
        )
        #expect(
            ManualAcquisitionDetection.candidate(url: url, response: response, bookMetadata: book) == nil
        )
    }

    @Test func unsupportedSchemesIgnored() {
        let book = book
        for raw in ["javascript:alert(1)", "blob:https://example.com/1", "data:text/plain,hi", "file:///tmp/a.epub"] {
            let url = URL(string: raw)!
            #expect(ManualAcquisitionDetection.isIgnoredScheme(url))
            #expect(ManualAcquisitionDetection.candidate(url: url, bookMetadata: book) == nil)
        }
    }

    @Test func longMagnetIsStillACandidate() throws {
        let hash = String(repeating: "a", count: 400)
        let url = try #require(URL(string: "magnet:?xt=urn:btih:\(hash)&dn=The+Hobbit+Extended"))
        let candidate = try #require(ManualAcquisitionDetection.candidate(url: url, bookMetadata: book))
        #expect(candidate.detectedType == .magnet)
        #expect(candidate.sourceURL.absoluteString.contains(hash))
    }

    @Test func responseHeadersPreferDispositionName() throws {
        let url = try #require(URL(string: "https://cdn.example.com/dl"))
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/x-bittorrent",
                "Content-Disposition": "attachment; filename=hobbit.torrent",
            ],
        )!
        let candidate = try #require(
            ManualAcquisitionDetection.candidate(url: url, response: response, bookMetadata: book)
        )
        #expect(candidate.detectedType == .torrent)
        #expect(candidate.filename == "hobbit.torrent")
    }
}
