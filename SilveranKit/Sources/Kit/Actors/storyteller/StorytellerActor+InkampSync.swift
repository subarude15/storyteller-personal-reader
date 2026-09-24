import Foundation

extension StorytellerActor {
    // MARK: - ink+amp Stats sync (private collection blob)

    public enum InkampStatsFetchResult: Sendable {
        /// Auth / network / collections list failed — do not wipe local.
        case unavailable(reason: String)
        /// No collection yet (first sync).
        case empty
        case document(InkampStatsSyncDocument)
    }

    public enum InkampStatsPushResult: Sendable, Equatable {
        case success
        case failure(reason: String)
    }

    private static let inkampStatsCollectionUUIDKey = "punkRally.stats.collectionUUID.v1"

    /// Fetches the Stats sync document from a private Storyteller collection
    /// (same auth as progress sync). Tolerates unrelated collections that fail to
    /// decode — Stats only needs `.inkamp.stats.v1`.
    public func fetchInkampStatsDocument() async -> InkampStatsFetchResult {
        guard await ensureAuthentication() != nil else {
            return .unavailable(reason: "auth failed")
        }

        let collections = await fetchCollections()
        if let collections {
            if let collection = collections.first(where: {
                $0.name == InkampStatsSyncDocument.collectionName
            }) {
                rememberInkampStatsCollectionUUID(collection.uuid)
                return Self.statsDocument(from: collection)
            }
        } else {
            // List failed — try remembered UUID before declaring unavailable.
            if let remembered = rememberedInkampStatsCollectionUUID(),
                let collection = await fetchCollection(uuid: remembered)
            {
                return Self.statsDocument(from: collection)
            }
            return .unavailable(reason: "fetchCollections failed")
        }

        if let remembered = rememberedInkampStatsCollectionUUID(),
            let collection = await fetchCollection(uuid: remembered)
        {
            return Self.statsDocument(from: collection)
        }

        return .empty
    }

    private static func statsDocument(from collection: StorytellerCollection) -> InkampStatsFetchResult {
        guard let description = collection.description, !description.isEmpty else {
            return .empty
        }
        guard description.hasPrefix("{") else {
            return .empty
        }
        guard let doc = try? StatsSyncMerge.decodeDescription(description) else {
            return .empty
        }
        return .document(doc)
    }

    /// Upserts the Stats sync document onto the private Storyteller collection.
    public func pushInkampStatsDocument(_ document: InkampStatsSyncDocument) async
        -> InkampStatsPushResult
    {
        guard await ensureAuthentication() != nil else {
            return .failure(reason: "auth failed")
        }
        let encoded: String
        do {
            encoded = try StatsSyncMerge.encodeDescription(document)
        } catch {
            logStorytellerError("pushInkampStatsDocument encode", error: error)
            return .failure(reason: "encode failed")
        }

        if let existing = await inkampStatsCollection() {
            rememberInkampStatsCollectionUUID(existing.uuid)
            let updated = await updateCollection(
                uuid: existing.uuid,
                payload: StorytellerCollectionUpdatePayload(
                    description: encoded,
                    isPublic: false
                )
            )
            if updated != nil {
                return .success
            }
            return .failure(reason: "updateCollection failed uuid=\(existing.uuid)")
        }

        let created = await createCollection(
            StorytellerCollectionCreatePayload(
                name: InkampStatsSyncDocument.collectionName,
                description: encoded,
                isPublic: false,
                users: nil
            )
        )
        if let created {
            if created.uuid != "pending" {
                rememberInkampStatsCollectionUUID(created.uuid)
            }
            return .success
        }
        return .failure(reason: "createCollection failed name=\(InkampStatsSyncDocument.collectionName)")
    }

    /// True when Storyteller credentials can authenticate (shared with progress sync).
    public func canReachStorytellerForStatsSync() async -> Bool {
        await ensureAuthentication() != nil
    }

    private func inkampStatsCollection() async -> StorytellerCollection? {
        if let collections = await fetchCollections(),
            let found = collections.first(where: {
                $0.name == InkampStatsSyncDocument.collectionName
            })
        {
            rememberInkampStatsCollectionUUID(found.uuid)
            return found
        }
        if let uuid = rememberedInkampStatsCollectionUUID(),
            let collection = await fetchCollection(uuid: uuid)
        {
            return collection
        }
        return nil
    }

    private func rememberInkampStatsCollectionUUID(_ uuid: String) {
        guard uuid != "pending", !uuid.isEmpty else { return }
        UserDefaults.standard.set(uuid, forKey: Self.inkampStatsCollectionUUIDKey)
    }

    private func rememberedInkampStatsCollectionUUID() -> String? {
        UserDefaults.standard.string(forKey: Self.inkampStatsCollectionUUIDKey)
    }

    // MARK: - ink+amp YouTube playhead sync (private collection blob)

    public enum InkampYouTubePlayheadFetchResult: Sendable {
        case unavailable(reason: String)
        case empty
        case document(InkampYouTubePlayheadSyncDocument)
    }

    public enum InkampYouTubePlayheadPushResult: Sendable, Equatable {
        case success
        case failure(reason: String)
    }

    private static let inkampYouTubePlayheadCollectionUUIDKey =
        "punkRally.youtubePlayheads.collectionUUID.v1"

    /// Fetches YouTube playheads from a private Storyteller collection
    /// (same auth as Stats / progress sync).
    public func fetchInkampYouTubePlayheadsDocument() async -> InkampYouTubePlayheadFetchResult {
        guard await ensureAuthentication() != nil else {
            return .unavailable(reason: "auth failed")
        }

        let collections = await fetchCollections()
        if let collections {
            if let collection = collections.first(where: {
                $0.name == InkampYouTubePlayheadSyncDocument.collectionName
            }) {
                rememberInkampYouTubePlayheadCollectionUUID(collection.uuid)
                return Self.youTubePlayheadsDocument(from: collection)
            }
        } else {
            if let remembered = rememberedInkampYouTubePlayheadCollectionUUID(),
                let collection = await fetchCollection(uuid: remembered)
            {
                return Self.youTubePlayheadsDocument(from: collection)
            }
            return .unavailable(reason: "fetchCollections failed")
        }

        if let remembered = rememberedInkampYouTubePlayheadCollectionUUID(),
            let collection = await fetchCollection(uuid: remembered)
        {
            return Self.youTubePlayheadsDocument(from: collection)
        }

        return .empty
    }

    private static func youTubePlayheadsDocument(from collection: StorytellerCollection)
        -> InkampYouTubePlayheadFetchResult
    {
        guard let description = collection.description, !description.isEmpty else {
            return .empty
        }
        guard description.hasPrefix("{") else {
            return .empty
        }
        guard let doc = try? YouTubePlayheadSyncMerge.decodeDescription(description) else {
            return .empty
        }
        return .document(doc)
    }

    /// Upserts the YouTube playhead sync document onto a private Storyteller collection.
    public func pushInkampYouTubePlayheadsDocument(_ document: InkampYouTubePlayheadSyncDocument)
        async -> InkampYouTubePlayheadPushResult
    {
        guard await ensureAuthentication() != nil else {
            return .failure(reason: "auth failed")
        }
        let encoded: String
        do {
            encoded = try YouTubePlayheadSyncMerge.encodeDescription(document)
        } catch {
            logStorytellerError("pushInkampYouTubePlayheadsDocument encode", error: error)
            return .failure(reason: "encode failed")
        }

        if let existing = await inkampYouTubePlayheadCollection() {
            rememberInkampYouTubePlayheadCollectionUUID(existing.uuid)
            let updated = await updateCollection(
                uuid: existing.uuid,
                payload: StorytellerCollectionUpdatePayload(
                    description: encoded,
                    isPublic: false
                )
            )
            if updated != nil {
                return .success
            }
            return .failure(reason: "updateCollection failed uuid=\(existing.uuid)")
        }

        let created = await createCollection(
            StorytellerCollectionCreatePayload(
                name: InkampYouTubePlayheadSyncDocument.collectionName,
                description: encoded,
                isPublic: false,
                users: nil
            )
        )
        if let created {
            if created.uuid != "pending" {
                rememberInkampYouTubePlayheadCollectionUUID(created.uuid)
            }
            return .success
        }
        return .failure(
            reason:
                "createCollection failed name=\(InkampYouTubePlayheadSyncDocument.collectionName)"
        )
    }

    private func inkampYouTubePlayheadCollection() async -> StorytellerCollection? {
        if let collections = await fetchCollections(),
            let found = collections.first(where: {
                $0.name == InkampYouTubePlayheadSyncDocument.collectionName
            })
        {
            rememberInkampYouTubePlayheadCollectionUUID(found.uuid)
            return found
        }
        if let uuid = rememberedInkampYouTubePlayheadCollectionUUID(),
            let collection = await fetchCollection(uuid: uuid)
        {
            return collection
        }
        return nil
    }

    private func rememberInkampYouTubePlayheadCollectionUUID(_ uuid: String) {
        guard uuid != "pending", !uuid.isEmpty else { return }
        UserDefaults.standard.set(uuid, forKey: Self.inkampYouTubePlayheadCollectionUUIDKey)
    }

    private func rememberedInkampYouTubePlayheadCollectionUUID() -> String? {
        UserDefaults.standard.string(forKey: Self.inkampYouTubePlayheadCollectionUUIDKey)
    }

    // MARK: - ink+amp podcast sync (private collection blob)

    public enum InkampPodcastSyncFetchResult: Sendable {
        case unavailable(reason: String)
        case empty
        case document(InkampPodcastSyncDocument)
    }

    public enum InkampPodcastSyncPushResult: Sendable, Equatable {
        case success
        case failure(reason: String)
    }

    private static let inkampPodcastSyncCollectionUUIDKey =
        "punkRally.podcastSync.collectionUUID.v1"

    /// Fetches podcast subscriptions + playheads from a private Storyteller collection
    /// (same auth as Stats / YouTube playheads). Downloads are never in this blob.
    public func fetchInkampPodcastSyncDocument() async -> InkampPodcastSyncFetchResult {
        guard await ensureAuthentication() != nil else {
            return .unavailable(reason: "auth failed")
        }

        let collections = await fetchCollections()
        if let collections {
            if let collection = collections.first(where: {
                $0.name == InkampPodcastSyncDocument.collectionName
            }) {
                rememberInkampPodcastSyncCollectionUUID(collection.uuid)
                return Self.podcastSyncDocument(from: collection)
            }
        } else {
            if let remembered = rememberedInkampPodcastSyncCollectionUUID(),
                let collection = await fetchCollection(uuid: remembered)
            {
                return Self.podcastSyncDocument(from: collection)
            }
            return .unavailable(reason: "fetchCollections failed")
        }

        if let remembered = rememberedInkampPodcastSyncCollectionUUID(),
            let collection = await fetchCollection(uuid: remembered)
        {
            return Self.podcastSyncDocument(from: collection)
        }

        return .empty
    }

    private static func podcastSyncDocument(from collection: StorytellerCollection)
        -> InkampPodcastSyncFetchResult
    {
        guard let description = collection.description, !description.isEmpty else {
            return .empty
        }
        guard description.hasPrefix("{") else {
            return .empty
        }
        guard let doc = try? PodcastSyncMerge.decodeDescription(description) else {
            return .empty
        }
        return .document(doc)
    }

    /// Upserts the podcast sync document onto a private Storyteller collection.
    public func pushInkampPodcastSyncDocument(_ document: InkampPodcastSyncDocument) async
        -> InkampPodcastSyncPushResult
    {
        guard await ensureAuthentication() != nil else {
            return .failure(reason: "auth failed")
        }
        let encoded: String
        do {
            encoded = try PodcastSyncMerge.encodeDescription(document)
        } catch {
            logStorytellerError("pushInkampPodcastSyncDocument encode", error: error)
            return .failure(reason: "encode failed")
        }

        if let existing = await inkampPodcastSyncCollection() {
            rememberInkampPodcastSyncCollectionUUID(existing.uuid)
            let updated = await updateCollection(
                uuid: existing.uuid,
                payload: StorytellerCollectionUpdatePayload(
                    description: encoded,
                    isPublic: false
                )
            )
            if updated != nil {
                return .success
            }
            return .failure(reason: "updateCollection failed uuid=\(existing.uuid)")
        }

        let created = await createCollection(
            StorytellerCollectionCreatePayload(
                name: InkampPodcastSyncDocument.collectionName,
                description: encoded,
                isPublic: false,
                users: nil
            )
        )
        if let created {
            if created.uuid != "pending" {
                rememberInkampPodcastSyncCollectionUUID(created.uuid)
            }
            return .success
        }
        return .failure(
            reason: "createCollection failed name=\(InkampPodcastSyncDocument.collectionName)"
        )
    }

    private func inkampPodcastSyncCollection() async -> StorytellerCollection? {
        if let collections = await fetchCollections(),
            let found = collections.first(where: {
                $0.name == InkampPodcastSyncDocument.collectionName
            })
        {
            rememberInkampPodcastSyncCollectionUUID(found.uuid)
            return found
        }
        if let uuid = rememberedInkampPodcastSyncCollectionUUID(),
            let collection = await fetchCollection(uuid: uuid)
        {
            return collection
        }
        return nil
    }

    private func rememberInkampPodcastSyncCollectionUUID(_ uuid: String) {
        guard uuid != "pending", !uuid.isEmpty else { return }
        UserDefaults.standard.set(uuid, forKey: Self.inkampPodcastSyncCollectionUUIDKey)
    }

    private func rememberedInkampPodcastSyncCollectionUUID() -> String? {
        UserDefaults.standard.string(forKey: Self.inkampPodcastSyncCollectionUUIDKey)
    }

    // MARK: - ink+amp settings sync (private collection blob)

    public enum InkampSettingsFetchResult: Sendable {
        case unavailable(reason: String)
        case empty
        case malformed(detail: String)
        case unsupportedSchema(Int)
        case document(SyncedAppSettings)
    }

    public enum InkampSettingsPushResult: Sendable, Equatable {
        case success
        case failure(reason: String)
    }

    private static let inkampSettingsCollectionUUIDKey = "punkRally.settingsSync.collectionUUID.v1"

    /// Account settings from a private Storyteller collection (same auth as podcast sync).
    public func fetchInkampSettingsDocument() async -> InkampSettingsFetchResult {
        switch await readInkampPrivateBlob(
            name: SyncedAppSettings.collectionName,
            uuidDefaultsKey: Self.inkampSettingsCollectionUUIDKey,
        ) {
            case .unavailable(let reason):
                return .unavailable(reason: reason)
            case .absent:
                return .empty
            case .payload(let raw):
                switch SettingsSyncCodec.inspect(raw) {
                    case .empty:
                        return .empty
                    case .document(let document):
                        return .document(document)
                    case .malformed(let detail):
                        debugLog("[SettingsSync] failure remote malformed \(detail)")
                        return .malformed(detail: detail)
                    case .unsupportedSchema(let version):
                        debugLog(
                            "[SettingsSync] schema mismatch remote=\(version) supported=\(SyncedAppSettings.schemaVersion)"
                        )
                        return .unsupportedSchema(version)
                }
        }
    }

    public func pushInkampSettingsDocument(_ document: SyncedAppSettings) async -> InkampSettingsPushResult {
        let encoded: String
        do {
            encoded = try SettingsSyncCodec.encode(document)
        } catch {
            debugLog("[SettingsSync] failure encode")
            return .failure(reason: "encode failed")
        }
        return await pushInkampPrivateBlob(
            name: SyncedAppSettings.collectionName,
            uuidDefaultsKey: Self.inkampSettingsCollectionUUIDKey,
            description: encoded,
        )
    }

    private enum InkampPrivateBlobRead: Sendable {
        case unavailable(reason: String)
        case absent
        case payload(String)
    }

    /// Shared read path for private description blobs. Settings is the first caller;
    /// podcast/stats keep their existing methods.
    private func readInkampPrivateBlob(name: String, uuidDefaultsKey: String) async -> InkampPrivateBlobRead {
        guard await ensureAuthentication() != nil else {
            return .unavailable(reason: "auth failed")
        }

        let collections = await fetchCollections()
        if let collections {
            if let collection = collections.first(where: { $0.name == name }) {
                rememberPrivateBlobUUID(collection.uuid, key: uuidDefaultsKey)
                return Self.privateBlobPayload(from: collection)
            }
        } else {
            if let remembered = UserDefaults.standard.string(forKey: uuidDefaultsKey),
                let collection = await fetchCollection(uuid: remembered)
            {
                return Self.privateBlobPayload(from: collection)
            }
            return .unavailable(reason: "fetchCollections failed")
        }

        if let remembered = UserDefaults.standard.string(forKey: uuidDefaultsKey),
            let collection = await fetchCollection(uuid: remembered)
        {
            return Self.privateBlobPayload(from: collection)
        }
        return .absent
    }

    private static func privateBlobPayload(from collection: StorytellerCollection) -> InkampPrivateBlobRead {
        guard let description = collection.description?.trimmingCharacters(in: .whitespacesAndNewlines),
            !description.isEmpty
        else {
            return .absent
        }
        return .payload(description)
    }

    private func pushInkampPrivateBlob(
        name: String,
        uuidDefaultsKey: String,
        description: String,
    ) async -> InkampSettingsPushResult {
        guard await ensureAuthentication() != nil else {
            return .failure(reason: "auth failed")
        }

        if let existing = await privateBlobCollection(name: name, uuidDefaultsKey: uuidDefaultsKey) {
            rememberPrivateBlobUUID(existing.uuid, key: uuidDefaultsKey)
            let updated = await updateCollection(
                uuid: existing.uuid,
                payload: StorytellerCollectionUpdatePayload(
                    description: description,
                    isPublic: false,
                ),
            )
            if updated != nil {
                return .success
            }
            return .failure(reason: "updateCollection failed uuid=\(existing.uuid)")
        }

        let created = await createCollection(
            StorytellerCollectionCreatePayload(
                name: name,
                description: description,
                isPublic: false,
                users: nil,
            ),
        )
        if let created {
            rememberPrivateBlobUUID(created.uuid, key: uuidDefaultsKey)
            return .success
        }
        return .failure(reason: "createCollection failed name=\(name)")
    }

    private func privateBlobCollection(name: String, uuidDefaultsKey: String) async -> StorytellerCollection? {
        if let collections = await fetchCollections(),
            let found = collections.first(where: { $0.name == name })
        {
            rememberPrivateBlobUUID(found.uuid, key: uuidDefaultsKey)
            return found
        }
        if let uuid = UserDefaults.standard.string(forKey: uuidDefaultsKey),
            let collection = await fetchCollection(uuid: uuid)
        {
            return collection
        }
        return nil
    }

    private func rememberPrivateBlobUUID(_ uuid: String, key: String) {
        guard uuid != "pending", !uuid.isEmpty else { return }
        UserDefaults.standard.set(uuid, forKey: key)
    }

    // MARK: - ink+amp book format links (private collection blob)
    //
    // Storyteller's POST /api/v2/books/merge deletes the other book record and relocates
    // files. This blob is the reversible association. See BookFormatLink.swift.

    public func fetchInkampBookFormatLinksDocument() async -> BookFormatLinkFetchResult {
        guard await ensureAuthentication() != nil else {
            return .unavailable(reason: Self.bookFormatLinkAuthReason(connectionStatus))
        }

        let collections = await fetchCollections()
        if let collections {
            if let collection = collections.first(where: {
                $0.name == BookFormatLinkDocument.collectionName
            }) {
                rememberInkampBookFormatLinksCollectionUUID(collection.uuid)
                return Self.bookFormatLinksDocument(from: collection)
            }
        } else {
            if let remembered = rememberedInkampBookFormatLinksCollectionUUID(),
                let collection = await fetchCollection(uuid: remembered)
            {
                return Self.bookFormatLinksDocument(from: collection)
            }
            return .unavailable(reason: "offline")
        }

        if let remembered = rememberedInkampBookFormatLinksCollectionUUID(),
            let collection = await fetchCollection(uuid: remembered)
        {
            return Self.bookFormatLinksDocument(from: collection)
        }
        return .empty
    }

    public func pushInkampBookFormatLinksDocument(_ description: String) async
        -> BookFormatLinkPushResult
    {
        guard await ensureAuthentication() != nil else {
            return .failure(reason: Self.bookFormatLinkAuthReason(connectionStatus))
        }
        guard description.hasPrefix("{") else {
            return .failure(reason: "encode failed")
        }

        if let existing = await inkampBookFormatLinksCollection() {
            rememberInkampBookFormatLinksCollectionUUID(existing.uuid)
            let updated = await updateCollection(
                uuid: existing.uuid,
                payload: StorytellerCollectionUpdatePayload(
                    description: description,
                    isPublic: false
                )
            )
            if updated != nil {
                return .success
            }
            return .failure(reason: Self.bookFormatLinkWriteFailureReason(connectionStatus))
        }

        let created = await createCollection(
            StorytellerCollectionCreatePayload(
                name: BookFormatLinkDocument.collectionName,
                description: description,
                isPublic: false,
                users: nil
            )
        )
        if let created {
            if created.uuid != "pending" {
                rememberInkampBookFormatLinksCollectionUUID(created.uuid)
            }
            return .success
        }
        return .failure(reason: Self.bookFormatLinkWriteFailureReason(connectionStatus))
    }

    private func inkampBookFormatLinksCollectionUUIDKey() -> String {
        "punkRally.bookFormatLinks.collectionUUID.v1.\(sourceRecordValue.id)"
    }

    private static func bookFormatLinksDocument(from collection: StorytellerCollection)
        -> BookFormatLinkFetchResult
    {
        guard let description = collection.description, !description.isEmpty,
            description.hasPrefix("{")
        else {
            return .empty
        }
        return .document(description)
    }

    private func inkampBookFormatLinksCollection() async -> StorytellerCollection? {
        if let collections = await fetchCollections(),
            let found = collections.first(where: {
                $0.name == BookFormatLinkDocument.collectionName
            })
        {
            rememberInkampBookFormatLinksCollectionUUID(found.uuid)
            return found
        }
        if let uuid = rememberedInkampBookFormatLinksCollectionUUID(),
            let collection = await fetchCollection(uuid: uuid)
        {
            return collection
        }
        return nil
    }

    private func rememberInkampBookFormatLinksCollectionUUID(_ uuid: String) {
        guard uuid != "pending", !uuid.isEmpty else { return }
        UserDefaults.standard.set(uuid, forKey: inkampBookFormatLinksCollectionUUIDKey())
    }

    private func rememberedInkampBookFormatLinksCollectionUUID() -> String? {
        UserDefaults.standard.string(forKey: inkampBookFormatLinksCollectionUUIDKey())
    }

    private static func bookFormatLinkWriteFailureReason(_ status: ConnectionStatus) -> String {
        switch status {
            case .error(let message):
                let lower = message.lowercased()
                if lower.contains("credential") || lower.contains("unauthorized") {
                    return "auth failed"
                }
                if lower.contains("timeout") || lower.contains("timed out") {
                    return "timeout"
                }
                return "offline"
            case .disconnected:
                return "offline"
            case .connected, .connecting:
                return "server rejected"
        }
    }
}
