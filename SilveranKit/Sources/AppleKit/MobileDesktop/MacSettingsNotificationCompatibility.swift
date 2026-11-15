// macOS-only compatibility for existing shared Settings notification posts.
// Their iOS declarations remain unchanged in PunkRallyShellSupport.swift.
// This declares names only; it adds no ingestion implementation or iOS behavior.
#if os(macOS)
import Foundation

extension Notification.Name {
    public static let punkRallyTorBoxIngestSucceeded = Notification.Name("punkRallyTorBoxIngestSucceeded")
    public static let punkRallyTorBoxIngestFailed = Notification.Name("punkRallyTorBoxIngestFailed")
}
#endif
