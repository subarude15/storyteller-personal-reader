import Foundation
import ZIPFoundation

extension StorytellerActor: BookSourceActor {
    public var sourceRecord: BookSourceRecord {
        sourceRecordValue
    }

    public func resolveLocalMedia(
        for bookID: String,
        category: LocalMediaCategory,
    ) async -> ResolvedLocalMedia? {
        guard
            let url = await LocalMediaActor.shared.resolveAndRecordBookPath(
                for: BookID(sourceID: sourceRecordValue.id, uuid: bookID),
                category: category,
            )
        else {
            return nil
        }
        return ResolvedLocalMedia(
            bookID: BookID(sourceID: sourceRecordValue.id, uuid: bookID),
            category: category,
            url: url,
            kind: .cached,
        )
    }

    public func localAudioFiles(for bookID: String) async -> [URL] {
        guard let manifest = await resolveLocalMedia(for: bookID, category: .audio) else {
            return []
        }
        return packagedAudioFiles(inPackageAt: manifest.url.deletingLastPathComponent())
    }

    /// Audio tracks of a downloaded `.audiobook` package, in the manifest's reading order. A
    /// Storyteller package may nest tracks under subdirectories (per-disc folders, nested archives),
    /// so the manifest's `readingOrder` hrefs, resolved relative to the manifest directory, are the
    /// authoritative list and order. Falls back to a recursive scan if the manifest is unreadable.
    private func packagedAudioFiles(inPackageAt directory: URL) -> [URL] {
        let fm = FileManager.default
        let manifestURL = directory.appendingPathComponent("manifest.json", isDirectory: false)
        if let data = try? Data(contentsOf: manifestURL),
            let manifest = try? decoder.decode(PackagedAudiobookManifest.self, from: data)
        {
            let urls =
                manifest.readingOrder
                .compactMap { resolvePackagedHref($0.href, inPackageAt: directory) }
                .filter { fm.fileExists(atPath: $0.path) }
            if !urls.isEmpty {
                return urls
            }
        }

        let all =
            (fm.enumerator(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles],
            )?.allObjects as? [URL]) ?? []
        return
            all
            .filter { AudioMediaTypes.isAudioFile($0) }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
    }

    private func resolvePackagedHref(_ href: String, inPackageAt rootURL: URL) -> URL? {
        let path = href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? href
        if let url = URL(string: path), url.isFileURL {
            return url
        }
        let decoded = path.removingPercentEncoding ?? path
        guard !decoded.isEmpty else { return nil }
        if decoded.hasPrefix("/") {
            return URL(fileURLWithPath: decoded)
        }
        return rootURL.appendingPathComponent(decoded, isDirectory: false)
    }

    public func acceptBook(
        bookUUID: String,
        title _: String,
        ebook: StorytellerUploadAsset?,
        audiobooks: [StorytellerUploadAsset],
        readaloud: StorytellerUploadAsset?,
        collectionUUID: String?,
        onProgress: (@Sendable (Double) -> Void)?,
    ) async -> String? {
        // A readaloud-only book goes straight through the new-book upload: the server's ingest
        // scanner detects media overlays and registers the epub as the readaloud on its own, and
        // the replace-asset phase below both needs the separate bookUpdate permission and would
        // leave a stray created book behind if it failed.
        if ebook == nil, audiobooks.isEmpty, let readaloud {
            let uploaded = await uploadBookAssets(
                bookUUID: bookUUID,
                readaloud: readaloud,
                collectionUUID: collectionUUID,
                onProgress: onProgress,
            )
            return uploaded ? bookUUID : nil
        }

        // The new-book upload endpoint classifies every epub as the ebook, so a pre-aligned readaloud
        // (also an epub) can't go through it because it would overwrite the ebook. Upload ebook + audiobook
        // there, then attach the readaloud through the format-aware replace-asset endpoint.
        if readaloud != nil {
            // The attach step needs bookUpdate where the create only needed bookCreate; failing
            // it after phase 1 would leave a partial book behind, so refuse up front unless the
            // server confirms the permission.
            guard await currentUserCanUpdateBooks() else {
                debugLog(
                    "[StorytellerActor] acceptBook: bookUpdate not confirmed; refusing to create a book the readaloud attach could strand (\(bookUUID))"
                )
                return nil
            }
        }

        let ebookBytes = ebook?.payloadByteCount ?? 0
        let audioBytes = audiobooks.reduce(Int64(0)) { $0 + $1.payloadByteCount }
        let readaloudBytes = readaloud?.payloadByteCount ?? 0
        let totalBytes = max(ebookBytes + audioBytes + readaloudBytes, 1)
        let baseBytes = ebookBytes + audioBytes

        var phase1Progress: (@Sendable (Double) -> Void)?
        if let onProgress {
            phase1Progress = { fraction in
                onProgress(Double(baseBytes) * fraction / Double(totalBytes))
            }
        }

        let uploaded = await uploadBookAssets(
            bookUUID: bookUUID,
            ebook: ebook,
            audiobooks: audiobooks,
            readaloud: nil,
            collectionUUID: collectionUUID,
            onProgress: phase1Progress,
        )
        guard uploaded else { return nil }

        guard let readaloud else {
            onProgress?(1.0)
            return bookUUID
        }

        var phase2Progress: (@Sendable (Int64, Int64) -> Void)?
        if let onProgress {
            phase2Progress = { sent, total in
                guard total > 0 else { return }
                let phaseBytes = Double(sent) / Double(total) * Double(readaloudBytes)
                onProgress((Double(baseBytes) + phaseBytes) / Double(totalBytes))
            }
        }

        let result = await replaceBookAsset(
            readaloud,
            bookUUID: bookUUID,
            replaceMetadata: false,
            onSendProgress: phase2Progress,
        )
        switch result {
            case .success:
                onProgress?(1.0)
                return bookUUID
            case .notSupported:
                debugLog(
                    "[StorytellerActor] acceptBook: server cannot attach a readaloud (replace-asset unsupported); ebook + audiobook uploaded for \(bookUUID)"
                )
                return nil
            case .failed:
                debugLog("[StorytellerActor] acceptBook: readaloud attach failed for \(bookUUID)")
                return nil
        }
    }

    public func deleteAsset(
        _ bookID: String,
        category: LocalMediaCategory,
    ) async -> DeleteAssetResult {
        let result = await deleteBookAsset(bookID, type: storytellerFormat(for: category))
        if case .success(let updatedBook) = result {
            try? await LocalMediaActor.shared.deleteMedia(
                for: BookID(sourceID: sourceRecordValue.id, uuid: bookID),
                category: category,
            )
            // The DELETE response is authoritative for this book; write it straight to the cache so
            // the UI updates without a full multi-source library refetch.
            try? await LocalMediaActor.shared.updateSourceCacheBookMetadata(
                updatedBook
            )
        }
        return result
    }

    public func replaceAsset(
        _ asset: StorytellerUploadAsset,
        bookID: String,
        replaceMetadata: Bool,
        onProgress: (@Sendable (Double) -> Void)?,
    ) async -> ReplaceAssetResult {
        var onSendProgress: (@Sendable (Int64, Int64) -> Void)?
        if let onProgress {
            onSendProgress = { sent, total in
                guard total > 0 else { return }
                onProgress(Double(sent) / Double(total))
            }
        }
        let result = await replaceBookAsset(
            asset,
            bookUUID: bookID,
            replaceMetadata: replaceMetadata,
            onSendProgress: onSendProgress,
        )
        if case .success = result {
            try? await LocalMediaActor.shared.deleteMedia(
                for: BookID(sourceID: sourceRecordValue.id, uuid: bookID),
                category: localMediaCategory(for: asset.format),
            )
        }
        return result
    }

    public func packageAudiobook(for bookID: String) async -> URL? {
        guard let media = await resolveLocalMedia(for: bookID, category: .audio) else {
            return nil
        }
        let audioDirectory = media.url.deletingLastPathComponent()
        let fm = FileManager.default
        let stagingDir = fm.temporaryDirectory.appendingPathComponent(
            "silveran-content-server",
            isDirectory: true,
        )
        let zipURL = stagingDir.appendingPathComponent(
            "\(bookID)-\(UUID().uuidString).audiobook"
        )

        do {
            try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: zipURL.path) {
                try fm.removeItem(at: zipURL)
            }
            let archive = try Archive(url: zipURL, accessMode: .create)

            // Recurse: a package can nest tracks under subdirectories, and the manifest's hrefs are
            // relative to its directory, so entries must keep their relative paths.
            let base = audioDirectory.standardizedFileURL.path
            let files =
                ((fm.enumerator(
                    at: audioDirectory,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles],
                )?.allObjects as? [URL]) ?? []).filter { !$0.hasDirectoryPath }

            for file in files {
                let relativePath = String(
                    file.standardizedFileURL.path.dropFirst(base.count).drop(while: { $0 == "/" })
                )
                // Audio is already compressed; store everything without re-deflating.
                try archive.addEntry(
                    with: relativePath,
                    fileURL: file,
                    compressionMethod: .none,
                )
            }

            // Silveran reads `manifest.json`; the official Storyteller client reads
            // `manifest.audiobook-manifest`. Duplicate it so both can open the result.
            if let manifest = files.first(where: { $0.lastPathComponent == "manifest.json" }) {
                let alias = stagingDir.appendingPathComponent("\(UUID().uuidString).manifest")
                try fm.copyItem(at: manifest, to: alias)
                defer { try? fm.removeItem(at: alias) }
                try archive.addEntry(
                    with: "manifest.audiobook-manifest",
                    fileURL: alias,
                    compressionMethod: .none,
                )
            }

            return zipURL
        } catch {
            debugLog("[StorytellerActor] packageAudiobook failed for \(bookID): \(error)")
            try? fm.removeItem(at: zipURL)
            return nil
        }
    }

    private func storytellerFormat(for category: LocalMediaCategory) -> StorytellerBookFormat {
        switch category {
            case .ebook: return .ebook
            case .audio: return .audiobook
            case .synced: return .readaloud
        }
    }

    private func localMediaCategory(for format: StorytellerBookFormat) -> LocalMediaCategory {
        switch format {
            case .ebook: return .ebook
            case .audiobook: return .audio
            case .readaloud: return .synced
        }
    }
}

private struct PackagedAudiobookManifest: Decodable {
    struct Link: Decodable {
        let href: String
    }
    let readingOrder: [Link]
}
