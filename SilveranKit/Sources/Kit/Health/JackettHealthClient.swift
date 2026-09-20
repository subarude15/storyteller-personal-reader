import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Read-only Jackett probe via the documented Torznab indexer-list API.
/// `t=indexers` is metadata only — never a search or active indexer test.
/// Jackett requires the API key as a query parameter; that URL is never logged or cached.
public struct JackettHealthClient: Sendable {
    public static let indexerListPath = "api/v2.0/indexers/all/results/torznab/api"

    public var transport: any DiagnosticHTTPTransport

    public init(transport: any DiagnosticHTTPTransport = LiveDiagnosticHTTPTransport()) {
        self.transport = transport
    }

    public func probe(baseURL: String, apiKey: String) async -> Result<
        JackettHealthSnapshot, IndexerProbeFailure
    > {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = IndexerEndpoint.baseURL(from: baseURL) else {
            return .failure(.invalidURL)
        }
        guard let url = IndexerEndpoint.url(
            base: base,
            path: Self.indexerListPath,
            query: [
                URLQueryItem(name: "apikey", value: key),
                URLQueryItem(name: "t", value: "indexers"),
                URLQueryItem(name: "configured", value: "true"),
            ],
        ) else { return .failure(.invalidURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/xml", forHTTPHeaderField: "Accept")

        let http: DiagnosticHTTPResponse
        do {
            http = try await transport.send(request)
        } catch let error as URLError {
            return .failure(error.code == .timedOut ? .timeout : .unreachable)
        } catch {
            return .failure(.unreachable)
        }
        if http.status == 401 || http.status == 403 { return .failure(.unauthorized) }
        guard (200..<300).contains(http.status) else {
            return .failure(.httpStatus(http.status))
        }
        guard let parsed = Self.parseIndexersXML(http.body, secret: key) else {
            return .failure(.malformed)
        }
        return .success(
            JackettHealthSnapshot(
                indexers: parsed,
                configuredCount: parsed.filter(\.enabled).count,
            )
        )
    }

    /// Parses Jackett's Torznab `t=indexers` document:
    /// `<indexers><indexer id="…" configured="true|false"><title>…</title>…</indexer></indexers>`
    static func parseIndexersXML(_ data: Data, secret: String) -> [ServiceIndexerRow]? {
        let delegate = JackettIndexersXMLDelegate(secret: secret)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.sawIndexersRoot else { return nil }
        return delegate.rows
    }
}

public struct JackettHealthSnapshot: Equatable, Sendable {
    public var indexers: [ServiceIndexerRow]
    public var configuredCount: Int
}

/// Collects `<indexer>` rows from Jackett's Torznab indexer list. No live health fields exist here.
private final class JackettIndexersXMLDelegate: NSObject, XMLParserDelegate {
    private let secret: String
    private(set) var sawIndexersRoot = false
    private(set) var rows: [ServiceIndexerRow] = []

    private var depth = 0
    private var inIndexer = false
    private var currentID = ""
    private var currentConfigured = true
    private var currentTitle = ""
    private var capturingTitle = false
    private var titleDepth = 0

    init(secret: String) {
        self.secret = secret
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attributeDict: [String: String] = [:],
    ) {
        depth += 1
        let name = elementName.lowercased()
        if depth == 1, name == "indexers" {
            sawIndexersRoot = true
            return
        }
        if name == "indexer", !inIndexer {
            inIndexer = true
            currentID = attributeDict["id"] ?? attributeDict["ID"] ?? ""
            let configuredRaw =
                (attributeDict["configured"] ?? attributeDict["Configured"] ?? "true")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            currentConfigured = configuredRaw != "false" && configuredRaw != "0"
            currentTitle = ""
            capturingTitle = false
            titleDepth = 0
            return
        }
        if inIndexer, name == "title", !capturingTitle {
            capturingTitle = true
            titleDepth = depth
            currentTitle = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capturingTitle else { return }
        currentTitle += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
    ) {
        let name = elementName.lowercased()
        if capturingTitle, name == "title", depth == titleDepth {
            capturingTitle = false
            titleDepth = 0
        }
        if inIndexer, name == "indexer" {
            let id = currentID.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = id.isEmpty ? "Indexer \(rows.count + 1)" : id
            let display = title.isEmpty ? fallback : title
            let safeID = IndexerSecretRedactor.redact(
                id.isEmpty ? fallback : id,
                secrets: [secret],
            )
            let safeName = IndexerSecretRedactor.redact(display, secrets: [secret])
            if currentConfigured {
                rows.append(
                    ServiceIndexerRow(
                        id: safeID,
                        name: safeName,
                        enabled: true,
                        health: .unknown,
                        detail: "Configured · live health not available",
                    )
                )
            } else {
                rows.append(
                    ServiceIndexerRow(
                        id: safeID,
                        name: safeName,
                        enabled: false,
                        health: .disabled,
                    )
                )
            }
            inIndexer = false
            currentID = ""
            currentTitle = ""
            currentConfigured = true
        }
        depth -= 1
    }
}
