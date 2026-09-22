//
//  TorBoxMediaFileSelection.swift
//  SilveranKit
//
//  Choose transferable TorBox files for NAS Phase 2. Junk is ignored, not deleted.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct TorBoxSelectedFile: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var size: Int64?
    public var relativePath: String

    public init(id: String, name: String, size: Int64? = nil, relativePath: String? = nil) {
        self.id = id
        self.name = name
        self.size = size
        self.relativePath = relativePath ?? name
    }
}

public enum TorBoxMediaFileSelection {
    public static let ebookExtensions: Set<String> = [
        "epub", "pdf", "mobi", "azw", "azw3", "cbz", "cbr",
    ]
    public static let audiobookExtensions: Set<String> = [
        "m4b", "m4a", "mp3", "flac", "ogg", "opus",
    ]
    public static let archiveExtensions: Set<String> = [
        "zip", "rar", "7z",
    ]
    public static let junkExtensions: Set<String> = [
        "nfo", "txt", "url", "exe", "scr", "jpg", "jpeg", "png", "gif", "bmp",
        "html", "htm", "mht", "lnk", "ds_store",
    ]

    public static func select(
        files: [TorrentJobFile],
        mediaType: NASMediaKind,
    ) -> [TorBoxSelectedFile] {
        let useful = files.compactMap { file -> TorBoxSelectedFile? in
            let name = file.name
            let base = (name as NSString).lastPathComponent
            guard !isJunk(base) else { return nil }
            let ext = extensionOf(base)
            if archiveExtensions.contains(ext) {
                // Archives are not auto-extracted in Phase 2.
                return nil
            }
            switch mediaType {
                case .ebook:
                    guard ebookExtensions.contains(ext) else { return nil }
                case .audiobook:
                    guard audiobookExtensions.contains(ext) else { return nil }
            }
            return TorBoxSelectedFile(
                id: file.id,
                name: base,
                size: file.size,
                relativePath: preserveRelativePath(name),
            )
        }

        switch mediaType {
            case .ebook:
                // Prefer a single best ebook (epub > others by size among preferred ext).
                if let preferred = preferredEbook(in: useful) {
                    return [preferred]
                }
                return useful
            case .audiobook:
                // Keep multi-track folders together; drop cover-only leftovers already.
                return useful.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        }
    }

    public static func unsupportedArchiveNames(in files: [TorrentJobFile]) -> [String] {
        files.compactMap { file in
            let base = (file.name as NSString).lastPathComponent
            let ext = extensionOf(base)
            return archiveExtensions.contains(ext) ? base : nil
        }
    }

    private static func preferredEbook(in files: [TorBoxSelectedFile]) -> TorBoxSelectedFile? {
        let preference = ["epub", "mobi", "azw3", "azw", "pdf", "cbz", "cbr"]
        for ext in preference {
            if let match = files.first(where: { extensionOf($0.name) == ext }) {
                return match
            }
        }
        return files.max { ($0.size ?? 0) < ($1.size ?? 0) }
    }

    private static func isJunk(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        if lower.contains("sample") { return true }
        if lower.hasPrefix(".") { return true }
        let ext = extensionOf(filename)
        if junkExtensions.contains(ext) { return true }
        return false
    }

    private static func extensionOf(_ filename: String) -> String {
        ((filename as NSString).pathExtension).lowercased()
    }

    /// Keep nested paths under the torrent folder, but strip leading "./".
    private static func preserveRelativePath(_ raw: String) -> String {
        var path = raw.replacingOccurrences(of: "\\", with: "/")
        while path.hasPrefix("./") { path = String(path.dropFirst(2)) }
        while path.hasPrefix("/") { path.removeFirst() }
        let parts = path.split(separator: "/").map { NASPathSafety.sanitizeComponent(String($0)) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? NASPathSafety.sanitizeComponent((raw as NSString).lastPathComponent) : parts.joined(separator: "/")
    }
}
