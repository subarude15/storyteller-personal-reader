//
//  NASDownloadSettings.swift
//  SilveranKit
//
//  Non-secret NAS download preferences. Passwords stay in the keychain.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum NASTorrentClient: String, Codable, Sendable, CaseIterable {
    case none
    case qbittorrent
    case deluge

    public var label: String {
        switch self {
            case .none: "None"
            case .qbittorrent: "qBittorrent"
            case .deluge: "Deluge"
        }
    }
}

public enum NASDownloadBackend: String, Codable, Sendable {
    case qbittorrent
    case deluge
    case synology

    public var label: String {
        switch self {
            case .qbittorrent: "qBittorrent"
            case .deluge: "Deluge"
            case .synology: "Synology"
        }
    }

    public var methodLabel: String {
        switch self {
            case .qbittorrent, .deluge: label
            case .synology: "Download on this device, then upload to NAS"
        }
    }
}

public struct NASDownloadSettingsSnapshot: Equatable, Sendable {
    public static let defaultAudiobookFolder = "/volume1/media/books/audiobooks"
    public static let defaultEbookFolder = "/volume1/media/books/books"

    public var torrentClient: NASTorrentClient
    public var qbittorrentBaseURL: String
    public var qbittorrentUsername: String
    public var delugeBaseURL: String
    public var synologyBaseURL: String
    public var synologyUsername: String
    public var audiobookFolder: String
    public var ebookFolder: String
    public var startAutomatically: Bool
    public var createTitleAuthorSubfolders: Bool

    public init(
        torrentClient: NASTorrentClient = .none,
        qbittorrentBaseURL: String = "",
        qbittorrentUsername: String = "",
        delugeBaseURL: String = "",
        synologyBaseURL: String = "",
        synologyUsername: String = "",
        audiobookFolder: String = NASDownloadSettingsSnapshot.defaultAudiobookFolder,
        ebookFolder: String = NASDownloadSettingsSnapshot.defaultEbookFolder,
        startAutomatically: Bool = true,
        createTitleAuthorSubfolders: Bool = false,
    ) {
        self.torrentClient = torrentClient
        self.qbittorrentBaseURL = qbittorrentBaseURL
        self.qbittorrentUsername = qbittorrentUsername
        self.delugeBaseURL = delugeBaseURL
        self.synologyBaseURL = synologyBaseURL
        self.synologyUsername = synologyUsername
        self.audiobookFolder = audiobookFolder
        self.ebookFolder = ebookFolder
        self.startAutomatically = startAutomatically
        self.createTitleAuthorSubfolders = createTitleAuthorSubfolders
    }

    public static let unset = NASDownloadSettingsSnapshot()

    public var trimmedQBittorrentBaseURL: String {
        qbittorrentBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedDelugeBaseURL: String {
        delugeBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Legacy Deluge URL lives on `SettingsActor.config`. Use it only when this
    /// snapshot has no URL. An explicit synced empty string clears config first,
    /// so this does not resurrect a stale value.
    public func resolvedDelugeBaseURL(configURL: String) -> String {
        if !trimmedDelugeBaseURL.isEmpty { return trimmedDelugeBaseURL }
        return configURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedSynologyBaseURL: String {
        synologyBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedSynologyUsername: String {
        synologyUsername.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedAudiobookFolder: String {
        audiobookFolder.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedEbookFolder: String {
        ebookFolder.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isSynologyConfigured: Bool {
        !trimmedSynologyBaseURL.isEmpty && !trimmedSynologyUsername.isEmpty
    }

    public func folder(for kind: NASMediaKind) -> String {
        switch kind {
            case .audiobook: trimmedAudiobookFolder
            case .ebook: trimmedEbookFolder
        }
    }
}

@MainActor
public final class NASDownloadSettingsStore {
    public static let shared = NASDownloadSettingsStore()

    public private(set) var snapshot: NASDownloadSettingsSnapshot

    public init(journal: SettingsSyncJournal = .live()) {
        if let document = journal.load() {
            snapshot = SettingsSyncApply.nasDownloads(document: document)
        } else {
            snapshot = NASDownloadSettingsSnapshot()
        }
    }

    public func applySynced(_ snapshot: NASDownloadSettingsSnapshot) {
        guard snapshot != self.snapshot else { return }
        self.snapshot = snapshot
        NotificationCenter.default.post(name: .inkampNASDownloadSettingsDidChange, object: nil)
    }

    public func replace(_ snapshot: NASDownloadSettingsSnapshot, at date: Date = Date()) {
        self.snapshot = snapshot
        SettingsSyncCoordinator.shared.noteLocalNASDownloadsChange(snapshot, at: date)
        NotificationCenter.default.post(name: .inkampNASDownloadSettingsDidChange, object: nil)
    }

    public func update(_ mutate: (inout NASDownloadSettingsSnapshot) -> Void) {
        var next = snapshot
        mutate(&next)
        guard next != snapshot else { return }
        replace(next)
    }

    public func setDelugeBaseURL(_ url: String) {
        update { $0.delugeBaseURL = url }
    }
}
