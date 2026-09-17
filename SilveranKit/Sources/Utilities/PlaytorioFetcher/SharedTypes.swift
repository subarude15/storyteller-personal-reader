public struct NormalizedBook: Codable, Equatable {
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
}

public struct BookFormat: Codable, Equatable {
    public var source: String
    public var format: String
    public var url: String
    public var size_mb: Double
}

public struct AdapterConfig: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var type: String
    public var priority: Int
    public var config: [String: String]
}

public enum AdapterResult: Equatable {
    case definitive(NormalizedBook)
    case enrichment(formats: [BookFormat], cover_url: String?, sample_audio_url: String?)
    case none
}
