import Foundation
import Testing
@testable import PlaytorioFetcher

// MARK: - metadata_sources correctness (Wave 2 preamble)
// Definitive sources come from NormalizedBook.metadata_sources (no adapterId on
// .definitive). Enrichment sources come from adapterId via appendSource.

@Test func testMetadataSourcesIncludesDefinitiveAndEnrichments() {
    let definitive = AdapterResult.definitive(
        NormalizedBook(
            title: "The Martian",
            author: "Andy Weir",
            narrator: "R. C. Bray",
            asin: "B00EMXBDMA",
            isbn: "",
            duration_min: 653,
            cover_url: "https://example.com/a.jpg",
            sample_audio_url: "",
            formats: [],
            metadata_sources: ["audible-metadata"]
        )
    )
    let libgen = AdapterResult.enrichment(
        formats: [
            BookFormat(
                source: "libgen",
                format: "epub",
                url: "https://example.com/libgen/martian.epub",
                size_mb: 1.0
            )
        ],
        cover_url: nil,
        sample_audio_url: nil,
        adapterId: "libgen-catalog"
    )
    let openlibrary = AdapterResult.enrichment(
        formats: [],
        cover_url: "https://covers.openlibrary.org/b/id/1-L.jpg",
        sample_audio_url: nil,
        adapterId: "openlibrary-normalizer"
    )

    let merged = BookNormalizer.merge([definitive, libgen, openlibrary])
    #expect(
        merged?.metadata_sources == [
            "audible-metadata",
            "libgen-catalog",
            "openlibrary-normalizer",
        ]
    )
}

@Test func testMetadataSourcesDedupesWithoutReordering() {
    let definitive = AdapterResult.definitive(
        NormalizedBook(
            title: "The Martian",
            author: "Andy Weir",
            narrator: "",
            asin: "B00EMXBDMA",
            isbn: "",
            duration_min: 1,
            cover_url: "",
            sample_audio_url: "",
            formats: [],
            metadata_sources: ["audible-metadata"]
        )
    )
    let enrichmentA = AdapterResult.enrichment(
        formats: [
            BookFormat(
                source: "libgen",
                format: "epub",
                url: "https://example.com/a.epub",
                size_mb: 1
            )
        ],
        cover_url: nil,
        sample_audio_url: nil,
        adapterId: "audible-metadata"
    )
    let enrichmentB = AdapterResult.enrichment(
        formats: [
            BookFormat(
                source: "libgen",
                format: "mp3",
                url: "https://example.com/b.mp3",
                size_mb: 2
            )
        ],
        cover_url: nil,
        sample_audio_url: nil,
        adapterId: "audible-metadata"
    )
    let inputs = [definitive, enrichmentA, enrichmentB]

    for _ in 0..<10 {
        let merged = BookNormalizer.merge(inputs)
        #expect(merged?.metadata_sources == ["audible-metadata"])
    }
}

@Test func testMetadataSourcesOrderIsStableAcrossRuns() {
    let definitive = AdapterResult.definitive(
        NormalizedBook(
            title: "The Martian",
            author: "Andy Weir",
            narrator: "",
            asin: "B00EMXBDMA",
            isbn: "",
            duration_min: 1,
            cover_url: "",
            sample_audio_url: "",
            formats: [],
            metadata_sources: ["audible-metadata"]
        )
    )
    let enrichmentA = AdapterResult.enrichment(
        formats: [
            BookFormat(
                source: "libgen",
                format: "epub",
                url: "https://example.com/a.epub",
                size_mb: 1
            )
        ],
        cover_url: nil,
        sample_audio_url: nil,
        adapterId: "audible-metadata"
    )
    let enrichmentB = AdapterResult.enrichment(
        formats: [
            BookFormat(
                source: "libgen",
                format: "mp3",
                url: "https://example.com/b.mp3",
                size_mb: 2
            )
        ],
        cover_url: nil,
        sample_audio_url: nil,
        adapterId: "audible-metadata"
    )
    let inputs = [definitive, enrichmentA, enrichmentB]

    let first = BookNormalizer.merge(inputs)?.metadata_sources
    #expect(first == ["audible-metadata"])
    for _ in 0..<10 {
        let again = BookNormalizer.merge(inputs)?.metadata_sources
        #expect(again == first)
    }
}
