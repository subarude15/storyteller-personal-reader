//
//  ManualSearchQueryTemplate.swift
//  SilveranKit
//
//  Substitutes {title} {author} {isbn} {workId} {query} into a search URL.
//  Missing values become empty; the result must still be http(s).
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct ManualSearchQueryValues: Equatable, Sendable {
    public var title: String
    public var author: String
    public var isbn: String
    public var workId: String
    public var query: String

    public init(
        title: String = "",
        author: String = "",
        isbn: String = "",
        workId: String = "",
        query: String = "",
    ) {
        self.title = title
        self.author = author
        self.isbn = isbn
        self.workId = workId
        self.query = query
    }

    public static func make(
        title: String,
        authors: [String],
        isbn: String?,
        workId: String?,
        customQuery: String? = nil,
    ) -> ManualSearchQueryValues {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let author = authors
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let isbnValue = isbn?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let work = workId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let defaultQuery = [trimmedTitle, author].filter { !$0.isEmpty }.joined(separator: " ")
        let query: String
        if let customQuery {
            let trimmed = customQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            query = trimmed.isEmpty ? defaultQuery : trimmed
        } else {
            query = defaultQuery
        }
        return ManualSearchQueryValues(
            title: trimmedTitle,
            author: author,
            isbn: isbnValue,
            workId: work,
            query: query,
        )
    }

    public static func make(
        from context: ManualSearchBookContext,
        customQuery: String? = nil,
    ) -> ManualSearchQueryValues {
        make(
            title: context.title,
            authors: context.authors,
            isbn: context.isbn,
            workId: context.openLibraryWorkID,
            customQuery: customQuery,
        )
    }
}

public enum ManualSearchTemplateError: Error, Equatable, Sendable {
    case emptyTemplate
    case malformedTemplate
    case invalidURL
    case unsupportedScheme
}

public enum ManualSearchQueryTemplate {
    public static let placeholders = ["title", "author", "isbn", "workId", "query"]

    public static func url(
        template: String,
        values: ManualSearchQueryValues,
    ) -> Result<URL, ManualSearchTemplateError> {
        let raw = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .failure(.emptyTemplate) }

        let substituted = substitute(raw, values: values)
        let tidied = tidy(substituted)
        guard let components = URLComponents(string: tidied) else {
            return .failure(looksLikeTemplate(raw) ? .invalidURL : .malformedTemplate)
        }
        if let scheme = components.scheme?.lowercased(), scheme != "http", scheme != "https" {
            return .failure(.unsupportedScheme)
        }
        guard let host = components.host, !host.isEmpty, let url = components.url else {
            return .failure(looksLikeTemplate(raw) ? .invalidURL : .malformedTemplate)
        }
        return .success(url)
    }

    public static func substitute(_ template: String, values: ManualSearchQueryValues) -> String {
        var result = template
        let pairs: [(String, String)] = [
            ("{title}", encode(values.title)),
            ("{author}", encode(values.author)),
            ("{isbn}", encode(values.isbn)),
            ("{workId}", encode(values.workId)),
            ("{query}", encode(values.query)),
        ]
        for (token, value) in pairs {
            result = result.replacingOccurrences(of: token, with: value)
        }
        return result
    }

    /// Encode a single substituted value. Query reserved characters are escaped.
    public static func encode(_ raw: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":/?#[]@!$&'()*+,;=")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// Collapse leftover separators when a placeholder was empty.
    public static func tidy(_ urlString: String) -> String {
        var result = urlString
        for _ in 0..<4 {
            result = result.replacingOccurrences(of: "++", with: "+")
            result = result.replacingOccurrences(of: "&&", with: "&")
        }
        result = result.replacingOccurrences(of: "?+", with: "?")
        result = result.replacingOccurrences(of: "&=", with: "=")
        result = result.replacingOccurrences(of: "?&", with: "?")
        if result.hasSuffix("+") || result.hasSuffix("&") || result.hasSuffix("?") || result.hasSuffix("=") {
            result.removeLast()
        }
        result = result.replacingOccurrences(of: "+=&", with: "&")
        result = result.replacingOccurrences(of: "+&", with: "&")
        return result
    }

    private static func looksLikeTemplate(_ raw: String) -> Bool {
        raw.contains("{") && raw.contains("}")
    }
}
