import Foundation
import SilveranAppleWidgets
import Testing

@Suite("Pending widget deep links")
struct InkAmpPendingDeepLinkTests {
    @Test func warmBrowseQueueSelectsHome() {
        let store = InkAmpPendingDeepLinkStore()
        let effect = InkAmpPendingDeepLinkDelivery.deliverWarm(
            url: InkAmpContinueLink.homeURL,
            store: store,
        )
        #expect(effect == .selectHome)
        #expect(store.peek() == nil)
        #expect(store.consume() == nil)
    }

    @Test func warmContinueOpensCurrentItem() {
        let store = InkAmpPendingDeepLinkStore()
        let effect = InkAmpPendingDeepLinkDelivery.deliverWarm(
            url: InkAmpContinueLink.continueURL,
            store: store,
        )
        #expect(effect == .selectHomeAndContinue(itemID: nil))
        #expect(store.consume() == nil)
    }

    @Test func warmUpNextOpensExactItem() {
        let store = InkAmpPendingDeepLinkStore()
        let id = "book:storyteller/abc-def"
        let effect = InkAmpPendingDeepLinkDelivery.deliverWarm(
            url: InkAmpContinueLink.queueItemURL(id: id),
            store: store,
        )
        #expect(effect == .selectHomeAndContinue(itemID: id))
        #expect(store.consume() == nil)
    }

    @Test func coldLaunchRetainsThenConsumesOnce() {
        let store = InkAmpPendingDeepLinkStore()
        // URL arrives before PunkRallyTabView exists.
        let retained = InkAmpPendingDeepLinkDelivery.retainCold(
            url: InkAmpContinueLink.homeURL,
            store: store,
        )
        #expect(retained == .home)
        #expect(store.peek() == .home)

        // Shell mounts and consumes once.
        let first = InkAmpPendingDeepLinkDelivery.consumeCold(store: store)
        #expect(first == .selectHome)
        #expect(store.peek() == nil)

        // Second consume must not fire again.
        let second = InkAmpPendingDeepLinkDelivery.consumeCold(store: store)
        #expect(second == nil)
    }

    @Test func coldContinueWithItemPreservesID() {
        let store = InkAmpPendingDeepLinkStore()
        let id = "pod:episode-guid"
        #expect(
            InkAmpPendingDeepLinkDelivery.retainCold(
                url: InkAmpContinueLink.queueItemURL(id: id),
                store: store,
            ) == .continueItem(id)
        )
        #expect(
            InkAmpPendingDeepLinkDelivery.consumeCold(store: store)
                == .selectHomeAndContinue(itemID: id)
        )
        #expect(InkAmpPendingDeepLinkDelivery.consumeCold(store: store) == nil)
    }

    @Test func pendingHomeDoesNotFireTwiceAfterWarmDelivery() {
        let store = InkAmpPendingDeepLinkStore()
        #expect(
            InkAmpPendingDeepLinkDelivery.deliverWarm(
                url: InkAmpContinueLink.homeURL,
                store: store,
            ) == .selectHome
        )
        // Shell onAppear after warm delivery must be a no-op.
        #expect(InkAmpPendingDeepLinkDelivery.consumeCold(store: store) == nil)
    }

    @Test func unrelatedURLsAreNotStored() {
        let store = InkAmpPendingDeepLinkStore()
        #expect(
            InkAmpContinueLink.pendingDeepLink(from: URL(string: "https://example.com")!) == nil
        )
        #expect(
            InkAmpContinueLink.storePendingDeepLink(
                from: URL(string: "punkrally://settings")!,
                store: store,
            ) == nil
        )
        #expect(store.peek() == nil)
        #expect(
            InkAmpContinueLink.storePendingDeepLink(
                from: InkAmpContinueLink.toggleURL,
                store: store,
            ) == nil
        )
        #expect(store.peek() == nil)
        #expect(
            InkAmpPendingDeepLinkDelivery.deliverWarm(
                url: URL(string: "magnet:?xt=urn:btih:abc")!,
                store: store,
            ) == nil
        )
    }

    @Test func parserMapsHomeContinueAndItem() {
        #expect(InkAmpContinueLink.pendingDeepLink(from: InkAmpContinueLink.homeURL) == .home)
        #expect(
            InkAmpContinueLink.pendingDeepLink(from: InkAmpContinueLink.continueURL)
                == .continueItem(nil)
        )
        let item = InkAmpContinueLink.queueItemURL(id: "book:src/uuid")
        #expect(
            InkAmpContinueLink.pendingDeepLink(from: item) == .continueItem("book:src/uuid")
        )
    }

    @Test func sharedStoreConsumeIsOneShot() {
        let store = InkAmpPendingDeepLinkStore.shared
        store.clear()
        store.set(.home)
        #expect(store.consume() == .home)
        #expect(store.consume() == nil)
        store.clear()
    }
}
