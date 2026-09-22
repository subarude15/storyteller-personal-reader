//
//  TorBoxarrManualRouting.swift
//  SilveranKit
//
//  Which completed-folder entry belongs to one TorBoxarr torrent.
//  Never the whole completed directory, and never a sibling torrent.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum TorBoxarrPayloadLocator {
    public struct Item: Equatable, Sendable {
        public var name: String
        /// Volume path of the one file or top-level folder to move.
        public var sourceVolumePath: String

        public init(name: String, sourceVolumePath: String) {
            self.name = name
            self.sourceVolumePath = sourceVolumePath
        }
    }

    /// Prefer `content_path`, then `save_path` + torrent `name`, then `torrents/files`.
    /// Paths outside the completed folder are not guessed from a magnet display name.
    public static func items(
        contentPath: String?,
        savePath: String?,
        torrentName: String?,
        fileNames: [String],
        completedFolder: String,
    ) -> [Item] {
        guard let completed = NASPathSafety.normalizeBase(completedFolder) else { return [] }
        if let content = nonempty(contentPath) {
            if let item = childItem(path: content, completed: completed) {
                return [item]
            }
            return fileItems(fileNames, completed: completed)
        }
        if let item = namedItem(savePath: savePath, torrentName: torrentName, completed: completed) {
            return [item]
        }
        return fileItems(fileNames, completed: completed)
    }

    private static func childItem(path raw: String, completed: String) -> Item? {
        guard let path = NASPathSafety.normalizeBase(raw),
            path != completed,
            NASPathSafety.staysWithin(root: completed, path: path)
        else { return nil }
        let relative = String(path.dropFirst(completed.count + 1))
        guard let name = firstComponent(relative) else { return nil }
        return item(name: name, completed: completed)
    }

    private static func namedItem(savePath: String?, torrentName: String?, completed: String) -> Item? {
        guard let name = singleComponent(torrentName),
            let save = NASPathSafety.normalizeBase(savePath ?? ""),
            save == completed || NASPathSafety.staysWithin(root: completed, path: save)
        else { return nil }
        if save != completed, (save as NSString).lastPathComponent == name {
            return item(name: name, completed: completed)
        }
        guard save == completed else { return nil }
        return item(name: name, completed: completed)
    }

    private static func fileItems(_ fileNames: [String], completed: String) -> [Item] {
        var seen: Set<String> = []
        var result: [Item] = []
        for raw in fileNames {
            guard let name = firstComponent(raw), seen.insert(name).inserted else { continue }
            guard let item = item(name: name, completed: completed) else { continue }
            result.append(item)
        }
        return result
    }

    private static func item(name: String, completed: String) -> Item? {
        let source = completed + "/" + name
        guard let normalized = NASPathSafety.normalizeBase(source),
            normalized != completed,
            NASPathSafety.staysWithin(root: completed, path: normalized),
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
