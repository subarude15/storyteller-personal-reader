import Foundation

/// A user-chosen alternate for one failed request. Never an automatic queue.
public enum RequestFallbackOption: Equatable, Sendable {
    case provider(BookRequestProviderKind)
    case alternateSearch
}

public struct RequestFallbackOffer: Equatable, Sendable {
    public var eligibleFormats: [BookRequestFormat]
    public var options: [RequestFallbackOption]

    public init(
        eligibleFormats: [BookRequestFormat] = [],
        options: [RequestFallbackOption] = [],
    ) {
        self.eligibleFormats = eligibleFormats
        self.options = options
    }

    public var canOffer: Bool {
        !eligibleFormats.isEmpty && !options.isEmpty
    }
}

/// What a confirmed manual fallback should submit. Empty formats means do not submit.
public struct RequestFallbackDecision: Equatable, Sendable {
    public var formats: [BookRequestFormat]
    public var providerOverride: BookRequestProviderKind
    public var message: String?

    public init(
        formats: [BookRequestFormat],
        providerOverride: BookRequestProviderKind,
        message: String? = nil,
    ) {
        self.formats = formats
        self.providerOverride = providerOverride
        self.message = message
    }
}

public struct RequestFallbackConfirmation: Equatable, Sendable {
    public var prompt: String
    public var footer: String
    public var confirmTitle: String

    public init(prompt: String, footer: String, confirmTitle: String) {
        self.prompt = prompt
        self.footer = footer
        self.confirmTitle = confirmTitle
    }
}

/// Manual alternate-source choices. Does not submit, notify, or change routing.
public enum RequestActivityFallbackPolicy {
    public static let alreadyInLibraryMessage =
        "This format is already available in your library."

    public static func alreadyRequestedMessage(provider: BookRequestProviderKind) -> String {
        "Already requested with \(provider.shortName)."
    }

    public static func requestedMessage(provider: BookRequestProviderKind) -> String {
        "Requested with \(provider.shortName)."
    }

    /// Stored LazyLibrarian / Shelfarr, or Automatic rows that already resolved a LazyLibrarian BookID.
    /// Automatic alone is not a provider.
    public static func resolvedProvider(_ item: RequestActivityItem) -> BookRequestProviderKind? {
        switch item.provider {
            case .lazyLibrarian:
                .lazyLibrarian
            case .shelfarr:
                .shelfarr
            case .automatic:
                if let bookID = item.providerBookID, !bookID.isEmpty {
                    .lazyLibrarian
                } else {
                    nil
                }
        }
    }

    public static func isLazyLibrarianConfigured(_ context: RequestActivityActionContext) -> Bool {
        context.lazyLibrarianEnabled
            && context.lazyLibrarianHasAPIKey
            && RequestActivityExternalLinks.browseURL(from: context.lazyLibrarianBaseURL) != nil
    }

    public static func isShelfarrConfigured(_ context: RequestActivityActionContext) -> Bool {
        context.shelfarrHasToken
            && RequestActivityExternalLinks.browseURL(from: context.shelfarrBaseURL) != nil
    }

    public static func isAlternateSearchConfigured(_ context: RequestActivityActionContext) -> Bool {
        context.bookSearchLANEnabled
            && RequestActivityExternalLinks.browseURL(from: context.bookSearchLANBaseURL) != nil
    }

    /// Formats that still need attention, plus configured alternates. Does not read history.
    public static func offer(
        for item: RequestActivityItem,
        context: RequestActivityActionContext,
    ) -> RequestFallbackOffer {
        let eligible = RequestActivityRetryPolicy.retryableFormats(for: item)
        guard !eligible.isEmpty else { return RequestFallbackOffer() }

        let current = resolvedProvider(item)
        var options: [RequestFallbackOption] = []
        if current != .shelfarr, isShelfarrConfigured(context) {
            options.append(.provider(.shelfarr))
        }
        if current != .lazyLibrarian, isLazyLibrarianConfigured(context) {
            options.append(.provider(.lazyLibrarian))
        }
        if isAlternateSearchConfigured(context) {
            options.append(.alternateSearch)
        }
        return RequestFallbackOffer(eligibleFormats: eligible, options: options)
    }

    /// Drops formats now in the library or already active/completed on the alternate provider.
    /// Does not mutate `item` or history.
    public static func decision(
        item: RequestActivityItem,
        provider: BookRequestProviderKind,
        formats: [BookRequestFormat],
        history: [RequestActivityItem],
    ) -> RequestFallbackDecision {
        let override: BookRequestProviderKind
        switch provider {
            case .lazyLibrarian, .shelfarr:
                override = provider
            case .automatic:
                return RequestFallbackDecision(formats: [], providerOverride: provider)
        }
        if resolvedProvider(item) == override {
            return RequestFallbackDecision(formats: [], providerOverride: override)
        }

        let selected = BookRequestFormat.allCases.filter { formats.contains($0) }
        let inLibrary = selected.filter {
            item.status(for: $0)?.status == .availableInLibrary
        }
        let retryable = RequestActivityRetryPolicy.retryableFormats(for: item)
        let candidates = selected.filter { retryable.contains($0) }
        let alternate = history.first {
            $0.canonicalWorkID == item.canonicalWorkID && $0.provider == override
        }
        let blocked = candidates.filter { format in
            guard let status = alternate?.status(for: format)?.status else { return false }
            return blocksResubmit(status)
        }
        let send = candidates.filter { format in
            !blocked.contains(format)
        }
        if !send.isEmpty {
            return RequestFallbackDecision(formats: send, providerOverride: override)
        }
        if !candidates.isEmpty, blocked.count == candidates.count {
            let blockedStatuses = blocked.compactMap { alternate?.status(for: $0)?.status }
            if blockedStatuses.allSatisfy({ $0 == .availableInLibrary }) {
                return RequestFallbackDecision(
                    formats: [],
                    providerOverride: override,
                    message: alreadyInLibraryMessage,
                )
            }
            return RequestFallbackDecision(
                formats: [],
                providerOverride: override,
                message: alreadyRequestedMessage(provider: override),
            )
        }
        if !inLibrary.isEmpty {
            return RequestFallbackDecision(
                formats: [],
                providerOverride: override,
                message: alreadyInLibraryMessage,
            )
        }
        return RequestFallbackDecision(formats: [], providerOverride: override)
    }

    public static func confirmation(
        bookTitle: String,
        formats: [BookRequestFormat],
        alternate: BookRequestProviderKind,
        currentProviderName: String,
    ) -> RequestFallbackConfirmation {
        let name = alternate.shortName
        let phrase = formatPhrase(formats)
        return RequestFallbackConfirmation(
            prompt: "Try \(name) for \(bookTitle) \(phrase)?",
            footer:
                "This will create a new request with \(name). Your existing \(currentProviderName) request will not be deleted.",
            confirmTitle: "Try \(name)",
        )
    }

    public static func optionsHeading(
        item: RequestActivityItem,
        formats: [BookRequestFormat],
    ) -> String {
        let who = resolvedProvider(item)?.shortName ?? "This request"
        let listed = BookRequestFormat.allCases
            .filter { formats.contains($0) }
            .map(\.label)
            .joined(separator: " · ")
        return "\(who) failed for:\n\(item.title) · \(listed)"
    }

    public static func formatPhrase(_ formats: [BookRequestFormat]) -> String {
        let ordered = BookRequestFormat.allCases.filter { formats.contains($0) }
        switch ordered.count {
            case 0:
                "request"
            case 1:
                ordered[0].label.lowercased()
            default:
                "ebook and audiobook"
        }
    }

    /// Active or completed alternate rows block another submit. A failed alternate can be updated.
    private static func blocksResubmit(_ status: RequestActivityStatus) -> Bool {
        !RequestActivityRetryPolicy.isRetryable(status)
    }
}
