import Foundation

public enum BookRequestProviderKind: String, Codable, CaseIterable, Sendable {
    /// Prefer LazyLibrarian when ready; otherwise Shelfarr.
    case automatic
    case lazyLibrarian
    case shelfarr

    public var displayName: String {
        switch self {
            case .automatic: "Automatic (LazyLibrarian preferred)"
            case .lazyLibrarian: "LazyLibrarian"
            case .shelfarr: "Shelfarr"
        }
    }

    public var shortName: String {
        switch self {
            case .automatic: "Automatic"
            case .lazyLibrarian: "LazyLibrarian"
            case .shelfarr: "Shelfarr"
        }
    }

    /// Safe decode for Settings. Unknown / empty → automatic (new default).
    /// Legacy `lazyLibrarian` / `shelfarr` values keep their explicit meaning.
    public static func preference(from raw: String) -> BookRequestProviderKind {
        BookRequestProviderKind(rawValue: raw) ?? .automatic
    }
}

public enum BookRequestFormat: String, CaseIterable, Codable, Sendable {
    case ebook
    case audiobook

    public var label: String {
        switch self {
            case .ebook: "Ebook"
            case .audiobook: "Audiobook"
        }
    }

    var lazyLibrarianType: String {
        switch self {
            case .ebook: "eBook"
            case .audiobook: "AudioBook"
        }
    }

    var shelfarrMedium: ShelfarrMedium {
        switch self {
            case .ebook: .ebook
            case .audiobook: .audiobook
        }
    }
}

public enum BookRequestPhase: Equatable, Sendable {
    case requested
    case searching
    case alreadyRequested
    case alreadyAvailable
    case failed
    case needsAttention
}

public struct BookRequestOutcome: Equatable, Sendable {
    public var format: BookRequestFormat
    public var phase: BookRequestPhase
    public var detail: String
    public var providerBookID: String?
    public var matchCandidates: [LazyLibrarianCandidate]
    public var matchReason: String?
    public var matchAttention: LazyLibrarianMatchAttention?

    public init(
        format: BookRequestFormat,
        phase: BookRequestPhase,
        detail: String,
        providerBookID: String? = nil,
        matchCandidates: [LazyLibrarianCandidate] = [],
        matchReason: String? = nil,
        matchAttention: LazyLibrarianMatchAttention? = nil,
    ) {
        self.format = format
        self.phase = phase
        self.detail = detail
        self.providerBookID = providerBookID
        self.matchCandidates = matchCandidates
        self.matchReason = matchReason
        self.matchAttention = matchAttention
    }
}

public struct BookRequestSubmission: Equatable, Sendable {
    public var provider: BookRequestProviderKind?
    public var outcomes: [BookRequestOutcome]
    public var message: String?

    public init(
        provider: BookRequestProviderKind?,
        outcomes: [BookRequestOutcome],
        message: String? = nil,
    ) {
        self.provider = provider
        self.outcomes = outcomes
        self.message = message
    }
}

public enum BookRequestRouting {
    /// Explicit LazyLibrarian / Shelfarr never silently fall back when that provider
    /// is not ready. Automatic prefers LazyLibrarian, then Shelfarr.
    public static func choose(
        preference: BookRequestProviderKind,
        lazyLibrarianReady: Bool,
        shelfarrReady: Bool,
    ) -> BookRequestProviderKind? {
        switch preference {
            case .automatic:
                if lazyLibrarianReady { return .lazyLibrarian }
                if shelfarrReady { return .shelfarr }
                return nil
            case .lazyLibrarian:
                return lazyLibrarianReady ? .lazyLibrarian : nil
            case .shelfarr:
                return shelfarrReady ? .shelfarr : nil
        }
    }
}

public enum BookRequestLibrary {
    public static func ownedFormats(_ books: [BookMetadata]) -> Set<BookRequestFormat> {
        var owned = Set<BookRequestFormat>()
        for book in books {
            if let ebook = book.ebook, !ebook.isMissing { owned.insert(.ebook) }
            if let audiobook = book.audiobook, !audiobook.isMissing { owned.insert(.audiobook) }
        }
        return owned
    }
}

/// Local duplicate gate used by `BookRequests.submit`.
///
/// `fallbackFromRequestID == nil` checks every provider for the work.
/// A non-nil id is an explicit manual fallback and checks only `provider`.
enum BookRequestDuplicates {
    struct Evaluation: Equatable {
        /// Outcomes the caller should see, including cross-provider duplicates.
        var callerOutcomes: [BookRequestOutcome]
        /// Outcomes stored on `provider`. Empty when the only hits are other providers.
        var persistedOutcomes: [BookRequestOutcome]
        var toSend: [BookRequestFormat]
    }

    static func evaluate(
        workID: String,
        formats: [BookRequestFormat],
        provider: BookRequestProviderKind,
        items: [RequestActivityItem],
        fallbackFromRequestID: String?,
    ) -> Evaluation {
        let rows = items.filter { $0.canonicalWorkID == workID }
        let considered =
            fallbackFromRequestID == nil
            ? rows
            : rows.filter { $0.provider == provider }

        var callerOutcomes: [BookRequestOutcome] = []
        var persistedOutcomes: [BookRequestOutcome] = []
        var toSend: [BookRequestFormat] = []
        for format in formats {
            guard let match = blockingMatch(for: format, in: considered, preferredProvider: provider)
            else {
                toSend.append(format)
                continue
            }
            let outcome = outcome(for: format, match: match)
            callerOutcomes.append(outcome)
            if match.item.provider == provider {
                persistedOutcomes.append(outcome)
            }
        }
        return Evaluation(
            callerOutcomes: callerOutcomes,
            persistedOutcomes: persistedOutcomes,
            toSend: toSend,
        )
    }

    private struct Match {
        var item: RequestActivityItem
        var status: RequestFormatStatus
    }

    /// Active or completed wins. A failed / needs-attention row does not block.
    /// Prefer the chosen provider when it is itself the blocker, so a retry
    /// updates that row instead of looking like a new provider.
    private static func blockingMatch(
        for format: BookRequestFormat,
        in items: [RequestActivityItem],
        preferredProvider: BookRequestProviderKind,
    ) -> Match? {
        let matches: [Match] = items.compactMap { item in
            guard let status = item.status(for: format), blocks(status.status) else { return nil }
            return Match(item: item, status: status)
        }
        return matches.first { $0.item.provider == preferredProvider } ?? matches.first
    }

    private static func blocks(_ status: RequestActivityStatus) -> Bool {
        switch status {
            case .availableInLibrary, .available, .alreadyAvailable, .downloaded,
                .wanted, .searching, .snatched, .requested, .alreadyRequested:
                return true
            case .failed, .needsAttention, .unknown:
                return false
        }
    }

    private static func outcome(for format: BookRequestFormat, match: Match) -> BookRequestOutcome {
        switch match.status.status {
            case .availableInLibrary, .available, .alreadyAvailable, .downloaded:
                return BookRequestOutcome(
                    format: format,
                    phase: .alreadyAvailable,
                    detail: match.status.detail ?? "Already available. Not queued again.",
                    providerBookID: match.item.providerBookID,
                )
            case .wanted, .searching, .snatched, .requested, .alreadyRequested:
                return BookRequestOutcome(
                    format: format,
                    phase: .alreadyRequested,
                    detail: match.status.detail ?? "Already requested. Not queued again.",
                    providerBookID: match.item.providerBookID,
                )
            case .failed, .needsAttention, .unknown:
                preconditionFailure("blockingMatch only returns active or completed statuses")
        }
    }
}

public enum BookRequests {
    public static func submit(
        work: CanonicalBookWork,
        formats: [BookRequestFormat],
        client: LazyLibrarianClient = LazyLibrarianClient(),
        history: RequestActivityStore = .shared,
        now: Date = Date(),
        providerOverride: BookRequestProviderKind? = nil,
        fallbackFromRequestID: String? = nil,
        fallbackKind: RequestFallbackKind? = nil,
    ) async -> BookRequestSubmission {
        let settings = await SettingsActor.shared.config
        let key = (try? await AuthenticationActor.shared.loadLazyLibrarianAPIKey()) ?? ""
        let lazyReady =
            settings.lazyLibrarianEnabled
            && !settings.lazyLibrarianBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let shelfReady =
            !settings.shelfarrBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.shelfarrAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let preference: BookRequestProviderKind
        if let providerOverride, providerOverride != .automatic {
            preference = providerOverride
        } else {
            preference = BookRequestProviderKind.preference(from: settings.bookRequestProvider)
        }
        guard let provider = BookRequestRouting.choose(
            preference: preference,
            lazyLibrarianReady: lazyReady,
            shelfarrReady: shelfReady,
        ) else {
            let message: String
            switch preference {
                case .automatic:
                    message = "Set up LazyLibrarian or Shelfarr in Settings."
                case .lazyLibrarian:
                    message = "LazyLibrarian is not configured. Enable it in Settings, or switch the provider."
                case .shelfarr:
                    message = "Shelfarr is not configured. Add a base URL and token in Settings, or switch the provider."
            }
            return BookRequestSubmission(provider: nil, outcomes: [], message: message)
        }

        debugLog(
            "[RequestActivity] request start work=\(work.workID) provider=\(provider.rawValue) formats=\(formats.map(\.rawValue).joined(separator: ","))"
        )

        // Normal submits look across providers. Manual fallback
        // (fallbackFromRequestID set) looks only at the chosen provider,
        // so the original row does not block a confirmed alternate.
        let workID = work.openLibraryWorkID ?? work.workID
        let guardResult = BookRequestDuplicates.evaluate(
            workID: workID,
            formats: formats,
            provider: provider,
            items: history.allItems(),
            fallbackFromRequestID: fallbackFromRequestID,
        )
        for outcome in guardResult.callerOutcomes
        where outcome.phase == .alreadyAvailable || outcome.phase == .alreadyRequested {
            debugLog(
                "[RequestActivity] duplicate avoided work=\(work.workID) format=\(outcome.format.rawValue) reason=\(outcome.phase == .alreadyAvailable ? "alreadyAvailable" : "alreadyRequested")"
            )
        }

        var providerOutcomes: [BookRequestOutcome] = []
        if !guardResult.toSend.isEmpty {
            switch provider {
                case .automatic:
                    preconditionFailure("BookRequestRouting.choose never returns automatic")
                case .lazyLibrarian:
                    providerOutcomes = await client.request(
                        work: work,
                        formats: guardResult.toSend,
                        baseURL: settings.lazyLibrarianBaseURL,
                        apiKey: key,
                        matching: LazyLibrarianMatchingSettings.preference,
                    )
                case .shelfarr:
                    let idea = readingIdea(work)
                    switch await ShelfarrRequestManager.request(
                        idea,
                        mediums: guardResult.toSend.map(\.shelfarrMedium),
                    ) {
                        case .success:
                            providerOutcomes = guardResult.toSend.map {
                                BookRequestOutcome(
                                    format: $0,
                                    phase: .requested,
                                    detail: "Shelfarr accepted this request. The file is not downloaded.",
                                )
                            }
                        case .failure(let error):
                            providerOutcomes = guardResult.toSend.map {
                                BookRequestOutcome(
                                    format: $0,
                                    phase: .failed,
                                    detail: error.userMessage,
                                )
                            }
                    }
            }
        }

        let outcomes = guardResult.callerOutcomes + providerOutcomes
        // A cross-provider duplicate is returned to the caller but not stored
        // as a new provider row. Same-provider duplicates still update that row.
        let persisted = guardResult.persistedOutcomes + providerOutcomes
        if !persisted.isEmpty {
            history.recordSubmission(
                work: work,
                provider: provider,
                outcomes: persisted,
                now: now,
                fallbackFromRequestID: fallbackFromRequestID,
                fallbackKind: fallbackKind,
            )
        }
        debugLog(
            "[RequestActivity] request end work=\(work.workID) provider=\(provider.rawValue) outcomes=\(outcomes.count)"
        )
        return BookRequestSubmission(provider: provider, outcomes: outcomes)
    }

    /// Queue a chosen LazyLibrarian candidate on the existing request row.
    public static func resolveLazyLibrarianMatch(
        item: RequestActivityItem,
        candidate: LazyLibrarianCandidate,
        client: LazyLibrarianClient = LazyLibrarianClient(),
        history: RequestActivityStore = .shared,
        now: Date = Date(),
    ) async -> BookRequestSubmission {
        guard item.provider == .lazyLibrarian else {
            return BookRequestSubmission(
                provider: item.provider,
                outcomes: [],
                message: "This request is not a LazyLibrarian request.",
            )
        }
        let formats = RequestActivityRetryPolicy.retryableFormats(for: item)
        guard !formats.isEmpty else {
            return BookRequestSubmission(
                provider: .lazyLibrarian,
                outcomes: [],
                message: "Nothing to queue.",
            )
        }
        let settings = await SettingsActor.shared.config
        let key = (try? await AuthenticationActor.shared.loadLazyLibrarianAPIKey()) ?? ""
        let work = item.canonicalWorkForRetry()
        let reason = matchReason(for: candidate, work: work)
        let outcomes = await client.queueResolved(
            bookID: candidate.bookID,
            formats: formats,
            baseURL: settings.lazyLibrarianBaseURL,
            apiKey: key,
            matchReason: reason,
        )
        if !outcomes.isEmpty {
            history.recordSubmission(
                work: work,
                provider: .lazyLibrarian,
                outcomes: outcomes,
                now: now,
                existingRequestID: item.id,
            )
        }
        return BookRequestSubmission(provider: .lazyLibrarian, outcomes: outcomes)
    }

    private static func matchReason(
        for candidate: LazyLibrarianCandidate,
        work: CanonicalBookWork,
    ) -> String {
        if case .matched(_, let reason, _) = LazyLibrarianMatcher.resolve(
            work: work,
            candidates: [candidate],
            preference: .useBestMatch,
        ) {
            return reason
        }
        return "Chosen LazyLibrarian match"
    }

    /// Retry only formats that RequestActivityRetryPolicy marks retryable.
    public static func retry(
        item: RequestActivityItem,
        formats: [BookRequestFormat]? = nil,
        client: LazyLibrarianClient = LazyLibrarianClient(),
        history: RequestActivityStore = .shared,
        now: Date = Date(),
    ) async -> BookRequestSubmission {
        let targets = formats ?? RequestActivityRetryPolicy.retryableFormats(for: item)
        guard !targets.isEmpty else {
            return BookRequestSubmission(
                provider: item.provider == .automatic ? nil : item.provider,
                outcomes: [],
                message: "Nothing to retry.",
            )
        }
        let override: BookRequestProviderKind? =
            (item.provider == .lazyLibrarian || item.provider == .shelfarr)
            ? item.provider
            : nil
        let stamped = RequestActivityTimeline.appendRetryStarted(
            to: item,
            formats: targets,
            now: now,
        )
        history.upsert(stamped)
        return await submit(
            work: stamped.canonicalWorkForRetry(),
            formats: targets,
            client: client,
            history: history,
            now: now,
            providerOverride: override,
        )
    }

    private static func readingIdea(_ work: CanonicalBookWork) -> ReadingIdea {
        ReadingIdea(
            id: work.openLibraryWorkID ?? work.workID,
            title: work.title,
            author: work.authors.joined(separator: ", "),
            coverURL: nil,
            blurb: nil,
            reason: "Selected book",
            score: 0,
            isbn: work.isbn,
            year: BookRequests.year(work.publicationYear),
        )
    }

    private static func year(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let digits = raw.filter(\.isNumber)
        guard digits.count >= 4 else { return nil }
        return Int(digits.prefix(4))
    }
}
