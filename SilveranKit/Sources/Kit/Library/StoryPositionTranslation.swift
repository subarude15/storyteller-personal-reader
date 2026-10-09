import Foundation

/// How precisely a story position was mapped when switching formats.
public enum StoryPositionPrecision: String, Sendable, Equatable, CaseIterable {
    /// Verified SMIL / media-overlay fragment handoff was performed.
    case mediaOverlayAlignment
    /// Matched chapter / content href or title between formats.
    case contentReference
    /// Matched chapter plus relative progress within that chapter.
    case chapterRelative
    /// Whole-book `totalProgression` percentage only (estimate).
    case wholeBookPercentage
    /// User (or policy) chose the destination format's previously saved position.
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

    /// Audiobook chapters with known wall-clock timing.
    public static func fromAudiobookChapters(
        _ chapters: [AudiobookChapter],
        totalDuration: TimeInterval,
    ) -> [StoryPositionChapter] {
        guard totalDuration > 0 else {
            return chapters.map {
                StoryPositionChapter(title: $0.title, href: $0.href)
            }
        }
        return chapters.map { chapter in
            StoryPositionChapter(
                title: chapter.title,
                href: chapter.href,
                startProgression: min(max(chapter.startTime / totalDuration, 0), 1),
                durationFraction: min(max(chapter.duration / totalDuration, 0), 1),
            )
        }
    }

    /// Session chapters (duration only) — reconstruct start offsets cumulatively.
    public static func fromSessionChapters(
        _ chapters: [AudiobookSessionChapter],
        totalDuration: TimeInterval,
    ) -> [StoryPositionChapter] {
        var cursor: TimeInterval = 0
        return chapters.map { chapter in
            let start = totalDuration > 0 ? cursor / totalDuration : nil
            let fraction = totalDuration > 0 ? chapter.duration / totalDuration : nil
            cursor += chapter.duration
            return StoryPositionChapter(
                title: chapter.title,
                href: chapter.id,
                startProgression: start.map { min(max($0, 0), 1) },
                durationFraction: fraction.map { min(max($0, 0), 1) },
            )
        }
    }

    /// EPUB / readaloud TOC sections (labeled spine entries).
    public static func fromLabeledSections(_ sections: [SectionInfo]) -> [StoryPositionChapter] {
        let labeled = sections.filter { section in
            guard let label = section.label?.trimmingCharacters(in: .whitespacesAndNewlines),
                !label.isEmpty
            else { return false }
            return true
        }
        guard !labeled.isEmpty else { return [] }
        let count = Double(labeled.count)
        return labeled.enumerated().map { index, section in
            StoryPositionChapter(
                title: section.label ?? "Chapter \(index + 1)",
                href: section.id,
                startProgression: Double(index) / count,
                durationFraction: 1 / count,
            )
        }
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
    /// True only when local SMIL / media-overlay entries were verified (not merely
    /// Storyteller readaloud availability / ALIGNED status).
    public let hasVerifiedMediaOverlay: Bool
    /// Progression gap above which an imprecise mapping offers a user choice
    /// against the destination's saved place.
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
        hasVerifiedMediaOverlay: Bool = false,
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
        self.hasVerifiedMediaOverlay = hasVerifiedMediaOverlay
        self.discrepancyThreshold = discrepancyThreshold
    }
}

/// Destination-saved alternate offered when an imprecise mapping disagrees.
/// Separate from `StoryPositionTranslation` so the value type is not recursive.
public struct StoryPositionAlternate: Sendable, Equatable {
    public let progression: Double
    public let locator: BookLocator?
    public let precision: StoryPositionPrecision
    public let shouldApplyHandoff: Bool

    public init(
        progression: Double,
        locator: BookLocator?,
        precision: StoryPositionPrecision = .destinationSaved,
        shouldApplyHandoff: Bool = true,
    ) {
        self.progression = progression
        self.locator = locator
        self.precision = precision
        self.shouldApplyHandoff = shouldApplyHandoff
    }

    public var asTranslation: StoryPositionTranslation {
        StoryPositionTranslation(
            progression: progression,
            locator: locator,
            precision: precision,
            shouldApplyHandoff: shouldApplyHandoff,
            conflictingDestinationSaved: nil,
        )
    }
}

public struct StoryPositionTranslation: Sendable, Equatable {
    public let progression: Double
    public let locator: BookLocator?
    public let precision: StoryPositionPrecision
    /// Always apply via `FormatSwitchHandoffStore` for intentional switches.
    public let shouldApplyHandoff: Bool
    /// When non-nil, present a choice: mapped (self) vs this destination-saved alternate.
    public let conflictingDestinationSaved: StoryPositionAlternate?

    public init(
        progression: Double,
        locator: BookLocator?,
        precision: StoryPositionPrecision,
        shouldApplyHandoff: Bool = true,
        conflictingDestinationSaved: StoryPositionAlternate? = nil,
    ) {
        self.progression = progression
        self.locator = locator
        self.precision = precision
        self.shouldApplyHandoff = shouldApplyHandoff
        self.conflictingDestinationSaved = conflictingDestinationSaved
    }

    /// Legacy alias used by earlier call sites / tests.
    public var shouldSeedDestination: Bool { shouldApplyHandoff }
}

/// Pure story-position mapping for ebook ↔ audiobook ↔ readaloud switches.
///
/// Priority:
/// 1. Verified media-overlay fragment handoff (only when a real mapping ran)
/// 2. Chapter / content-reference mapping
/// 3. Chapter-relative progress estimation
/// 4. Whole-book percentage
///
/// Imprecise mappings that disagree with a newer destination saved place expose
/// `conflictingDestinationSaved` for an explicit user choice — never silent replace.
public enum StoryPositionTranslator {
    public static func normalizedChapterTitle(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let stripped = folded
            .replacingOccurrences(
                of: #"^(chapter|ch\.?|part|section)\s*[\dIVXLCDM]+[.:)\-]?\s*"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"^[\dIVXLCDM]+[.:)\-]\s*"#,
                with: "",
                options: .regularExpression
            )
        let cleaned = Self.alphanumericWords(stripped)
        // "Chapter 4" alone strips to empty — keep the full token so equals still match.
        return cleaned.isEmpty ? Self.alphanumericWords(folded) : cleaned
    }

    private static func alphanumericWords(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == " " ? Character(scalar) : " "
        }
        return String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func translate(_ input: StoryPositionTranslationInput) -> StoryPositionTranslation {
        let clampedSource = clampProgression(input.sourceProgression)

        let mapped: StoryPositionTranslation
        if let overlay = mediaOverlayTranslation(input: input, progression: clampedSource) {
            mapped = overlay
        } else if let content = contentReferenceTranslation(input: input, progression: clampedSource)
        {
            mapped = content
        } else {
            mapped = wholeBookTranslation(input: input, progression: clampedSource)
        }

        return attachDiscrepancyChoice(mapped, input: input)
    }

    public static func locatorForDestination(
        category: LocalMediaCategory,
        progression: Double,
        chapterTitle: String? = nil,
        chapterHref: String? = nil,
        sourceLocator: BookLocator? = nil,
        chapterProgression: Double? = nil,
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
                        progression: chapterProgression.map(clampProgression),
                        position: nil,
                        totalProgression: clamped,
                        cssSelector: nil,
                        partialCfi: nil,
                        domRange: nil,
                    ),
                    text: nil,
                )
            case .ebook, .synced:
                if let source = sourceLocator,
                    !isAudioLocator(source)
                {
                    let locations = BookLocator.Locations(
                        fragments: source.locations?.fragments,
                        progression: source.locations?.progression ?? chapterProgression.map(
                            clampProgression
                        ),
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
                        progression: chapterProgression.map(clampProgression),
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

    public static func isAudioLocator(_ locator: BookLocator) -> Bool {
        locator.type.contains("audio") || locator.href.hasPrefix("audiobook")
    }

    /// Placeholder / non-spine hrefs that cannot drive Foliate navigation alone.
    public static func isPlaceholderReaderHref(_ href: String) -> Bool {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let lower = trimmed.lowercased()
        return lower == "ebook" || lower == "audiobook" || lower.hasPrefix("audiobook://")
    }

    public static func isImprecise(_ precision: StoryPositionPrecision) -> Bool {
        switch precision {
            case .wholeBookPercentage, .chapterRelative:
                return true
            case .mediaOverlayAlignment, .contentReference, .destinationSaved:
                return false
        }
    }

    /// Resolve a format-switch ebook/readaloud locator into something Foliate can open.
    /// Percentage-only / placeholder hrefs map onto the closest spine section.
    public static func resolveReaderNavigationTarget(
        locator: BookLocator,
        progression: Double,
        bookStructure: [SectionInfo],
    ) -> (locator: BookLocator, navigation: ReaderNavigationStrategy) {
        let clamped = clampProgression(progression)
        if isAudioLocator(locator) {
            let resolved = resolveSpineLocator(
                progression: clamped,
                bookStructure: bookStructure,
                title: locator.title,
            )
            return (resolved, .bookFraction)
        }

        if let fragment = locator.locations?.fragments?.first, !fragment.isEmpty,
            !isPlaceholderReaderHref(locator.href),
            findSectionIndex(for: locator.href, in: bookStructure) != nil
        {
            return (locator, .fragment)
        }

        if !isPlaceholderReaderHref(locator.href),
            findSectionIndex(for: locator.href, in: bookStructure) != nil
        {
            if locator.locations?.progression != nil {
                return (locator, .sectionFraction)
            }
            if locator.locations?.totalProgression != nil {
                return (locator, .bookFraction)
            }
            return (locator, .href)
        }

        let resolved = resolveSpineLocator(
            progression: clamped,
            bookStructure: bookStructure,
            title: locator.title,
        )
        debugLog(
            "[StoryPosition] Resolved placeholder/invalid href=\(locator.href) → spine=\(resolved.href) prog=\(clamped)"
        )
        return (resolved, .bookFraction)
    }

    public enum ReaderNavigationStrategy: String, Sendable, Equatable {
        case fragment
        case sectionFraction
        case bookFraction
        case href
    }

    // MARK: - Private

    private static func mediaOverlayTranslation(
        input: StoryPositionTranslationInput,
        progression: Double,
    ) -> StoryPositionTranslation? {
        // Only claim mediaOverlayAlignment when verified SMIL exists AND we perform
        // a real fragment-bearing text handoff into a reader/readaloud destination.
        guard input.hasVerifiedMediaOverlay else { return nil }
        guard let source = input.sourceLocator else { return nil }
        guard !isAudioLocator(source) else { return nil }
        guard let fragment = source.locations?.fragments?.first, !fragment.isEmpty else {
            return nil
        }
        guard input.destinationCategory == .synced || input.destinationCategory == .ebook else {
            return nil
        }

        let locator = locatorForDestination(
            category: input.destinationCategory,
            progression: progression,
            chapterTitle: source.title,
            chapterHref: source.href,
            sourceLocator: source,
        )
        return StoryPositionTranslation(
            progression: progression,
            locator: locator,
            precision: .mediaOverlayAlignment,
            shouldApplyHandoff: true,
        )
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
            return translationForChapterMatch(
                input: input,
                source: source,
                matched: match,
                fallback: progression,
            )
        }

        if let title = source.title, !title.isEmpty {
            let needle = normalizedChapterTitle(title)
            guard !needle.isEmpty,
                let match = chapters.first(where: {
                    normalizedChapterTitle($0.title) == needle
                })
            else { return nil }
            return translationForChapterMatch(
                input: input,
                source: source,
                matched: match,
                fallback: progression,
            )
        }

        return nil
    }

    private static func translationForChapterMatch(
        input: StoryPositionTranslationInput,
        source: BookLocator,
        matched: StoryPositionChapter,
        fallback: Double,
    ) -> StoryPositionTranslation {
        let mapped = chapterMappedProgression(
            source: source,
            matched: matched,
            fallback: fallback,
        )
        let chapterProg = source.locations?.progression
        // Never reuse an audio-shaped locator for ebook/readaloud destinations.
        let reusableSource: BookLocator? =
            (input.destinationCategory != .audio && !isAudioLocator(source)) ? source : nil
        return StoryPositionTranslation(
            progression: mapped.progression,
            locator: locatorForDestination(
                category: input.destinationCategory,
                progression: mapped.progression,
                chapterTitle: matched.title,
                chapterHref: matched.href,
                sourceLocator: reusableSource,
                chapterProgression: chapterProg,
            ),
            precision: mapped.usedRelative ? .chapterRelative : .contentReference,
            shouldApplyHandoff: true,
        )
    }

    private static func wholeBookTranslation(
        input: StoryPositionTranslationInput,
        progression: Double,
    ) -> StoryPositionTranslation {
        let chapter = closestChapter(in: input.destinationChapters, progression: progression)
        let chapterProg: Double? = {
            guard let chapter,
                let start = chapter.startProgression,
                let duration = chapter.durationFraction,
                duration > 0
            else { return nil }
            return clampProgression((progression - start) / duration)
        }()
        let reusableSource: BookLocator? = {
            guard let source = input.sourceLocator, !isAudioLocator(source) else { return nil }
            return source
        }()
        let locator = locatorForDestination(
            category: input.destinationCategory,
            progression: progression,
            chapterTitle: chapter?.title ?? input.sourceLocator?.title,
            chapterHref: chapter?.href,
            sourceLocator: reusableSource,
            chapterProgression: chapterProg,
        )
        return StoryPositionTranslation(
            progression: progression,
            locator: locator,
            precision: .wholeBookPercentage,
            shouldApplyHandoff: true,
        )
    }

    private static func closestChapter(
        in chapters: [StoryPositionChapter],
        progression: Double,
    ) -> StoryPositionChapter? {
        guard !chapters.isEmpty else { return nil }
        let clamped = clampProgression(progression)
        var best: StoryPositionChapter?
        var bestDistance = Double.greatestFiniteMagnitude
        for chapter in chapters {
            guard let start = chapter.startProgression else { continue }
            let end = start + max(chapter.durationFraction ?? 0, 0)
            if clamped >= start && clamped <= max(end, start) {
                return chapter
            }
            let distance = min(abs(clamped - start), abs(clamped - end))
            if distance < bestDistance {
                bestDistance = distance
                best = chapter
            }
        }
        return best ?? chapters.first
    }

    private static func resolveSpineLocator(
        progression: Double,
        bookStructure: [SectionInfo],
        title: String?,
    ) -> BookLocator {
        let clamped = clampProgression(progression)
        guard !bookStructure.isEmpty else {
            return locatorForDestination(
                category: .ebook,
                progression: clamped,
                chapterTitle: title,
            )
        }
        let index = min(
            max(Int((clamped * Double(bookStructure.count)).rounded(.down)), 0),
            bookStructure.count - 1,
        )
        let section = bookStructure[index]
        let start = Double(index) / Double(bookStructure.count)
        let duration = 1 / Double(bookStructure.count)
        let chapterProg = duration > 0 ? clampProgression((clamped - start) / duration) : 0
        return locatorForDestination(
            category: .ebook,
            progression: clamped,
            chapterTitle: title ?? section.label,
            chapterHref: section.id,
            chapterProgression: chapterProg,
        )
    }

    private static func attachDiscrepancyChoice(
        _ mapped: StoryPositionTranslation,
        input: StoryPositionTranslationInput,
    ) -> StoryPositionTranslation {
        guard isImprecise(mapped.precision),
            hasSignificantDestinationConflict(input: input, mappedProgression: mapped.progression),
            let destProg = input.destinationSavedProgression
        else {
            return mapped
        }

        let alternate = StoryPositionAlternate(
            progression: clampProgression(destProg),
            locator: input.destinationSavedLocator
                ?? locatorForDestination(
                    category: input.destinationCategory,
                    progression: destProg,
                    sourceLocator: input.destinationSavedLocator,
                ),
            precision: .destinationSaved,
            shouldApplyHandoff: true,
        )
        return StoryPositionTranslation(
            progression: mapped.progression,
            locator: mapped.locator,
            precision: mapped.precision,
            shouldApplyHandoff: true,
            conflictingDestinationSaved: alternate,
        )
    }

    private static func hasSignificantDestinationConflict(
        input: StoryPositionTranslationInput,
        mappedProgression: Double,
    ) -> Bool {
        guard let destProg = input.destinationSavedProgression else { return false }
        let gap = abs(clampProgression(mappedProgression) - clampProgression(destProg))
        guard gap >= input.discrepancyThreshold else { return false }
        guard destProg > 0.02 else { return false }
        if let destTs = input.destinationSavedTimestamp, let sourceTs = input.sourceTimestamp {
            return destTs > sourceTs
        }
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

    public static func progressPercentLabel(_ progression: Double) -> String {
        let clamped = min(max(progression, 0), 1)
        return "\(Int((clamped * 100).rounded()))%"
    }
}
