import Foundation
import Testing
@testable import PlaytorioFetcher

@Test func testNormalizedBookCodableRoundTrip() throws {
    let original = NormalizedBook(
        title: "The Martian",
        author: "Andy Weir",
        narrator: "R. C. Bray",
        asin: "B00EMXBDMA",
        isbn: "9780804139021",
        duration_min: 653,
        cover_url: "https://example.com/cover.jpg",
        sample_audio_url: "https://example.com/sample.mp3",
        formats: [
            BookFormat(
                source: "openlibrary",
                format: "epub",
                url: "https://example.com/book.epub",
                size_mb: 1.5
            )
        ],
        metadata_sources: ["openlibrary", "librivox"]
    )

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(NormalizedBook.self, from: data)

    #expect(decoded == original)
}
