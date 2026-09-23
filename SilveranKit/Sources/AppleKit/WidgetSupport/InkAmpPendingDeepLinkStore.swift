import Foundation

/// Widget / `punkrally://` destinations that must survive cold launch until the
/// ink+amp tab shell is mounted.
public enum InkAmpPendingDeepLink: Equatable, Sendable {
    /// `punkrally://home` — Browse Queue / open Home.
    case home
    /// `punkrally://continue` or `punkrally://continue?item=<id>`.
    case continueItem(String?)
}

/// In-process one-shot store for Continue / Home deep links.
///
/// NotificationCenter alone is not enough on cold launch: `handleOpenURL` can
/// run while `PunkRallyTabView` is still behind the startup ProgressView, so
/// listeners are not registered yet. The URL handler always writes here; the
/// shell consumes exactly once on appear (and when a pending-ready signal
/// arrives while already mounted).
public final class InkAmpPendingDeepLinkStore: @unchecked Sendable {
    public static let shared = InkAmpPendingDeepLinkStore()

    private let lock = NSLock()
    private var pending: InkAmpPendingDeepLink?

    public init() {}

    public func set(_ link: InkAmpPendingDeepLink) {
        lock.lock()
        pending = link
        lock.unlock()
    }

    /// Returns the pending action and clears it. Second call returns nil.
    public func consume() -> InkAmpPendingDeepLink? {
        lock.lock()
        let value = pending
        pending = nil
        lock.unlock()
        return value
    }

    public func peek() -> InkAmpPendingDeepLink? {
        lock.lock()
        let value = pending
        lock.unlock()
        return value
    }

    public func clear() {
        lock.lock()
        pending = nil
        lock.unlock()
    }
}

extension InkAmpContinueLink {
    /// Maps a widget URL to a pending shell action. Toggle and unrelated URLs
    /// return nil (they are not stored for deferred Home navigation).
    public static func pendingDeepLink(from url: URL) -> InkAmpPendingDeepLink? {
        if isHomeURL(url) {
            return .home
        }
        if isContinueURL(url) {
            if wantsToggle(url) { return nil }
            return .continueItem(queueItemID(from: url))
        }
        return nil
    }

    /// Posts after a pending Continue/Home deep link is stored so a warm shell
    /// can consume immediately. Cold launch relies on shell `onAppear` instead.
    public static let pendingDeepLinkReadyNotification = Notification.Name(
        "punkRallyPendingWidgetDeepLink"
    )

    public static func storePendingDeepLink(from url: URL, store: InkAmpPendingDeepLinkStore = .shared)
        -> InkAmpPendingDeepLink?
    {
        guard let action = pendingDeepLink(from: url) else { return nil }
        store.set(action)
        return action
    }

    public static func notifyPendingDeepLinkReady() {
        NotificationCenter.default.post(name: pendingDeepLinkReadyNotification, object: nil)
    }
}

/// Pure delivery effects for pending widget deep links (testable without SwiftUI).
public enum InkAmpPendingDeepLinkDelivery {
    public enum Effect: Equatable, Sendable {
        case selectHome
        case selectHomeAndContinue(itemID: String?)
    }

    public static func effect(for action: InkAmpPendingDeepLink) -> Effect {
        switch action {
            case .home:
                return .selectHome
            case .continueItem(let itemID):
                return .selectHomeAndContinue(itemID: itemID)
        }
    }

    /// Warm path: URL arrives while shell is listening — store, then consume once.
    public static func deliverWarm(
        url: URL,
        store: InkAmpPendingDeepLinkStore,
    ) -> Effect? {
        guard InkAmpContinueLink.storePendingDeepLink(from: url, store: store) != nil else {
            return nil
        }
        guard let action = store.consume() else { return nil }
        return effect(for: action)
    }

    /// Cold path: URL arrives before shell exists; shell later consumes once.
    public static func retainCold(
        url: URL,
        store: InkAmpPendingDeepLinkStore,
    ) -> InkAmpPendingDeepLink? {
        InkAmpContinueLink.storePendingDeepLink(from: url, store: store)
    }

    public static func consumeCold(store: InkAmpPendingDeepLinkStore) -> Effect? {
        guard let action = store.consume() else { return nil }
        return effect(for: action)
    }
}
