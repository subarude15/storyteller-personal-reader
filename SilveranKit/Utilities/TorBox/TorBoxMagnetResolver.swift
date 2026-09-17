import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Pure TorBox resolve helpers (no Storyteller types — safe for PlaytorioFetcher / Linux).
public enum TorBoxMagnetResolver {
    public enum Phase: Equatable, Sendable {
        case resolving
        case waitingForCache
        case ready
    }

    public struct Resolved: Sendable {
        public var torrent: TorBoxTorrentInfo
        public var file: TorBoxTorrentFile
        public var downloadURL: URL

        public init(torrent: TorBoxTorrentInfo, file: TorBoxTorrentFile, downloadURL: URL) {
            self.torrent = torrent
            self.file = file
            self.downloadURL = downloadURL
        }
    }

    public static func resolve(
        magnet: String,
        apiKey: String,
        http: any TorBoxHTTPClient = URLSessionTorBoxHTTPClient(),
        onPhase: (@Sendable (Phase) -> Void)? = nil
    ) async throws -> Resolved {
        onPhase?(.resolving)
        let client = TorBoxClient(apiKey: apiKey, http: http)
        // Custom poll so we can surface "waiting" for uncached torrents.
        let torrentID = try await client.addMagnet(magnet)
        let deadline = Date().addingTimeInterval(300)
        var sawDownloading = false
        while Date() < deadline {
            let info = try await client.getTorrent(id: torrentID, bypassCache: true)
            if info.isDownloadReady {
                guard let file = TorBoxClient.preferredFile(in: info.files, prefer: [
                    "epub", "mobi", "azw3", "pdf", "mp3", "m4b", "m4a",
                ]) else {
                    throw TorBoxError.noDownloadableFile
                }
                onPhase?(.ready)
                let url = try await client.requestDownloadURL(torrentID: info.id, fileID: file.id)
                return Resolved(torrent: info, file: file, downloadURL: url)
            }
            if !sawDownloading {
                sawDownloading = true
                onPhase?(.waitingForCache)
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw TorBoxError.timeout
    }

    public static func downloadFile(from url: URL, maxBytes: Int64 = 500 * 1024 * 1024) async throws -> Data {
        #if canImport(FoundationNetworking)
        let (data, response) = try await URLSession.shared.data(from: url)
        #else
        let (data, response) = try await URLSession.shared.data(from: url)
        #endif
        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            throw TorBoxError.api(message: "Download failed (HTTP \(http.statusCode)).")
        }
        if Int64(data.count) > maxBytes {
            throw TorBoxError.api(message: "Downloaded file is too large to ingest on this device.")
        }
        return data
    }

    public static func isEbookFilename(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        return lower.hasSuffix(".epub") || lower.hasSuffix(".pdf")
            || lower.hasSuffix(".mobi") || lower.hasSuffix(".azw3")
    }

    public static func isAudiobookFilename(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        return lower.hasSuffix(".mp3") || lower.hasSuffix(".m4b")
            || lower.hasSuffix(".m4a") || lower.hasSuffix(".flac")
    }

    public static func contentType(for filename: String) -> String {
        let lower = filename.lowercased()
        if lower.hasSuffix(".epub") { return "application/epub+zip" }
        if lower.hasSuffix(".pdf") { return "application/pdf" }
        if lower.hasSuffix(".mp3") { return "audio/mpeg" }
        if lower.hasSuffix(".m4b") || lower.hasSuffix(".m4a") { return "audio/mp4" }
        return "application/octet-stream"
    }
}
