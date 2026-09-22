import Foundation

/// How ink+amp treats a LazyLibrarian result that is not an obvious match.
/// Default is to ask. Exact identifier, ISBN, and a single title+author match
/// can still proceed without asking.
public enum LazyLibrarianAutomaticMatching: String, Codable, CaseIterable, Sendable, Identifiable {
    case askWhenUncertain
    case useBestMatch

    public var id: String { rawValue }

    public var label: String {
        switch self {
            case .askWhenUncertain: "Ask me when uncertain"
            case .useBestMatch: "Use best match automatically"
        }
    }

    public static func preference(from raw: String?) -> LazyLibrarianAutomaticMatching {
        guard let raw, let value = LazyLibrarianAutomaticMatching(rawValue: raw) else {
            return .askWhenUncertain
        }
        return value
    }
}

/// Local preference, same UserDefaults pattern as other request behavior settings.
public enum LazyLibrarianMatchingSettings {
    public static let key = "punkRally.lazyLibrarian.automaticMatching"

    public static var preference: LazyLibrarianAutomaticMatching {
        get { LazyLibrarianAutomaticMatching.preference(from: UserDefaults.standard.string(forKey: key)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

public enum LazyLibrarianMatchTier: Int, Comparable, Equatable, Sendable {
    case titleOnly = 1
    case strongTitleAuthor = 2
    case exactTitleAuthor = 3
    case isbn = 4
    case openLibraryEdition = 5
    case openLibraryWork = 6

    public static func < (lhs: LazyLibrarianMatchTier, rhs: LazyLibrarianMatchTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Title-only hits are reviewable and are never queued on their own.
    public var isReasonable: Bool {
        self >= .strongTitleAuthor
    }

    public var reason: String {
        switch self {
            case .openLibraryWork: "Matched by OpenLibrary work"
            case .openLibraryEdition: "Matched by OpenLibrary edition"
            case .isbn: "Matched by ISBN"
            case .exactTitleAuthor, .strongTitleAuthor: "Matched by title + author"
            case .titleOnly: "Title only"
        }
    }
}

public enum LazyLibrarianMatchDecision: Equatable, Sendable {
    case matched(LazyLibrarianCandidate, reason: String, tier: LazyLibrarianMatchTier)
    case ambiguous(best: LazyLibrarianCandidate, candidates: [LazyLibrarianCandidate])
    case noMatch
}

/// Why a request is sitting in Needs attention, distinct from a provider outage.
public enum LazyLibrarianMatchAttention: String, Codable, Equatable, Sendable {
    case ambiguous
    case noMatch
    case providerFailure
}

public enum LazyLibrarianMatchCopy {
    public static let ambiguous = "We found possible matches but couldn’t confidently choose one."
    public static let noCandidates = "No LazyLibrarian candidates were found. Nothing was queued."
}

extension LazyLibrarianMatcher {
    /// Rank candidates, then decide whether to queue, ask, or stop.
    /// Networking stays in `LazyLibrarianClient`.
    public static func resolve(
        work: CanonicalBookWork,
        candidates: [LazyLibrarianCandidate],
        preference: LazyLibrarianAutomaticMatching,
    ) -> LazyLibrarianMatchDecision {
        let ranked = ranked(work: work, candidates: candidates)
        let reasonable = ranked.filter(\.tier.isReasonable)
        let review = reasonable + ranked.filter { $0.tier == .titleOnly }
        guard let best = review.first else { return .noMatch }

        switch preference {
            case .useBestMatch:
                if let top = reasonable.first {
                    return matched(top)
                }
                return .ambiguous(best: best.candidate, candidates: review.map(\.candidate))
            case .askWhenUncertain:
                if let top = reasonable.first, top.tier >= .isbn {
                    return matched(top)
                }
                let ids = Set(reasonable.map(\.candidate.bookID))
                if ids.count == 1, let only = reasonable.first {
                    return matched(only)
                }
                if let year = publicationYear(work.publicationYear) {
                    let dated = reasonable.filter { $0.candidate.year == year }
                    if Set(dated.map(\.candidate.bookID)).count == 1, let only = dated.first {
                        return matched(only)
                    }
                }
                return .ambiguous(best: best.candidate, candidates: review.map(\.candidate))
        }
    }

    /// Highest-ranked title+author (or better) candidate. Nil when the only hits are title-only.
    public static func bestResolvable(
        work: CanonicalBookWork,
        candidates: [LazyLibrarianCandidate],
    ) -> LazyLibrarianCandidate? {
        guard case .matched(let candidate, _, let tier) = resolve(
            work: work,
            candidates: candidates,
            preference: .useBestMatch,
        ), tier.isReasonable else { return nil }
        return candidate
    }

    public static func canReview(_ item: RequestActivityItem) -> Bool {
        item.matchAttention == .ambiguous && !(item.matchCandidates ?? []).isEmpty
    }

    public static func canUseBest(_ item: RequestActivityItem) -> Bool {
        bestResolvable(work: item.canonicalWorkForRetry(), candidates: item.matchCandidates ?? []) != nil
    }

    private static func matched(
        _ row: (candidate: LazyLibrarianCandidate, tier: LazyLibrarianMatchTier),
    ) -> LazyLibrarianMatchDecision {
        .matched(row.candidate, reason: row.tier.reason, tier: row.tier)
    }
}
