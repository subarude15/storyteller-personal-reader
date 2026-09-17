import Foundation
import Testing

@testable import SilveranKit

@Test func adStripChipLabelsCoverJobStates() {
    #expect(PodcastAdStripState.original.chipLabel == "Original")
    #expect(PodcastAdStripState.cleaning.chipLabel == "Cleaning…")
    #expect(PodcastAdStripState.clean.chipLabel == "Clean")
    #expect(PodcastAdStripState.failed.chipLabel == "Clean failed")
}

@Test func adStripEndpointJoinDoesNotEncodeSlashes() {
    // Mirrors PodcastAdStripHTTPPipeline.endpoint — keep in sync if that helper changes.
    func endpoint(_ base: URL, _ path: String) -> URL? {
        let trimmedBase = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(trimmedBase)/\(trimmedPath)")
    }
    let base = URL(string: "http://192.168.1.2:20129")!
    #expect(endpoint(base, "health")?.absoluteString == "http://192.168.1.2:20129/health")
    #expect(
        endpoint(base, "v1/jobs/abc/audio")?.absoluteString
            == "http://192.168.1.2:20129/v1/jobs/abc/audio"
    )
}
