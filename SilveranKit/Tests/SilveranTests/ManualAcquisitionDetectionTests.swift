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

    @Test func magnetInterceptsImmediately() throws {
        let url = try #require(URL(string: "magnet:?xt=urn:btih:abcdef&dn=The+Hobbit"))
        let action = try #require(
            ManualAcquisitionDetection.actionStageCandidate(
                url: url,
                bookMetadata: book,
                providerID: "open-library",
            )
        )
        #expect(action.detectedType == .magnet)
        #expect(action.transportKind == .magnet)
        #expect(action.providerID == "open-library")
        #expect(action.bookMetadata.title == "The Hobbit")
    }

    @Test func httpPathExtensionIsNotClassifiedAtActionStage() throws {
        for name in ["file.pdf", "hobbit.epub", "hobbit.m4b", "hobbit.torrent", "hobbit.zip"] {
            let url = try #require(URL(string: "https://example.com/\(name)"))
            #expect(ManualAcquisitionDetection.actionStageCandidate(url: url, bookMetadata: book) == nil)
            #expect(ManualAcquisitionDetection.candidate(url: url, bookMetadata: book) == nil)
        }
    }

    @Test func pdfURLReturningHTMLIsNotAnAcquisition() throws {
        let url = try #require(URL(string: "https://example.com/file.pdf"))
        let response = URLResponse(
            url: url,
            mimeType: "text/html",
            expectedContentLength: 1200,
            textEncodingName: "utf-8",
        )
        #expect(
            ManualAcquisitionDetection.candidate(url: url, response: response, bookMetadata: book) == nil
        )
    }

    @Test func epubURLReturningEpubMIMEIsAnAcquisition() throws {
        let url = try #require(URL(string: "https://files.example.com/hobbit.epub"))
        let candidate = try #require(
            ManualAcquisitionDetection.candidate(
                url: url,
                mimeType: "application/epub+zip",
                bookMetadata: book,
            )
        )
        #expect(candidate.detectedType == .epub)
        #expect(candidate.detectedType.label == "eBook")
        #expect(candidate.transportKind == .directHTTP)
    }

    @Test func extensionlessURLWithContentDispositionIsAnAcquisition() throws {
        let url = try #require(URL(string: "https://files.example.com/get"))
        let candidate = try #require(
            ManualAcquisitionDetection.candidate(
                url: url,
                mimeType: "application/octet-stream",
                contentDisposition: "attachment; filename=\"book.epub\"",
                bookMetadata: book,
            )
        )
        #expect(candidate.detectedType == .epub)
        #expect(candidate.filename == "book.epub")
    }

    @Test func extensionlessURLWithUsefulMIMEIsAnAcquisition() throws {
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

    @Test func ordinaryHTMLPageIsNormalNavigation() {
        let url = URL(string: "https://example.com/book/the-hobbit")!
        #expect(ManualAcquisitionDetection.actionStageCandidate(url: url, bookMetadata: book) == nil)
        #expect(
            ManualAcquisitionDetection.candidate(
                url: url,
                mimeType: "text/html; charset=utf-8",
                bookMetadata: book,
            ) == nil
        )
    }

    @Test func torrentMIMEIsDetected() throws {
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
        #expect(candidate.transportKind == .torrent)
    }

    @Test func downloadSuggestedFilenameIsUsed() throws {
        let url = try #require(URL(string: "https://cdn.example.com/dl"))
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/octet-stream"],
        )!
        let candidate = try #require(
            ManualAcquisitionDetection.candidate(
                url: url,
                response: response,
                suggestedFilename: "The.Hobbit.epub",
                bookMetadata: book,
            )
        )
        #expect(candidate.detectedType == .epub)
        #expect(candidate.filename == "The.Hobbit.epub")
    }

    @Test func recognizedExtensionsWithMatchingMIME() throws {
        let cases: [(String, String, ManualAcquisitionDetectedType)] = [
            ("hobbit.torrent", "application/x-bittorrent", .torrent),
            ("hobbit.epub", "application/epub+zip", .epub),
            ("hobbit.pdf", "application/pdf", .pdf),
            ("hobbit.mobi", "application/x-mobipocket-ebook", .mobi),
            ("hobbit.azw", "application/vnd.amazon.ebook", .azw),
            ("hobbit.azw3", "application/octet-stream", .azw3),
            ("hobbit.cbz", "application/vnd.comicbook+zip", .cbz),
            ("hobbit.cbr", "application/vnd.comicbook-rar", .cbr),
            ("hobbit.m4b", "audio/x-m4b", .m4b),
            ("hobbit.mp3", "audio/mpeg", .mp3),
            ("hobbit.m4a", "audio/x-m4a", .m4a),
            ("hobbit.flac", "audio/flac", .flac),
            ("hobbit.zip", "application/zip", .zip),
        ]
        for (name, mime, expected) in cases {
            let url = try #require(URL(string: "https://files.example.com/\(name)"))
            let candidate = try #require(
                ManualAcquisitionDetection.candidate(url: url, mimeType: mime, bookMetadata: book)
            )
            #expect(candidate.detectedType == expected)
        }
    }

    @Test func contentDispositionUTF8Filename() throws {
        let header = "attachment; filename*=UTF-8''The%20Hobbit.m4b"
        #expect(ManualAcquisitionDetection.filenameFromContentDisposition(header) == "The Hobbit.m4b")
    }

    @Test func unsupportedSchemesIgnored() {
        for raw in ["javascript:alert(1)", "blob:https://example.com/1", "data:text/plain,hi", "file:///tmp/a.epub"] {
            let url = URL(string: raw)!
            #expect(ManualAcquisitionDetection.isIgnoredScheme(url))
            #expect(ManualAcquisitionDetection.actionStageCandidate(url: url, bookMetadata: book) == nil)
            #expect(ManualAcquisitionDetection.candidate(url: url, bookMetadata: book) == nil)
        }
    }

    @Test func longMagnetIsStillACandidate() throws {
        let hash = String(repeating: "a", count: 400)
        let url = try #require(URL(string: "magnet:?xt=urn:btih:\(hash)&dn=The+Hobbit+Extended"))
        let candidate = try #require(ManualAcquisitionDetection.actionStageCandidate(url: url, bookMetadata: book))
        #expect(candidate.detectedType == .magnet)
        #expect(candidate.sourceURL.absoluteString.contains(hash))
    }
}
