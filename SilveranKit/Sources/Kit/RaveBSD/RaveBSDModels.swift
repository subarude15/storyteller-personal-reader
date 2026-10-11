//
//  RaveBSDModels.swift
//  SilveranKit
//
//  JSON shapes from self-hosted RaveBSD (IdleEndeavor/RaveBSD). Fields are
//  optional because sources omit metadata — never invent values.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum RaveBSDMediaMode: String, Sendable, CaseIterable {
    case ebooks
    case audiobooks

    public init(mediaType: ManualSearchMediaType) {
        switch mediaType {
            case .ebook: self = .ebooks
            case .audiobook: self = .audiobooks
        }
    }

    public var mediaType: ManualSearchMediaType {
        switch self {
            case .ebooks: .ebook
            case .audiobooks: .audiobook
        }
    }

    public var label: String {
        mediaType.label
    }
}

/// How the client can acquire a row. Derived only from fields present on the payload.
public enum RaveBSDAcquisitionMethod: String, Sendable, Equatable {
    case magnet
    case directHTTP
    case unresolved
    case pageOnly

    public var label: String {
        switch self {
            case .magnet: "Magnet"
            case .directHTTP: "Direct download"
            case .unresolved: "Needs resolve"
            case .pageOnly: "Source page"
        }
    }
}

public struct RaveBSDSearchResult: Equatable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var author: String
    public var year: String
    public var format: String
    public var filesize: Int64
    public var language: String
    public var source: String
    public var downloadURL: String
    public var coverURL: String
    public var directURL: String
    public var magnet: String
    public var infoHash: String
    public var md5: String
    public var directFrom: String
    public var directReady: Bool

    public init(
        id: String,
        title: String,
        author: String = "",
        year: String = "",
        format: String = "",
        filesize: Int64 = 0,
        language: String = "",
        source: String = "",
        downloadURL: String = "",
        coverURL: String = "",
        directURL: String = "",
        magnet: String = "",
        infoHash: String = "",
        md5: String = "",
        directFrom: String = "",
        directReady: Bool = false,
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.year = year
        self.format = format
        self.filesize = filesize
        self.language = language
        self.source = source
        self.downloadURL = downloadURL
        self.coverURL = coverURL
        self.directURL = directURL
        self.magnet = magnet
        self.infoHash = infoHash
        self.md5 = md5
        self.directFrom = directFrom
        self.directReady = directReady
    }

    public var acquisitionMethod: RaveBSDAcquisitionMethod {
        if !normalizedMagnet.isEmpty { return .magnet }
        if !normalizedDirectURL.isEmpty { return .directHTTP }
        if !id.isEmpty { return .unresolved }
        if !downloadURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .pageOnly }
        return .pageOnly
    }

    public var canAttemptDownload: Bool {
        switch acquisitionMethod {
            case .magnet, .directHTTP, .unresolved: true
            case .pageOnly: false
        }
    }

    public var normalizedMagnet: String {
        let trimmed = magnet.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix("magnet:") ? trimmed : ""
    }

    public var normalizedDirectURL: String {
        let trimmed = directURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else { return "" }
        return trimmed
    }

    public var formatDisplay: String? {
        let trimmed = format.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return trimmed.uppercased().hasPrefix(".")
            ? String(trimmed.dropFirst()).uppercased()
            : trimmed.uppercased()
    }

    public var filesizeDisplay: String? {
        guard filesize > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: filesize, countStyle: .file)
    }

    public var warning: String? {
        switch acquisitionMethod {
            case .pageOnly:
                return "No direct download link from RaveBSD"
            case .unresolved:
                return "Download link not resolved yet"
            case .magnet, .directHTTP:
                return nil
        }
    }
}

public struct RaveBSDSearchMeta: Equatable, Sendable {
    public var counts: [String: Int]

    public init(counts: [String: Int] = [:]) {
        self.counts = counts
    }

    public var totalReported: Int {
        counts.values.reduce(0, +)
    }
}

public struct RaveBSDSearchResponse: Equatable, Sendable {
    public var source: String
    public var results: [RaveBSDSearchResult]
    public var meta: RaveBSDSearchMeta

    public init(
        source: String = "all",
        results: [RaveBSDSearchResult] = [],
        meta: RaveBSDSearchMeta = RaveBSDSearchMeta(),
    ) {
        self.source = source
        self.results = results
        self.meta = meta
    }
}

public struct RaveBSDResolveResponse: Equatable, Sendable {
    public var id: String
    public var directURL: String
    public var magnet: String
    public var infoHash: String
    public var downloadURL: String
    public var format: String
    public var filesize: Int64
    public var directFrom: String

    public init(
        id: String,
        directURL: String = "",
        magnet: String = "",
        infoHash: String = "",
        downloadURL: String = "",
        format: String = "",
        filesize: Int64 = 0,
        directFrom: String = "",
    ) {
        self.id = id
        self.directURL = directURL
        self.magnet = magnet
        self.infoHash = infoHash
        self.downloadURL = downloadURL
        self.format = format
        self.filesize = filesize
        self.directFrom = directFrom
    }
}

public enum RaveBSDConnectionStatus: Equatable, Sendable {
    case success(host: String, detail: String)
    case unavailable(host: String?, detail: String)
    case timeout(host: String?, detail: String)
    case authOrCloudflare(host: String?, detail: String)
    case invalidEndpoint(detail: String)
    case unsupportedAPIResponse(host: String?, detail: String)

    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    public var title: String {
        switch self {
            case .success: "Connected"
            case .unavailable: "Unavailable"
            case .timeout: "Timed out"
            case .authOrCloudflare: "Auth / Cloudflare Access"
            case .invalidEndpoint: "Invalid endpoint"
            case .unsupportedAPIResponse: "Unsupported API response"
        }
    }

    public var detail: String {
        switch self {
            case .success(_, let detail),
                .unavailable(_, let detail),
                .timeout(_, let detail),
                .authOrCloudflare(_, let detail),
                .unsupportedAPIResponse(_, let detail):
                detail
            case .invalidEndpoint(let detail):
                detail
        }
    }
}

enum RaveBSDJSON {
    static func string(_ any: Any?, fallback: String = "") -> String {
        if let value = any as? String { return value }
        if let value = any as? NSNumber { return value.stringValue }
        return fallback
    }

    static func int64(_ any: Any?) -> Int64 {
        if let value = any as? Int64 { return value }
        if let value = any as? Int { return Int64(value) }
        if let value = any as? Double { return Int64(value) }
        if let value = any as? NSNumber { return value.int64Value }
        if let value = any as? String, let parsed = Int64(value) { return parsed }
        return 0
    }

    static func bool(_ any: Any?) -> Bool {
        if let value = any as? Bool { return value }
        if let value = any as? NSNumber { return value.boolValue }
        if let value = any as? String {
            return value.lowercased() == "true" || value == "1"
        }
        return false
    }
}

public enum RaveBSDResponseParsing {
    public static func search(data: Data) throws -> RaveBSDSearchResponse {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw RaveBSDClientError.unsupportedAPIResponse("Root JSON was not an object")
        }
        if let error = root["error"] as? String, !error.isEmpty,
            (root["results"] as? [Any])?.isEmpty != false
        {
            // Error-only payloads still decode so callers can surface the message.
        }
        let rawResults = root["results"] as? [Any] ?? []
        var results: [RaveBSDSearchResult] = []
        results.reserveCapacity(rawResults.count)
        for (index, item) in rawResults.enumerated() {
            guard let dict = item as? [String: Any] else { continue }
            if let parsed = parseResult(dict, fallbackIndex: index) {
                results.append(parsed)
            }
        }
        var metaCounts: [String: Int] = [:]
        if let meta = root["meta"] as? [String: Any] {
            for (key, value) in meta {
                metaCounts[key] = Int(RaveBSDJSON.int64(value))
            }
        }
        return RaveBSDSearchResponse(
            source: RaveBSDJSON.string(root["source"], fallback: "all"),
            results: results,
            meta: RaveBSDSearchMeta(counts: metaCounts),
        )
    }

    public static func resolve(data: Data) throws -> RaveBSDResolveResponse {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw RaveBSDClientError.unsupportedAPIResponse("Resolve JSON was not an object")
        }
        if let error = root["error"] as? String, !error.isEmpty {
            throw RaveBSDClientError.expiredOrUnknownResult(error)
        }
        let id = RaveBSDJSON.string(root["id"])
        guard !id.isEmpty else {
            throw RaveBSDClientError.unsupportedAPIResponse("Resolve payload missing id")
        }
        return RaveBSDResolveResponse(
            id: id,
            directURL: RaveBSDJSON.string(root["directUrl"]),
            magnet: RaveBSDJSON.string(root["magnet"]),
            infoHash: RaveBSDJSON.string(root["infoHash"]),
            downloadURL: RaveBSDJSON.string(root["downloadUrl"]),
            format: RaveBSDJSON.string(root["format"]),
            filesize: RaveBSDJSON.int64(root["filesize"]),
            directFrom: RaveBSDJSON.string(root["directFrom"]),
        )
    }

    public static func isHealthOK(_ data: Data, status: Int) -> Bool {
        guard (200..<300).contains(status) else { return false }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return text == "ok"
    }

    private static func parseResult(
        _ dict: [String: Any],
        fallbackIndex: Int,
    ) -> RaveBSDSearchResult? {
        let title = RaveBSDJSON.string(dict["title"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        var id = RaveBSDJSON.string(dict["id"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty {
            // Single-source routes may omit id; synthesize a stable row key for UI only.
            // Resolve/torrent require a real server id from /search/all or /api/v1/search.
            let source = RaveBSDJSON.string(dict["source"])
            let format = RaveBSDJSON.string(dict["format"])
            id = "local-\(fallbackIndex)-\(source)-\(title)-\(format)"
        }
        return RaveBSDSearchResult(
            id: id,
            title: title,
            author: RaveBSDJSON.string(dict["author"]),
            year: RaveBSDJSON.string(dict["year"]),
            format: RaveBSDJSON.string(dict["format"]),
            filesize: RaveBSDJSON.int64(dict["filesize"]),
            language: RaveBSDJSON.string(dict["language"]),
            source: RaveBSDJSON.string(dict["source"]),
            downloadURL: RaveBSDJSON.string(dict["downloadUrl"]),
            coverURL: RaveBSDJSON.string(dict["coverUrl"]),
            directURL: RaveBSDJSON.string(dict["directUrl"]),
            magnet: RaveBSDJSON.string(dict["magnet"]),
            infoHash: RaveBSDJSON.string(dict["infoHash"]),
            md5: RaveBSDJSON.string(dict["md5"]),
            directFrom: RaveBSDJSON.string(dict["directFrom"]),
            directReady: RaveBSDJSON.bool(dict["directReady"]),
        )
    }
}

public enum RaveBSDResultFiltering {
    /// Keep rows that match the requested media mode when format hints exist.
    /// Unknown formats are kept — never drop a row for missing metadata.
    public static func matching(
        _ results: [RaveBSDSearchResult],
        mode: RaveBSDMediaMode,
    ) -> [RaveBSDSearchResult] {
        results.filter { result in
            let format = result.format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if format.isEmpty { return true }
            switch mode {
                case .ebooks:
                    if audioFormats.contains(format) { return false }
                    return true
                case .audiobooks:
                    if ebookFormats.contains(format) { return false }
                    return true
            }
        }
    }

    public static func deduplicated(_ results: [RaveBSDSearchResult]) -> [RaveBSDSearchResult] {
        var seen = Set<String>()
        var out: [RaveBSDSearchResult] = []
        out.reserveCapacity(results.count)
        for result in results {
            let key = [
                result.title,
                result.author,
                result.source,
                result.format,
                result.normalizedMagnet.isEmpty ? result.normalizedDirectURL : result.normalizedMagnet,
            ]
            .map { $0.lowercased().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression) }
            .joined(separator: "|")
            if seen.insert(key).inserted {
                out.append(result)
            }
        }
        return out
    }

    private static let ebookFormats: Set<String> = [
        "epub", "pdf", "mobi", "azw", "azw3", "fb2", "djvu", "txt", "cbz", "cbr",
    ]
    private static let audioFormats: Set<String> = [
        "m4b", "mp3", "m4a", "flac", "ogg", "opus",
    ]
}
