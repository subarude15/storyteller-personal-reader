import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Read-only Jackett probe. Lists configured indexers only — no searches or tests.
/// Jackett requires the API key as a query parameter; that URL is never logged or cached.
public struct JackettHealthClient: Sendable {
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
            path: "api/v2.0/indexers",
            query: [
                URLQueryItem(name: "configured", value: "true"),
                URLQueryItem(name: "apikey", value: key),
            ],
        ) else { return .failure(.invalidURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

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
        guard let rows = try? JSONSerialization.jsonObject(with: http.body) as? [Any] else {
            return .failure(.malformed)
        }
        let indexers = rows.enumerated().compactMap { index, value -> ServiceIndexerRow? in
            guard let row = value as? [String: Any] else { return nil }
            return Self.row(row, fallbackID: index, secret: key)
        }
        return .success(
            JackettHealthSnapshot(
                indexers: indexers,
                configuredCount: indexers.filter(\.enabled).count,
            )
        )
    }

    private static func row(
        _ row: [String: Any],
        fallbackID: Int,
        secret: String,
    ) -> ServiceIndexerRow {
        let id =
            (row["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? String(fallbackID)
        let name =
            ((row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.isEmpty ? nil : IndexerSecretRedactor.redact($0, secrets: [secret])
            } ?? IndexerSecretRedactor.redact(id, secrets: [secret])
        let configured =
            (row["configured"] as? Bool) ?? (row["configured"] as? NSNumber)?.boolValue ?? true
        let safeID = IndexerSecretRedactor.redact(id, secrets: [secret])
        if !configured {
            return ServiceIndexerRow(
                id: safeID,
                name: name,
                enabled: false,
                health: .disabled,
            )
        }
        // A stored error on the list payload is a known failure. Jackett still has no
        // live health here — we never call the indexer test or search endpoints.
        let stored =
            (row["error"] as? String)
            ?? (row["last_error"] as? String)
            ?? (row["lastError"] as? String)
        let trimmed = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return ServiceIndexerRow(
                id: safeID,
                name: name,
                enabled: true,
                health: .failing,
                detail: IndexerSecretRedactor.redact(trimmed, secrets: [secret]),
            )
        }
        return ServiceIndexerRow(
            id: safeID,
            name: name,
            enabled: true,
            health: .unknown,
            detail: "Configured · live health not available",
        )
    }
}

public struct JackettHealthSnapshot: Equatable, Sendable {
    public var indexers: [ServiceIndexerRow]
    public var configuredCount: Int
}
