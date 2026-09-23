//
//  NASDestinationRoutingTests.swift
//  SilveranTests
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit
import Testing

@Suite("NAS destination routing")
struct NASDestinationRoutingTests {
    private let audiobookBook = ManualSearchBookContext(
        title: "The Hobbit",
        authors: ["J.R.R. Tolkien"],
        requestedMediaType: .audiobook,
    )
    private let ebookBook = ManualSearchBookContext(
        title: "The Hobbit",
        authors: ["J.R.R. Tolkien"],
        requestedMediaType: .ebook,
    )
    private let bareBook = ManualSearchBookContext(
        title: "The Hobbit",
        authors: ["J.R.R. Tolkien"],
    )

    private func settings(
        audiobook: String = "/media/audiobooks",
        ebook: String = "/media/books",
        subfolders: Bool = false,
    ) -> NASDownloadSettingsSnapshot {
        NASDownloadSettingsSnapshot(
            audiobookFolder: audiobook,
            ebookFolder: ebook,
            createTitleAuthorSubfolders: subfolders,
        )
    }

    private func candidate(
        url: String,
        type: ManualAcquisitionDetectedType,
        book: ManualSearchBookContext,
        mime: String? = nil,
        filename: String? = nil,
    ) -> ManualAcquisitionCandidate {
        ManualAcquisitionCandidate(
            sourceURL: URL(string: url)!,
            detectedType: type,
            filename: filename,
            mimeType: mime,
            bookMetadata: book,
        )
    }

    @Test func m4bUsesAudiobookFolder() {
        let item = candidate(
            url: "https://files.example/hobbit.m4b",
            type: .m4b,
            book: bareBook,
        )
        #expect(NASDestinationRouting.mediaKind(for: item) == .resolved(.audiobook))
        #expect(
            NASDestinationRouting.destination(for: item, kind: .audiobook, settings: settings())
                == .success("/media/audiobooks")
        )
    }

    @Test func mp3UsesAudiobookFolder() {
        let item = candidate(url: "https://files.example/hobbit.mp3", type: .mp3, book: bareBook)
        #expect(NASDestinationRouting.mediaKind(for: item) == .resolved(.audiobook))
    }

    @Test func epubUsesEbookFolder() {
        let item = candidate(url: "https://files.example/hobbit.epub", type: .epub, book: bareBook)
        #expect(NASDestinationRouting.mediaKind(for: item) == .resolved(.ebook))
        #expect(
            NASDestinationRouting.destination(for: item, kind: .ebook, settings: settings())
                == .success("/media/books")
        )
    }

    @Test func pdfUsesEbookFolder() {
        let item = candidate(url: "https://files.example/hobbit.pdf", type: .pdf, book: bareBook)
        #expect(NASDestinationRouting.mediaKind(for: item) == .resolved(.ebook))
    }

    @Test func audiobookMagnetUsesAudiobookFolder() {
        let item = candidate(
            url: "magnet:?xt=urn:btih:abc",
            type: .magnet,
            book: audiobookBook,
        )
        #expect(NASDestinationRouting.mediaKind(for: item) == .resolved(.audiobook))
        #expect(
            NASDestinationRouting.destination(for: item, kind: .audiobook, settings: settings())
                == .success("/media/audiobooks")
        )
    }

    @Test func ebookMagnetUsesEbookFolder() {
        let item = candidate(
            url: "magnet:?xt=urn:btih:abc",
            type: .magnet,
            book: ebookBook,
        )
        #expect(NASDestinationRouting.mediaKind(for: item) == .resolved(.ebook))
        #expect(
            NASDestinationRouting.destination(for: item, kind: .ebook, settings: settings())
                == .success("/media/books")
        )
    }

    @Test func zipUsesRequestedMediaType() {
        let audioZip = candidate(
            url: "https://files.example/hobbit.zip",
            type: .zip,
            book: audiobookBook,
        )
        let ebookZip = candidate(
            url: "https://files.example/hobbit.zip",
            type: .zip,
            book: ebookBook,
        )
        #expect(NASDestinationRouting.mediaKind(for: audioZip) == .resolved(.audiobook))
        #expect(NASDestinationRouting.mediaKind(for: ebookZip) == .resolved(.ebook))
    }

    @Test func ambiguousZipPromptsInsteadOfGuessing() {
        let item = candidate(
            url: "https://files.example/hobbit.zip",
            type: .zip,
            book: bareBook,
            mime: "application/octet-stream",
        )
        #expect(NASDestinationRouting.mediaKind(for: item) == .needsChoice)
        let preview = NASHandoffPreview.make(candidate: item, settings: settings())
        #expect(preview.needsMediaTypeChoice)
        #expect(!preview.canSubmit)
    }

    @Test func requestedMediaTypeBeatsDetectedFileType() {
        let item = candidate(
            url: "https://files.example/odd.epub",
            type: .epub,
            book: audiobookBook,
        )
        #expect(NASDestinationRouting.mediaKind(for: item) == .resolved(.audiobook))
    }

    @Test func emptyDestinationIsRejected() {
        let item = candidate(url: "https://files.example/hobbit.epub", type: .epub, book: bareBook)
        #expect(
            NASDestinationRouting.destination(
                for: item,
                kind: .ebook,
                settings: settings(ebook: "  "),
            ) == .failure(.emptyDestination)
        )
    }

    @Test func destinationStaysUnderConfiguredRoot() {
        let item = candidate(url: "https://files.example/hobbit.m4b", type: .m4b, book: bareBook)
        let result = NASDestinationRouting.destination(
            for: item,
            kind: .audiobook,
            settings: settings(subfolders: true),
        )
        guard case .success(let path) = result else {
            Issue.record("expected a path")
            return
        }
        #expect(NASPathSafety.staysWithin(root: "/media/audiobooks", path: path))
        #expect(path.hasPrefix("/media/audiobooks/"))
        #expect(!path.contains(".."))
    }

    @Test func unsafeTitleDoesNotTraverse() {
        let book = ManualSearchBookContext(
            title: "../../etc/passwd",
            authors: ["..\\..\\secret"],
        )
        let item = candidate(url: "https://files.example/hobbit.epub", type: .epub, book: book)
        let result = NASDestinationRouting.destination(
            for: item,
            kind: .ebook,
            settings: settings(subfolders: true),
        )
        guard case .success(let path) = result else {
            Issue.record("expected a sanitized path")
            return
        }
        #expect(NASPathSafety.staysWithin(root: "/media/books", path: path))
        #expect(!path.contains(".."))
        #expect(!path.contains("/etc/"))
        #expect(path.hasPrefix("/media/books/"))
    }

    @Test func invalidBaseWithTraversalIsRejected() {
        #expect(NASPathSafety.normalizeBase("/media/books/../etc") == nil)
        #expect(
            NASPathSafety.join(base: "/media/books/../etc", title: "The Hobbit")
                == .failure(.invalidBase)
        )
    }

    @Test func torrentWithoutContextPrompts() {
        let item = candidate(
            url: "https://files.example/hobbit.torrent",
            type: .torrent,
            book: bareBook,
        )
        #expect(NASDestinationRouting.mediaKind(for: item) == .needsChoice)
    }
}

@Suite("NAS backend routing")
struct NASBackendRoutingTests {
    @Test func magnetGoesToPreferredTorrentClient() {
        let qb = NASDownloadSettingsSnapshot(
            torrentClient: .qbittorrent,
            qbittorrentBaseURL: "http://qb.example:8080",
            synologyBaseURL: "http://nas.example:5000",
            synologyUsername: "josh",
        )
        #expect(NASBackendRouting.backend(transport: .magnet, settings: qb) == .success(.qbittorrent))
        #expect(NASBackendRouting.backend(transport: .torrent, settings: qb) == .success(.qbittorrent))
        #expect(NASBackendRouting.backend(transport: .directHTTP, settings: qb) == .success(.synology))
    }

    @Test func magnetDoesNotUseSynologyUpload() {
        let deluge = NASDownloadSettingsSnapshot(
            torrentClient: .deluge,
            delugeBaseURL: "http://deluge.example:8112",
            synologyBaseURL: "http://nas.example:5000",
            synologyUsername: "josh",
        )
        #expect(NASBackendRouting.backend(transport: .magnet, settings: deluge) == .success(.deluge))
        #expect(NASBackendRouting.backend(transport: .directHTTP, settings: deluge) == .success(.synology))
    }

    @Test func missingTorrentClientFailsCleanly() {
        let none = NASDownloadSettingsSnapshot(
            torrentClient: .none,
            synologyBaseURL: "http://nas.example:5000",
            synologyUsername: "josh",
        )
        #expect(NASBackendRouting.backend(transport: .magnet, settings: none) == .failure(.torrentClientNotSelected))
    }

    @Test func defaultFoldersAreTheSynologyVolumePaths() {
        let defaults = NASDownloadSettingsSnapshot()
        #expect(defaults.audiobookFolder == "/volume1/data/media/books/audiobooks")
        #expect(defaults.ebookFolder == "/volume1/data/media/books/books")
        #expect(defaults.delugeIncomingFolder == "/volume1/data/torrents/incoming")
        #expect(defaults.delugeCompletedFolder == "/volume1/data/torrents/completed")
        let epub = ManualAcquisitionCandidate(
            sourceURL: URL(string: "https://files.example/hobbit.epub")!,
            detectedType: .epub,
            bookMetadata: ManualSearchBookContext(title: "The Hobbit"),
        )
        let m4b = ManualAcquisitionCandidate(
            sourceURL: URL(string: "https://files.example/hobbit.m4b")!,
            detectedType: .m4b,
            bookMetadata: ManualSearchBookContext(title: "The Hobbit"),
        )
        #expect(
            NASDestinationRouting.destination(for: epub, kind: .ebook, settings: defaults)
                == .success("/volume1/data/media/books/books")
        )
        #expect(
            NASDestinationRouting.destination(for: m4b, kind: .audiobook, settings: defaults)
                == .success("/volume1/data/media/books/audiobooks")
        )
    }
}

@Suite("Synology path mapping")
struct SynologyPathMappingTests {
    @Test func volumePathBecomesShareRelative() {
        guard case .success(let mapped) = SynologyPathMapping.resolve(
            "/volume1/data/media/books/books"
        )
        else {
            Issue.record("expected mapping")
            return
        }
        #expect(mapped.volumePath == "/volume1/data/media/books/books")
        #expect(mapped.fileStationPath == "/data/media/books/books")
        #expect(mapped.shareName == "data")
    }

    @Test func audiobookVolumePathMaps() {
        guard case .success(let mapped) = SynologyPathMapping.resolve(
            "/volume1/data/media/books/audiobooks"
        )
        else {
            Issue.record("expected mapping")
            return
        }
        #expect(mapped.fileStationPath == "/data/media/books/audiobooks")
        #expect(mapped.shareName == "data")
    }

    @Test func alreadyShareRelativePathIsKept() {
        guard case .success(let mapped) = SynologyPathMapping.resolve("/media/books/books") else {
            Issue.record("expected mapping")
            return
        }
        #expect(mapped.fileStationPath == "/media/books/books")
        #expect(mapped.shareName == "media")
    }
}
