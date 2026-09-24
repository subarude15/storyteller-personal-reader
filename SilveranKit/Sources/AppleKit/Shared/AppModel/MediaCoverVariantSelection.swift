import Foundation

/// Pure cover-variant selection for library / card presentation.
///
/// Owns only the deterministic ebook-vs-audiobook preference rules formerly
/// inlined on `MediaViewModel`. Load/cache/network cover pipelines stay on
/// the view model.
enum MediaCoverVariantSelection {
    /// Default variant when the UI has no explicit `CoverPreference`.
    /// Ebook (when present) wins over audiobook; otherwise audio-square; else standard.
    static func coverVariant(for item: BookMetadata) -> MediaViewModel.CoverVariant {
        if item.hasAvailableEbook {
            return .standard
        }
        if item.hasAvailableAudiobook {
            return .audioSquare
        }
        return .standard
    }

    /// Variant for an explicit user cover preference (library chrome).
    ///
    /// Current quirks preserved intentionally:
    /// - `.preferEbook` and `.storytellerDouble` use the same rule.
    /// - `.preferAudiobook` checks `hasAvailableAudiobook || isAudiobookOnly`
    ///   (the second clause is redundant given `isAudiobookOnly`'s definition).
    static func coverVariant(
        for item: BookMetadata,
        preference: CoverPreference,
    ) -> MediaViewModel.CoverVariant {
        switch preference {
            case .preferEbook, .storytellerDouble:
                if item.hasAvailableEbook {
                    return .standard
                }
                return item.hasAvailableAudiobook ? .audioSquare : .standard
            case .preferAudiobook:
                if item.hasAvailableAudiobook || item.isAudiobookOnly {
                    return .audioSquare
                }
                return .standard
        }
    }
}
