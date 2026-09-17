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
        #elseif os(macOS)
        // Prefer Application Support for app builds; CLI/Linux still use ~/.playtorio via
        // the home-directory path below when running outside a sandboxed app bundle.
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return support.appendingPathComponent("Playtorio", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".playtorio", isDirectory: true)
        #else
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".playtorio", isDirectory: true)
        #endif
    }
}
