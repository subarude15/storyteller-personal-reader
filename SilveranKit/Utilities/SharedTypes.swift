public struct NormalizedBook: Codable, Equatable, Sendable {
    public var title: String
    public var author: String
    public var narrator: String
    public var asin: String
    public var isbn: String
    public var duration_min: Int
    public var cover_url: String
    public var sample_audio_url: String
    public var formats: [BookFormat]
    public var metadata_sources: [String]

    public init(
        title: String,
        author: String,
        narrator: String,
        asin: String,
        isbn: String,
        duration_min: Int,
        cover_url: String,
        sample_audio_url: String,
        formats: [BookFormat],
        metadata_sources: [String]
    ) {
        self.title = title
        self.author = author
        self.narrator = narrator
        self.asin = asin
        self.isbn = isbn
        self.duration_min = duration_min
        self.cover_url = cover_url
        self.sample_audio_url = sample_audio_url
        self.formats = formats
        self.metadata_sources = metadata_sources
    }
}

public struct BookFormat: Codable, Equatable, Sendable {
    public var source: String
    public var format: String
    public var url: String
    public var size_mb: Double

    public init(source: String, format: String, url: String, size_mb: Double) {
        self.source = source
        self.format = format
        self.url = url
        self.size_mb = size_mb
    }
}

public struct AdapterConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var type: String
    public var priority: Int
    public var config: [String: String]

    public init(
        id: String,
        name: String,
        enabled: Bool,
        type: String,
        priority: Int,
        config: [String: String]
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.type = type
        self.priority = priority
        self.config = config
    }
}

public enum AdapterResult: Equatable, Sendable {
    case definitive(NormalizedBook)
    /// `adapterId` identifies the contributing adapter for `metadata_sources` merging.
    case enrichment(
        formats: [BookFormat],
        cover_url: String?,
        sample_audio_url: String?,
        adapterId: String
    )
    case none
}
