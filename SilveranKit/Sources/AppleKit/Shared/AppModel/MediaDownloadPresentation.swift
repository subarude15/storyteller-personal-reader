import Foundation

/// Pure download presentation derivation formerly inlined on `MediaViewModel`.
///
/// Owns progress-fraction / active / completed math and local-path / preferred-category
/// selection. Does **not** own download tasks, observers, or path caches.
enum MediaDownloadPresentation {
    /// Clamp byte progress into `0...1`, or `nil` when expected is missing/non-positive.
    static func progressFraction(received: Int64, expected: Int64?) -> Double? {
        guard let expected, expected > 0 else { return nil }
        return min(max(Double(received) / Double(expected), 0), 1)
    }

    /// Current category activity rule: active while not finished and not skipped.
    /// Note: `isFailed` is intentionally ignored (paused records set failed without finishing).
    static func isCategoryActive(isFinished: Bool, wasSkipped: Bool) -> Bool {
        !isFinished && !wasSkipped
    }

    static func totalReceived(
        categories: some Collection<MediaViewModel.DownloadProgressState.CategoryState>
    ) -> Int64 {
        categories.reduce(0) { $0 + $1.latestReceived }
    }

    static func totalExpected(
        categories: some Collection<MediaViewModel.DownloadProgressState.CategoryState>
    ) -> Int64? {
        guard !categories.isEmpty else { return nil }
        var sum: Int64 = 0
        for state in categories {
            guard let expected = state.expected else { return nil }
            sum += expected
        }
        return sum
    }

    static func progressFraction(
        categories: some Collection<MediaViewModel.DownloadProgressState.CategoryState>
    ) -> Double? {
        progressFraction(received: totalReceived(categories: categories), expected: totalExpected(categories: categories))
    }

    static func isDownloadActive(
        categories: some Collection<MediaViewModel.DownloadProgressState.CategoryState>
    ) -> Bool {
        categories.contains { isCategoryActive(isFinished: $0.isFinished, wasSkipped: $0.wasSkipped) }
    }

    /// Empty category map is **not** completed.
    static func isDownloadCompleted(
        categories: some Collection<MediaViewModel.DownloadProgressState.CategoryState>
    ) -> Bool {
        !categories.isEmpty && categories.allSatisfy { $0.isFinished || $0.wasSkipped }
    }

    static func hasLocalPath(_ paths: MediaPaths?, category: LocalMediaCategory) -> Bool {
        paths?.path(for: category) != nil
    }

    static func localPath(from paths: MediaPaths?, category: LocalMediaCategory) -> URL? {
        paths?.path(for: category)
    }

    /// Precedence: synced → (audio vs ebook by preference when both) → audio → ebook → nil.
    static func preferredDownloadedCategory(
        hasSynced: Bool,
        hasAudio: Bool,
        hasEbook: Bool,
        preferAudioOverEbook: Bool,
    ) -> LocalMediaCategory? {
        if hasSynced { return .synced }
        if hasAudio && hasEbook {
            return preferAudioOverEbook ? .audio : .ebook
        }
        if hasAudio { return .audio }
        if hasEbook { return .ebook }
        return nil
    }
}
