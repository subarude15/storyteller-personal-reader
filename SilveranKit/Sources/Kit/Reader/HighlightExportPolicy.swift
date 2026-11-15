import Foundation

/// Pure filtering, formatting, and Markdown export policies for reader highlights and bookmarks.
public enum HighlightExportPolicy {
    /// Filters highlights by search query (matching passage text, note, or chapter title),
    /// optional highlight color, and optional notes-only toggle.
    public static func filterHighlights(
        _ highlights: [Highlight],
        searchText: String = "",
        selectedColor: HighlightColor? = nil,
        onlyWithNotes: Bool = false
    ) -> [Highlight] {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return highlights.filter { highlight in
            if let selectedColor, highlight.color != selectedColor {
                return false
            }

            if onlyWithNotes {
                guard let note = highlight.note?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !note.isEmpty
                else {
                    return false
                }
            }

            guard !trimmedQuery.isEmpty else { return true }
            return matchesQuery(highlight, query: trimmedQuery)
        }
    }

    /// Filters bookmarks by search query (matching chapter title, passage text, or note).
    public static func filterBookmarks(
        _ bookmarks: [Highlight],
        searchText: String = ""
    ) -> [Highlight] {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return bookmarks }
        return bookmarks.filter { matchesQuery($0, query: trimmedQuery) }
    }

    /// Returns the distinct `HighlightColor` values present in `highlights`, ordered by canonical palette slot.
    public static func availableColors(in highlights: [Highlight]) -> [HighlightColor] {
        let present = Set(highlights.compactMap(\.color))
        return HighlightColor.allCases.filter { present.contains($0) }
    }

    /// Formats a highlight or bookmark's total book progression (or chapter progression fallback) as `"42%"`.
    public static func progressPercentText(for highlight: Highlight) -> String? {
        let raw = highlight.locator.locations?.totalProgression
            ?? highlight.locator.locations?.progression
        guard let raw, raw.isFinite else { return nil }
        let clamped = min(max(raw, 0), 1)
        let percent = Int((clamped * 100).rounded())
        return "\(percent)%"
    }

    /// Formats a single highlight or bookmark as clean Markdown for clipboard copy or share sheet.
    public static func markdownQuote(
        for highlight: Highlight,
        bookTitle: String? = nil,
        author: String? = nil
    ) -> String {
        var lines: [String] = []
        let cleanPassage = highlight.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanPassage.isEmpty {
            let quoted = cleanPassage
                .components(separatedBy: .newlines)
                .map { "> \($0)" }
                .joined(separator: "\n")
            lines.append(quoted)
        }

        if let note = highlight.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            lines.append("")
            lines.append("**Note:** \(note)")
        }

        var attributionParts: [String] = []
        if let title = bookTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            if let author = author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
                attributionParts.append("*\(title)* by \(author)")
            } else {
                attributionParts.append("*\(title)*")
            }
        }
        if let chapter = highlight.chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            !chapter.isEmpty
        {
            attributionParts.append(chapter)
        }
        if let percent = progressPercentText(for: highlight) {
            attributionParts.append(percent)
        }

        if !attributionParts.isEmpty {
            lines.append("")
            lines.append("— " + attributionParts.joined(separator: " · "))
        }

        return lines.joined(separator: "\n")
    }

    /// Exports a full Markdown notebook of a book's highlights and bookmarks.
    public static func markdownNotebook(
        bookTitle: String?,
        author: String? = nil,
        highlights: [Highlight],
        bookmarks: [Highlight] = []
    ) -> String {
        var lines: [String] = []
        let resolvedTitle = bookTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? "Reading Notebook"
        lines.append("# \(resolvedTitle)")
        if let author = author?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            lines.append("*by \(author)*")
        }
        lines.append("")

        if !highlights.isEmpty {
            lines.append("## Highlights (\(highlights.count))")
            lines.append("")
            for highlight in highlights {
                var meta: [String] = []
                if let chapter = highlight.chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                    meta.append("**\(chapter)**")
                }
                if let percent = progressPercentText(for: highlight) {
                    meta.append(percent)
                }
                if let color = highlight.color {
                    meta.append(color.rawValue.capitalized)
                }
                if !meta.isEmpty {
                    lines.append("### " + meta.joined(separator: " · "))
                }

                let cleanPassage = highlight.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanPassage.isEmpty {
                    let quoted = cleanPassage
                        .components(separatedBy: .newlines)
                        .map { "> \($0)" }
                        .joined(separator: "\n")
                    lines.append(quoted)
                }

                if let note = highlight.note?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                    lines.append("")
                    lines.append("- **Note:** \(note)")
                }
                lines.append("")
            }
        }

        if !bookmarks.isEmpty {
            lines.append("## Bookmarks (\(bookmarks.count))")
            lines.append("")
            for bookmark in bookmarks {
                var headerParts: [String] = []
                if let chapter = bookmark.chapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                    headerParts.append("**\(chapter)**")
                } else {
                    headerParts.append("**Bookmark**")
                }
                if let percent = progressPercentText(for: bookmark) {
                    headerParts.append("(\(percent))")
                }
                let excerpt = bookmark.displayText
                if !excerpt.isEmpty {
                    lines.append("- \(headerParts.joined(separator: " ")): \"\(excerpt)\"")
                } else {
                    lines.append("- \(headerParts.joined(separator: " "))")
                }
                if let note = bookmark.note?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
                    lines.append("  - *Note:* \(note)")
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matchesQuery(_ highlight: Highlight, query: String) -> Bool {
        if highlight.text.localizedStandardContains(query) {
            return true
        }
        if let note = highlight.note, note.localizedStandardContains(query) {
            return true
        }
        if let chapter = highlight.chapterTitle, chapter.localizedStandardContains(query) {
            return true
        }
        return false
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
