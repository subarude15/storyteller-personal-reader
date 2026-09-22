import Foundation

/// Storyteller-native merge of an e-book record and an audiobook record.
///
/// Server: `POST /api/v2/books/merge` (`bookCreate`). The first UUID in `from` is the
/// surviving book; later UUIDs are absorbed and their records are removed. Assets are
/// relocated onto the survivor. ink+amp-local state is not moved by Storyteller.
///
/// Local state this PR migrates after a successful merge:
/// - reading/listening progress and pending progress-sync rows
/// - sync-history rows keyed by the original BookIDs
/// - local highlights/bookmarks files (copied onto the survivor; originals kept)
/// - the private BookFormatLink association for the old pair
///
/// Local state preserved, not remapped, in this PR:
/// - on-disk downloads under the absorbed Storyteller UUID (`LocalMediaActor` paths)
/// - in-flight `DownloadManager` records (not deleted)
/// - Stats `SessionTracker` rows (historical media IDs stay as recorded)
/// - recommendation / request-activity rows keyed by the old UUID
/// - cached cover bytes keyed by the absorbed BookID
public enum StorytellerBookMergeEligibility {
    public static func isEligible(_ current: BookMetadata, _ other: BookMetadata) -> Bool {
        reason(current, other) == nil
    }

    public static func reason(_ current: BookMetadata, _ other: BookMetadata) -> String? {
        guard current.sourceID == other.sourceID else {
            return "different Storyteller sources"
        }
        guard isStorytellerUUID(current.uuid), isStorytellerUUID(other.uuid) else {
            return "missing Storyteller UUID"
        }
        guard current.id != other.id else {
            return "same record"
        }
        guard !BookFormatMatcher.isPodcastLike(current),
            !BookFormatMatcher.isPodcastLike(other)
        else {
            return "podcast"
        }
        let left = BookFormatMatcher.presentFormats(current)
        let right = BookFormatMatcher.presentFormats(other)
        guard !left.isEmpty, !right.isEmpty else {
            return "missing format"
        }
        guard left.isDisjoint(with: right) else {
            return "duplicate format"
        }
        let combined = left.union(right)
        guard combined.contains(.ebook), combined.contains(.audiobook) else {
            return "not ebook + audiobook"
        }
        return nil
    }

    public static func isStorytellerUUID(_ raw: String) -> Bool {
        UUID(uuidString: raw) != nil
    }
}

public enum StorytellerBookMergeProgress {
    /// Newest timestamp wins; equal timestamps prefer the larger progress fraction.
    public static func preferred(from progress: [BookID: BookProgress]) -> BookProgress? {
        progress.values.max { lhs, rhs in
            let leftTime = lhs.timestamp ?? 0
            let rightTime = rhs.timestamp ?? 0
            if leftTime != rightTime { return leftTime < rightTime }
            return lhs.progressFraction < rhs.progressFraction
        }
    }
}

public enum StorytellerBookMergePayload {
    /// Conservative metadata: ebook title/authors/language/publication, audiobook narrators,
    /// union of tags/collections/series. The ebook UUID is first so it survives.
    public static func request(ebook: BookMetadata, audiobook: BookMetadata)
        -> StorytellerBookMergeRequest
    {
        let titleSource = firstNonEmpty(ebook.title, audiobook.title)
        StorytellerBookMergeRequest(
            update: StorytellerBookMergeUpdate(
                title: titleSource,
                subtitle: firstPresent(ebook.subtitle, audiobook.subtitle),
                language: firstPresent(ebook.language, audiobook.language),
                publicationDate: firstPresent(ebook.publicationDate, audiobook.publicationDate),
                description: firstPresent(ebook.description, audiobook.description),
                rating: ebook.rating ?? audiobook.rating,
            ),
            relations: StorytellerBookMergeRelations(
                creators: uniqueCreators(ebook: ebook, audiobook: audiobook),
                series: uniqueSeries([ebook.series ?? [], audiobook.series ?? []]),
                collections: uniqueCollections([ebook.collections ?? [], audiobook.collections ?? []]),
                tags: uniqueTags([ebook.tags ?? [], audiobook.tags ?? []]),
            ),
            from: [ebook.uuid, audiobook.uuid],
        )
    }

    public static func pair(current: BookMetadata, other: BookMetadata) -> (
        ebook: BookMetadata, audiobook: BookMetadata
    )? {
        let currentFormats = BookFormatMatcher.presentFormats(current)
        let otherFormats = BookFormatMatcher.presentFormats(other)
        if currentFormats.contains(.ebook), otherFormats.contains(.audiobook) {
            return (current, other)
        }
        if currentFormats.contains(.audiobook), otherFormats.contains(.ebook) {
            return (other, current)
        }
        return nil
    }

    public static func encode(_ request: StorytellerBookMergeRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(request)
    }

    public static func decodeSurvivingBook(_ data: Data, sourceID: BookSourceID) throws
        -> BookMetadata
    {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(StorytellerBookMetadataPayload.self, from: data)
            .scoped(to: sourceID)
    }

    private static func firstPresent(_ left: String?, _ right: String?) -> String? {
        if let left, !left.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return left
        }
        if let right, !right.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return right
        }
        return nil
    }

    private static func firstNonEmpty(_ left: String, _ right: String) -> String {
        firstPresent(left, right) ?? left
    }

    private static func uniqueCreators(ebook: BookMetadata, audiobook: BookMetadata)
        -> [StorytellerCreatorRelationUpdate]
    {
        var seen: Set<String> = []
        var result: [StorytellerCreatorRelationUpdate] = []
        func append(_ creators: [BookCreator]?, role: String) {
            for creator in creators ?? [] {
                guard let name = creator.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !name.isEmpty
                else { continue }
                let key = "\(creator.uuid ?? "")|\(role)|\(name.lowercased())"
                guard seen.insert(key).inserted else { continue }
                let fileAs = creator.fileAs?.trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(
                    StorytellerCreatorRelationUpdate(
                        uuid: creator.uuid,
                        id: creator.id,
                        name: name,
                        fileAs: (fileAs?.isEmpty == false ? fileAs : nil) ?? name,
                        role: role,
                    )
                )
            }
        }
        append(ebook.authors, role: "aut")
        append(audiobook.authors, role: "aut")
        append(audiobook.narrators, role: "nrt")
        append(ebook.narrators, role: "nrt")
        append(ebook.creators, role: "oth")
        append(audiobook.creators, role: "oth")
        return result
    }

    private static func uniqueSeries(_ groups: [[BookSeries]]) -> [StorytellerSeriesRelationUpdate] {
        var seen: Set<String> = []
        var result: [StorytellerSeriesRelationUpdate] = []
        for series in groups.flatMap({ $0 }) {
            let name = series.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = name.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(
                StorytellerSeriesRelationUpdate(
                    uuid: series.uuid,
                    name: name,
                    featured: series.featured == 1,
                    position: series.position.map { Double($0) },
                )
            )
        }
        return result
    }

    private static func uniqueCollections(_ groups: [[BookCollectionSummary]]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for collection in groups.flatMap({ $0 }) {
            guard let uuid = collection.uuid, StorytellerBookMergeEligibility.isStorytellerUUID(uuid)
            else { continue }
            guard seen.insert(uuid).inserted else { continue }
            result.append(uuid)
        }
        return result
    }

    private static func uniqueTags(_ groups: [[BookTag]]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for tag in groups.flatMap({ $0 }) {
            let name = tag.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            result.append(name)
        }
        return result
    }
}

public struct StorytellerMergeLocalSnapshot: Sendable {
    public var bookIDs: [BookID]
    public var progress: [BookID: BookProgress]
    public var pending: [PendingProgressSync]
    public var history: [BookID: [SyncHistoryEntry]]
    public var highlights: [BookID: [Highlight]]
    public var links: BookFormatLinkDocument

    public init(
        bookIDs: [BookID] = [],
        progress: [BookID: BookProgress] = [:],
        pending: [PendingProgressSync] = [],
        history: [BookID: [SyncHistoryEntry]] = [:],
        highlights: [BookID: [Highlight]] = [:],
        links: BookFormatLinkDocument = .empty,
    ) {
        self.bookIDs = bookIDs
        self.progress = progress
        self.pending = pending
        self.history = history
        self.highlights = highlights
        self.links = links
    }
}

public protocol StorytellerBookMergeStateStore: Sendable {
    func snapshot(bookIDs: [BookID], links: BookFormatLinkDocument) async
        -> StorytellerMergeLocalSnapshot
    func apply(snapshot: StorytellerMergeLocalSnapshot, surviving: BookID) async -> String?
}

public struct DefaultStorytellerBookMergeStateStore: StorytellerBookMergeStateStore {
    public init() {}

    public func snapshot(bookIDs: [BookID], links: BookFormatLinkDocument) async
        -> StorytellerMergeLocalSnapshot
    {
        let progressSnapshot = await ProgressSyncActor.shared.snapshotMergeProgress(
            bookIDs: bookIDs
        )
        var highlights: [BookID: [Highlight]] = [:]
        for bookID in bookIDs {
            highlights[bookID] =
                (try? await FilesystemActor.shared.loadHighlights(bookID: bookID)) ?? []
        }
        return StorytellerMergeLocalSnapshot(
            bookIDs: bookIDs,
            progress: progressSnapshot.progress,
            pending: progressSnapshot.pending,
            history: progressSnapshot.history,
            highlights: highlights,
            links: links,
        )
    }

    public func apply(snapshot: StorytellerMergeLocalSnapshot, surviving: BookID) async -> String? {
        var warnings: [String] = []
        do {
            try await FilesystemActor.shared.applyMergeHighlights(
                snapshot.highlights,
                surviving: surviving,
            )
        } catch {
            warnings.append("highlights: \(error.localizedDescription)")
        }
        await ProgressSyncActor.shared.applyMergeProgress(snapshot, surviving: surviving)
        return warnings.isEmpty ? nil : warnings.joined(separator: "; ")
    }
}

public enum StorytellerBookMergeTexts {
    public static let mergeTitle = "Merge in Storyteller"
    public static let mergeSubtitle =
        "Combine these into one Storyteller book and start Read & Listen alignment."
    public static let destructiveTitle = "Merge these books in Storyteller?"
    public static let destructiveBody = """
        Storyteller will combine the e-book and audiobook into one server record. One original \
        Storyteller book record will be removed. The ebook and audiobook files are kept and moved \
        into the surviving record.

        ink+amp will preserve or migrate local progress, bookmarks, and downloads where it can.

        Read & Listen processing starts after the merge.

        This is not the same as reversible Link Formats.
        """
    public static let confirmAction = "Merge in Storyteller"
}
