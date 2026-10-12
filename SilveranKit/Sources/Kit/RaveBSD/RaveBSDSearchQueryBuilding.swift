//
//  RaveBSDSearchQueryBuilding.swift
//  SilveranKit
//
//  Keeps title / author / free-text consistent so a stale free-text field
//  cannot win after the user edits structured fields.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum RaveBSDSearchQueryBuilding {
    public static func composedQuery(title: String, author: String) -> String {
        ManualSearchQueryValues.make(
            from: ManualSearchBookContext(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                authors: {
                    let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? [] : [trimmed]
                }(),
            )
        ).query
    }

    /// Prefer structured title/author when free-text is empty or still matches them.
    /// Use free-text only when it differs from the current composed title+author.
    public static func make(
        title: String,
        author: String,
        freeText: String,
        mode: RaveBSDMediaMode,
    ) -> RaveBSDSearchQuery {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        let free = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let composed = composedQuery(title: trimmedTitle, author: trimmedAuthor)
        if !free.isEmpty, free != composed {
            return RaveBSDSearchQuery(freeText: free, mode: mode)
        }
        return RaveBSDSearchQuery(title: trimmedTitle, author: trimmedAuthor, mode: mode)
    }

    /// After a title/author edit, realign free-text so the next search cannot
    /// reuse a previous free-text query.
    public static func syncedFreeText(title: String, author: String) -> String {
        composedQuery(title: title, author: author)
    }
}
