import Foundation

/// Which formats on a request are safe to re-queue.
///
/// Retryable: failed / needsAttention (submission failure, missing provider record, etc.).
/// Not retryable: normal in-progress provider states, provider Have, Available in Library,
/// temporary lookup timeouts that have not escalated to needsAttention.
///
/// Shelfarr: only failed submission evidence (`.failed` / `.needsAttention`). A successfully
/// accepted Shelfarr request that stays `.requested` is never retryable.
public enum RequestActivityRetryPolicy: Sendable {
    public static func isRetryable(_ status: RequestActivityStatus) -> Bool {
        switch status {
            case .failed, .needsAttention:
                true
            case .requested, .searching, .wanted, .snatched, .downloaded, .available,
                .alreadyAvailable, .availableInLibrary, .alreadyRequested, .unknown:
                false
        }
    }

    /// Formats that should be re-sent. Completed / still-active formats are excluded.
    public static func retryableFormats(for item: RequestActivityItem) -> [BookRequestFormat] {
        item.requestedFormats.filter { format in
            guard let status = item.status(for: format)?.status else { return false }
            if status == .availableInLibrary { return false }
            return isRetryable(status)
        }
    }

    public static func canRetry(_ item: RequestActivityItem) -> Bool {
        !retryableFormats(for: item).isEmpty
    }
}

/// Settings snapshot used to decide which recovery actions are available.
public struct RequestActivityActionContext: Equatable, Sendable {
    public var lazyLibrarianEnabled: Bool
    public var lazyLibrarianBaseURL: String
    public var shelfarrBaseURL: String
    public var bookSearchLANEnabled: Bool
    public var bookSearchLANBaseURL: String

    public init(
        lazyLibrarianEnabled: Bool = false,
        lazyLibrarianBaseURL: String = "",
        shelfarrBaseURL: String = "",
        bookSearchLANEnabled: Bool = false,
        bookSearchLANBaseURL: String = "",
    ) {
        self.lazyLibrarianEnabled = lazyLibrarianEnabled
        self.lazyLibrarianBaseURL = lazyLibrarianBaseURL
        self.shelfarrBaseURL = shelfarrBaseURL
        self.bookSearchLANEnabled = bookSearchLANEnabled
        self.bookSearchLANBaseURL = bookSearchLANBaseURL
    }

    public init(config: SilveranGlobalConfig) {
        self.init(
            lazyLibrarianEnabled: config.lazyLibrarianEnabled,
            lazyLibrarianBaseURL: config.lazyLibrarianBaseURL,
            shelfarrBaseURL: config.shelfarrBaseURL,
            bookSearchLANEnabled: config.bookSearchLANEnabled,
            bookSearchLANBaseURL: config.bookSearchLANBaseURL,
        )
    }
}

public struct RequestActivityActionAvailability: Equatable, Sendable {
    public var canCheckStatus: Bool
    public var canRetry: Bool
    public var canOpenLazyLibrarian: Bool
    public var canOpenShelfarr: Bool
    public var canOpenAlternateSearch: Bool
    public var retryFormats: [BookRequestFormat]

    public init(
        canCheckStatus: Bool = false,
        canRetry: Bool = false,
        canOpenLazyLibrarian: Bool = false,
        canOpenShelfarr: Bool = false,
        canOpenAlternateSearch: Bool = false,
        retryFormats: [BookRequestFormat] = [],
    ) {
        self.canCheckStatus = canCheckStatus
        self.canRetry = canRetry
        self.canOpenLazyLibrarian = canOpenLazyLibrarian
        self.canOpenShelfarr = canOpenShelfarr
        self.canOpenAlternateSearch = canOpenAlternateSearch
        self.retryFormats = retryFormats
    }

    public var hasAnyAction: Bool {
        canCheckStatus || canRetry || canOpenLazyLibrarian || canOpenShelfarr
            || canOpenAlternateSearch
    }
}

/// Declarative recovery-action visibility for Request Activity.
public enum RequestActivityActions {
    public static func availability(
        for item: RequestActivityItem,
        context: RequestActivityActionContext,
    ) -> RequestActivityActionAvailability {
        let retryFormats = RequestActivityRetryPolicy.retryableFormats(for: item)
        let llURL = RequestActivityExternalLinks.browseURL(from: context.lazyLibrarianBaseURL)
        let shelfURL = RequestActivityExternalLinks.browseURL(from: context.shelfarrBaseURL)
        let lanURL = RequestActivityExternalLinks.browseURL(from: context.bookSearchLANBaseURL)

        // Open LL when this request is (or was) LazyLibrarian-backed.
        // Automatic rows that still carry a providerBookID came from LL.
        let openLL =
            llURL != nil
            && item.provider != .shelfarr
            && (item.provider == .lazyLibrarian
                || (item.providerBookID?.isEmpty == false))
        let openShelf =
            shelfURL != nil
            && item.provider == .shelfarr
        let openLAN =
            context.bookSearchLANEnabled
            && lanURL != nil

        return RequestActivityActionAvailability(
            canCheckStatus: true,
            canRetry: !retryFormats.isEmpty,
            canOpenLazyLibrarian: openLL,
            canOpenShelfarr: openShelf,
            canOpenAlternateSearch: openLAN,
            retryFormats: retryFormats,
        )
    }
}

/// Safe http/https browse URLs — never append secrets.
public enum RequestActivityExternalLinks {
    /// Accept only http/https. Strip userinfo / query / fragment.
    public static func browseURL(from raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        guard var components = URLComponents(string: text),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty
        else { return nil }
        components.scheme = scheme
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        if components.path == "/" { components.path = "" }
        return components.url
    }

    public static func lazyLibrarianHome(baseURL: String) -> URL? {
        browseURL(from: baseURL)
    }

    public static func shelfarrHome(baseURL: String) -> URL? {
        browseURL(from: baseURL)
    }

    public static func bookSearchLAN(baseURL: String) -> URL? {
        browseURL(from: baseURL)
    }

    /// Log-safe host string (no credentials).
    public static func sanitizedDescription(of url: URL) -> String {
        ServiceHealthURLSanitizer.sanitize(url.absoluteString) ?? url.host ?? "url"
    }
}

extension RequestActivityItem {
    /// Rebuild a CanonicalBookWork for retry submission.
    public func canonicalWorkForRetry() -> CanonicalBookWork {
        let authors: [String]
        let units = RequestLibraryMatcher.authorUnits(from: author)
        if units.count > 1 {
            authors = units
        } else if author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            authors = []
        } else {
            authors = [author.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        let olWork =
            openLibraryWorkID
            ?? RequestLibraryMatcher.normalizeOpenLibraryID(canonicalWorkID).flatMap {
                $0.contains("/works/") ? $0 : nil
            }
        return CanonicalBookWork(
            workID: canonicalWorkID,
            title: title,
            subtitle: nil,
            authors: authors,
            language: nil,
            isbn: isbn,
            openLibraryWorkID: olWork,
            openLibraryEditionID: openLibraryEditionID,
            publicationYear: nil,
        )
    }
}
