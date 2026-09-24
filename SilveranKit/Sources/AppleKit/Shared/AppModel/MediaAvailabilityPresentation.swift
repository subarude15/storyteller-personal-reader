import Foundation

/// Pure library media-kind / narration availability matching.
///
/// Formerly duplicated on `MediaViewModel` and `LibraryDerivationActor` (including
/// nested `Context`). Format presence itself stays on `BookMetadata`
/// (`hasAvailable*`, `isEbookOnly`, …).
///
/// Two narration matchers are intentional current behavior:
/// - ``matchesItemsNarrationFilter`` — used by `items(for:)` lists (`hasAnyAudiobookAsset`)
/// - ``matchesNarrationFilter`` — used after merging audiobook-only shelves (`isEbookOnly` / audio||readaloud)
enum MediaAvailabilityPresentation {
    /// Shelf kind membership.
    /// - `.ebook`: has ebook **or** aligned readaloud
    /// - `.audiobook`: audiobook present and **not** ebook and **not** readaloud
    static func matchesKind(_ metadata: BookMetadata, kind: MediaKind) -> Bool {
        switch kind {
            case .ebook:
                return metadata.hasAvailableEbook || metadata.hasAvailableReadaloud
            case .audiobook:
                return !metadata.hasAvailableEbook && !metadata.hasAvailableReadaloud
                    && metadata.hasAvailableAudiobook
        }
    }

    /// Narration filter for `items(for:)` / media-grid item lists.
    static func matchesItemsNarrationFilter(
        _ item: BookMetadata,
        filter: NarrationFilter,
    ) -> Bool {
        switch filter {
            case .both:
                return true
            case .withAudio:
                return item.hasAnyAudiobookAsset
            case .withoutAudio:
                return !item.hasAnyAudiobookAsset
        }
    }

    /// Stricter narration filter used when counting/filtering after optional
    /// audiobook-only shelf merge (`shouldIncludeAudiobookOnlyItems`).
    static func matchesNarrationFilter(
        _ item: BookMetadata,
        filter: NarrationFilter,
    ) -> Bool {
        switch filter {
            case .both:
                return true
            case .withAudio:
                return item.hasAvailableAudiobook || item.hasAvailableReadaloud
            case .withoutAudio:
                return item.isEbookOnly
        }
    }

    /// Whether media-grid derivation should union the audiobook-only shelf.
    static func shouldIncludeAudiobookOnlyItems(for filter: NarrationFilter) -> Bool {
        switch filter {
            case .both, .withAudio:
                return true
            case .withoutAudio:
                return false
        }
    }

    /// Append `supplemental` books whose IDs are not already in `primary` (stable order).
    static func mergeItems(
        _ primary: [BookMetadata],
        with supplemental: [BookMetadata],
    ) -> [BookMetadata] {
        guard !supplemental.isEmpty else { return primary }
        var result = primary
        var seen = Set(result.map(\.id))
        for item in supplemental where !seen.contains(item.id) {
            seen.insert(item.id)
            result.append(item)
        }
        return result
    }
}
