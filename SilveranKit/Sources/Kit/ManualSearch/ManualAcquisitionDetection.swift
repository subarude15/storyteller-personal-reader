//
//  ManualAcquisitionDetection.swift
//  SilveranKit
//
//  Identifies acquisition links from a URL and optional HTTP metadata.
//  Never downloads the file body.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum ManualAcquisitionDetection {
    public static let fileExtensions: [String: ManualAcquisitionDetectedType] = [
        "torrent": .torrent,
        "epub": .epub,
        "pdf": .pdf,
        "mobi": .mobi,
        "azw": .azw,
        "azw3": .azw3,
        "cbz": .cbz,
        "cbr": .cbr,
        "zip": .zip,
        "m4b": .m4b,
        "mp3": .mp3,
        "m4a": .m4a,
        "flac": .flac,
    ]

    public static let mimeTypes: [String: ManualAcquisitionDetectedType] = [
        "application/x-bittorrent": .torrent,
        "application/epub+zip": .epub,
        "application/pdf": .pdf,
        "application/x-mobipocket-ebook": .mobi,
        "application/vnd.amazon.ebook": .azw,
        "application/x-cbr": .cbr,
        "application/vnd.comicbook+zip": .cbz,
        "application/vnd.comicbook-rar": .cbr,
        "application/zip": .zip,
        "application/x-zip-compressed": .zip,
        "audio/mp4": .m4b,
        "audio/x-m4b": .m4b,
        "audio/m4b": .m4b,
        "audio/mpeg": .mp3,
        "audio/mp3": .mp3,
        "audio/x-m4a": .m4a,
        "audio/m4a": .m4a,
        "audio/flac": .flac,
        "audio/x-flac": .flac,
    ]

    /// Schemes that must never become acquisition candidates.
    public static func isIgnoredScheme(_ url: URL) -> Bool {
        let scheme = (url.scheme ?? "").lowercased()
        switch scheme {
            case "javascript", "data", "blob", "file", "about", "itms-apps", "itms":
                return true
            default:
                return false
        }
    }

    public static func isNavigableWebURL(_ url: URL) -> Bool {
        let scheme = (url.scheme ?? "").lowercased()
        return scheme == "http" || scheme == "https"
    }

    /// Navigation-action stage: only schemes that never have HTTP metadata.
    public static func actionStageCandidate(
        url: URL,
        bookMetadata: ManualSearchBookContext,
        providerID: String? = nil,
    ) -> ManualAcquisitionCandidate? {
        if url.scheme?.lowercased() == "magnet" {
            return candidate(url: url, bookMetadata: bookMetadata, providerID: providerID)
        }
        return nil
    }

    public static func candidate(
        url: URL,
        mimeType: String? = nil,
        contentDisposition: String? = nil,
        suggestedFilename: String? = nil,
        bookMetadata: ManualSearchBookContext,
        providerID: String? = nil,
    ) -> ManualAcquisitionCandidate? {
        if isIgnoredScheme(url) { return nil }

        let dispositionFilename = filenameFromContentDisposition(contentDisposition)
        let filename = firstNonEmpty([
            suggestedFilename,
            dispositionFilename,
            filenameFromPath(url),
        ])

        if url.scheme?.lowercased() == "magnet" {
            return ManualAcquisitionCandidate(
                sourceURL: url,
                detectedType: .magnet,
                filename: filename ?? "Magnet link",
                sourceHost: host(of: url),
                mimeType: mimeType,
                bookMetadata: bookMetadata,
                providerID: providerID,
            )
        }

        guard isNavigableWebURL(url) else { return nil }

        if isHTML(mimeType) { return nil }

        // HTTP/HTTPS: path extension is not enough. Wait for MIME,
        // Content-Disposition, or a WebKit suggested filename.
        guard hasHTTPClassificationMetadata(
            mimeType: mimeType,
            contentDisposition: contentDisposition,
            suggestedFilename: suggestedFilename,
        ) else {
            return nil
        }

        let detected =
            typeFromFilename(filename)
            ?? typeFromPath(url)
            ?? typeFromMIME(mimeType)

        guard let detected else { return nil }

        return ManualAcquisitionCandidate(
            sourceURL: url,
            detectedType: detected,
            filename: filename,
            sourceHost: host(of: url),
            mimeType: mimeType,
            bookMetadata: bookMetadata,
            providerID: providerID,
        )
    }

    public static func hasHTTPClassificationMetadata(
        mimeType: String?,
        contentDisposition: String?,
        suggestedFilename: String?,
    ) -> Bool {
        if let mimeType, !mimeType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if let contentDisposition, !contentDisposition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if let suggestedFilename, !suggestedFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    public static func candidate(
        url: URL,
        response: URLResponse?,
        suggestedFilename: String? = nil,
        bookMetadata: ManualSearchBookContext,
        providerID: String? = nil,
    ) -> ManualAcquisitionCandidate? {
        let http = response as? HTTPURLResponse
        let mime = response?.mimeType ?? header(http, "Content-Type")
        let disposition = header(http, "Content-Disposition")
        let responseName = response?.suggestedFilename
        return candidate(
            url: url,
            mimeType: mime.flatMap {
                $0.split(separator: ";").first.map {
                    String($0).trimmingCharacters(in: .whitespaces)
                }
            },
            contentDisposition: disposition,
            suggestedFilename: firstNonEmpty([suggestedFilename, responseName]),
            bookMetadata: bookMetadata,
            providerID: providerID,
        )
    }

    public static func typeFromFilename(_ filename: String?) -> ManualAcquisitionDetectedType? {
        guard let filename, let ext = ext(of: filename) else { return nil }
        return fileExtensions[ext]
    }

    public static func typeFromPath(_ url: URL) -> ManualAcquisitionDetectedType? {
        typeFromFilename(url.lastPathComponent)
    }

    public static func typeFromMIME(_ mimeType: String?) -> ManualAcquisitionDetectedType? {
        guard let mimeType else { return nil }
        let normalized = mimeType.split(separator: ";").first
            .map { String($0).trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return mimeTypes[normalized]
    }

    public static func isHTML(_ mimeType: String?) -> Bool {
        guard let mimeType else { return false }
        let normalized = mimeType.split(separator: ";").first
            .map { String($0).trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return normalized == "text/html" || normalized == "application/xhtml+xml" || normalized.hasPrefix("text/html")
    }

    public static func filenameFromContentDisposition(_ header: String?) -> String? {
        guard let header, !header.isEmpty else { return nil }
        if let encoded = match(header, pattern: #"filename\*\s*=\s*(?:UTF-8|utf-8)''([^;]+)"#) {
            let trimmed = encoded.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            return trimmed.removingPercentEncoding ?? trimmed
        }
        if let quoted = match(header, pattern: #"filename\s*=\s*"([^"]+)""#) {
            return quoted
        }
        if let plain = match(header, pattern: #"filename\s*=\s*([^;\s]+)"#) {
            return plain.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    public static func host(of url: URL) -> String? {
        if url.scheme?.lowercased() == "magnet" {
            return "magnet"
        }
        return url.host
    }

    private static func filenameFromPath(_ url: URL) -> String? {
        let last = url.lastPathComponent
        guard !last.isEmpty, last != "/", last.contains(".") else { return nil }
        return last.removingPercentEncoding ?? last
    }

    private static func ext(of filename: String) -> String? {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dot = trimmed.lastIndex(of: ".") else { return nil }
        let ext = trimmed[trimmed.index(after: dot)...].lowercased()
        return ext.isEmpty ? nil : ext
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        for value in values {
            if let value {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func match(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
            match.numberOfRanges > 1,
            let swiftRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[swiftRange])
    }

    private static func header(_ response: HTTPURLResponse?, _ field: String) -> String? {
        guard let response else { return nil }
        let target = field.lowercased()
        for (key, value) in response.allHeaderFields {
            if String(describing: key).lowercased() == target {
                return String(describing: value)
            }
        }
        return nil
    }
}
