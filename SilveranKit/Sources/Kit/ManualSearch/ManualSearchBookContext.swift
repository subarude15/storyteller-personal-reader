//
//  ManualSearchBookContext.swift
//  SilveranKit
//
//  Book metadata handed to Manual Search. Missing fields are allowed.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct ManualSearchBookContext: Equatable, Sendable, Hashable {
    public var title: String
    public var authors: [String]
    public var openLibraryWorkID: String?
    public var isbn: String?
    public var requestedMediaType: ManualSearchMediaType?

    public init(
        title: String,
        authors: [String] = [],
        openLibraryWorkID: String? = nil,
        isbn: String? = nil,
        requestedMediaType: ManualSearchMediaType? = nil,
    ) {
        self.title = title
        self.authors = authors
        self.openLibraryWorkID = openLibraryWorkID
        self.isbn = isbn
        self.requestedMediaType = requestedMediaType
    }

    public var authorDisplay: String {
        authors
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    public var defaultQuery: String {
        ManualSearchQueryValues.make(from: self).query
    }

    public static func from(
        _ work: CanonicalBookWork,
        requestedMediaType: ManualSearchMediaType? = nil,
    ) -> ManualSearchBookContext {
        ManualSearchBookContext(
            title: work.title,
            authors: work.authors,
            openLibraryWorkID: work.openLibraryWorkID,
            isbn: work.isbn,
            requestedMediaType: requestedMediaType,
        )
    }
}
