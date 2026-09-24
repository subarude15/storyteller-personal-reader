import Foundation

extension StorytellerActor {
    /// Lists collections visible to the user via `/api/v2/collections`.
    /// Server implementation: `storyteller/web/src/app/api/v2/collections/route.ts` (GET handler).
    public func fetchCollections() async -> [StorytellerCollection]? {
        guard let (baseURL, token) = await ensureAuthentication() else { return nil }
        let collectionsURL = baseURL.appendingPathComponent("collections")

        do {
            var allowedStatuses = Set(200..<300)
            allowedStatuses.insert(401)
            allowedStatuses.insert(403)
            allowedStatuses.insert(404)

            let response = try await httpGet(
                collectionsURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                session: urlSession,
                allowedStatusCodes: allowedStatuses,
            )

            guard
                case .success = evaluateResponse(
                    response,
                    methodName: "fetchCollections",
                    context: "collections",
                )
            else {
                return nil
            }

            return try decodeCollectionsList(from: response.data)
        } catch {
            logStorytellerError("fetchCollections", error: error)
            return nil
        }
    }

    /// Decodes the collections array, skipping individual bad elements so one
    /// malformed collection cannot wipe Stats sync / library collection UI.
    private func decodeCollectionsList(from data: Data) throws -> [StorytellerCollection] {
        if let all = try? decoder.decode([StorytellerCollection].self, from: data) {
            return all
        }

        let root = try JSONSerialization.jsonObject(with: data)
        guard let items = root as? [Any] else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "collections root is not an array")
            )
        }

        var decoded: [StorytellerCollection] = []
        for (index, item) in items.enumerated() {
            guard JSONSerialization.isValidJSONObject(item),
                let itemData = try? JSONSerialization.data(withJSONObject: item),
                let collection = try? decoder.decode(StorytellerCollection.self, from: itemData)
            else {
                debugLog(
                    "[StorytellerActor] fetchCollections skipped index=\(index) (element decode failed)"
                )
                continue
            }
            decoded.append(collection)
        }
        debugLog(
            "[StorytellerActor] fetchCollections tolerant decode kept=\(decoded.count)/\(items.count)"
        )
        return decoded
    }

    /// Retrieves details for a specific collection via `/api/v2/collections/{uuid}`.
    /// Server implementation: `storyteller/web/src/app/api/v2/collections/[uuid]/route.ts` (GET handler).
    /// TODO: UNTESTED
    func fetchCollection(uuid: String) async -> StorytellerCollection? {
        guard let (baseURL, token) = await ensureAuthentication() else { return nil }
        let collectionURL =
            baseURL
            .appendingPathComponent("collections")
            .appendingPathComponent(uuid)

        do {
            var allowedStatuses = Set(200..<300)
            allowedStatuses.insert(401)
            allowedStatuses.insert(403)
            allowedStatuses.insert(404)

            let response = try await httpGet(
                collectionURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                session: urlSession,
                allowedStatusCodes: allowedStatuses,
            )

            guard
                case .success = evaluateResponse(
                    response,
                    methodName: "fetchCollection",
                    context: "collection \(uuid)",
                )
            else {
                return nil
            }

            return try decoder.decode(StorytellerCollection.self, from: response.data)
        } catch {
            logStorytellerError("fetchCollection", error: error)
            return nil
        }
    }

    /// Creates a new collection using `/api/v2/collections`.
    /// Server implementation: `storyteller/web/src/app/api/v2/collections/route.ts` (POST handler).
    /// TODO: UNTESTED
    public func createCollection(_ payload: StorytellerCollectionCreatePayload) async
        -> StorytellerCollection?
    {
        guard let (baseURL, token) = await ensureAuthentication() else { return nil }
        let collectionsURL = baseURL.appendingPathComponent("collections")

        do {
            let payloadData = try encoder.encode(payload)

            var allowedStatuses = Set(200..<300)
            allowedStatuses.insert(401)
            allowedStatuses.insert(403)

            let response = try await httpPost(
                collectionsURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                body: payloadData,
                session: urlSession,
                allowedStatusCodes: allowedStatuses,
            )

            guard
                case .success = evaluateResponse(
                    response,
                    methodName: "createCollection",
                    context: "collection creation",
                )
            else {
                return nil
            }

            do {
                return try decoder.decode(StorytellerCollection.self, from: response.data)
            } catch {
                logStorytellerError("createCollection decode", error: error)
                let uuid = Self.peekCollectionUUID(from: response.data) ?? "pending"
                return StorytellerCollection(
                    uuid: uuid,
                    name: payload.name,
                    description: payload.description,
                    isPublic: payload.isPublic
                )
            }
        } catch {
            logStorytellerError("createCollection", error: error)
            return nil
        }
    }

    private static func peekCollectionUUID(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let uuid = object["uuid"] as? String,
            !uuid.isEmpty
        else {
            return nil
        }
        return uuid
    }

    /// Updates collection metadata via `/api/v2/collections/{uuid}`.
    /// Server implementation: `storyteller/web/src/app/api/v2/collections/[uuid]/route.ts` (PUT handler).
    public func updateCollection(
        uuid: String,
        payload: StorytellerCollectionUpdatePayload,
    ) async -> StorytellerCollection? {
        guard
            payload.name != nil || payload.description != nil || payload.isPublic != nil
                || payload.users != nil
        else {
            debugLog("[StorytellerActor] updateCollection requires at least one field to update.")
            return nil
        }

        guard let (baseURL, token) = await ensureAuthentication() else { return nil }
        let collectionURL =
            baseURL
            .appendingPathComponent("collections")
            .appendingPathComponent(uuid)

        do {
            let payloadData = try encoder.encode(payload)

            var allowedStatuses = Set(200..<300)
            allowedStatuses.insert(401)
            allowedStatuses.insert(403)
            allowedStatuses.insert(404)

            let response = try await httpPut(
                collectionURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                body: payloadData,
                session: urlSession,
                allowedStatusCodes: allowedStatuses,
            )

            guard
                case .success = evaluateResponse(
                    response,
                    methodName: "updateCollection",
                    context: "collection \(uuid)",
                )
            else {
                return nil
            }

            do {
                return try decoder.decode(StorytellerCollection.self, from: response.data)
            } catch {
                logStorytellerError("updateCollection decode", error: error)
                // Write landed; response shape mismatch must not fail Stats push.
                return StorytellerCollection(
                    uuid: uuid,
                    name: payload.name ?? "",
                    description: payload.description,
                    isPublic: payload.isPublic ?? false
                )
            }
        } catch {
            logStorytellerError("updateCollection", error: error)
            return nil
        }
    }

    /// Deletes a collection with `/api/v2/collections/{uuid}`.
    /// Server implementation: `storyteller/web/src/app/api/v2/collections/[uuid]/route.ts` (DELETE handler).
    /// TODO: UNTESTED
    public func deleteCollection(uuid: String) async -> Bool {
        guard let (baseURL, token) = await ensureAuthentication() else { return false }
        let collectionURL =
            baseURL
            .appendingPathComponent("collections")
            .appendingPathComponent(uuid)

        var allowedStatuses = Set(200..<300)
        allowedStatuses.insert(401)
        allowedStatuses.insert(403)
        allowedStatuses.insert(404)

        do {
            let response = try await httpDelete(
                collectionURL.absoluteString,
                headers: [
                    "Authorization": authorizationHeaderValue(for: token)
                ],
                session: urlSession,
                allowedStatusCodes: allowedStatuses,
            )

            return evaluateResponse(
                response,
                methodName: "deleteCollection",
                context: "collection \(uuid)",
            ) == .success
        } catch {
            logStorytellerError("deleteCollection", error: error)
            return false
        }
    }

    /// Adds book memberships to collections via `/api/v2/collections/books`.
    /// Server implementation: `storyteller/web/src/app/api/v2/collections/books/route.ts` (POST handler).
    /// TODO: UNTESTED
    func addBooks(_ bookIds: [String], toCollections collectionIds: [String]) async -> Bool {
        guard !bookIds.isEmpty, !collectionIds.isEmpty else {
            debugLog("[StorytellerActor] addBooks requires non-empty books and collections.")
            return false
        }

        guard let (baseURL, token) = await ensureAuthentication() else { return false }
        let membershipURL = baseURL.appendingPathComponent("collections/books")

        struct MembershipBody: Encodable {
            let collections: [String]
            let books: [String]
        }

        let body = MembershipBody(collections: collectionIds, books: bookIds)

        do {
            let payload = try encoder.encode(body)

            var allowedStatuses = Set(200..<300)
            allowedStatuses.insert(401)
            allowedStatuses.insert(403)

            let response = try await httpPost(
                membershipURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                body: payload,
                session: urlSession,
                allowedStatusCodes: allowedStatuses,
            )

            return evaluateResponse(
                response,
                methodName: "addBooks",
                context: "membership add",
            ) == .success
        } catch {
            logStorytellerError("addBooks", error: error)
            return false
        }
    }

    /// Removes book memberships from collections via `/api/v2/collections/books`.
    /// Server implementation: `storyteller/web/src/app/api/v2/collections/books/route.ts` (DELETE handler).
    /// TODO: UNTESTED
    func removeBooks(_ bookIds: [String], fromCollections collectionIds: [String]) async -> Bool {
        guard !bookIds.isEmpty, !collectionIds.isEmpty else {
            debugLog("[StorytellerActor] removeBooks requires non-empty books and collections.")
            return false
        }

        guard let (baseURL, token) = await ensureAuthentication() else { return false }
        let membershipURL = baseURL.appendingPathComponent("collections/books")

        struct MembershipBody: Encodable {
            let collections: [String]
            let books: [String]
        }

        let body = MembershipBody(collections: collectionIds, books: bookIds)

        do {
            let payload = try encoder.encode(body)

            var allowedStatuses = Set(200..<300)
            allowedStatuses.insert(401)
            allowedStatuses.insert(403)

            let response = try await httpDelete(
                membershipURL.absoluteString,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "Authorization": authorizationHeaderValue(for: token),
                ],
                body: payload,
                session: urlSession,
                allowedStatusCodes: allowedStatuses,
            )

            return evaluateResponse(
                response,
                methodName: "removeBooks",
                context: "membership removal",
            ) == .success
        } catch {
            logStorytellerError("removeBooks", error: error)
            return false
        }
    }
}
