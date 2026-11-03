import Foundation

/// Platform-free scrubber tick geometry, jump-back history snapshots, and current-page
/// bookmark matching for the Apple Books–style reader chrome.
public enum ReaderScrubberPolicy {
    public enum ScrubScope: String, Codable, Sendable, Equatable, CaseIterable {
        case book
        case chapter
    }

    public struct ChapterTick: Equatable, Sendable, Identifiable {
        public let id: String
        public let sectionIndex: Int
        public let label: String
        public let fraction: Double

        public init(id: String, sectionIndex: Int, label: String, fraction: Double) {
            self.id = id
            self.sectionIndex = sectionIndex
            self.label = label
            self.fraction = min(max(fraction, 0.0), 1.0)
        }
    }

    public struct JumpSnapshot: Equatable, Sendable {
        public let sectionIndex: Int?
        public let cfi: String?
        public let href: String?
        public let chapterFraction: Double
        public let bookFraction: Double?
        public let pageNumber: Int?
        public let totalPages: Int?
        public let chapterTitle: String?
        public let isForwardTarget: Bool

        public init(
            sectionIndex: Int?,
            cfi: String?,
            href: String?,
            chapterFraction: Double,
            bookFraction: Double?,
            pageNumber: Int?,
            totalPages: Int?,
            chapterTitle: String?,
            isForwardTarget: Bool = false
        ) {
            self.sectionIndex = sectionIndex
            self.cfi = cfi
            self.href = href
            self.chapterFraction = min(max(chapterFraction, 0.0), 1.0)
            self.bookFraction = bookFraction.map { min(max($0, 0.0), 1.0) }
            self.pageNumber = pageNumber
            self.totalPages = totalPages
            self.chapterTitle = chapterTitle
            self.isForwardTarget = isForwardTarget
        }

        public var pillLabel: String {
            let prefix = isForwardTarget ? "Forward to" : "Back to"
            if let page = pageNumber, page > 0 {
                if let frac = bookFraction {
                    let pct = Int((frac * 100).rounded())
                    return "\(prefix) Page \(page) (\(pct)%)"
                }
                return "\(prefix) Page \(page)"
            }
            if let frac = bookFraction {
                let pct = Int((frac * 100).rounded())
                return "\(prefix) \(pct)%"
            }
            if let title = chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
                !title.isEmpty
            {
                let clipped = title.count > 22 ? String(title.prefix(20)) + "…" : title
                return "\(prefix) \(clipped)"
            }
            return "\(prefix) previous page"
        }

        public func isSignificantJump(
            toSection: Int?,
            toPage: Int?,
            toBookFraction: Double?
        ) -> Bool {
            if let fromSection = sectionIndex,
                let targetSection = toSection,
                fromSection != targetSection
            {
                return true
            }
            if let fromPage = pageNumber,
                let targetPage = toPage,
                abs(targetPage - fromPage) >= 2
            {
                return true
            }
            if let fromFrac = bookFraction,
                let targetFrac = toBookFraction,
                abs(targetFrac - fromFrac) >= 0.015
            {
                return true
            }
            return false
        }
    }

    /// Computes normalized book-wide chapter tick marks (`0.0 ... 1.0`), deduplicating
    /// closely-spaced subchapters so tick marks stay crisp on the scrubber track.
    public static func buildChapterTicks(
        tocEntries: [TocEntry],
        sections: [SectionInfo],
        sectionFractions: [Double]? = nil,
        maxTicks: Int = 40,
        minSeparation: Double = 0.012
    ) -> [ChapterTick] {
        let sectionStarts = resolvedSectionStartFractions(
            sections: sections,
            sectionFractions: sectionFractions
        )
        guard !sectionStarts.isEmpty else { return [] }

        var rawTicks: [ChapterTick] = []
        if !tocEntries.isEmpty {
            for (idx, entry) in tocEntries.enumerated() {
                let clampedSection = min(max(entry.sectionIndex, 0), sectionStarts.count - 1)
                let startFraction = sectionStarts[clampedSection]
                let trimmed = entry.label.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = trimmed.isEmpty ? "Chapter \(idx + 1)" : trimmed
                rawTicks.append(
                    ChapterTick(
                        id: "toc-\(idx)-\(clampedSection)",
                        sectionIndex: clampedSection,
                        label: label,
                        fraction: startFraction
                    )
                )
            }
        } else {
            let candidates = sections.filter {
                guard let label = $0.label?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return false
                }
                return !label.isEmpty
            }
            let sourceSections = candidates.isEmpty ? sections : candidates
            for section in sourceSections {
                let clampedSection = min(max(section.index, 0), sectionStarts.count - 1)
                let startFraction = sectionStarts[clampedSection]
                let trimmed = section.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let label = trimmed.isEmpty ? "Section \(clampedSection + 1)" : trimmed
                rawTicks.append(
                    ChapterTick(
                        id: "sec-\(clampedSection)",
                        sectionIndex: clampedSection,
                        label: label,
                        fraction: startFraction
                    )
                )
            }
        }

        let sorted = rawTicks.sorted { lhs, rhs in
            if abs(lhs.fraction - rhs.fraction) > 0.0001 {
                return lhs.fraction < rhs.fraction
            }
            return lhs.sectionIndex < rhs.sectionIndex
        }

        var deduplicated: [ChapterTick] = []
        for tick in sorted {
            if let last = deduplicated.last,
                abs(tick.fraction - last.fraction) < minSeparation
            {
                continue
            }
            deduplicated.append(tick)
        }

        guard deduplicated.count > maxTicks, maxTicks > 1 else {
            return deduplicated
        }

        var sampled: [ChapterTick] = []
        let step = Double(deduplicated.count - 1) / Double(maxTicks - 1)
        for i in 0..<maxTicks {
            let idx = min(Int((Double(i) * step).rounded()), deduplicated.count - 1)
            sampled.append(deduplicated[idx])
        }
        return sampled
    }

    /// Resolves starting fraction (`0.0 ... 1.0`) for each section in `sections`.
    public static func resolvedSectionStartFractions(
        sections: [SectionInfo],
        sectionFractions: [Double]? = nil
    ) -> [Double] {
        guard !sections.isEmpty else { return [] }

        if let explicit = sectionFractions, explicit.count >= sections.count {
            return (0..<sections.count).map { idx in
                min(max(explicit[idx], 0.0), 1.0)
            }
        }

        // If SMIL cumulative durations exist, derive section start fractions from audio duration.
        if let totalSmil = sections.reversed().compactMap({ $0.mediaOverlay.last?.cumSumAtEnd }).first,
            totalSmil > 0
        {
            var starts: [Double] = []
            var runningStart: Double = 0
            for section in sections {
                starts.append(min(max(runningStart / totalSmil, 0.0), 1.0))
                if let sectionEnd = section.mediaOverlay.last?.cumSumAtEnd, sectionEnd > runningStart {
                    runningStart = sectionEnd
                }
            }
            return starts
        }

        let count = sections.count
        guard count > 1 else { return [0.0] }
        return (0..<count).map { idx in
            Double(idx) / Double(count)
        }
    }

    /// Finds the active chapter tick at a scrubbed book fraction (`0.0 ... 1.0`).
    public static func activeChapter(
        atBookFraction fraction: Double,
        ticks: [ChapterTick],
        sections: [SectionInfo] = []
    ) -> ChapterTick? {
        let clamped = min(max(fraction, 0.0), 1.0)
        if !ticks.isEmpty {
            var match = ticks[0]
            for tick in ticks {
                if tick.fraction <= clamped + 0.0005 {
                    match = tick
                } else {
                    break
                }
            }
            return match
        }
        guard !sections.isEmpty else { return nil }
        let idx = min(
            max(Int((clamped * Double(sections.count)).rounded(.down)), 0),
            sections.count - 1
        )
        let sec = sections[idx]
        return ChapterTick(
            id: "sec-\(idx)",
            sectionIndex: idx,
            label: sec.label ?? "Chapter \(idx + 1)",
            fraction: Double(idx) / Double(max(sections.count, 1))
        )
    }

    /// Interior page tick positions (`0.0 < f < 1.0`) for chapter-level scrubbing when page count is modest.
    public static func pageTickFractions(totalPages: Int, maxTicks: Int = 36) -> [Double] {
        guard totalPages >= 3, totalPages <= maxTicks else { return [] }
        let denominator = Double(totalPages - 1)
        return (1..<(totalPages - 1)).map { pageIndex in
            Double(pageIndex) / denominator
        }
    }

    /// Converts a normalized chapter fraction (`0.0 ... 1.0`) to a 1-based page number (`1 ... totalPages`).
    public static func pageNumber(forChapterFraction fraction: Double, totalPages: Int) -> Int {
        guard totalPages > 1 else { return 1 }
        let clamped = min(max(fraction, 0.0), 1.0)
        return min(max(Int((clamped * Double(totalPages - 1)).rounded()) + 1, 1), totalPages)
    }

    /// Discrete token for triggering `UISelectionFeedbackGenerator` during scrubbing without spam.
    public static func hapticStepToken(
        for fraction: Double,
        scope: ScrubScope,
        totalPages: Int?,
        ticks: [ChapterTick]
    ) -> Int {
        let clamped = min(max(fraction, 0.0), 1.0)
        switch scope {
            case .chapter:
                if let total = totalPages, total > 1 {
                    return pageNumber(forChapterFraction: clamped, totalPages: total)
                }
                return Int((clamped * 25).rounded())
            case .book:
                let chapterRank = ticks.lastIndex(where: { $0.fraction <= clamped + 0.0005 }) ?? 0
                let percentBucket = Int((clamped * 50).rounded())
                return (chapterRank * 1_000) + percentBucket
        }
    }

    /// Returns the bookmark matching the current visible page, if any.
    public static func matchingBookmark(
        in bookmarks: [Highlight],
        sectionIndex: Int?,
        cfi: String?,
        href: String?,
        bookFraction: Double?,
        totalPagesInSection: Int?,
        sections: [SectionInfo]
    ) -> Highlight? {
        let candidates = bookmarks.filter(\.isBookmark)
        guard !candidates.isEmpty else { return nil }

        let trimmedCfi = cfi?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedCfi.isEmpty {
            if let exactCfi = candidates.first(where: {
                $0.locator.locations?.partialCfi?.trimmingCharacters(in: .whitespacesAndNewlines)
                    == trimmedCfi
            }) {
                return exactCfi
            }
        }

        for bookmark in candidates {
            let bookmarkSection = findSectionIndex(for: bookmark.locator.href, in: sections)
            let sameSection: Bool = {
                if let sectionIndex, let bookmarkSection {
                    return sectionIndex == bookmarkSection
                }
                if let href, !href.isEmpty {
                    return bookmark.locator.href == href
                        || bookmark.locator.href.hasSuffix("/\(href)")
                        || href.hasSuffix("/\(bookmark.locator.href)")
                }
                return false
            }()
            guard sameSection else { continue }

            if let totalPagesInSection, totalPagesInSection <= 1 {
                return bookmark
            }

            if let currentFraction = bookFraction,
                let bookmarkFraction = bookmark.locator.locations?.totalProgression
            {
                if abs(currentFraction - bookmarkFraction) <= 0.008 {
                    return bookmark
                }
            }
        }

        return nil
    }
}
