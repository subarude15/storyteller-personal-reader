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
}

public struct BookRequestOutcome: Equatable, Sendable {
    public var format: BookRequestFormat
    public var phase: BookRequestPhase
    public var detail: String
    public var providerBookID: String?

    public init(
        format: BookRequestFormat,
        phase: BookRequestPhase,
        detail: String,
        providerBookID: String? = nil,
    ) {
        self.format = format
        self.phase = phase
        self.detail = detail
        self.providerBookID = providerBookID
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

public enum BookRequests {
    public static func submit(
        work: CanonicalBookWork,
        formats: [BookRequestFormat],
        client: LazyLibrarianClient = LazyLibrarianClient(),
        history: RequestActivityStore = .shared,
        now: Date = Date(),
        providerOverride: BookRequestProviderKind? = nil,
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

        // Local duplicate short-circuit before hitting providers.
        let existing = history.item(forWorkID: work.openLibraryWorkID ?? work.workID)
        var toSend: [BookRequestFormat] = []
        var localOutcomes: [BookRequestOutcome] = []
        for format in formats {
            if let prior = existing?.status(for: format) {
                switch prior.status {
                    case .availableInLibrary, .available, .alreadyAvailable, .downloaded:
                        debugLog(
                            "[RequestActivity] duplicate avoided work=\(work.workID) format=\(format.rawValue) reason=alreadyAvailable"
                        )
                        localOutcomes.append(
                            BookRequestOutcome(
                                format: format,
                                phase: .alreadyAvailable,
                                detail: prior.detail ?? "Already available. Not queued again.",
                                providerBookID: existing?.providerBookID,
                            )
                        )
                        continue
                    case .wanted, .searching, .snatched, .requested, .alreadyRequested:
                        debugLog(
                            "[RequestActivity] duplicate avoided work=\(work.workID) format=\(format.rawValue) reason=alreadyRequested"
                        )
                        localOutcomes.append(
                            BookRequestOutcome(
                                format: format,
                                phase: .alreadyRequested,
                                detail: prior.detail ?? "Already requested. Not queued again.",
                                providerBookID: existing?.providerBookID,
                            )
                        )
                        continue
                    case .failed, .needsAttention, .unknown:
                        break
                }
            }
            toSend.append(format)
        }

        var providerOutcomes: [BookRequestOutcome] = []
        if !toSend.isEmpty {
            switch provider {
                case .automatic:
                    preconditionFailure("BookRequestRouting.choose never returns automatic")
                case .lazyLibrarian:
                    providerOutcomes = await client.request(
                        work: work,
                        formats: toSend,
                        baseURL: settings.lazyLibrarianBaseURL,
                        apiKey: key,
                    )
                case .shelfarr:
                    let idea = readingIdea(work)
                    switch await ShelfarrRequestManager.request(
                        idea,
                        mediums: toSend.map(\.shelfarrMedium),
                    ) {
                        case .success:
                            providerOutcomes = toSend.map {
                                BookRequestOutcome(
                                    format: $0,
                                    phase: .requested,
                                    detail: "Shelfarr accepted this request. The file is not downloaded.",
                                )
                            }
                        case .failure(let error):
                            providerOutcomes = toSend.map {
                                BookRequestOutcome(
                                    format: $0,
                                    phase: .failed,
                                    detail: error.userMessage,
                                )
                            }
                    }
            }
        }

        let outcomes = localOutcomes + providerOutcomes
        history.recordSubmission(
            work: work,
            provider: provider,
            outcomes: outcomes,
            now: now,
        )
        debugLog(
            "[RequestActivity] request end work=\(work.workID) provider=\(provider.rawValue) outcomes=\(outcomes.count)"
        )
        return BookRequestSubmission(provider: provider, outcomes: outcomes)
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
        return await submit(
            work: item.canonicalWorkForRetry(),
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
