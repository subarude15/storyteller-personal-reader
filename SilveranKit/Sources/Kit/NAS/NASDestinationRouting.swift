//
//  NASDestinationRouting.swift
//  SilveranKit
//
//  Audiobook vs eBook folder selection and path safety for NAS handoff.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum NASMediaKind: String, Codable, Sendable, CaseIterable {
    case ebook
    case audiobook

    public var label: String {
        switch self {
            case .ebook: "eBook"
            case .audiobook: "Audiobook"
        }
    }

    public static func from(_ type: ManualSearchMediaType) -> NASMediaKind {
        switch type {
            case .ebook: .ebook
            case .audiobook: .audiobook
        }
    }
}

public enum NASDestinationResolution: Equatable, Sendable {
    case resolved(NASMediaKind)
    case needsChoice
}

public enum NASDestinationError: Error, Equatable, Sendable {
    case emptyDestination
    case escapedRoot
    case invalidBase
}

public enum NASDestinationRouting {
    public static func mediaKind(
        for candidate: ManualAcquisitionCandidate,
        override: NASMediaKind? = nil,
    ) -> NASDestinationResolution {
        if let override { return .resolved(override) }
        if let requested = candidate.bookMetadata.requestedMediaType {
            return .resolved(NASMediaKind.from(requested))
        }
        if let fromType = mediaKind(detected: candidate.detectedType) {
            return .resolved(fromType)
        }
        if let fromMIME = mediaKind(mimeType: candidate.mimeType) {
            return .resolved(fromMIME)
        }
        return .needsChoice
    }

    public static func mediaKind(detected type: ManualAcquisitionDetectedType) -> NASMediaKind? {
        switch type {
            case .m4b, .mp3, .m4a, .flac:
                return .audiobook
            case .epub, .pdf, .mobi, .azw, .azw3, .cbz, .cbr:
                return .ebook
            case .zip, .torrent, .magnet:
                return nil
        }
    }

    public static func mediaKind(mimeType: String?) -> NASMediaKind? {
        guard let mimeType else { return nil }
        let normalized = mimeType.split(separator: ";").first
            .map { String($0).trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if normalized.hasPrefix("audio/") { return .audiobook }
        if normalized == "application/octet-stream" { return nil }
        return nil
    }

    public static func destination(
        for candidate: ManualAcquisitionCandidate,
        kind: NASMediaKind,
        settings: NASDownloadSettingsSnapshot,
    ) -> Result<String, NASDestinationError> {
        let base = settings.folder(for: kind)
        guard !base.isEmpty else { return .failure(.emptyDestination) }
        let author = settings.createTitleAuthorSubfolders ? candidate.bookMetadata.authorDisplay : nil
        let title = settings.createTitleAuthorSubfolders ? candidate.bookMetadata.title : nil
        return NASPathSafety.join(
            base: base,
            author: author,
            title: title,
        )
    }
}

public enum NASBackendRouting {
    public static func backend(
        transport: ManualAcquisitionTransportKind,
        settings: NASDownloadSettingsSnapshot,
    ) -> Result<NASDownloadBackend, NASHandoffError> {
        switch transport {
            case .magnet, .torrent:
                switch settings.torrentClient {
                    case .torbox:
                        if !settings.torboxEnabled {
                            return .failure(.backendNotConfigured(.torbox))
                        }
                        return .success(.torbox)
                    case .qbittorrent:
                        if settings.trimmedQBittorrentBaseURL.isEmpty {
                            return .failure(.backendNotConfigured(.qbittorrent))
                        }
                        return .success(.qbittorrent)
                    case .deluge:
                        if settings.trimmedDelugeBaseURL.isEmpty {
                            return .failure(.backendNotConfigured(.deluge))
                        }
                        return .success(.deluge)
                    case .none:
                        return .failure(.torrentClientNotSelected)
                }
            case .directHTTP:
                if settings.isSynologyConfigured {
                    return .success(.synology)
                }
                return .failure(.backendNotConfigured(.synology))
        }
    }
}

/// `/volume1/data/media/books/books` is a DSM volume path. File Station wants
/// `/data/media/books/books` (share-relative). qBittorrent/Deluge keep the volume path.
public struct SynologyFileStationPath: Equatable, Sendable {
    public var volumePath: String
    public var fileStationPath: String
    public var shareName: String

    public init(volumePath: String, fileStationPath: String, shareName: String) {
        self.volumePath = volumePath
        self.fileStationPath = fileStationPath
        self.shareName = shareName
    }
}

public enum SynologyPathMapping {
    public static func resolve(_ raw: String) -> Result<SynologyFileStationPath, NASDestinationError> {
        guard let normalized = NASPathSafety.normalizeBase(raw) else {
            return .failure(
                raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? .emptyDestination
                    : .invalidBase
            )
        }
        let fileStation: String
        if let stripped = stripVolumePrefix(normalized) {
            fileStation = stripped
        } else {
            fileStation = normalized
        }
        guard fileStation.hasPrefix("/"), fileStation.count > 1 else {
            return .failure(.invalidBase)
        }
        let parts = fileStation.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let share = parts.first, !share.isEmpty, share != ".." else {
            return .failure(.invalidBase)
        }
        return .success(
            SynologyFileStationPath(
                volumePath: normalized,
                fileStationPath: fileStation,
                shareName: share,
            )
        )
    }

    public static func filePath(directory: String, filename: String) -> Result<String, NASDestinationError> {
        let safe = NASPathSafety.sanitizeComponent(filename)
        guard !safe.isEmpty else { return .failure(.invalidBase) }
        switch resolve(directory) {
            case .failure(let error):
                return .failure(error)
            case .success(let mapped):
                let joined = mapped.fileStationPath + "/" + safe
                guard NASPathSafety.staysWithin(root: mapped.fileStationPath, path: joined) else {
                    return .failure(.escapedRoot)
                }
                return .success(joined)
        }
    }

    private static func stripVolumePrefix(_ path: String) -> String? {
        let pattern = #"^/volume\d+(/.*)?$"#
        guard path.range(of: pattern, options: .regularExpression) != nil else { return nil }
        guard let slash = path.dropFirst().firstIndex(of: "/") else { return nil }
        let remainder = String(path[slash...])
        return remainder.isEmpty ? nil : remainder
    }
}

public enum NASPathSafety {
    public static func sanitizeComponent(_ raw: String) -> String {
        var scalars: [Character] = []
        for character in raw {
            if character == "/" || character == "\\" || character == ":" {
                scalars.append("-")
                continue
            }
            guard let scalar = character.unicodeScalars.first else { continue }
            if character.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) {
                continue
            }
            if scalar == "\0" { continue }
            scalars.append(character)
        }
        var cleaned = String(scalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if cleaned == "." || cleaned == ".." {
            cleaned = ""
        }
        while cleaned.contains("..") {
            cleaned = cleaned.replacingOccurrences(of: "..", with: "")
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func normalizeBase(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("\0") { return nil }
        text = text.replacingOccurrences(of: "\\", with: "/")
        while text.contains("//") {
            text = text.replacingOccurrences(of: "//", with: "/")
        }
        if text.count > 1, text.hasSuffix("/") {
            text.removeLast()
        }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.contains(where: { $0 == ".." }) { return nil }
        return text
    }

    public static func staysWithin(root: String, path: String) -> Bool {
        guard let normalizedRoot = normalizeBase(root), let normalizedPath = normalizeBase(path)
        else {
            return false
        }
        if normalizedPath == normalizedRoot { return true }
        return normalizedPath.hasPrefix(normalizedRoot + "/")
    }

    public static func join(
        base: String,
        author: String? = nil,
        title: String? = nil,
    ) -> Result<String, NASDestinationError> {
        guard let root = normalizeBase(base) else {
            return .failure(base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .emptyDestination
                : .invalidBase)
        }
        var extras: [String] = []
        if let author {
            let safe = sanitizeComponent(author)
            if !safe.isEmpty { extras.append(safe) }
        }
        if let title {
            let safe = sanitizeComponent(title)
            if !safe.isEmpty { extras.append(safe) }
        }
        let path = extras.isEmpty ? root : root + "/" + extras.joined(separator: "/")
        guard staysWithin(root: root, path: path) else { return .failure(.escapedRoot) }
        return .success(path)
    }
}

public enum NASMagnetValidation {
    public static func isValid(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "magnet" else { return false }
        let text = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.lowercased().contains("xt=")
    }
}
