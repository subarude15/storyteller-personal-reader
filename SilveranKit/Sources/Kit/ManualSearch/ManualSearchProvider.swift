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
            case .ebook: "Ebook"
            case .audiobook: "Audiobook"
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

public enum ManualSearchProviderValidation: Equatable, Sendable {
    public static let sampleValues = ManualSearchQueryValues(
        title: "The Hobbit",
        author: "J.R.R. Tolkien",
        isbn: "9780547928227",
        workId: "OL27479W",
        query: "The Hobbit J.R.R. Tolkien",
    )

    public static func validateTemplate(_ template: String) -> Result<URL, ManualSearchTemplateError> {
        ManualSearchQueryTemplate.url(template: template, values: sampleValues)
    }

    public static func validateForSave(_ provider: ManualSearchProvider) -> ManualSearchTemplateError? {
        let name = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .emptyTemplate }
        switch validateTemplate(provider.searchURLTemplate) {
            case .success: return nil
            case .failure(let error): return error
        }
    }
}
