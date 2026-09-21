//
//  ManualSearchProviderEditorTests.swift
//  SilveranTests
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit
import Testing

@Suite("Manual Search provider editor")
struct ManualSearchProviderEditorTests {
    @Test func supportedPlaceholdersAreRecognized() {
        #expect(ManualSearchQueryTemplate.containsSupportedPlaceholder("https://x.com?q={query}"))
        #expect(ManualSearchQueryTemplate.containsSupportedPlaceholder("https://x.com?t={title}"))
        #expect(ManualSearchQueryTemplate.containsSupportedPlaceholder("https://x.com?a={author}"))
        #expect(ManualSearchQueryTemplate.containsSupportedPlaceholder("https://x.com?i={isbn}"))
        #expect(ManualSearchQueryTemplate.containsSupportedPlaceholder("https://x.com?w={workId}"))
        #expect(!ManualSearchQueryTemplate.containsSupportedPlaceholder("https://example.com"))
        #expect(!ManualSearchQueryTemplate.containsSupportedPlaceholder("https://x.com?q={unknown}"))
    }

    @Test func queryPlaceholderProducesEncodedTitleAndAuthor() throws {
        let result = ManualSearchProviderValidation.testSearch(
            "https://example.com/search?q={query}"
        )
        #expect(result.status == .looksGood)
        #expect(result.title == "Search looks good")
        let url = try #require(result.exampleURL)
        #expect(url.absoluteString.contains("The%20Hobbit"))
        #expect(url.absoluteString.contains("Tolkien"))
        #expect(result.sampleLabel == "The Hobbit — J.R.R. Tolkien")
        #expect(result.canOpenExample)
    }

    @Test func titleAndAuthorPlaceholdersWorkIndependently() throws {
        let titleURL = try ManualSearchQueryTemplate.url(
            template: "https://example.com/t/{title}",
            values: ManualSearchProviderValidation.sampleValues,
        ).get()
        #expect(titleURL.absoluteString.contains("The%20Hobbit"))
        #expect(!titleURL.absoluteString.contains("Tolkien"))

        let authorURL = try ManualSearchQueryTemplate.url(
            template: "https://example.com/a/{author}",
            values: ManualSearchProviderValidation.sampleValues,
        ).get()
        #expect(authorURL.absoluteString.contains("Tolkien"))
        #expect(!authorURL.absoluteString.contains("Hobbit"))
    }

    @Test func validURLWithNoPlaceholderReturnsWarningState() {
        let assessment = ManualSearchProviderValidation.assessTemplate("https://example.com")
        #expect(assessment == .missingPlaceholder(URL(string: "https://example.com")!))
        let test = ManualSearchProviderValidation.testSearch("https://example.com")
        #expect(test.status == .needsAttention)
        #expect(test.title == "Search needs attention")
        #expect(test.detail.contains("no search placeholders"))
        #expect(ManualSearchProviderValidation.inlineTemplateFeedback("https://example.com") == "No search placeholder")
    }

    @Test func malformedURLReturnsErrorState() {
        let test = ManualSearchProviderValidation.testSearch("not a url")
        #expect(test.status == .failed)
        #expect(test.title == "Couldn't build search URL")
        #expect(test.exampleURL == nil)
        #expect(ManualSearchProviderValidation.assessTemplate("") == .failure(.emptyTemplate))
    }

    @Test func unsupportedSchemeReturnsError() {
        let test = ManualSearchProviderValidation.testSearch("javascript:alert(1)")
        #expect(test.status == .failed)
        #expect(ManualSearchProviderValidation.assessTemplate("ftp://example.com/{query}") == .failure(.unsupportedScheme))
        #expect(
            ManualSearchProviderValidation.validateForSave(
                ManualSearchProvider(
                    id: "x",
                    name: "Bad",
                    searchURLTemplate: "ftp://example.com/{query}",
                    sortOrder: 0,
                    isBuiltIn: false,
                )
            ) == .unsupportedScheme
        )
    }

    @Test func emptyNameIsRejectedOnSave() {
        let provider = ManualSearchProvider(
            id: "x",
            name: "   ",
            searchURLTemplate: "https://example.com/search?q={query}",
            sortOrder: 0,
            isBuiltIn: false,
        )
        #expect(ManualSearchProviderValidation.validateForSave(provider) == .emptyName)
    }

    @Test func noPlaceholderProviderCanStillBeSaved() {
        let provider = ManualSearchProvider(
            id: "browse",
            name: "Homepage",
            searchURLTemplate: "https://example.com",
            sortOrder: 0,
            isBuiltIn: false,
        )
        #expect(ManualSearchProviderValidation.validateForSave(provider) == nil)
        #expect(ManualSearchProviderValidation.assessTemplate(provider.searchURLTemplate) == .missingPlaceholder(URL(string: "https://example.com")!))
    }

    @Test func validSymbolDisplaysNormallyAndInvalidFallsBack() {
        let ok = ManualSearchSymbolName.resolve("headphones") { $0 == "headphones" }
        #expect(ok.name == "headphones")
        #expect(!ok.usedFallback)

        let bad = ManualSearchSymbolName.resolve("not.a.real.symbol") { _ in false }
        #expect(bad.name == "globe")
        #expect(bad.usedFallback)

        let empty = ManualSearchSymbolName.resolve("  ") { _ in true }
        #expect(empty.name == ManualSearchSymbolName.fallback)
        #expect(empty.usedFallback)

        #expect(ManualSearchSymbolName.normalize("") == "globe")
        #expect(ManualSearchSymbolName.normalize("book") == "book")
        #expect(ManualSearchSymbolName.suggestions.contains("globe"))
        #expect(ManualSearchSymbolName.suggestions.contains("magnifyingglass"))
    }

    @Test func formatLabelsAreUserFacing() {
        #expect(ManualSearchMediaType.ebook.label == "eBooks")
        #expect(ManualSearchMediaType.audiobook.label == "Audiobooks")
    }

    @Test func inlineFeedbackForValidTemplate() {
        #expect(
            ManualSearchProviderValidation.inlineTemplateFeedback(
                "https://openlibrary.org/search?q={query}"
            ) == "Search template looks valid"
        )
    }
}
