import Foundation

/// How precisely a story position was mapped when switching formats.
public enum StoryPositionPrecision: String, Sendable, Equatable, CaseIterable {
    /// Verified SMIL / media-overlay fragment handoff was performed.
    case mediaOverlayAlignment
    /// Matched chapter / content href or title between formats.
    case contentReference
    /// Matched chapter plus relative progress within that chapter (timing verified).
    case chapterRelative
    /// Whole-book `totalProgression` percentage only (estimate across different clocks).
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

    /// Audiobook chapters with known wall-clock timing (verified for audio clock).
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

    /// EPUB TOC sections with **equal-weight** timing (unverified — not SMIL).
    public static func fromLabeledSections(_ sections: [SectionInfo]) -> [StoryPositionChapter] {
        let labeled = labeledSections(sections)
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

    /// Prefer SMIL cumsum timing for labeled sections; fall back to equal-weight TOC.
    /// `timingVerified` is true only when SMIL durations were used.
    public static func fromSectionsPreferringSmilTiming(
        _ sections: [SectionInfo]
    ) -> (chapters: [StoryPositionChapter], timingVerified: Bool) {
        let smilTotal = smilTotalDuration(in: sections)
        let labeled = labeledSections(sections)
        guard smilTotal > 0, !labeled.isEmpty else {
            return (fromLabeledSections(sections), false)
        }

        var chapters: [StoryPositionChapter] = []
        for section in labeled {
            let overlay = section.mediaOverlay
            guard let last = overlay.last else {
                chapters.append(
                    StoryPositionChapter(title: section.label ?? section.id, href: section.id)
                )
                continue
            }
            let startSeconds: Double = {
                guard let first = overlay.first else { return 0 }
                let prior = first.cumSumAtEnd - (first.end - first.begin)
                return max(prior, 0)
            }()
            let endSeconds = last.cumSumAtEnd
            let duration = max(endSeconds - startSeconds, 0)
            chapters.append(
                StoryPositionChapter(
                    title: section.label ?? section.id,
                    href: section.id,
                    startProgression: min(max(startSeconds / smilTotal, 0), 1),
                    durationFraction: min(max(duration / smilTotal, 0), 1),
                )
            )
        }
        return (chapters, true)
    }

    public static func smilTotalDuration(in sections: [SectionInfo]) -> TimeInterval {
        for section in sections.reversed() {
            if let last = section.mediaOverlay.last {
                return last.cumSumAtEnd
            }
        }
        return 0
    }

    private static func labeledSections(_ sections: [SectionInfo]) -> [SectionInfo] {
        sections.filter { section in
            guard let label = section.label?.trimmingCharacters(in: .whitespacesAndNewlines),
                !label.isEmpty
            else { return false }
            return true
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
    /// Wall-clock elapsed when source is standalone audiobook (seconds).
    public let sourceElapsedSeconds: TimeInterval?
    /// Standalone audiobook package duration (seconds) for the **source** when leaving audio.
    public let sourceAudiobookDuration: TimeInterval?
    /// Standalone audiobook package duration (seconds) for the **destination** when entering audio.
    public let destinationAudiobookDuration: TimeInterval?
    /// Destination chapters for title/href matching (may be empty when unknown).
    public let destinationChapters: [StoryPositionChapter]
    /// True when `destinationChapters` timing came from SMIL or audiobook wall-clock.
    public let destinationChaptersTimingVerified: Bool
    /// Destination EPUB/SMIL structure for fragment validation and audio→SMIL map.
    public let destinationBookStructure: [SectionInfo]
    /// SMIL total narration duration on destination (or source when mapping reverse).
    public let destinationSmilTotalDuration: TimeInterval?
    /// Source SMIL structure when leaving readaloud (for readaloud→audiobook).
    public let sourceBookStructure: [SectionInfo]
    public let sourceSmilTotalDuration: TimeInterval?
    /// Previously saved position on the destination book/format, if any.
    public let destinationSavedProgression: Double?
    public let destinationSavedTimestamp: Double?
    public let destinationSavedLocator: BookLocator?
    /// True only when local SMIL / media-overlay entries were verified.
    public let hasVerifiedMediaOverlay: Bool
    /// Progression gap above which an imprecise mapping offers a user choice.
    public let discrepancyThreshold: Double
    /// Max relative duration mismatch for audiobook↔SMIL timeline gate.
    public let timelineCompatibilityTolerance: Double

    public init(
        sourceBookID: BookID,
        destinationBookID: BookID,
        sourceCategory: LocalMediaCategory,
        destinationCategory: LocalMediaCategory,
        sourceLocator: BookLocator?,
        sourceProgression: Double,
        sourceTimestamp: Double? = nil,
        sourceElapsedSeconds: TimeInterval? = nil,
        sourceAudiobookDuration: TimeInterval? = nil,
        destinationAudiobookDuration: TimeInterval? = nil,
        destinationChapters: [StoryPositionChapter] = [],
        destinationChaptersTimingVerified: Bool = false,
        destinationBookStructure: [SectionInfo] = [],
        destinationSmilTotalDuration: TimeInterval? = nil,
        sourceBookStructure: [SectionInfo] = [],
        sourceSmilTotalDuration: TimeInterval? = nil,
        destinationSavedProgression: Double? = nil,
        destinationSavedTimestamp: Double? = nil,
        destinationSavedLocator: BookLocator? = nil,
        hasVerifiedMediaOverlay: Bool = false,
        discrepancyThreshold: Double = 0.15,
        timelineCompatibilityTolerance: Double = 0.08,
    ) {
        self.sourceBookID = sourceBookID
        self.destinationBookID = destinationBookID
        self.sourceCategory = sourceCategory
        self.destinationCategory = destinationCategory
        self.sourceLocator = sourceLocator
        self.sourceProgression = sourceProgression
        self.sourceTimestamp = sourceTimestamp
        self.sourceElapsedSeconds = sourceElapsedSeconds
        self.sourceAudiobookDuration = sourceAudiobookDuration
        self.destinationAudiobookDuration = destinationAudiobookDuration
        self.destinationChapters = destinationChapters
        self.destinationChaptersTimingVerified = destinationChaptersTimingVerified
        self.destinationBookStructure = destinationBookStructure
        self.destinationSmilTotalDuration = destinationSmilTotalDuration
        self.sourceBookStructure = sourceBookStructure
        self.sourceSmilTotalDuration = sourceSmilTotalDuration
        self.destinationSavedProgression = destinationSavedProgression
        self.destinationSavedTimestamp = destinationSavedTimestamp
        self.destinationSavedLocator = destinationSavedLocator
        self.hasVerifiedMediaOverlay = hasVerifiedMediaOverlay
        self.discrepancyThreshold = discrepancyThreshold
        self.timelineCompatibilityTolerance = timelineCompatibilityTolerance
    }
}

/// Destination-saved alternate offered when an imprecise mapping disagrees.
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
            mappingMethod: "destinationSaved",
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
    /// Diagnostic label for logs (e.g. smilFragment, chapterTitle, wholeBookPercent).
    public let mappingMethod: String

    public init(
        progression: Double,
        locator: BookLocator?,
        precision: StoryPositionPrecision,
        shouldApplyHandoff: Bool = true,
        conflictingDestinationSaved: StoryPositionAlternate? = nil,
        mappingMethod: String = "unspecified",
    ) {
        self.progression = progression
        self.locator = locator
        self.precision = precision
        self.shouldApplyHandoff = shouldApplyHandoff
        self.conflictingDestinationSaved = conflictingDestinationSaved
        self.mappingMethod = mappingMethod
    }

    public var shouldSeedDestination: Bool { shouldApplyHandoff }
}

/// Pure story-position mapping for ebook ↔ audiobook ↔ readaloud switches.
///
/// Priority:
/// 1. Verified SMIL fragment handoff (text↔text, or audio→SMIL when timelines compatible)
/// 2. Chapter / content-reference mapping (relative only when timing verified)
/// 3. Whole-book percentage (always approximate; never silent overwrite of saved dest)
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
        } else if let audioSmil = audiobookSmilTranslation(input: input, progression: clampedSource) {
            mapped = audioSmil
        } else if let smilAudio = smilAudiobookTranslation(input: input, progression: clampedSource)
        {
            mapped = smilAudio
        } else if let content = contentReferenceTranslation(input: input, progression: clampedSource)
        {
            mapped = content
        } else {
            mapped = wholeBookTranslation(input: input, progression: clampedSource)
        }

        debugLog(
            "[StoryPosition] \(input.sourceCategory.rawValue)→\(input.destinationCategory.rawValue) method=\(mapped.mappingMethod) precision=\(mapped.precision.rawValue) prog=\(mapped.progression) conflict=\(mapped.conflictingDestinationSaved != nil)"
        )
        return attachDiscrepancyChoice(mapped, input: input)
    }

    /// Duration match is necessary but not sufficient for identical narration.
    public static func areAudioTimelinesCompatible(
        audiobookDuration: TimeInterval,
        smilDuration: TimeInterval,
        tolerance: Double = 0.08,
    ) -> Bool {
        guard audiobookDuration > 1, smilDuration > 1 else { return false }
        let denom = max(audiobookDuration, smilDuration)
        let ratio = abs(audiobookDuration - smilDuration) / denom
        return ratio <= tolerance
    }

    /// Map wall-clock elapsed onto a SMIL fragment when structure is present.
    public static func mapElapsedToSmilFragment(
        elapsedSeconds: TimeInterval,
        smilTotalDuration: TimeInterval,
        sections: [SectionInfo],
    ) -> (href: String, fragment: String, progression: Double)? {
        guard smilTotalDuration > 0, !sections.isEmpty else { return nil }
        let target = min(max(elapsedSeconds, 0), smilTotalDuration)
        for section in sections {
            for entry in section.mediaOverlay {
                if entry.cumSumAtEnd >= target {
                    let href = entry.textHref.isEmpty ? section.id : entry.textHref
                    let base = href.split(separator: "#").first.map(String.init) ?? href
                    return (
                        base,
                        entry.textId,
                        clampProgression(entry.cumSumAtEnd / smilTotalDuration)
                    )
                }
            }
        }
        if let lastSection = sections.last(where: { !$0.mediaOverlay.isEmpty }),
            let last = lastSection.mediaOverlay.last
        {
            let href = last.textHref.isEmpty ? lastSection.id : last.textHref
            let base = href.split(separator: "#").first.map(String.init) ?? href
            return (base, last.textId, 1)
        }
        return nil
    }

    /// Whether `href` (+ optional fragment) exists in destination structure.
    public static func destinationContains(
        href: String,
        fragment: String?,
        in sections: [SectionInfo],
    ) -> Bool {
        guard !sections.isEmpty else { return true }  // unknown structure — allow
        guard !isPlaceholderReaderHref(href) else { return false }
        guard let sectionIndex = findSectionIndex(for: href, in: sections) else { return false }
        guard let fragment, !fragment.isEmpty else { return true }
        let section = sections[sectionIndex]
        if section.mediaOverlay.isEmpty { return true }  // ebook spine without SMIL
        return section.mediaOverlay.contains { $0.textId == fragment }
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

    public static func isApproximate(_ precision: StoryPositionPrecision) -> Bool {
        switch precision {
            case .wholeBookPercentage:
                return true
            case .chapterRelative, .contentReference, .mediaOverlayAlignment, .destinationSaved:
                return false
        }
    }

    public static func resolveReaderNavigationTarget(
        locator: BookLocator,
        progression: Double,
        bookStructure: [SectionInfo],
    ) -> (locator: BookLocator, navigation: ReaderNavigationStrategy) {
        let clamped = clampProgression(progression)
        if isAudioLocator(locator) {
            if let smil = mapElapsedToSmilFragment(
                elapsedSeconds: clamped
                    * (StoryPositionChapter.smilTotalDuration(in: bookStructure) > 0
                        ? StoryPositionChapter.smilTotalDuration(in: bookStructure)
                        : 1),
                smilTotalDuration: StoryPositionChapter.smilTotalDuration(in: bookStructure),
                sections: bookStructure,
            ), StoryPositionChapter.smilTotalDuration(in: bookStructure) > 0 {
                let loc = BookLocator(
                    href: smil.href,
                    type: "application/xhtml+xml",
                    title: locator.title,
                    locations: BookLocator.Locations(
                        fragments: [smil.fragment],
                        progression: nil,
                        position: nil,
                        totalProgression: clamped,
                        cssSelector: nil,
                        partialCfi: nil,
                        domRange: nil,
                    ),
                    text: nil,
                )
                return (loc, .fragment)
            }
            let resolved = resolveSpineLocator(
                progression: clamped,
                bookStructure: bookStructure,
                title: locator.title,
            )
            return (resolved, .bookFraction)
        }

        if let fragment = locator.locations?.fragments?.first, !fragment.isEmpty,
            !isPlaceholderReaderHref(locator.href)
        {
            if destinationContains(href: locator.href, fragment: fragment, in: bookStructure)
                || bookStructure.isEmpty
            {
                return (locator, .fragment)
            }
            // Fragment missing — fall back to spine href or closest chapter.
            if findSectionIndex(for: locator.href, in: bookStructure) != nil {
                var withoutFragment = locator
                withoutFragment = BookLocator(
                    href: locator.href,
                    type: locator.type,
                    title: locator.title,
                    locations: BookLocator.Locations(
                        fragments: nil,
                        progression: locator.locations?.progression,
                        position: locator.locations?.position,
                        totalProgression: locator.locations?.totalProgression ?? clamped,
                        cssSelector: locator.locations?.cssSelector,
                        partialCfi: locator.locations?.partialCfi,
                        domRange: locator.locations?.domRange,
                    ),
                    text: locator.text,
                )
                if locator.locations?.progression != nil {
                    return (withoutFragment, .sectionFraction)
                }
                return (withoutFragment, .href)
            }
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

    // MARK: - Private mapping paths

    private static func mediaOverlayTranslation(
        input: StoryPositionTranslationInput,
        progression: Double,
    ) -> StoryPositionTranslation? {
        guard input.hasVerifiedMediaOverlay else { return nil }
        guard let source = input.sourceLocator else { return nil }
        guard !isAudioLocator(source) else { return nil }
        guard let fragment = source.locations?.fragments?.first, !fragment.isEmpty else {
            return nil
        }
        guard input.destinationCategory == .synced || input.destinationCategory == .ebook else {
            return nil
        }

        let structure = input.destinationBookStructure
        if !structure.isEmpty,
            !destinationContains(href: source.href, fragment: fragment, in: structure)
        {
            // Prefer closest valid spine location over claiming exact fragment sync.
            if let sectionIndex = findSectionIndex(for: source.href, in: structure) {
                let section = structure[sectionIndex]
                let locator = locatorForDestination(
                    category: input.destinationCategory,
                    progression: progression,
                    chapterTitle: section.label ?? source.title,
                    chapterHref: section.id,
                    chapterProgression: source.locations?.progression,
                )
                debugLog(
                    "[StoryPosition] Fragment \(fragment) missing in destination; using spine \(section.id)"
                )
                return StoryPositionTranslation(
                    progression: progression,
                    locator: locator,
                    precision: .contentReference,
                    shouldApplyHandoff: true,
                    mappingMethod: "fragmentMissingClosestSpine",
                )
            }
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
            mappingMethod: "textFragmentHandoff",
        )
    }

    /// Audiobook wall-clock → SMIL fragment when timelines appear compatible.
    private static func audiobookSmilTranslation(
        input: StoryPositionTranslationInput,
        progression: Double,
    ) -> StoryPositionTranslation? {
        guard input.sourceCategory == .audio else { return nil }
        guard input.destinationCategory == .synced || input.destinationCategory == .ebook else {
            return nil
        }
        guard input.hasVerifiedMediaOverlay else { return nil }
        let structure = input.destinationBookStructure
        guard !structure.isEmpty else { return nil }

        let smilTotal =
            input.destinationSmilTotalDuration
            ?? StoryPositionChapter.smilTotalDuration(in: structure)
        guard smilTotal > 1 else { return nil }

        let audioDuration = input.sourceAudiobookDuration ?? 0
        guard
            areAudioTimelinesCompatible(
                audiobookDuration: audioDuration,
                smilDuration: smilTotal,
                tolerance: input.timelineCompatibilityTolerance,
            )
        else {
            debugLog(
                "[StoryPosition] Audiobook↔SMIL gate failed audio=\(audioDuration)s smil=\(smilTotal)s tolerance=\(input.timelineCompatibilityTolerance) — approximate fallback"
            )
            return nil
        }

        let elapsed: TimeInterval = {
            if let e = input.sourceElapsedSeconds, e >= 0 { return e }
            return progression * audioDuration
        }()
        // Scale into SMIL clock (durations close but not identical).
        let scaled = elapsed * (smilTotal / audioDuration)
        guard
            let mapped = mapElapsedToSmilFragment(
                elapsedSeconds: scaled,
                smilTotalDuration: smilTotal,
                sections: structure,
            )
        else { return nil }

        guard destinationContains(href: mapped.href, fragment: mapped.fragment, in: structure)
        else {
            debugLog(
                "[StoryPosition] SMIL map produced missing fragment \(mapped.href)#\(mapped.fragment)"
            )
            return nil
        }

        let locator = BookLocator(
            href: mapped.href,
            type: "application/xhtml+xml",
            title: input.sourceLocator?.title,
            locations: BookLocator.Locations(
                fragments: [mapped.fragment],
                progression: nil,
                position: nil,
                totalProgression: mapped.progression,
                cssSelector: nil,
                partialCfi: nil,
                domRange: nil,
            ),
            text: nil,
        )
        debugLog(
            "[StoryPosition] Audiobook→SMIL fragment \(mapped.href)#\(mapped.fragment) elapsed=\(elapsed)s scaled=\(scaled)s audioDur=\(audioDuration) smilDur=\(smilTotal)"
        )
        return StoryPositionTranslation(
            progression: mapped.progression,
            locator: locator,
            precision: .mediaOverlayAlignment,
            shouldApplyHandoff: true,
            mappingMethod: "audiobookTimeToSmilFragment",
        )
    }

    /// Readaloud SMIL time → audiobook wall-clock progression when compatible.
    private static func smilAudiobookTranslation(
        input: StoryPositionTranslationInput,
        progression: Double,
    ) -> StoryPositionTranslation? {
        guard input.sourceCategory == .synced else { return nil }
        guard input.destinationCategory == .audio else { return nil }
        let smilTotal =
            input.sourceSmilTotalDuration
            ?? StoryPositionChapter.smilTotalDuration(in: input.sourceBookStructure)
        let destAudio = input.destinationAudiobookDuration ?? 0
        guard smilTotal > 1, destAudio > 1 else { return nil }
        guard
            areAudioTimelinesCompatible(
                audiobookDuration: destAudio,
                smilDuration: smilTotal,
                tolerance: input.timelineCompatibilityTolerance,
            )
        else {
            debugLog(
                "[StoryPosition] SMIL→Audiobook gate failed smil=\(smilTotal)s audio=\(destAudio)s"
            )
            return nil
        }

        let smilElapsed = progression * smilTotal
        let audioProgression = clampProgression(smilElapsed / destAudio)
        let chapter = closestChapter(
            in: input.destinationChapters,
            progression: audioProgression,
        )
        let chapterProg: Double? = {
            guard let chapter,
                let start = chapter.startProgression,
                let duration = chapter.durationFraction,
                duration > 0
            else { return nil }
            return clampProgression((audioProgression - start) / duration)
        }()
        let locator = locatorForDestination(
            category: .audio,
            progression: audioProgression,
            chapterTitle: chapter?.title ?? input.sourceLocator?.title,
            chapterHref: chapter?.href,
            chapterProgression: chapterProg,
        )
        debugLog(
            "[StoryPosition] SMIL→Audiobook prog=\(audioProgression) smilElapsed=\(smilElapsed)s"
        )
        return StoryPositionTranslation(
            progression: audioProgression,
            locator: locator,
            precision: .mediaOverlayAlignment,
            shouldApplyHandoff: true,
            mappingMethod: "smilTimeToAudiobookProgress",
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
        let timingOK = input.destinationChaptersTimingVerified
        let mapped = chapterMappedProgression(
            source: source,
            matched: matched,
            fallback: fallback,
            allowRelative: timingOK,
        )
        let chapterProg = timingOK ? source.locations?.progression : nil
        let reusableSource: BookLocator? =
            (input.destinationCategory != .audio && !isAudioLocator(source)) ? source : nil
        let precision: StoryPositionPrecision =
            mapped.usedRelative ? .chapterRelative : .contentReference
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
            precision: precision,
            shouldApplyHandoff: true,
            mappingMethod: mapped.usedRelative ? "chapterRelativeVerified" : "chapterTitleOrHref",
        )
    }

    private static func wholeBookTranslation(
        input: StoryPositionTranslationInput,
        progression: Double,
    ) -> StoryPositionTranslation {
        // Do not invent chapter hrefs from equal-weight TOC for percentage estimates.
        let locator = locatorForDestination(
            category: input.destinationCategory,
            progression: progression,
            chapterTitle: input.sourceLocator?.title,
            chapterHref: nil,
            sourceLocator: {
                guard let source = input.sourceLocator, !isAudioLocator(source) else { return nil }
                return source
            }(),
            chapterProgression: nil,
        )
        return StoryPositionTranslation(
            progression: progression,
            locator: locator,
            precision: .wholeBookPercentage,
            shouldApplyHandoff: true,
            mappingMethod: "wholeBookPercentEstimate",
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
        // Prefer SMIL-timed chapters when available.
        let (smilChapters, verified) = StoryPositionChapter.fromSectionsPreferringSmilTiming(
            bookStructure
        )
        if verified, let chapter = closestChapter(in: smilChapters, progression: clamped) {
            let chapterProg: Double? = {
                guard let start = chapter.startProgression,
                    let duration = chapter.durationFraction,
                    duration > 0
                else { return nil }
                return clampProgression((clamped - start) / duration)
            }()
            return locatorForDestination(
                category: .ebook,
                progression: clamped,
                chapterTitle: title ?? chapter.title,
                chapterHref: chapter.href,
                chapterProgression: chapterProg,
            )
        }

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
        return locatorForDestination(
            category: .ebook,
            progression: clamped,
            chapterTitle: title ?? section.label,
            chapterHref: section.id,
        )
    }

    private static func attachDiscrepancyChoice(
        _ mapped: StoryPositionTranslation,
        input: StoryPositionTranslationInput,
    ) -> StoryPositionTranslation {
        // Exact alignment never prompts.
        if mapped.precision == .mediaOverlayAlignment {
            return mapped
        }

        guard let destProg = input.destinationSavedProgression, destProg > 0.02 else {
            return mapped
        }

        let shouldOffer: Bool = {
            if isApproximate(mapped.precision) {
                // Phase A: never silently overwrite with unverified percentage conversion.
                return true
            }
            if mapped.precision == .chapterRelative {
                return hasSignificantDestinationConflict(
                    input: input,
                    mappedProgression: mapped.progression,
                    requireNewerDestination: false,
                )
            }
            // contentReference: only when gap is large
            return hasSignificantDestinationConflict(
                input: input,
                mappedProgression: mapped.progression,
                requireNewerDestination: true,
            )
        }()

        guard shouldOffer else { return mapped }

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
            mappingMethod: mapped.mappingMethod,
        )
    }

    private static func hasSignificantDestinationConflict(
        input: StoryPositionTranslationInput,
        mappedProgression: Double,
        requireNewerDestination: Bool,
    ) -> Bool {
        guard let destProg = input.destinationSavedProgression else { return false }
        let gap = abs(clampProgression(mappedProgression) - clampProgression(destProg))
        guard gap >= input.discrepancyThreshold else { return false }
        guard destProg > 0.02 else { return false }
        guard requireNewerDestination else { return true }
        if let destTs = input.destinationSavedTimestamp, let sourceTs = input.sourceTimestamp {
            return destTs > sourceTs
        }
        return destProg > 0.05
    }

    private static func chapterMappedProgression(
        source: BookLocator,
        matched: StoryPositionChapter,
        fallback: Double,
        allowRelative: Bool,
    ) -> (progression: Double, usedRelative: Bool) {
        guard allowRelative,
            let start = matched.startProgression,
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

    public static func precisionLabel(for precision: StoryPositionPrecision) -> String {
        switch precision {
            case .mediaOverlayAlignment: return "exact alignment"
            case .contentReference: return "chapter match"
            case .chapterRelative: return "chapter estimate"
            case .wholeBookPercentage: return "approximate percentage"
            case .destinationSaved: return "saved place"
        }
    }
}
