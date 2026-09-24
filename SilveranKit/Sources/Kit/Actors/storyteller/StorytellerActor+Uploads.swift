import Foundation

extension StorytellerActor {
    /// Uploads one or more assets for a book using the Tus protocol exposed at `/api/v2/books/upload`.
    /// Server implementation: `storyteller/web/src/app/api/v2/books/upload/[[...path]]/route.ts`.
    public func uploadBookAssets(
        bookUUID: String,
        ebook: StorytellerUploadAsset? = nil,
        audiobook: StorytellerUploadAsset? = nil,
        audiobooks: [StorytellerUploadAsset] = [],
        readaloud: StorytellerUploadAsset? = nil,
        collectionUUID: String? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil,
    ) async -> Bool {
        let audiobookAssets = audiobooks + [audiobook].compactMap(\.self)
        let assets = [ebook].compactMap(\.self) + audiobookAssets + [readaloud].compactMap(\.self)
        guard !assets.isEmpty else {
            debugLog("[StorytellerActor] uploadBookAssets requires at least one asset.")
            return false
        }

        guard let (baseURL, token) = await ensureAuthentication() else { return false }
        let totalBytes = assets.reduce(Int64(0)) { $0 + $1.payloadByteCount }
        var completedBytes: Int64 = 0
        for (index, asset) in assets.enumerated() {
            if Task.isCancelled { return false }
            let assetBaseBytes = completedBytes
            let byteCount = asset.payloadByteCount
            var onSendProgress: (@Sendable (Int64, Int64) -> Void)?
            if let onProgress, totalBytes > 0 {
                onSendProgress = { sentBytes, _ in
                    onProgress(Double(assetBaseBytes + sentBytes) / Double(totalBytes))
                }
            }
            let status = await uploadAsset(
                asset,
                bookUUID: bookUUID,
                collectionUUID: index == 0 ? collectionUUID : nil,
                baseURL: baseURL,
                token: token,
                directoryFileCount: assets.count,
                audioFileCount: audiobookAssets.count,
                onSendProgress: onSendProgress,
            )
            guard status == .uploaded else { return false }
            completedBytes += byteCount
        }
        return true
    }

    public func uploadStorytellerFile(
        _ asset: StorytellerUploadAsset,
        bookUUID: String,
        directoryFileCount: Int,
        audioFileCount: Int,
        collectionUUID: String? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil,
    ) async -> StorytellerFileUploadResult {
        if Task.isCancelled {
            return StorytellerFileUploadResult(identity: asset.uploadIdentity, status: .cancelled)
        }
        guard let (baseURL, token) = await ensureAuthentication() else {
            return StorytellerFileUploadResult(identity: asset.uploadIdentity, status: .unauthorized)
        }
        var onSendProgress: (@Sendable (Int64, Int64) -> Void)?
        if let onProgress {
            onSendProgress = { sent, total in
                guard total > 0 else { return }
                onProgress(Double(sent) / Double(total))
            }
        }
        let status = await uploadAsset(
            asset,
            bookUUID: bookUUID,
            collectionUUID: collectionUUID,
            baseURL: baseURL,
            token: token,
            directoryFileCount: directoryFileCount,
            audioFileCount: audioFileCount,
            onSendProgress: onSendProgress,
        )
        return StorytellerFileUploadResult(identity: asset.uploadIdentity, status: status)
    }


    private func defaultMimeType(for format: StorytellerBookFormat, filename: String) -> String? {
        if let inferred = inferMimeType(from: filename) {
            return inferred
        }
        switch format {
            case .ebook, .readaloud:
                return "application/epub+zip"
            case .audiobook:
                return "application/zip"
        }
    }

    private func inferMimeType(from filename: String) -> String? {
        if filename.lowercased().hasSuffix(".epub") { return "application/epub+zip" }
        if filename.lowercased().hasSuffix(".zip") { return "application/zip" }
        if filename.lowercased().hasSuffix(".mp3") { return "audio/mpeg" }
        if filename.lowercased().hasSuffix(".m4a") { return "audio/m4a" }
        if filename.lowercased().hasSuffix(".m4b") { return "audio/m4b" }
        if filename.lowercased().hasSuffix(".mp4") { return "audio/mp4" }
        return nil
    }

    private enum TusSendResult {
        case uploaded
        case failed
        case unauthorized
        case cancelled
        case notSupported
    }

    private func sendTus(
        asset: StorytellerUploadAsset,
        uploadBaseURL: URL,
        metadata: [String: String],
        token: AccessToken,
        treatNotFoundAsUnsupported: Bool,
        onSendProgress: (@Sendable (Int64, Int64) -> Void)?,
    ) async -> TusSendResult {
        let byteCount = asset.payloadByteCount
        guard byteCount > 0 else {
            debugLog("[StorytellerActor] upload received an empty payload for \(asset.filename).")
            return .failed
        }
        if Task.isCancelled { return .cancelled }

        let metadataHeader =
            metadata
            .map { key, value in
                let encodedValue = Data(value.utf8).base64EncodedString()
                return "\(key) \(encodedValue)"
            }
            .joined(separator: ",")

        do {
            var createAllowedStatuses = Set(200..<300)
            createAllowedStatuses.insert(401)
            createAllowedStatuses.insert(403)
            if treatNotFoundAsUnsupported {
                createAllowedStatuses.insert(404)
                createAllowedStatuses.insert(405)
            }

            let createResponse = try await httpPost(
                uploadBaseURL.absoluteString,
                headers: [
                    "Tus-Resumable": "1.0.0",
                    "Authorization": authorizationHeaderValue(for: token),
                    "Upload-Length": "\(byteCount)",
                    "Upload-Metadata": metadataHeader,
                    "Content-Length": "0",
                ],
                body: Data(),
                session: uploadURLSession,
                allowedStatusCodes: createAllowedStatuses,
            )

            if treatNotFoundAsUnsupported,
                createResponse.statusCode == 404 || createResponse.statusCode == 405
            {
                return .notSupported
            }

            switch evaluateResponse(
                createResponse,
                methodName: "uploadAsset",
                context: "create for \(asset.filename)",
            ) {
                case .success:
                    break
                case .unauthorized:
                    return .unauthorized
                default:
                    return .failed
            }

            guard let locationHeader = createResponse.response.value(forHTTPHeaderField: "Location")
            else {
                debugLog("[StorytellerActor] uploadAsset missing Location header.")
                return .failed
            }

            let uploadURL = resolveUploadLocation(locationHeader, relativeTo: uploadBaseURL)

            var patchAllowedStatuses = Set(200..<300)
            patchAllowedStatuses.insert(401)
            patchAllowedStatuses.insert(403)

            let patchResponse = try await httpPatch(
                uploadURL.absoluteString,
                headers: [
                    "Tus-Resumable": "1.0.0",
                    "Content-Type": "application/offset+octet-stream",
                    "Authorization": authorizationHeaderValue(for: token),
                    "Upload-Offset": "0",
                    "Content-Length": "\(byteCount)",
                ],
                body: asset.fileURL == nil ? asset.data : nil,
                bodyFileURL: asset.fileURL,
                session: uploadURLSession,
                allowedStatusCodes: patchAllowedStatuses,
                onSendProgress: onSendProgress,
            )

            switch evaluateResponse(
                patchResponse,
                methodName: "uploadAsset",
                context: "patch for \(asset.filename)",
            ) {
                case .success:
                    break
                case .unauthorized:
                    return .unauthorized
                default:
                    return .failed
            }

            let offset = patchResponse.response.value(forHTTPHeaderField: "Upload-Offset")
            if Int64(offset ?? "") != byteCount {
                debugLog("[StorytellerActor] uploadAsset patch offset mismatch.")
                return .failed
            }
            return .uploaded
        } catch is CancellationError {
            return .cancelled
        } catch let error as URLError where error.code == .cancelled {
            return .cancelled
        } catch {
            logStorytellerError("uploadAsset", error: error)
            return .failed
        }
    }

    private func uploadAsset(
        _ asset: StorytellerUploadAsset,
        bookUUID: String,
        collectionUUID: String?,
        baseURL: URL,
        token: AccessToken,
        directoryFileCount: Int,
        audioFileCount: Int,
        onSendProgress: (@Sendable (Int64, Int64) -> Void)? = nil,
    ) async -> StorytellerFileUploadResult.Status {
        let uploadBaseURL =
            baseURL
            .appendingPathComponent("books")
            .appendingPathComponent("upload")

        var metadata: [String: String] = [
            "bookUuid": bookUUID,
            "filename": asset.filename,
        ]

        if let contentType = asset.contentType {
            metadata["filetype"] = contentType
        } else if let guessedType = defaultMimeType(for: asset.format, filename: asset.filename) {
            metadata["filetype"] = guessedType
        }

        if let relativePath = asset.relativePath {
            metadata["relativePath"] = relativePath
        }

        if let collectionUUID {
            metadata["collection"] = collectionUUID
        }

        // Current Storyteller defers scan until this many importable files are in the
        // book directory. Older servers still read totalAudioFiles.
        metadata["totalFiles"] = "\(max(directoryFileCount, 1))"
        if asset.format == .audiobook, audioFileCount > 1 {
            metadata["totalAudioFiles"] = "\(audioFileCount)"
        }

        switch await sendTus(
            asset: asset,
            uploadBaseURL: uploadBaseURL,
            metadata: metadata,
            token: token,
            treatNotFoundAsUnsupported: false,
            onSendProgress: onSendProgress,
        ) {
            case .uploaded:
                return .uploaded
            case .unauthorized:
                return .unauthorized
            case .cancelled:
                return .cancelled
            case .failed, .notSupported:
                return .failed
        }
    }

    /// Result of a replaceBookAsset operation.
    /// Replaces a specific asset type on an existing book using `/api/v2/books/{bookId}/replace-asset/upload`.
    /// Server implementation: `storyteller/web/src/app/api/v2/books/[bookId]/replace-asset/upload/[[...path]]/route.ts`.
    /// Returns `.notSupported` if the server doesn't have this endpoint.
    /// - Parameters:
    ///   - asset: The asset to upload.
    ///   - bookUUID: The UUID of the book to replace the asset on.
    ///   - replaceMetadata: If true, updates book metadata from the new file. Defaults to false.
    public func replaceBookAsset(
        _ asset: StorytellerUploadAsset,
        bookUUID: String,
        replaceMetadata: Bool = false,
        onSendProgress: (@Sendable (Int64, Int64) -> Void)? = nil,
    ) async -> ReplaceAssetResult {
        guard let (baseURL, token) = await ensureAuthentication() else { return .failed }

        let uploadBaseURL =
            baseURL
            .appendingPathComponent("books")
            .appendingPathComponent(bookUUID)
            .appendingPathComponent("replace-asset")
            .appendingPathComponent("upload")

        let batchId = UUID().uuidString

        var metadata: [String: String] = [
            "bookUuid": bookUUID,
            "format": asset.format.rawValue,
            "filename": asset.filename,
            "batchId": batchId,
        ]

        if let contentType = asset.contentType {
            metadata["filetype"] = contentType
        } else if let guessedType = defaultMimeType(for: asset.format, filename: asset.filename) {
            metadata["filetype"] = guessedType
        }

        if asset.format == .audiobook {
            metadata["totalAudioFiles"] = "1"
        }

        if let relativePath = asset.relativePath {
            metadata["relativePath"] = relativePath
        }

        if !replaceMetadata {
            metadata["metadataFieldOverrides"] = skipMetadataFieldOverridesJSONString()
        }

        switch await sendTus(
            asset: asset,
            uploadBaseURL: uploadBaseURL,
            metadata: metadata,
            token: token,
            treatNotFoundAsUnsupported: true,
            onSendProgress: onSendProgress,
        ) {
            case .uploaded:
                return .success
            case .notSupported:
                return .notSupported
            case .failed, .unauthorized, .cancelled:
                return .failed
        }
    }

    public func attachStorytellerReadaloud(
        _ asset: StorytellerUploadAsset,
        bookUUID: String,
        onProgress: (@Sendable (Double) -> Void)? = nil,
    ) async -> StorytellerFileUploadResult {
        var onSendProgress: (@Sendable (Int64, Int64) -> Void)?
        if let onProgress {
            onSendProgress = { sent, total in
                guard total > 0 else { return }
                onProgress(Double(sent) / Double(total))
            }
        }
        let replaced = await replaceBookAsset(
            asset,
            bookUUID: bookUUID,
            replaceMetadata: false,
            onSendProgress: onSendProgress,
        )
        let status: StorytellerFileUploadResult.Status
        switch replaced {
            case .success:
                status = .uploaded
            case .notSupported:
                status = .failed
            case .failed:
                status = accessToken == nil ? .unauthorized : .failed
        }
        return StorytellerFileUploadResult(identity: asset.uploadIdentity, status: status)
    }

    private func skipMetadataFieldOverridesJSONString() -> String {
        let overrides = [
            "authors": "skip",
            "cover": "skip",
            "creators": "skip",
            "description": "skip",
            "language": "skip",
            "narrators": "skip",
            "publicationDate": "skip",
            "series": "skip",
            "subtitle": "skip",
            "tags": "skip",
            "title": "skip",
        ]
        let data = try? JSONSerialization.data(
            withJSONObject: overrides,
            options: [.sortedKeys],
        )
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }


    private func resolveUploadLocation(_ locationHeader: String, relativeTo baseURL: URL) -> URL {
        if let explicit = URL(string: locationHeader), explicit.host != nil {
            return explicit
        }

        if locationHeader.hasPrefix("/") {
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            components?.path = locationHeader
            components?.query = nil
            components?.fragment = nil
            if let url = components?.url { return url }
        }

        return baseURL.appendingPathComponent(locationHeader)
    }
}
