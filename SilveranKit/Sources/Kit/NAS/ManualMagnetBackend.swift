//
//  ManualMagnetBackend.swift
//  SilveranKit
//
//  Manual magnet screen choice: TorBox (TorBoxarr qBittorrent bridge) or Deluge.
//  Non-secret preferences live in UserDefaults. The password stays in the keychain.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Where a manual magnet is sent. TorBox is the fresh-install default.
public enum ManualDownloadBackend: String, Codable, CaseIterable, Sendable, Identifiable {
    case torBox
    case deluge

    public var id: String { rawValue }

    public var label: String {
        switch self {
            case .torBox: "TorBox"
            case .deluge: "Deluge"
        }
    }
}

public enum ManualMagnetCopy {
    public static func submitting(_ backend: ManualDownloadBackend) -> String {
        "Submitting to \(backend.label)…"
    }

    public static func accepted(_ backend: ManualDownloadBackend) -> String {
        switch backend {
            case .torBox: "Accepted by TorBox"
            case .deluge: "Accepted by Deluge"
        }
    }

    public static func failed(_ backend: ManualDownloadBackend) -> String {
        "\(backend.label) submission failed"
    }
}

/// TorBoxarr qBittorrent bridge. The WebUI password is not stored here.
public struct TorBoxarrConnectionSettings: Equatable, Sendable {
    public static let defaultHost = "192.168.1.2"
    public static let defaultPort = 8085
    public static let defaultUsername = "admin"
    /// TorBoxarr drops completed payloads here. This is not the library folder.
    public static let completedFolder = "/volume1/data/torrents/completed"

    public var host: String
    public var port: Int
    public var username: String

    public init(
        host: String = TorBoxarrConnectionSettings.defaultHost,
        port: Int = TorBoxarrConnectionSettings.defaultPort,
        username: String = TorBoxarrConnectionSettings.defaultUsername,
    ) {
        self.host = host
        self.port = port
        self.username = username
    }

    public static func current(in defaults: UserDefaults? = nil) -> TorBoxarrConnectionSettings {
        TorBoxarrConnectionSettings(
            host: ManualMagnetBackendSettings.host(in: defaults),
            port: ManualMagnetBackendSettings.port(in: defaults),
            username: ManualMagnetBackendSettings.username(in: defaults),
        )
    }

    /// `http://host:port`. A host that already includes a port is left intact.
    public var baseURL: String? {
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = host.lowercased()
        if lower.hasPrefix("https://") {
            host.removeFirst("https://".count)
        } else if lower.hasPrefix("http://") {
            host.removeFirst("http://".count)
        }
        while host.hasSuffix("/") { host.removeLast() }
        guard !host.isEmpty, !host.contains("://"), (1...65535).contains(port) else { return nil }
        if host.contains(":") { return "http://\(host)" }
        return "http://\(host):\(port)"
    }
}

/// Last manual-magnet backend, plus editable TorBoxarr host details.
public enum ManualMagnetBackendSettings {
    public static let backendKey = "punkRally.manualDownload.backend"
    public static let hostKey = "punkRally.torboxarr.host"
    public static let portKey = "punkRally.torboxarr.port"
    public static let usernameKey = "punkRally.torboxarr.username"

    public static var store: UserDefaults = .standard

    public static func backend(in defaults: UserDefaults? = nil) -> ManualDownloadBackend {
        let defaults = defaults ?? store
        guard let raw = defaults.string(forKey: backendKey),
            let value = ManualDownloadBackend(rawValue: raw)
        else { return .torBox }
        return value
    }

    public static func setBackend(_ backend: ManualDownloadBackend, in defaults: UserDefaults? = nil) {
        (defaults ?? store).set(backend.rawValue, forKey: backendKey)
    }

    public static func host(in defaults: UserDefaults? = nil) -> String {
        let stored = (defaults ?? store).string(forKey: hostKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? TorBoxarrConnectionSettings.defaultHost : stored
    }

    public static func setHost(_ host: String, in defaults: UserDefaults? = nil) {
        (defaults ?? store).set(host, forKey: hostKey)
    }

    public static func port(in defaults: UserDefaults? = nil) -> Int {
        let defaults = defaults ?? store
        guard let value = defaults.object(forKey: portKey) as? Int, (1...65535).contains(value) else {
            return TorBoxarrConnectionSettings.defaultPort
        }
        return value
    }

    public static func setPort(_ port: Int, in defaults: UserDefaults? = nil) {
        (defaults ?? store).set(port, forKey: portKey)
    }

    public static func username(in defaults: UserDefaults? = nil) -> String {
        let stored = (defaults ?? store).string(forKey: usernameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? TorBoxarrConnectionSettings.defaultUsername : stored
    }

    public static func setUsername(_ username: String, in defaults: UserDefaults? = nil) {
        (defaults ?? store).set(username, forKey: usernameKey)
    }
}

public enum TorBoxarrProbe {
    /// Login, then read `/api/v2/app/version`. Does not add a torrent.
    public static func testConnection(
        settings: TorBoxarrConnectionSettings,
        password: String,
        client: QBittorrentClient = QBittorrentClient(),
    ) async -> QBittorrentConnection {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .authenticationFailed }
        guard let base = settings.baseURL, !settings.username.trimmingCharacters(in: .whitespaces).isEmpty
        else { return .invalidURL }
        do {
            _ = try await client.appVersion(
                baseURL: base,
                username: settings.username,
                password: trimmed,
            )
            return .ok
        } catch let error as QBittorrentClientError {
            return error.connection
        } catch let error as URLError {
            switch error.code {
                case .timedOut: return .timeout
                default: return .cannotReachServer
            }
        } catch {
            return .invalidResponse
        }
    }
}
