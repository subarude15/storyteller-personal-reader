import Foundation

extension StorytellerActor {
    /// Updates book metadata using the multipart protocol handled at `/api/v2/books/{bookId}`.
    /// Server implementation: `storyteller/web/src/app/api/v2/books/[bookId]/route.ts` (PUT handler).
    public func updateBook(
        _ payload: StorytellerBookUpdatePayload,
        textCover: StorytellerCoverUpload? = nil,
        audioCover: StorytellerCoverUpload? = nil,
    ) async -> BookMetadata? {
        guard let (baseURL, token) = await ensureAuthentication() else { return nil }
        let updateURL =
            baseURL
            .appendingPathComponent("books")
            .appendingPathComponent(payload.uuid)

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        var fieldOrder: [String] = []
        var formEntries: [(name: String, value: String)] = []
        var fileEntries: [(name: String, upload: StorytellerCoverUpload)] = []

        // Bug in swift compiler requires non-isolated (local isolation cannot validate)
        nonisolated func registerField(_ name: String) {
            if !fieldOrder.contains(name) {
                fieldOrder.append(name)
            }
        }

        func appendJSONField<T: Encodable>(_ name: String, value: T?) -> Bool {
            registerField(name)
            guard let fragment = jsonFragment(from: value) else {
                debugLog("[StorytellerActor] updateBook failed to encode field \(name).")
                return false
            }
            formEntries.append((name, fragment))
            return true
        }

        if let title = payload.title {
            guard appendJSONField("title", value: title) else { return nil }
        }

        if let subtitle = payload.subtitle {
            guard appendJSONField("subtitle", value: subtitle) else { return nil }
        }

        if let language = payload.language {
            guard appendJSONField("language", value: language) else { return nil }
        }

        if let publicationDate = payload.publicationDate {
            switch publicationDate {
                case .value(let date):
                    guard appendJSONField("publicationDate", value: date) else { return nil }
                case .null:
                    guard appendJSONField("publicationDate", value: Optional<String>.none) else {
                        return nil
                    }
            }
        }

        if let descriptionWrapper = payload.description {
            guard appendJSONField("description", value: descriptionWrapper) else { return nil }
        }

        if let ratingWrapper = payload.rating {
            switch ratingWrapper {
                case .value(let rating):
                    guard appendJSONField("rating", value: rating) else { return nil }
                case .null:
                    guard appendJSONField("rating", value: Optional<Double>.none) else {
                        return nil
                    }
            }
        }

        if let statusWrapper = payload.status {
            guard appendJSONField("status", value: statusWrapper) else { return nil }
        }

        if let authors = payload.authors {
            registerField("authors")
            for author in authors {
                guard appendJSONField("authors", value: Optional(author)) else { return nil }
            }
        }

        if let narrators = payload.narrators {
            registerField("narrators")
            for narrator in narrators {
                guard appendJSONField("narrators", value: Optional(narrator)) else { return nil }
            }
        }

        if let creators = payload.creators {
            registerField("creators")
            for creator in creators {
                guard appendJSONField("creators", value: creator) else { return nil }
            }
        }

        if let series = payload.series {
            registerField("series")
            for item in series {
                guard appendJSONField("series", value: item) else { return nil }
            }
        }

        if let collections = payload.collections {
            registerField("collections")
            for collection in collections {
                formEntries.append(("collections", collection))
            }
        }

        if let tags = payload.tags {
            registerField("tags")
            for tag in tags {
                guard appendJSONField("tags", value: Optional(tag)) else { return nil }
            }
        }

        if let textCover {
            registerField("textCover")
            fileEntries.append(("textCover", textCover))
        }

        if let audioCover {
            registerField("audioCover")
            fileEntries.append(("audioCover", audioCover))
        }

        guard !fieldOrder.isEmpty else {
            debugLog("[StorytellerActor] updateBook called without any fields to update.")
            return nil
        }

        for field in fieldOrder {
            appendFormField(&body, boundary: boundary, name: "fields", value: field)
        }

        for entry in formEntries {
            appendFormField(&body, boundary: boundary, name: entry.name, value: entry.value)
        }

        for entry in fileEntries {
            appendFileField(
                &body,
                boundary: boundary,
                name: entry.name,
                file: entry.upload,
            )
        }

        finalizeMultipart(&body, boundary: boundary)

        let headers: [String: String] = [
            "Authorization": authorizationHeaderValue(for: token),
            "Content-Type": "multipart/form-data; boundary=\(boundary)",
            "Accept": "application/json",
        ]

        var allowedStatuses = Set(200..<300)
        allowedStatuses.insert(401)
        allowedStatuses.insert(403)
        allowedStatuses.insert(404)
        allowedStatuses.insert(405)

        do {
            let response = try await httpPut(
                updateURL.absoluteString,
                headers: headers,
                body: body,
                session: urlSession,
                allowedStatusCodes: allowedStatuses,
            )

            let status = evaluateResponse(
                response,
                methodName: "updateBook",
                context: "book \(payload.uuid)",
            )
            guard case .success = status else {
                if let errorMessage = extractServerErrorMessage(from: response.data) {
                    lastUpdateBookError = errorMessage
                } else {
                    lastUpdateBookError = "Server rejected update (HTTP \(response.statusCode))"
                }
                return nil
            }

            do {
                lastUpdateBookError = nil
                return try decoder.decode(
                    StorytellerBookMetadataPayload.self,
                    from: response.data,
                ).scoped(to: sourceRecordValue.id)
            } catch {
                logStorytellerError("updateBook decode", error: error)
                let bodyPreview =
                    String(data: response.data.prefix(500), encoding: .utf8) ?? "<binary>"
                debugLog("[StorytellerActor] updateBook response body: \(bodyPreview)")
                lastUpdateBookError = "Failed to decode server response"
                return nil
            }
        } catch {
            logStorytellerError("updateBook", error: error)
            lastUpdateBookError = "Network error: \(error.localizedDescription)"
            return nil
        }
    }

    /// Deletes a book using `/api/v2/books/{bookId}` (the server also deletes its files), then drops
    /// the device's downloaded copy so nothing is stranded.
    /// Server implementation: `storyteller/web/src/app/api/v2/books/[bookId]/route.ts` (DELETE handler).
    public func deleteBook(_ bookId: String) async -> Bool {
        guard let (baseURL, token) = await ensureAuthentication() else { return false }
        let deleteURL =
            baseURL
            .appendingPathComponent("books")
            .appendingPathComponent(bookId)

        var allowedStatuses = Set(200..<300)
        allowedStatuses.insert(401)
        allowedStatuses.insert(403)
        allowedStatuses.insert(404)

        do {
            let response = try await httpDelete(
                deleteURL.absoluteString,
                headers: [
                    "Authorization": authorizationHeaderValue(for: token)
                ],
                session: urlSession,
                allowedStatusCodes: allowedStatuses,
            )

            let succeeded =
                evaluateResponse(
                    response,
                    methodName: "deleteBook",
                    context: "book \(bookId)",
                ) == .success
            if succeeded {
                await LocalMediaActor.shared.removeAllMedia(
                    for: BookID(sourceID: sourceRecordValue.id, uuid: bookId)
                )
            }
            return succeeded
        } catch {
            logStorytellerError("deleteBook", error: error)
            return false
        }
    }

    /// Deletes a specific asset type from a book using `/api/v2/books/{bookId}/replace-asset`.
    /// Server implementation: `storyteller/web/src/app/api/v2/books/[bookId]/replace-asset/route.ts` (DELETE handler).
    /// Returns `.notSupported` if the server doesn't have this endpoint.
    public func deleteBookAsset(
        _ bookId: String,
        type: StorytellerBookFormat,
    ) async -> DeleteAssetResult {
        guard let (baseURL, token) = await ensureAuthentication() else { return .failed }
        let deleteURL =
            baseURL
            .appendingPathComponent("books")
            .appendingPathComponent(bookId)
            .appendingPathComponent("replace-asset")

        let queryParameters = ["format": type.rawValue]

        var allowedStatuses = Set(200..<300)
        allowedStatuses.insert(401)
        allowedStatuses.insert(403)
        allowedStatuses.insert(404)
        allowedStatuses.insert(405)

        do {
            let response = try await httpDelete(
                deleteURL.absoluteString,
                headers: [
                    "Authorization": authorizationHeaderValue(for: token),
                    "Accept": "application/json",
                ],
                queryParameters: queryParameters,
                session: urlSession,
                allowedStatusCodes: allowedStatuses,
            )

            let status = response.statusCode
            if status == 404 || status == 405 {
                debugLog(
                    "[StorytellerActor] deleteBookAsset: endpoint not supported (status \(status))"
                )
                return .notSupported
            }

            guard
                case .success = evaluateResponse(
                    response,
                    methodName: "deleteBookAsset",
                    context: "\(type.rawValue) for book \(bookId)",
                )
            else {
                return .failed
            }

            do {
                let updatedBook = try decoder.decode(
                    StorytellerBookMetadataPayload.self,
                    from: response.data,
                ).scoped(to: sourceRecordValue.id)
                return .success(updatedBook)
            } catch {
                logStorytellerError("deleteBookAsset decode", error: error)
                return .failed
            }
        } catch {
            logStorytellerError("deleteBookAsset", error: error)
            return .failed
        }
    }

    /// Merges 2–3 Storyteller books into the first UUID in `request.from`.
    /// Server implementation: `storyteller/web/src/app/api/v2/books/merge/route.ts` (POST, `bookCreate`).
    public func mergeBooks(_ request: StorytellerBookMergeRequest) async
        -> StorytellerBookMergeHTTPResult
    {
        guard let (baseURL, token) = await ensureAuthentication() else {
            return .failure(
                BookFormatLinkMerge.failure(
                    forTransportReason: Self.bookFormatLinkAuthReason(connectionStatus)
                )
            )
        }
        let mergeURL =
            baseURL
            .appendingPathComponent("books")
            .appendingPathComponent("merge")

        var allowedStatuses = Set(200..<300)
        allowedStatuses.insert(401)
        allowedStatuses.insert(403)
        allowedStatuses.insert(404)
        allowedStatuses.insert(405)

        do {
            let payload = try StorytellerBookMergePayload.encode(request)
            let response = try await httpPost(
                mergeURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                body: payload,
                session: urlSession,
                allowedStatusCodes: allowedStatuses,
            )

            switch evaluateResponse(
                response,
                methodName: "mergeBooks",
                context: request.from.joined(separator: ","),
            ) {
                case .success:
                    do {
                        let book = try StorytellerBookMergePayload.decodeSurvivingBook(
                            response.data,
                            sourceID: sourceRecordValue.id,
                        )
                        return .success(book)
                    } catch {
                        logStorytellerError("mergeBooks decode", error: error)
                        return .failure(.serverRejected)
                    }
                case .unauthorized:
                    return .failure(.authenticationExpired)
                case .notFound:
                    return .failure(.sourceMissing)
                case .notModified, .unexpected:
                    return .failure(.serverRejected)
            }
        } catch {
            logStorytellerError("mergeBooks", error: error)
            return .failure(BookFormatLinkMerge.failure(forTransportReason: error.localizedDescription))
        }
    }

    /// Starts alignment processing for a book (creates readaloud from ebook + audiobook).
    /// Server implementation: `storyteller/web/src/app/api/v2/books/[bookId]/process/route.ts` (POST handler).
    public func startAlignment(for bookId: String, restart: AlignmentRestartMode = .none) async
        -> Bool
    {
        guard let (baseURL, token) = await ensureAuthentication() else { return false }
        let processURL =
            baseURL
            .appendingPathComponent("books")
            .appendingPathComponent(bookId)
            .appendingPathComponent("process")

        var queryParameters: [String: String] = [:]
        if restart != .none {
            queryParameters["restart"] = restart.rawValue
        }

        var allowedStatuses = Set(200..<300)
        allowedStatuses.insert(401)
        allowedStatuses.insert(403)
        allowedStatuses.insert(404)

        do {
            let response = try await httpPost(
                processURL.absoluteString,
                headers: [
                    "Authorization": authorizationHeaderValue(for: token)
                ],
                queryParameters: queryParameters,
                session: urlSession,
                allowedStatusCodes: allowedStatuses,
            )

            return evaluateResponse(
                response,
                methodName: "startAlignment",
                context: "book \(bookId)",
            ) == .success
        } catch {
            logStorytellerError("startAlignment", error: error)
            return false
        }
    }

    /// Cancels alignment processing for a book.
    /// Server implementation: `storyteller/web/src/app/api/v2/books/[bookId]/process/route.ts` (DELETE handler).
    public func cancelAlignment(for bookId: String) async -> Bool {
        guard let (baseURL, token) = await ensureAuthentication() else { return false }
        let processURL =
            baseURL
            .appendingPathComponent("books")
            .appendingPathComponent(bookId)
            .appendingPathComponent("process")

        var allowedStatuses = Set(200..<300)
        allowedStatuses.insert(401)
        allowedStatuses.insert(403)
        allowedStatuses.insert(404)

        do {
            let response = try await httpDelete(
                processURL.absoluteString,
                headers: [
                    "Authorization": authorizationHeaderValue(for: token)
                ],
                session: urlSession,
                allowedStatusCodes: allowedStatuses,
            )

            return evaluateResponse(
                response,
                methodName: "cancelAlignment",
                context: "book \(bookId)",
            ) == .success
        } catch {
            logStorytellerError("cancelAlignment", error: error)
            return false
        }
    }

    /// Upgrades a book's EPUB files from EPUB 2 to EPUB 3.
    /// Server implementation: `storyteller/web/src/app/api/v2/books/[bookId]/upgrade-epub/route.ts`.
    public func upgradeEpub(for bookId: String) async -> Bool {
        guard let (baseURL, token) = await ensureAuthentication() else { return false }
        let url =
            baseURL
            .appendingPathComponent("books")
            .appendingPathComponent(bookId)
            .appendingPathComponent("upgrade-epub")

        var allowedStatuses = Set(200..<300)
        allowedStatuses.insert(401)
        allowedStatuses.insert(403)
        allowedStatuses.insert(404)

        do {
            let bodyData = try JSONSerialization.data(
                withJSONObject: ["createBackup": true]
            )
            let response = try await httpPost(
                url.absoluteString,
                headers: [
                    "Authorization": authorizationHeaderValue(for: token),
                    "Content-Type": "application/json",
                ],
                body: bodyData,
                session: urlSession,
                allowedStatusCodes: allowedStatuses,
            )

            return evaluateResponse(
                response,
                methodName: "upgradeEpub",
                context: "book \(bookId)",
            ) == .success
        } catch {
            logStorytellerError("upgradeEpub", error: error)
            return false
        }
    }

    private func extractServerErrorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = json["message"] as? String
        else { return nil }
        return message
    }

    private func appendFormField(
        _ body: inout Data,
        boundary: String,
        name: String,
        value: String,
    ) {
        guard let headerData = "--\(boundary)\r\n".data(using: .utf8) else { return }
        body.append(headerData)
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        body.append(value.data(using: .utf8) ?? Data())
        body.append("\r\n".data(using: .utf8)!)
    }

    private func appendFileField(
        _ body: inout Data,
        boundary: String,
        name: String,
        file: StorytellerCoverUpload,
    ) {
        guard let headerData = "--\(boundary)\r\n".data(using: .utf8) else { return }
        body.append(headerData)
        body.append(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(file.filename)\"\r\n"
                .data(using: .utf8)!
        )
        if let contentType = file.contentType {
            body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        } else {
            body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        }
        body.append(file.data)
        body.append("\r\n".data(using: .utf8)!)
    }

    private func finalizeMultipart(_ body: inout Data, boundary: String) {
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
    }

    private func jsonFragment(from value: (some Encodable)?) -> String? {
        if let value {
            do {
                let data = try encoder.encode(value)
                guard let string = String(data: data, encoding: .utf8) else {
                    debugLog("[StorytellerActor] Failed to encode JSON fragment: invalid UTF-8.")
                    return nil
                }
                return string
            } catch {
                logStorytellerError("jsonFragment encode", error: error)
                return nil
            }
        }
        return "null"
    }
}
