import Foundation

/// How precisely a story position was mapped when switching formats.
public enum StoryPositionPrecision: String, Sendable, Equatable, CaseIterable {
    /// SMIL / media-overlay fragment or Storyteller text↔audio alignment.
    case mediaOverlayAlignment
    /// Matched chapter / content href or title between formats.
    case contentReference
    /// Matched chapter plus relative progress within that chapter.
    case chapterRelative
    /// Whole-book `totalProgression` percentage only.
    case wholeBookPercentage
    /// Kept the destination format's previously saved position.
    case destinationSaved
}

public struct StoryPositionChapter: Sendable, Equatable {
    public let title: String
    public let href: String?
    /// Start of chapter as a fraction of the whole book (0…1), when known.
    public let startProgression: Double?
    /// Chapter length as a fraction of the whole book (0…1), when known.
    public let durationFraction: Double?

    public init(
        title: String,
        href: String? = nil,
        startProgression: Double? = nil,
        durationFraction: Double? = nil,
    ) {
        self.title = title
        self.href = href
        self.startProgression = startProgression
        self.durationFraction = durationFraction
    }
}

public struct StoryPositionTranslationInput: Sendable, Equatable {
    public let sourceBookID: BookID
    public let destinationBookID: BookID
    public let sourceCategory: LocalMediaCategory
    public let destinationCategory: LocalMediaCategory
    public let sourceLocator: BookLocator?
    public let sourceProgression: Double
    public let sourceTimestamp: Double?
    /// Destination chapters for title/href matching (may be empty when unknown).
    public let destinationChapters: [StoryPositionChapter]
    /// Previously saved position on the destination book/format, if any.
    public let destinationSavedProgression: Double?
    public let destinationSavedTimestamp: Double?
    public let destinationSavedLocator: BookLocator?
    /// True when SMIL / media-overlay (or equivalent Storyteller alignment) is available
    /// for the destination (or shared) edition.
    public let hasMediaOverlayAlignment: Bool
    /// Progression gap above which a weak (percentage-only) mapping may defer to the
    /// destination's saved place instead of overwriting it.
    public let discrepancyThreshold: Double

    public init(
        sourceBookID: BookID,
        destinationBookID: BookID,
        sourceCategory: LocalMediaCategory,
        destinationCategory: LocalMediaCategory,
        sourceLocator: BookLocator?,
        sourceProgression: Double,
        sourceTimestamp: Double? = nil,
        destinationChapters: [StoryPositionChapter] = [],
        destinationSavedProgression: Double? = nil,
        destinationSavedTimestamp: Double? = nil,
        destinationSavedLocator: BookLocator? = nil,
        hasMediaOverlayAlignment: Bool = false,
        discrepancyThreshold: Double = 0.15,
    ) {
        self.sourceBookID = sourceBookID
        self.destinationBookID = destinationBookID
        self.sourceCategory = sourceCategory
        self.destinationCategory = destinationCategory
        self.sourceLocator = sourceLocator
        self.sourceProgression = sourceProgression
        self.sourceTimestamp = sourceTimestamp
        self.destinationChapters = destinationChapters
        self.destinationSavedProgression = destinationSavedProgression
        self.destinationSavedTimestamp = destinationSavedTimestamp
        self.destinationSavedLocator = destinationSavedLocator
        self.hasMediaOverlayAlignment = hasMediaOverlayAlignment
        self.discrepancyThreshold = discrepancyThreshold
    }
}

public struct StoryPositionTranslation: Sendable, Equatable {
    public let progression: Double
    public let locator: BookLocator?
    public let precision: StoryPositionPrecision
    /// When true, callers should write this position onto the destination book via
    /// ProgressSyncActor before opening (cross-book links, or forced handoff).
    public let shouldSeedDestination: Bool

    public init(
        progression: Double,
        locator: BookLocator?,
        precision: StoryPositionPrecision,
        shouldSeedDestination: Bool,
    ) {
        self.progression = progression
        self.locator = locator
        self.precision = precision
        self.shouldSeedDestination = shouldSeedDestination
    }
}

/// Pure story-position mapping for ebook ↔ audiobook ↔ readaloud switches.
///
/// Priority (matches product doctrine):
/// 1. Media-overlay / Storyteller alignment when available
/// 2. Chapter / content-reference mapping
/// 3. Chapter-relative progress estimation
/// 4. Whole-book percentage
///
/// Does not write sync state — callers seed ProgressSyncActor when needed.
public enum StoryPositionTranslator {
    /// Normalize chapter titles for fuzzy matching across ebook/audio editions.
    public static func normalizedChapterTitle(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let stripped = folded
            .replacingOccurrences(of: #"^(chapter|ch\.?|part|section)\s*[\dIVXLCDM]+[.:)\-]?\s*"#,
                with: "",
                options: .regularExpression)
            .replacingOccurrences(of: #"^[\dIVXLCDM]+[.:)\-]\s*"#,
                with: "",
                options: .regularExpression)
        let scalars = stripped.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == " " ? Character(scalar) : " "
        }
        return String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func translate(_ input: StoryPositionTranslationInput) -> StoryPositionTranslation {
        let clampedSource = clampProgression(input.sourceProgression)
        let sameBook = input.sourceBookID == input.destinationBookID

        if let overlay = mediaOverlayTranslation(input: input, progression: clampedSource) {
            return finalize(
                overlay,
                input: input,
                sameBook: sameBook,
                allowDestinationFallback: false,
            )
        }

        if let content = contentReferenceTranslation(input: input, progression: clampedSource) {
            return finalize(
                content,
                input: input,
                sameBook: sameBook,
                allowDestinationFallback: content.precision == .chapterRelative
                    || content.precision == .wholeBookPercentage,
            )
        }

        let percentage = wholeBookTranslation(input: input, progression: clampedSource)
        return finalize(
            percentage,
            input: input,
            sameBook: sameBook,
            allowDestinationFallback: true,
        )
    }

    /// Build a destination-shaped locator carrying progression (and optional chapter title).
    public static func locatorForDestination(
        category: LocalMediaCategory,
        progression: Double,
        chapterTitle: String? = nil,
        chapterHref: String? = nil,
        sourceLocator: BookLocator? = nil,
    ) -> BookLocator {
        let clamped = clampProgression(progression)
        switch category {
            case .audio:
                return BookLocator(
                    href: chapterHref ?? "audiobook",
                    type: "audio/mp4",
                    title: chapterTitle,
                    locations: BookLocator.Locations(
                        fragments: nil,
                        progression: nil,
                        position: nil,
                        totalProgression: clamped,
                        cssSelector: nil,
                        partialCfi: nil,
                        domRange: nil,
                    ),
                    text: nil,
                )
            case .ebook, .synced:
                // Prefer keeping text/SMIL fragments when switching into reader/readaloud
                // from another text-bearing locator on the same structural edition.
                if let source = sourceLocator,
                    !source.type.contains("audio"),
                    !source.href.hasPrefix("audiobook")
                {
                    let locations = BookLocator.Locations(
                        fragments: source.locations?.fragments,
                        progression: source.locations?.progression,
                        position: source.locations?.position,
                        totalProgression: clamped,
                        cssSelector: source.locations?.cssSelector,
                        partialCfi: source.locations?.partialCfi,
                        domRange: source.locations?.domRange,
                    )
                    return BookLocator(
                        href: source.href,
                        type: source.type.isEmpty ? "application/xhtml+xml" : source.type,
                        title: chapterTitle ?? source.title,
                        locations: locations,
                        text: source.text,
                    )
                }
                return BookLocator(
                    href: chapterHref ?? "ebook",
                    type: "application/xhtml+xml",
                    title: chapterTitle,
                    locations: BookLocator.Locations(
                        fragments: nil,
                        progression: nil,
                        position: nil,
                        totalProgression: clamped,
                        cssSelector: nil,
                        partialCfi: nil,
                        domRange: nil,
                    ),
                    text: nil,
                )
        }
    }

    // MARK: - Private

    private static func mediaOverlayTranslation(
        input: StoryPositionTranslationInput,
        progression: Double,
    ) -> StoryPositionTranslation? {
        guard input.hasMediaOverlayAlignment else { return nil }
        let source = input.sourceLocator
        let hasFragment = source?.locations?.fragments?.first.map { !$0.isEmpty } == true
        let isTextLocator =
            source.map { !$0.type.contains("audio") && !$0.href.hasPrefix("audiobook") } ?? false

        // Text/SMIL fragment is the strongest handoff into readaloud (or ebook with MO).
        if hasFragment, isTextLocator,
            input.destinationCategory == .synced || input.destinationCategory == .ebook
        {
            let locator = locatorForDestination(
                category: input.destinationCategory,
                progression: progression,
                chapterTitle: source?.title,
                chapterHref: source?.href,
                sourceLocator: source,
            )
            return StoryPositionTranslation(
                progression: progression,
                locator: locator,
                precision: .mediaOverlayAlignment,
                shouldSeedDestination: false,
            )
        }

        // Readaloud / SMIL destination can land from whole-book % via existing EPM/MOM paths.
        if input.destinationCategory == .synced || input.sourceCategory == .synced {
            let locator = locatorForDestination(
                category: input.destinationCategory,
                progression: progression,
                chapterTitle: source?.title,
                chapterHref: nil,
                sourceLocator: isTextLocator ? source : nil,
            )
            return StoryPositionTranslation(
                progression: progression,
                locator: locator,
                precision: .mediaOverlayAlignment,
                shouldSeedDestination: false,
            )
        }

        return nil
    }

    private static func contentReferenceTranslation(
        input: StoryPositionTranslationInput,
        progression: Double,
    ) -> StoryPositionTranslation? {
        guard let source = input.sourceLocator else { return nil }
        let chapters = input.destinationChapters
        guard !chapters.isEmpty else { return nil }

        let href = source.href
        if !href.isEmpty,
            href != "audiobook",
            href != "ebook",
            let match = chapters.first(where: { chapter in
                guard let destHref = chapter.href, !destHref.isEmpty else { return false }
                return hrefEquals(href, destHref)
            })
        {
            let mapped = chapterMappedProgression(
                source: source,
                matched: match,
                fallback: progression,
            )
            return StoryPositionTranslation(
                progression: mapped.progression,
                locator: locatorForDestination(
                    category: input.destinationCategory,
                    progression: mapped.progression,
                    chapterTitle: match.title,
                    chapterHref: match.href,
                    sourceLocator: input.destinationCategory == .audio ? nil : source,
                ),
                precision: mapped.usedRelative ? .chapterRelative : .contentReference,
                shouldSeedDestination: false,
            )
        }

        if let title = source.title, !title.isEmpty {
            let needle = normalizedChapterTitle(title)
            guard !needle.isEmpty,
                let match = chapters.first(where: {
                    normalizedChapterTitle($0.title) == needle
                })
            else { return nil }

            let mapped = chapterMappedProgression(
                source: source,
                matched: match,
                fallback: progression,
            )
            return StoryPositionTranslation(
                progression: mapped.progression,
                locator: locatorForDestination(
                    category: input.destinationCategory,
                    progression: mapped.progression,
                    chapterTitle: match.title,
                    chapterHref: match.href,
                    sourceLocator: input.destinationCategory == .audio ? nil : source,
                ),
                precision: mapped.usedRelative ? .chapterRelative : .contentReference,
                shouldSeedDestination: false,
            )
        }

        return nil
    }

    private static func wholeBookTranslation(
        input: StoryPositionTranslationInput,
        progression: Double,
    ) -> StoryPositionTranslation {
        let locator = locatorForDestination(
            category: input.destinationCategory,
            progression: progression,
            chapterTitle: input.sourceLocator?.title,
            sourceLocator: input.sourceLocator,
        )
        return StoryPositionTranslation(
            progression: progression,
            locator: locator,
            precision: .wholeBookPercentage,
            shouldSeedDestination: false,
        )
    }

    private static func finalize(
        _ candidate: StoryPositionTranslation,
        input: StoryPositionTranslationInput,
        sameBook: Bool,
        allowDestinationFallback: Bool,
    ) -> StoryPositionTranslation {
        var result = candidate

        if allowDestinationFallback,
            shouldPreferDestinationSaved(input: input, mappedProgression: result.progression)
        {
            let destProg = clampProgression(input.destinationSavedProgression ?? result.progression)
            result = StoryPositionTranslation(
                progression: destProg,
                locator: input.destinationSavedLocator
                    ?? locatorForDestination(
                        category: input.destinationCategory,
                        progression: destProg,
                        sourceLocator: input.destinationSavedLocator,
                    ),
                precision: .destinationSaved,
                shouldSeedDestination: false,
            )
        }

        // Same-book: PSA already holds the flushed source position — no extra seed.
        // Cross-book (format link): seed so the destination restores the intentional place.
        let needsSeed = !sameBook && result.precision != .destinationSaved
        if needsSeed != result.shouldSeedDestination {
            result = StoryPositionTranslation(
                progression: result.progression,
                locator: result.locator,
                precision: result.precision,
                shouldSeedDestination: needsSeed,
            )
        }
        return result
    }

    private static func shouldPreferDestinationSaved(
        input: StoryPositionTranslationInput,
        mappedProgression: Double,
    ) -> Bool {
        guard let destProg = input.destinationSavedProgression else { return false }
        let gap = abs(clampProgression(mappedProgression) - clampProgression(destProg))
        guard gap >= input.discrepancyThreshold else { return false }
        // Prefer destination only when it looks like a real, possibly newer place —
        // not an empty/near-zero slot overshadowing an intentional mid-book switch.
        guard destProg > 0.02 else { return false }
        if let destTs = input.destinationSavedTimestamp, let sourceTs = input.sourceTimestamp {
            return destTs > sourceTs
        }
        // No timestamps: still allow fallback when the mapped % is only a coarse estimate
        // and destination already has a substantial place.
        return destProg > 0.05
    }

    private static func chapterMappedProgression(
        source: BookLocator,
        matched: StoryPositionChapter,
        fallback: Double,
    ) -> (progression: Double, usedRelative: Bool) {
        guard let start = matched.startProgression,
            let duration = matched.durationFraction,
            duration > 0,
            let chapterProg = source.locations?.progression
        else {
            if let start = matched.startProgression {
                return (clampProgression(start), false)
            }
            return (clampProgression(fallback), false)
        }
        let relative = clampProgression(chapterProg)
        return (clampProgression(start + relative * duration), true)
    }

    private static func hrefEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = lhs.split(separator: "#").first.map(String.init) ?? lhs
        let b = rhs.split(separator: "#").first.map(String.init) ?? rhs
        if a == b { return true }
        return (a as NSString).lastPathComponent == (b as NSString).lastPathComponent
    }

    private static func clampProgression(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

/// Labels for format-switch UI (Home picker + in-player menus).
public enum FormatSwitchLabels {
    public static func title(for category: LocalMediaCategory) -> String {
        switch category {
            case .ebook: return "Ebook"
            case .audio: return "Audiobook"
            case .synced: return "Readaloud"
        }
    }

    public static func systemImage(for category: LocalMediaCategory) -> String {
        switch category {
            case .ebook: return "book"
            case .audio: return "headphones"
            case .synced: return "text.book.closed"
        }
    }
}
