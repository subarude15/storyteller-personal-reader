//
//  NASLibraryPathMigrationTests.swift
//  SilveranTests
//
//  Correct Storyteller library defaults and migrate only the known wrong ones.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit
import Testing

@Suite("NAS library path defaults and migration")
struct NASLibraryPathMigrationTests {
    @Test func defaultEbookFolderIsStorytellerDataMediaBooks() {
        #expect(
            NASDownloadSettingsSnapshot.defaultEbookFolder
                == "/volume1/data/media/books/books"
        )
        #expect(NASDownloadSettingsSnapshot().ebookFolder == "/volume1/data/media/books/books")
    }

    @Test func defaultAudiobookFolderIsStorytellerDataMediaAudiobooks() {
        #expect(
            NASDownloadSettingsSnapshot.defaultAudiobookFolder
                == "/volume1/data/media/books/audiobooks"
        )
        #expect(
            NASDownloadSettingsSnapshot().audiobookFolder
                == "/volume1/data/media/books/audiobooks"
        )
    }

    @Test func oldExactDefaultEbookPathMigrates() {
        #expect(
            NASDownloadSettingsSnapshot.migrateLegacyLibraryFolder(
                "/volume1/media/books/books"
            ) == "/volume1/data/media/books/books"
        )
        var snapshot = NASDownloadSettingsSnapshot(
            audiobookFolder: "/custom/audio",
            ebookFolder: "/volume1/media/books/books",
        )
        snapshot.migrateLegacyDefaultLibraryFolders()
        #expect(snapshot.ebookFolder == "/volume1/data/media/books/books")
        #expect(snapshot.audiobookFolder == "/custom/audio")
    }

    @Test func oldExactDefaultAudiobookPathMigrates() {
        #expect(
            NASDownloadSettingsSnapshot.migrateLegacyLibraryFolder(
                "/volume1/media/books/audiobooks"
            ) == "/volume1/data/media/books/audiobooks"
        )
        let migrated = NASDownloadSettingsSnapshot(
            audiobookFolder: "/volume1/media/books/audiobooks",
            ebookFolder: "/custom/ebooks",
        ).migratingLegacyDefaultLibraryFolders()
        #expect(migrated.audiobookFolder == "/volume1/data/media/books/audiobooks")
        #expect(migrated.ebookFolder == "/custom/ebooks")
    }

    @Test func customUserPathsArePreserved() {
        let customEbook = "/volume1/data/media/books/my-ebooks"
        let customAudio = "/share/audiobooks"
        let snapshot = NASDownloadSettingsSnapshot(
            audiobookFolder: customAudio,
            ebookFolder: customEbook,
        ).migratingLegacyDefaultLibraryFolders()
        #expect(snapshot.ebookFolder == customEbook)
        #expect(snapshot.audiobookFolder == customAudio)
        #expect(
            NASDownloadSettingsSnapshot.migrateLegacyLibraryFolder(customEbook) == customEbook
        )
        #expect(
            NASDownloadSettingsSnapshot.migrateLegacyLibraryFolder(customAudio) == customAudio
        )
    }

    @Test func torBoxarrCompletedHostPathRemainsUnchanged() {
        #expect(
            TorBoxarrConnectionSettings.hostCompletedFolder
                == "/volume1/data/torrents/completed"
        )
        #expect(
            NASDownloadSettingsSnapshot.defaultDelugeCompletedFolder
                == "/volume1/data/torrents/completed"
        )
    }

    @Test func torBoxarrAPICompletedPathRemainsUnchanged() {
        #expect(TorBoxarrConnectionSettings.apiCompletedFolder == "/data/completed")
        #expect(
            TorBoxarrConnectionSettings.apiDefaultSavePath
                == TorBoxarrConnectionSettings.apiCompletedFolder
        )
    }

    @Test func finalRoutingForEbookTargetsCorrectedEbookPath() {
        let defaults = NASDownloadSettingsSnapshot()
        let epub = ManualAcquisitionCandidate(
            sourceURL: URL(string: "https://files.example/hobbit.epub")!,
            detectedType: .epub,
            bookMetadata: ManualSearchBookContext(
                title: "The Hobbit",
                requestedMediaType: .ebook,
            ),
        )
        #expect(
            NASDestinationRouting.destination(for: epub, kind: .ebook, settings: defaults)
                == .success("/volume1/data/media/books/books")
        )
        #expect(defaults.folder(for: .ebook) == "/volume1/data/media/books/books")
    }

    @Test func finalRoutingForAudiobookTargetsCorrectedAudiobookPath() {
        let defaults = NASDownloadSettingsSnapshot()
        let m4b = ManualAcquisitionCandidate(
            sourceURL: URL(string: "https://files.example/hobbit.m4b")!,
            detectedType: .m4b,
            bookMetadata: ManualSearchBookContext(
                title: "The Hobbit",
                requestedMediaType: .audiobook,
            ),
        )
        #expect(
            NASDestinationRouting.destination(for: m4b, kind: .audiobook, settings: defaults)
                == .success("/volume1/data/media/books/audiobooks")
        )
        #expect(defaults.folder(for: .audiobook) == "/volume1/data/media/books/audiobooks")
    }

    @Test func syncedLegacyDefaultsMigrateWithoutRewritingCustomPaths() {
        var document = SyncedAppSettings(schemaVersion: 3)
        document.integrations.nasDownloads.ebookFolder = TimestampedSetting(
            value: "/volume1/media/books/books",
            modifiedAt: Date(timeIntervalSince1970: 100),
        )
        document.integrations.nasDownloads.audiobookFolder = TimestampedSetting(
            value: "/volume1/custom/audiobooks",
            modifiedAt: Date(timeIntervalSince1970: 100),
        )
        let migrated = SettingsSyncMerge.migrateLegacyNASLibraryFolders(
            document,
            at: Date(timeIntervalSince1970: 200),
        )
        #expect(
            migrated.integrations.nasDownloads.ebookFolder?.value
                == "/volume1/data/media/books/books"
        )
        #expect(
            migrated.integrations.nasDownloads.audiobookFolder?.value
                == "/volume1/custom/audiobooks"
        )
        #expect(
            migrated.integrations.nasDownloads.audiobookFolder?.modifiedAt
                == Date(timeIntervalSince1970: 100)
        )
        let applied = SettingsSyncApply.nasDownloads(document: migrated)
        #expect(applied.ebookFolder == "/volume1/data/media/books/books")
        #expect(applied.audiobookFolder == "/volume1/custom/audiobooks")

        let again = SettingsSyncMerge.migrateLegacyNASLibraryFolders(
            migrated,
            at: Date(timeIntervalSince1970: 300),
        )
        #expect(again == migrated)
    }
}
