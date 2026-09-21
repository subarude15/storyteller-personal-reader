//
//  ManualSearchQueryTemplateTests.swift
//  SilveranTests
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit
import Testing

@Suite("Manual Search query templates")
struct ManualSearchQueryTemplateTests {
    private let hobbit = ManualSearchQueryValues(
        title: "The Hobbit",
        author: "J.R.R. Tolkien",
        isbn: "9780547928227",
        workId: "OL27479W",
        query: "The Hobbit J.R.R. Tolkien",
    )

    @Test func titleAndAuthorSubstitution() throws {
        let url = try ManualSearchQueryTemplate.url(
            template: "https://example.com/search?q={title}+{author}",
            values: hobbit,
        ).get()
        #expect(url.scheme == "https")
        #expect(url.host == "example.com")
        #expect(url.absoluteString.contains("The%20Hobbit"))
        #expect(url.absoluteString.contains("Tolkien"))
    }

    @Test func valuesAreURLEncoded() throws {
        let values = ManualSearchQueryValues(
            title: "Book & Cover",
            author: "Name/Title",
            query: "Book & Cover Name/Title",
        )
        let url = try ManualSearchQueryTemplate.url(
            template: "https://example.com/search?q={query}",
            values: values,
        ).get()
        #expect(url.absoluteString.contains("Book%20%26%20Cover"))
        #expect(!url.absoluteString.contains("Book & Cover"))
        #expect(url.absoluteString.contains("Name%2FTitle"))
    }

    @Test func missingAuthorDoesNotBreakURL() throws {
        let values = ManualSearchQueryValues(title: "The Hobbit", query: "The Hobbit")
        let url = try ManualSearchQueryTemplate.url(
            template: "https://example.com/search?q={title}+{author}",
            values: values,
        ).get()
        #expect(url.host == "example.com")
        #expect(url.absoluteString.contains("The%20Hobbit"))
        #expect(!url.absoluteString.contains("++"))
    }

    @Test func isbnAndWorkIDSubstitution() throws {
        let url = try ManualSearchQueryTemplate.url(
            template: "https://example.com/find?isbn={isbn}&work={workId}",
            values: hobbit,
        ).get()
        #expect(url.absoluteString == "https://example.com/find?isbn=9780547928227&work=OL27479W")
    }

    @Test func customQueryReplacesDefaultQuery() throws {
        let context = ManualSearchBookContext(title: "The Hobbit", authors: ["J.R.R. Tolkien"])
        let values = ManualSearchQueryValues.make(from: context, customQuery: "hobbit tolkien 1937")
        #expect(values.query == "hobbit tolkien 1937")
        #expect(values.title == "The Hobbit")
        let url = try ManualSearchQueryTemplate.url(
            template: "https://example.com/search?q={query}",
            values: values,
        ).get()
        #expect(url.absoluteString.contains("hobbit%20tolkien%201937"))
    }

    @Test func malformedTemplateRejected() {
        #expect(ManualSearchQueryTemplate.url(template: "", values: hobbit) == .failure(.emptyTemplate))
        #expect(
            ManualSearchQueryTemplate.url(template: "not a url", values: hobbit) == .failure(.malformedTemplate)
        )
        #expect(
            ManualSearchQueryTemplate.url(template: "javascript:alert(1)", values: hobbit)
                == .failure(.unsupportedScheme)
        )
        #expect(
            ManualSearchQueryTemplate.url(template: "{title}", values: hobbit) == .failure(.malformedTemplate)
        )
    }

    @Test func defaultBuiltInTemplatesProduceHTTPSurls() throws {
        for provider in ManualSearchCatalog.builtIn {
            let url = try ManualSearchQueryTemplate.url(
                template: provider.searchURLTemplate,
                values: hobbit,
            ).get()
            #expect(url.scheme == "https")
            #expect(url.host != nil)
        }
    }
}
