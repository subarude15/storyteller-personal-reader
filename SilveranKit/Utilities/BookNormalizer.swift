import Foundation

public enum BookNormalizer {
    /// Merges adapter results into one book.
    ///
    /// When there is no `.definitive` but at least one usable `.enrichment`,
    /// returns a `NormalizedBook` with empty string / zero scalar fields and
    /// the enrichment formats / cover / sample filled in. Callers that require
    /// a resolved identity should check `asin`/`isbn`/`title` themselves.
    public static func merge(_ results: [AdapterResult]) -> NormalizedBook? {
        var book: NormalizedBook?
        var sources: [String] = []
        var seenSources = Set<String>()
        var seenURLs = Set<String>()

        func appendSource(_ id: String) {
            guard !id.isEmpty, !seenSources.contains(id) else { return }
            seenSources.insert(id)
            sources.append(id)
        }

        // Pass 1: first definitive wins identity fields.
        for result in results {
            if case .definitive(let definitive) = result {
                book = definitive
                for s in definitive.metadata_sources {
                    appendSource(s)
                }
                for f in definitive.formats {
                    seenURLs.insert(f.url)
                }
                break
            }
        }

        // Pass 2: enrichments append formats and fill empty fields only.
        for result in results {
            switch result {
            case .definitive:
                continue
            case .none:
                continue
            case .enrichment(let formats, let cover, let sample, let adapterId):
                appendSource(adapterId)
                if book == nil {
                    book = NormalizedBook(
                        title: "",
                        author: "",
                        narrator: "",
                        asin: "",
                        isbn: "",
                        duration_min: 0,
                        cover_url: "",
                        sample_audio_url: "",
                        formats: [],
                        metadata_sources: []
                    )
                }
                guard var current = book else { continue }

                for format in formats {
                    if seenURLs.insert(format.url).inserted {
                        current.formats.append(format)
                    }
                }
                if current.cover_url.isEmpty, let cover, !cover.isEmpty {
                    current.cover_url = cover
                }
                if current.sample_audio_url.isEmpty, let sample, !sample.isEmpty {
                    current.sample_audio_url = sample
                }
                book = current
            }
        }

        guard var merged = book else { return nil }
        // Usable enrichment-only: must have formats, cover, or sample.
        let hasUsableEnrichment =
            !merged.formats.isEmpty
            || !merged.cover_url.isEmpty
            || !merged.sample_audio_url.isEmpty
        let hasDefinitiveIdentity =
            !merged.asin.isEmpty || !merged.isbn.isEmpty || !merged.title.isEmpty
        if !hasDefinitiveIdentity && !hasUsableEnrichment {
            return nil
        }

        merged.metadata_sources = sources
        return merged
    }
}
