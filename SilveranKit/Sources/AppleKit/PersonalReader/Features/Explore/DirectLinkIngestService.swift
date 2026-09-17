import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Direct HTTPS EPUB / Audio Ingest (Lawful)
//
// The user pastes a direct https:// link to a file they have the right to download
// (publisher link, author share, public-domain host, their own storage). The service
// validates scheme + extension + HEAD Content-Type and then downloads. No scraping,
// no DRM stripping, no bundled index.

// Mirrors Silveran's accepted extensions (Storyteller: epub only; folder: epub+cbz)
// plus audio types Silveran already knows. Keep in sync with `MediaModels`.
public enum DirectLinkKind: String, Sendable {
    case epub
    case cbz
    case m4b
    case m4a
    case mp3
    case zip // Readium audiobook package

    public var mimeHint: String {
        switch self {
        case .epub: return "application/epub+zip"
        case .cbz: return "application/x-cbz"
        case .m4b: return "audio/mp4"
        case .m4a: return "audio/mp4"
        case .mp3: return "audio/mpeg"
        case .zip: return "application/zip"
        }
    }

    public static func from(url: URL) -> DirectLinkKind? {
        switch url.pathExtension.lowercased() {
        case "epub": return .epub
        case "cbz": return .cbz
        case "m4b": return .m4b
        case "m4a": return .m4a
        case "mp3": return .mp3
        case "zip": return .zip
        default: return nil
        }
    }

    public static let allowedExtensions: Set<String> = ["epub", "cbz", "m4b", "m4a", "mp3", "zip"]
}

/// Result of validating a user-pasted link before any download begins.
public struct ValidatedDirectLink: Sendable, Hashable {
    public let url: URL
    public let kind: DirectLinkKind
    public let provenance: AcquisitionProvenance

    public init(url: URL, kind: DirectLinkKind, provenance: AcquisitionProvenance) {
        self.url = url
        self.kind = kind
        self.provenance = provenance
    }
}

public actor DirectLinkIngestService {
    public static let shared = DirectLinkIngestService()

    private let urlSession: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.urlSession = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 300
            self.urlSession = URLSession(configuration: cfg)
        }
    }

    /// Validate the string the user pasted. Must be https and an allowed extension.
    /// Does not hit the network.
    public func validate(urlString: String) throws -> ValidatedDirectLink {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "https",
              let host = url.host, !host.isEmpty else {
            throw ExploreAcquisitionError.notHTTPS
        }
        if OPDSCatalogs.isBannedHost(host) {
            throw ExploreAcquisitionError.disallowedHost(host)
        }
        guard let kind = DirectLinkKind.from(url: url) else {
            throw ExploreAcquisitionError.unsupportedExtension(url.pathExtension.isEmpty ? "(none)" : url.pathExtension)
        }
        let provenance = AcquisitionProvenance(transport: .directHTTPS, sourceName: host, sourceURL: url)
        return ValidatedDirectLink(url: url, kind: kind, provenance: provenance)
    }

    /// Optional HEAD probe to check Content-Type / size before a large GET.
    /// Callers may skip this and go straight to download; validation still enforces extension.
    public func probe(_ link: ValidatedDirectLink) async throws {
        var req = URLRequest(url: link.url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 15
        let (_, resp) = try await urlSession.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
            throw ExploreAcquisitionError.catalogUnreachable("HEAD \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        if let ct = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(), !ct.isEmpty {
            // Accept any ct that plausibly matches; reject obvious HTML where an EPUB was expected
            if link.kind == .epub && ct.contains("text/html") {
                throw ExploreAcquisitionError.contentTypeMismatch(expected: link.kind.mimeHint, actual: ct)
            }
        }
    }

    /// Download the validated link into memory. Caller then hands Data to
    /// `BookServiceActor.acceptBook` / `FolderSourceActor` — this service never
    /// strips DRM and never writes directly to the library.
    public func download(_ link: ValidatedDirectLink) async throws -> Data {
        var req = URLRequest(url: link.url)
        req.httpMethod = "GET"
        req.timeoutInterval = 300
        // Accept anything; server decides.
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        let (data, resp) = try await urlSession.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ExploreAcquisitionError.catalogUnreachable("GET \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard !data.isEmpty else {
            throw ExploreAcquisitionError.catalogUnreachable("Empty response")
        }
        return data
    }

    /// Convenience: validate + probe + download in one call (for UI “Add via Link” flow).
    public func fetch(urlString: String) async throws -> (ValidatedDirectLink, Data) {
        let link = try validate(urlString: urlString)
        // HEAD is best-effort — some hosts return 405; treat probe failure as non-fatal.
        try? await probe(link)
        let data = try await download(link)
        return (link, data)
    }
}
