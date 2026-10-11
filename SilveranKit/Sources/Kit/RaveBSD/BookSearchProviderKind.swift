//
//  BookSearchProviderKind.swift
//  SilveranKit
//
//  User-facing search surface for a book: native RaveBSD, LazyLibrarian
//  request, or Manual Search (browser templates). Distinct from
//  BookRequestProviderKind (automatic acquisition backends).
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum BookSearchProviderKind: String, Codable, CaseIterable, Sendable {
    case raveBSD
    case lazyLibrarian
    case manual

    public var displayName: String {
        switch self {
            case .raveBSD: "RaveBSD"
            case .lazyLibrarian: "LazyLibrarian"
            case .manual: "Manual Search"
        }
    }

    public var shortName: String {
        displayName
    }

    /// Safe decode for Settings. Unknown / empty → RaveBSD (new default).
    public static func preference(from raw: String) -> BookSearchProviderKind {
        BookSearchProviderKind(rawValue: raw) ?? .raveBSD
    }
}
