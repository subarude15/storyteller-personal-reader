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
    case aria2

    public var label: String {
        switch self {
            case .qbittorrent: "qBittorrent"
            case .deluge: "Deluge"
            case .aria2: "aria2"
        }
    }
}

public struct NASDownloadSettingsSnapshot: Equatable, Sendable {
    public var torrentClient: NASTorrentClient
    public var qbittorrentBaseURL: String
    public var qbittorrentUsername: String
    public var delugeBaseURL: String
    public var aria2RPCURL: String
    public var audiobookFolder: String
    public var ebookFolder: String
    public var startAutomatically: Bool
    public var createTitleAuthorSubfolders: Bool

    public init(
        torrentClient: NASTorrentClient = .none,
        qbittorrentBaseURL: String = "",
        qbittorrentUsername: String = "",
        delugeBaseURL: String = "",
        aria2RPCURL: String = "",
        audiobookFolder: String = "",
        ebookFolder: String = "",
        startAutomatically: Bool = true,
        createTitleAuthorSubfolders: Bool = false,
    ) {
        self.torrentClient = torrentClient
        self.qbittorrentBaseURL = qbittorrentBaseURL
        self.qbittorrentUsername = qbittorrentUsername
        self.delugeBaseURL = delugeBaseURL
        self.aria2RPCURL = aria2RPCURL
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

    public var trimmedAria2RPCURL: String {
        aria2RPCURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedAudiobookFolder: String {
        audiobookFolder.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var trimmedEbookFolder: String {
        ebookFolder.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isAria2Configured: Bool {
        !trimmedAria2RPCURL.isEmpty
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
