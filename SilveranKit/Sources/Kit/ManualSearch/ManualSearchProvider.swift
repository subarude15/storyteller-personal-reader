//
//  ManualSearchProvider.swift
//  SilveranKit
//
//  Configurable search-site records for Manual Search. Templates only —
//  no credentials, no per-site behavior in the UI.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum ManualSearchMediaType: String, Codable, CaseIterable, Sendable {
    case ebook
    case audiobook

    public var label: String {
        switch self {
            case .ebook: "eBooks"
            case .audiobook: "Audiobooks"
        }
    }

    public static func from(_ format: BookRequestFormat) -> ManualSearchMediaType {
        switch format {
            case .ebook: .ebook
            case .audiobook: .audiobook
        }
    }
}

/// One search website the user can open for a book.
public struct ManualSearchProvider: Codable, Equatable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var searchURLTemplate: String
    public var supportedMediaTypes: [ManualSearchMediaType]
    public var symbolName: String
    public var sortOrder: Int
    public var isBuiltIn: Bool

    public init(
        id: String,
        name: String,
        enabled: Bool = true,
        searchURLTemplate: String,
        supportedMediaTypes: [ManualSearchMediaType] = ManualSearchMediaType.allCases,
        symbolName: String = "globe",
        sortOrder: Int,
        isBuiltIn: Bool,
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.searchURLTemplate = searchURLTemplate
        self.supportedMediaTypes = supportedMediaTypes
        self.symbolName = symbolName
        self.sortOrder = sortOrder
        self.isBuiltIn = isBuiltIn
    }
}

public enum ManualSearchCatalog {
    public static let builtIn: [ManualSearchProvider] = [
        ManualSearchProvider(
            id: "open-library",
            name: "Open Library",
            searchURLTemplate: "https://openlibrary.org/search?q={query}",
            supportedMediaTypes: [.ebook],
            symbolName: "books.vertical",
            sortOrder: 0,
            isBuiltIn: true,
        ),
        ManualSearchProvider(
            id: "internet-archive",
            name: "Internet Archive",
            searchURLTemplate: "https://archive.org/search?query={query}",
            supportedMediaTypes: [.ebook, .audiobook],
            symbolName: "building.columns",
            sortOrder: 1,
            isBuiltIn: true,
        ),
        ManualSearchProvider(
            id: "project-gutenberg",
            name: "Project Gutenberg",
            searchURLTemplate: "https://www.gutenberg.org/ebooks/search/?query={query}",
            supportedMediaTypes: [.ebook],
            symbolName: "text.book.closed",
            sortOrder: 2,
            isBuiltIn: true,
        ),
        ManualSearchProvider(
            id: "librivox",
            name: "LibriVox",
            searchURLTemplate: "https://librivox.org/?s={query}",
            supportedMediaTypes: [.audiobook],
            symbolName: "headphones",
            sortOrder: 3,
            isBuiltIn: true,
        ),
    ]

    public static func builtIn(id: String) -> ManualSearchProvider? {
        builtIn.first { $0.id == id }
    }

    /// Overlay synced records on the built-in catalog. Unknown built-in IDs
    /// are ignored; new catalog entries that a device has not seen yet append.
    public static func resolve(synced: [ManualSearchProvider]?) -> [ManualSearchProvider] {
        guard let synced, !synced.isEmpty else {
            return builtIn
        }

        let builtInIDs = Set(builtIn.map(\.id))
        var resolved: [ManualSearchProvider] = []
        var seen = Set<String>()

        for record in synced.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            if record.isBuiltIn {
                guard let catalog = builtIn(id: record.id) else { continue }
                var merged = catalog
                merged.enabled = record.enabled
                merged.searchURLTemplate = record.searchURLTemplate
                merged.name = record.name
                merged.symbolName = record.symbolName.isEmpty ? catalog.symbolName : record.symbolName
                merged.supportedMediaTypes =
                    record.supportedMediaTypes.isEmpty
                    ? catalog.supportedMediaTypes : record.supportedMediaTypes
                merged.sortOrder = record.sortOrder
                merged.isBuiltIn = true
                resolved.append(merged)
                seen.insert(record.id)
            } else {
                var custom = record
                custom.isBuiltIn = false
                if custom.symbolName.isEmpty { custom.symbolName = "globe" }
                resolved.append(custom)
                seen.insert(record.id)
            }
        }

        var nextOrder = (resolved.map(\.sortOrder).max() ?? -1) + 1
        for catalog in builtIn where !seen.contains(catalog.id) && builtInIDs.contains(catalog.id) {
            var added = catalog
            added.sortOrder = nextOrder
            nextOrder += 1
            resolved.append(added)
        }

        return resolved.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public static func reindex(_ providers: [ManualSearchProvider]) -> [ManualSearchProvider] {
        providers.enumerated().map { index, provider in
            var copy = provider
            copy.sortOrder = index
            return copy
        }
    }
}

public struct ManualSearchSettingsSnapshot: Equatable, Sendable {
    public var providers: [ManualSearchProvider]
    public var openInAppBrowser: Bool

    public init(
        providers: [ManualSearchProvider] = ManualSearchCatalog.builtIn,
        openInAppBrowser: Bool = true,
    ) {
        self.providers = providers
        self.openInAppBrowser = openInAppBrowser
    }

    public var enabledProviders: [ManualSearchProvider] {
        providers.filter(\.enabled).sorted { $0.sortOrder < $1.sortOrder }
    }
}

public enum ManualSearchTemplateAssessment: Equatable, Sendable {
    /// Valid http(s) URL that includes at least one supported placeholder.
    case looksGood(URL)
    /// Valid http(s) URL with no search placeholders (homepage / browse-only).
    case missingPlaceholder(URL)
    case failure(ManualSearchTemplateError)
}

public struct ManualSearchTemplateTestResult: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case looksGood
        case needsAttention
        case failed
    }

    public var status: Status
    public var title: String
    public var detail: String
    public var exampleURL: URL?
    public var sampleLabel: String

    public init(
        status: Status,
        title: String,
        detail: String,
        exampleURL: URL? = nil,
        sampleLabel: String = ManualSearchProviderValidation.sampleLabel,
    ) {
        self.status = status
        self.title = title
        self.detail = detail
        self.exampleURL = exampleURL
        self.sampleLabel = sampleLabel
    }

    public var canOpenExample: Bool { exampleURL != nil }
}

public enum ManualSearchSymbolName {
    public static let fallback = "globe"
    public static let suggestions = [
        "globe",
        "book",
        "books.vertical",
        "headphones",
        "magnifyingglass",
        "safari",
    ]

    /// Resolve a typed SF Symbol name. Empty or invalid names fall back to `globe`.
    public static func resolve(
        _ raw: String,
        isValidSymbol: (String) -> Bool,
    ) -> (name: String, usedFallback: Bool) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return (fallback, true)
        }
        if isValidSymbol(trimmed) {
            return (trimmed, false)
        }
        return (fallback, true)
    }

    /// Kit-side normalize when a platform symbol check is unavailable.
    public static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

public enum ManualSearchProviderValidation: Equatable, Sendable {
    public static let sampleValues = ManualSearchQueryValues(
        title: "The Hobbit",
        author: "J.R.R. Tolkien",
        isbn: "9780547928227",
        workId: "OL27479W",
        query: "The Hobbit J.R.R. Tolkien",
    )

    public static let sampleLabel = "The Hobbit — J.R.R. Tolkien"

    public static let placeholderHelpLines: [(token: String, meaning: String)] = [
        ("{query}", "Title + author"),
        ("{title}", "Book title"),
        ("{author}", "Author"),
        ("{isbn}", "ISBN"),
        ("{workId}", "Storyteller/Open Library work ID"),
    ]

    public static let exampleTemplate = "https://openlibrary.org/search?q={query}"

    public static func validateTemplate(_ template: String) -> Result<URL, ManualSearchTemplateError> {
        ManualSearchQueryTemplate.url(template: template, values: sampleValues)
    }

    public static func containsSupportedPlaceholder(_ template: String) -> Bool {
        ManualSearchQueryTemplate.containsSupportedPlaceholder(template)
    }

    public static func assessTemplate(_ template: String) -> ManualSearchTemplateAssessment {
        switch validateTemplate(template) {
            case .success(let url):
                if containsSupportedPlaceholder(template) {
                    return .looksGood(url)
                }
                return .missingPlaceholder(url)
            case .failure(let error):
                return .failure(error)
        }
    }

    public static func testSearch(_ template: String) -> ManualSearchTemplateTestResult {
        switch assessTemplate(template) {
            case .looksGood(let url):
                return ManualSearchTemplateTestResult(
                    status: .looksGood,
                    title: "Search looks good",
                    detail: "Example:\n\(sampleLabel)\nOpens:\n\(url.absoluteString)",
                    exampleURL: url,
                )
            case .missingPlaceholder(let url):
                return ManualSearchTemplateTestResult(
                    status: .needsAttention,
                    title: "Search needs attention",
                    detail:
                        "This URL is valid, but it contains no search placeholders.\nEvery book will open the same page.\nTry adding {query}.",
                    exampleURL: url,
                )
            case .failure(let error):
                return ManualSearchTemplateTestResult(
                    status: .failed,
                    title: "Couldn't build search URL",
                    detail: failureReason(error),
                    exampleURL: nil,
                )
        }
    }

    public static func inlineTemplateFeedback(_ template: String) -> String? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch assessTemplate(trimmed) {
            case .looksGood:
                return "Search template looks valid"
            case .missingPlaceholder:
                return "No search placeholder"
            case .failure:
                return nil
        }
    }

    public static func validateForSave(_ provider: ManualSearchProvider) -> ManualSearchTemplateError? {
        let name = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .emptyName }
        switch validateTemplate(provider.searchURLTemplate) {
            case .success: return nil
            case .failure(let error): return error
        }
    }

    public static func failureReason(_ error: ManualSearchTemplateError) -> String {
        switch error {
            case .emptyName: "Enter a provider name."
            case .emptyTemplate: "Enter a search URL template."
            case .malformedTemplate: "That template is not a valid URL."
            case .invalidURL: "The template does not produce a valid URL."
            case .unsupportedScheme:
                "Use an http or https URL. Do not put credentials in the template."
        }
    }
}
