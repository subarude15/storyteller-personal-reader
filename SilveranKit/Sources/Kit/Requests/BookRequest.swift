import Foundation

public enum BookRequestProviderKind: String, Codable, CaseIterable, Sendable {
    case lazyLibrarian
    case shelfarr

    public var displayName: String {
        switch self {
            case .lazyLibrarian: "LazyLibrarian"
            case .shelfarr: "Shelfarr"
        }
    }

    public static func preference(from raw: String) -> BookRequestProviderKind {
        BookRequestProviderKind(rawValue: raw) ?? .lazyLibrarian
    }
}

public enum BookRequestFormat: String, CaseIterable, Sendable {
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

    public init(format: BookRequestFormat, phase: BookRequestPhase, detail: String) {
        self.format = format
        self.phase = phase
        self.detail = detail
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
    public static func choose(
        preference: BookRequestProviderKind,
        lazyLibrarianReady: Bool,
        shelfarrReady: Bool,
    ) -> BookRequestProviderKind? {
        switch preference {
            case .lazyLibrarian:
                if lazyLibrarianReady { return .lazyLibrarian }
                if shelfarrReady { return .shelfarr }
            case .shelfarr:
                if shelfarrReady { return .shelfarr }
                if lazyLibrarianReady { return .lazyLibrarian }
        }
        return nil
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
        guard let provider = BookRequestRouting.choose(
            preference: .preference(from: settings.bookRequestProvider),
            lazyLibrarianReady: lazyReady,
            shelfarrReady: shelfReady,
        ) else {
            return BookRequestSubmission(
                provider: nil,
                outcomes: [],
                message: "Set up LazyLibrarian or Shelfarr in Settings.",
            )
        }
        switch provider {
            case .lazyLibrarian:
                let outcomes = await client.request(
                    work: work,
                    formats: formats,
                    baseURL: settings.lazyLibrarianBaseURL,
                    apiKey: key,
                )
                return BookRequestSubmission(provider: .lazyLibrarian, outcomes: outcomes)
            case .shelfarr:
                let idea = readingIdea(work)
                let sent = await ShelfarrRequestManager.request(
                    idea,
                    mediums: formats.map(\.shelfarrMedium),
                )
                let detail =
                    sent
                    ? "Request accepted. Shelfarr has it. The file is not downloaded."
                    : "Shelfarr did not accept the request."
                let phase: BookRequestPhase = sent ? .requested : .failed
                return BookRequestSubmission(
                    provider: .shelfarr,
                    outcomes: formats.map {
                        BookRequestOutcome(format: $0, phase: phase, detail: detail)
                    },
                )
        }
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
