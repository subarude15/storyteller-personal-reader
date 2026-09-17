import Foundation

/// Shared sandbox-safe directories for Playtorio SQLite files.
enum PlaytorioPaths {
    /// Base directory for settings / cache / library on this platform.
    static func dataDirectory() -> URL {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Playtorio", isDirectory: true)
        #else
        // Prefer Application Support when present (macOS app); otherwise ~/.playtorio
        // for CLI/Linux. Use NSHomeDirectory() — never homeDirectoryForCurrentUser —
        // so this file stays iOS-safe even under multiplatform availability checking.
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return support.appendingPathComponent("Playtorio", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".playtorio", isDirectory: true)
        #endif
    }
}
