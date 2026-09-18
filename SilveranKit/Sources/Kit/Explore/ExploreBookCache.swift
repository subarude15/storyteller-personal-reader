import Foundation

/// Actor-backed HTTPS EPUB downloader / temporary cache for Explore Read now.
public actor ExploreBookCache {
    public static let shared = ExploreBookCache()

    public static let maxDownloadBytes = ExploreEPUBValidator.maxDownloadBytes

    private let fileManager: FileManager
    private let session: URLSession
    private var inFlight: [String: Task<URL, Error>] = [:]

    public init(fileManager: FileManager = .default, session: URLSession = .shared) {
        self.fileManager = fileManager
        self.session = session
    }

    public nonisolated static func cacheKey(
        sourceID: String,
        itemID: String,
        acquisitionURL: URL
    ) -> String {
        let base = ExploreBookIdentity.stableID(sourceID: sourceID, itemID: itemID)
        let urlPart = ExploreBookIdentity.sanitize(acquisitionURL.absoluteString)
        return "\(base)__\(urlPart)"
    }

    public func cachedFileURL(for key: String) -> URL? {
        let url = fileURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    public func hasValidCachedEPUB(for key: String) -> Bool {
        guard let url = cachedFileURL(for: key) else { return false }
        do {
            try ExploreEPUBValidator.validateEPUB(at: url, declaredMIME: "application/epub+zip")
            return true
        } catch {
            try? fileManager.removeItem(at: url)
            return false
        }
    }

    /// Downloads (or reuses) a validated EPUB. Coalesces duplicate concurrent requests.
    public func downloadEPUB(
        sourceID: String,
        itemID: String,
        from url: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
            throw ExploreCatalogError.httpsRequired
        }
        let key = Self.cacheKey(sourceID: sourceID, itemID: itemID, acquisitionURL: url)
        if hasValidCachedEPUB(for: key), let existing = cachedFileURL(for: key) {
            progress?(1)
            return existing
        }

        if let existing = inFlight[key] {
            return try await existing.value
        }

        let task = Task<URL, Error> {
            try await self.performDownload(key: key, from: url, progress: progress)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// Downloads an audiobook file (m4b/mp3) with a size/HTML guard but no EPUB
    /// ZIP validation — audio is a raw media file, not an archive. Coalesces
    /// concurrent requests and caches by acquisition URL.
    public func downloadAudio(
        sourceID: String,
        itemID: String,
        from url: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
            throw ExploreCatalogError.httpsRequired
        }
        let key = Self.cacheKey(sourceID: sourceID, itemID: itemID, acquisitionURL: url)
        if let existing = cachedAudioFileURL(for: key) {
            progress?(1)
            return existing
        }

        if let existing = inFlight[key] {
            return try await existing.value
        }

        let task = Task<URL, Error> {
            try await self.performAudioDownload(key: key, from: url, progress: progress)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    public func removeCachedFile(for key: String) {
        let url = fileURL(for: key)
        try? fileManager.removeItem(at: url)
    }

    // MARK: - Private

    private func cachedAudioFileURL(for key: String) -> URL? {
        let url = audioFileURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func performAudioDownload(
        key: String,
        from url: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("audio/*, application/octet-stream;q=0.9, */*;q=0.1", forHTTPHeaderField: "Accept")
        request.setValue("ink+amp-explore/1.0", forHTTPHeaderField: "User-Agent")

        let (tempURL, response): (URL, URLResponse)
        do {
            (tempURL, response) = try await session.download(for: request)
        } catch is CancellationError {
            throw ExploreCatalogError.cancelled
        } catch {
            throw ExploreCatalogError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            try? fileManager.removeItem(at: tempURL)
            throw ExploreCatalogError.network("No HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            try? fileManager.removeItem(at: tempURL)
            throw ExploreCatalogError.httpStatus(http.statusCode)
        }

        if http.expectedContentLength > 0,
            http.expectedContentLength > Self.maxDownloadBytes
        {
            try? fileManager.removeItem(at: tempURL)
            throw ExploreCatalogError.downloadTooLarge
        }

        let values = try tempURL.resourceValues(forKeys: [.fileSizeKey])
        if let size = values.fileSize, Int64(size) > Self.maxDownloadBytes {
            try? fileManager.removeItem(at: tempURL)
            throw ExploreCatalogError.downloadTooLarge
        }

        // Reject obvious HTML/JSON error pages (e.g. an ad-wall or login page).
        let handle = try FileHandle(forReadingFrom: tempURL)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 512) ?? Data()
        if ExploreEPUBValidator.looksLikeHTML(prefix) || ExploreEPUBValidator.looksLikeJSON(prefix) {
            try? fileManager.removeItem(at: tempURL)
            throw ExploreCatalogError.validationFailed(
                "Download looked like a web page or error response, not an audiobook."
            )
        }

        let destination = audioFileURL(for: key)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let staging = destination.appendingPathExtension("tmp")
        try? fileManager.removeItem(at: staging)
        try fileManager.moveItem(at: tempURL, to: staging)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: staging, to: destination)
        progress?(1)
        return destination
    }

    private func performDownload(
        key: String,
        from url: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("application/epub+zip, application/zip;q=0.9, */*;q=0.1", forHTTPHeaderField: "Accept")
        request.setValue("ink+amp-explore/1.0", forHTTPHeaderField: "User-Agent")

        let (tempURL, response): (URL, URLResponse)
        do {
            (tempURL, response) = try await session.download(for: request)
        } catch is CancellationError {
            throw ExploreCatalogError.cancelled
        } catch {
            throw ExploreCatalogError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            try? fileManager.removeItem(at: tempURL)
            throw ExploreCatalogError.network("No HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            try? fileManager.removeItem(at: tempURL)
            throw ExploreCatalogError.httpStatus(http.statusCode)
        }

        if http.expectedContentLength > 0,
            http.expectedContentLength > Self.maxDownloadBytes
        {
            try? fileManager.removeItem(at: tempURL)
            throw ExploreCatalogError.downloadTooLarge
        }

        let values = try tempURL.resourceValues(forKeys: [.fileSizeKey])
        if let size = values.fileSize, Int64(size) > Self.maxDownloadBytes {
            try? fileManager.removeItem(at: tempURL)
            throw ExploreCatalogError.downloadTooLarge
        }

        let mime = http.mimeType
        do {
            try ExploreEPUBValidator.validateEPUB(at: tempURL, declaredMIME: mime)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }

        let destination = fileURL(for: key)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let staging = destination.appendingPathExtension("tmp")
        try? fileManager.removeItem(at: staging)
        try fileManager.moveItem(at: tempURL, to: staging)
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: staging, to: destination)
        progress?(1)
        return destination
    }

    private func cachesRoot() -> URL {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("ExploreEPUBCache", isDirectory: true)
    }

    private func fileURL(for key: String) -> URL {
        cachesRoot().appendingPathComponent("\(key).epub", isDirectory: false)
    }

    private func audioFileURL(for key: String) -> URL {
        cachesRoot().appendingPathComponent("\(key).audio", isDirectory: false)
    }
}
