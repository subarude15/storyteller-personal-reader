//
//  TorBoxarrManualRouting.swift
//  SilveranKit
//
//  Which completed-folder entry belongs to one TorBoxarr torrent.
//  TorBoxarr reports content_path / save_path in the container namespace;
//  File Station moves use the Synology host path for the same relative child.
//  Never the whole completed directory, and never a sibling torrent.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Outcome of matching a submitted magnet to TorBoxarr’s qBittorrent `hash` (PublicID).
public enum TorBoxarrPublicIDResolution: Equatable, Sendable {
    case resolved(String)
    case notFound
    case ambiguous
}

/// Locate TorBoxarr’s PublicID by magnet identity — never by display name alone.
public enum TorBoxarrJobIdentity {
    /// Match `magnet_uri` BTIH identity against the submitted magnet.
    /// Multiple rows with the same PublicID collapse to one; distinct PublicIDs are ambiguous.
    public static func resolve(
        torrents: [QBittorrentTorrentSnapshot],
        magnetURI: String,
    ) -> TorBoxarrPublicIDResolution {
        guard let wanted = TorrentHash.fromMagnet(magnetURI) else { return .notFound }
        var publicIDs = Set<String>()
        for torrent in torrents {
            guard let reported = torrent.magnetURI,
                let identity = TorrentHash.fromMagnet(reported),
                identity == wanted
            else { continue }
            let id = torrent.hash.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            publicIDs.insert(id)
        }
        if publicIDs.isEmpty { return .notFound }
        if publicIDs.count == 1, let only = publicIDs.first { return .resolved(only) }
        return .ambiguous
    }
}

public enum TorBoxarrPayloadLocator {
    public struct Item: Equatable, Sendable {
        public var name: String
        /// Synology host volume path of the one file or top-level folder to move.
        public var sourceVolumePath: String

        public init(name: String, sourceVolumePath: String) {
            self.name = name
            self.sourceVolumePath = sourceVolumePath
        }
    }

    /// Prefer `content_path`, then `save_path` + torrent `name`, then `torrents/files`.
    ///
    /// - `apiCompletedFolder`: TorBoxarr container root (e.g. `/data/completed`) used to
    ///   interpret qBittorrent `content_path` / `save_path`.
    /// - `hostCompletedFolder`: Synology host root (e.g. `/volume1/data/torrents/completed`)
    ///   used to build File Station `sourceVolumePath`.
    public static func items(
        contentPath: String?,
        savePath: String?,
        torrentName: String?,
        fileNames: [String],
        apiCompletedFolder: String,
        hostCompletedFolder: String,
    ) -> [Item] {
        guard let apiRoot = NASPathSafety.normalizeBase(apiCompletedFolder),
            let hostRoot = NASPathSafety.normalizeBase(hostCompletedFolder)
        else { return [] }
        if let content = nonempty(contentPath) {
            if let item = childItem(path: content, apiRoot: apiRoot, hostRoot: hostRoot) {
                return [item]
            }
            return fileItems(fileNames, hostRoot: hostRoot)
        }
        if let item = namedItem(
            savePath: savePath,
            torrentName: torrentName,
            apiRoot: apiRoot,
            hostRoot: hostRoot,
        ) {
            return [item]
        }
        return fileItems(fileNames, hostRoot: hostRoot)
    }

    /// Container completed root for interpreting TorBoxarr status paths.
    /// Prefers `save_path` when it is a valid parent of `content_path`, or equals
    /// `content_path` (multifile at the completed root); otherwise the configured fallback.
    public static func apiCompletedRoot(
        savePath: String?,
        contentPath: String?,
        fallback: String = TorBoxarrConnectionSettings.apiCompletedFolder,
    ) -> String {
        let fallbackRoot = NASPathSafety.normalizeBase(fallback)
            ?? TorBoxarrConnectionSettings.apiCompletedFolder
        guard let save = NASPathSafety.normalizeBase(savePath ?? ""), !save.isEmpty else {
            return fallbackRoot
        }
        if let content = NASPathSafety.normalizeBase(contentPath ?? ""), !content.isEmpty {
            if content != save, NASPathSafety.staysWithin(root: save, path: content) {
                return save
            }
            if content == save {
                return save
            }
            return fallbackRoot
        }
        return save
    }

    private static func childItem(path raw: String, apiRoot: String, hostRoot: String) -> Item? {
        guard let path = NASPathSafety.normalizeBase(raw),
            path != apiRoot,
            NASPathSafety.staysWithin(root: apiRoot, path: path)
        else { return nil }
        let relative = String(path.dropFirst(apiRoot.count + 1))
        guard let name = firstComponent(relative) else { return nil }
        return item(name: name, hostRoot: hostRoot)
    }

    private static func namedItem(
        savePath: String?,
        torrentName: String?,
        apiRoot: String,
        hostRoot: String,
    ) -> Item? {
        guard let name = singleComponent(torrentName),
            let save = NASPathSafety.normalizeBase(savePath ?? ""),
            save == apiRoot || NASPathSafety.staysWithin(root: apiRoot, path: save)
        else { return nil }
        if save != apiRoot, (save as NSString).lastPathComponent == name {
            return item(name: name, hostRoot: hostRoot)
        }
        guard save == apiRoot else { return nil }
        return item(name: name, hostRoot: hostRoot)
    }

    private static func fileItems(_ fileNames: [String], hostRoot: String) -> [Item] {
        var seen: Set<String> = []
        var result: [Item] = []
        for raw in fileNames {
            guard let name = firstComponent(raw), seen.insert(name).inserted else { continue }
            guard let item = item(name: name, hostRoot: hostRoot) else { continue }
            result.append(item)
        }
        return result
    }

    private static func item(name: String, hostRoot: String) -> Item? {
        let source = hostRoot + "/" + name
        guard let normalized = NASPathSafety.normalizeBase(source),
            normalized != hostRoot,
            NASPathSafety.staysWithin(root: hostRoot, path: normalized),
            (normalized as NSString).lastPathComponent == name
        else { return nil }
        return Item(name: name, sourceVolumePath: normalized)
    }

    private static func nonempty(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func singleComponent(_ raw: String?) -> String? {
        guard let text = nonempty(raw), !text.contains("/"), !text.contains("\\") else { return nil }
        return firstComponent(text)
    }

    private static func firstComponent(_ raw: String) -> String? {
        let name = raw.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        guard !name.isEmpty, name != ".", name != "..", !name.contains("\0") else { return nil }
        return name
    }
}
