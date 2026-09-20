import Foundation

/// Where a Request Activity entry point should land.
public enum RequestActivityNavigationDestination: Equatable, Sendable {
    case list
    case detail(requestID: String)

    public var requestID: String? {
        switch self {
            case .list:
                nil
            case .detail(let requestID):
                requestID
        }
    }
}

/// Parsed navigation signal. `kind` is optional metadata and is not required to navigate.
public struct RequestActivityNavigationRequest: Equatable, Sendable {
    public var destination: RequestActivityNavigationDestination
    public var kind: String?

    public init(destination: RequestActivityNavigationDestination, kind: String? = nil) {
        self.destination = destination
        self.kind = kind
    }
}

public enum RequestActivityNavigation {
    public static let requestIDKey = "requestID"
    public static let kindKey = "kind"
    public static let missingHistoryMessage = "That request is no longer in history."

    /// Isolate raw notification userInfo lookups. Missing or malformed ids fall back to the list.
    public static func request(from userInfo: [AnyHashable: Any]?) -> RequestActivityNavigationRequest {
        let kind = userInfo?[kindKey] as? String
        guard let requestID = userInfo?[requestIDKey] as? String else {
            return RequestActivityNavigationRequest(destination: .list, kind: kind)
        }
        let trimmed = requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return RequestActivityNavigationRequest(destination: .list, kind: kind)
        }
        return RequestActivityNavigationRequest(
            destination: .detail(requestID: trimmed),
            kind: kind,
        )
    }

    /// A detail id that is not in history stays on the list. Never invents a request row.
    public static func resolved(
        _ destination: RequestActivityNavigationDestination,
        itemExists: (String) -> Bool,
    ) -> RequestActivityNavigationDestination {
        switch destination {
            case .list:
                .list
            case .detail(let requestID):
                itemExists(requestID) ? .detail(requestID: requestID) : .list
        }
    }

    /// Map a provider-row id to its logical chain id when known.
    /// Notification payloads stay unchanged; only presentation navigation remaps.
    public static func resolvedChainDetail(
        requestID: String,
        chainIDForRequest: (String) -> String?,
        itemExists: (String) -> Bool,
    ) -> RequestActivityNavigationDestination {
        if let chainID = chainIDForRequest(requestID) {
            return .detail(requestID: chainID)
        }
        return resolved(.detail(requestID: requestID), itemExists: itemExists)
    }
}

/// One-shot pending destination. Survives until a mounted view consumes it.
public final class RequestActivityNavigationCoordinator: @unchecked Sendable {
    public static let shared = RequestActivityNavigationCoordinator()

    private let lock = NSLock()
    private var pending: RequestActivityNavigationDestination?

    public init() {}

    public func set(_ destination: RequestActivityNavigationDestination) {
        lock.lock()
        pending = destination
        lock.unlock()
    }

    public func peek() -> RequestActivityNavigationDestination? {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    public func consume() -> RequestActivityNavigationDestination? {
        lock.lock()
        defer { lock.unlock() }
        let value = pending
        pending = nil
        return value
    }
}

/// Library entry points. The general summary stays on the list; a known item opens detail.
public enum RequestActivityLibraryNavigation {
    public static var summary: RequestActivityNavigationDestination { .list }

    public static func badge(
        book: BookMetadata,
        index: RequestLibraryPresentationIndex,
    ) -> RequestActivityNavigationDestination {
        if let chain = index.matchChain(book: book) {
            return .detail(requestID: chain.id)
        }
        if let requestID = index.match(book: book)?.id {
            return .detail(requestID: requestID)
        }
        return .list
    }

    public static func pendingRow(
        _ row: RequestLibraryPendingRow,
    ) -> RequestActivityNavigationDestination {
        .detail(requestID: row.id)
    }
}
