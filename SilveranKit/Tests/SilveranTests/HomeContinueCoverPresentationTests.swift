import Foundation
import SilveranAppleKit
import SilveranKit
import Testing

@Suite("Home Continue cover presentation")
struct HomeContinueCoverPresentationTests {
    @Test func artworkUpdatesWhenContinueBookChangesFromThemToTheTroop() {
        let themID = BookID(sourceID: "storyteller", uuid: "them-cover-a")
        let troopID = BookID(sourceID: "storyteller", uuid: "troop-cover-b")

        let them = HomeContinueCoverPresentation.book(id: themID, title: "Them")
        let troop = HomeContinueCoverPresentation.book(id: troopID, title: "The Troop")

        // Simulate Continue transitioning Them (artwork A) → The Troop (artwork B).
        let previous: HomeContinueCoverPresentation? = them
        let next: HomeContinueCoverPresentation? = troop

        #expect(previous?.title == "Them")
        #expect(next?.title == "The Troop")
        #expect(previous?.artworkIdentity != next?.artworkIdentity)
        #expect(
            HomeContinueCoverPresentation.mustClearCachedBookImage(previous: previous, next: next)
        )

        // After the transition, Continue exposes Troop artwork — not Them's.
        let active = next
        #expect(active?.artworkIdentity == troop.artworkIdentity)
        #expect(active?.artworkIdentity != them.artworkIdentity)
        #expect(active?.itemID == "book:storyteller/troop-cover-b")
    }

    @Test func podcastArtworkIdentityIncludesResolvedCoverURL() {
        let urlA = URL(string: "https://cdn.example/pod-a.jpg")!
        let urlB = URL(string: "https://cdn.example/pod-b.jpg")!
        let episodeA = HomeContinueCoverPresentation.podcast(
            episodeID: "ep-1",
            title: "Episode One",
            coverURL: urlA
        )
        let episodeB = HomeContinueCoverPresentation.podcast(
            episodeID: "ep-2",
            title: "Episode Two",
            coverURL: urlB
        )

        #expect(episodeA.artworkIdentity != episodeB.artworkIdentity)
        #expect(episodeA.artworkIdentity.contains(urlA.absoluteString))
        #expect(
            HomeContinueCoverPresentation.mustClearCachedBookImage(
                previous: episodeA,
                next: episodeB
            )
        )
    }

    @Test func sameItemDoesNotForceCoverReload() {
        let id = BookID(sourceID: "storyteller", uuid: "same")
        let first = HomeContinueCoverPresentation.book(id: id, title: "Same")
        let second = HomeContinueCoverPresentation.book(id: id, title: "Same")
        #expect(
            !HomeContinueCoverPresentation.mustClearCachedBookImage(
                previous: first,
                next: second
            )
        )
    }
}
