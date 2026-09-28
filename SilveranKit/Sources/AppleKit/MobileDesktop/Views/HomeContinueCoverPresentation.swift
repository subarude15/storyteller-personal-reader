//
//  HomeContinueCoverPresentation.swift
//  SilveranAppleKit
//
//  Continue / Up next cover identity — keys image views off media id (or
//  resolved artwork URL), not title or slot reuse.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit

/// Presentation tokens for Home Continue cover artwork.
///
/// SwiftUI reuses the Continue cover view when only the active item changes.
/// Bind load tasks / `.id` to `artworkIdentity` so a prior book's `@State`
/// image cannot paint over the new Continue item.
public struct HomeContinueCoverPresentation: Equatable, Sendable, Hashable {
    public let itemID: String
    public let artworkIdentity: String
    public let title: String

    public init(itemID: String, artworkIdentity: String, title: String) {
        self.itemID = itemID
        self.artworkIdentity = artworkIdentity
        self.title = title
    }

    public static func book(id: BookID, title: String) -> HomeContinueCoverPresentation {
        let itemID = "book:\(id.sourceID)/\(id.uuid)"
        return HomeContinueCoverPresentation(
            itemID: itemID,
            artworkIdentity: itemID,
            title: title
        )
    }

    public static func podcast(
        episodeID: String,
        title: String,
        coverURL: URL?
    ) -> HomeContinueCoverPresentation {
        let itemID = "pod:\(episodeID)"
        let artworkIdentity: String
        if let coverURL {
            artworkIdentity = "\(itemID)|\(coverURL.absoluteString)"
        } else {
            artworkIdentity = itemID
        }
        return HomeContinueCoverPresentation(
            itemID: itemID,
            artworkIdentity: artworkIdentity,
            title: title
        )
    }

    /// Cached book-cover `@State` must clear when Continue's artwork identity changes.
    public static func mustClearCachedBookImage(
        previous: HomeContinueCoverPresentation?,
        next: HomeContinueCoverPresentation?
    ) -> Bool {
        previous?.artworkIdentity != next?.artworkIdentity
    }
}
