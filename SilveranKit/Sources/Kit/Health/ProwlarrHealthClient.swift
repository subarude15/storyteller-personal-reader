import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Read-only Prowlarr probe. Uses `X-Api-Key`. Never searches or edits indexers.
public struct ProwlarrHealthClient: Sendable {
    public var transport: any DiagnosticHTTPTransport

    public init(transport: any DiagnosticHTTPTransport = LiveDiagnosticHTTPTransport()) {
        self.transport = transport
    }

    public func probe(baseURL: String, apiKey: String) async -> Result<
        ProwlarrHealthSnapshot, IndexerProbeFailure
    > {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = IndexerEndpoint.baseURL(from: baseURL) else {
            return .failure(.invalidURL)
        }
        let statusResult = await get(
            base: base,
            path: "api/v1/system/status",
            apiKey: key,
        )
        let statusBody: Data
        switch statusResult {
            case .failure(let error): return .failure(error)
            case .success(let body): statusBody = body
        }
        let version = Self.version(from: statusBody)

        let indexersResult = await get(base: base, path: "api/v1/indexer", apiKey: key)
        let indexerBody: Data
        switch indexersResult {
            case .failure(let error): return .failure(error)
            case .success(let body): indexerBody = body
        }
        guard let indexerRows = Self.indexerObjects(indexerBody) else {
            return .failure(.malformed)
        }

        let statusList = await get(base: base, path: "api/v1/indexerstatus", apiKey: key)
        let failures: [Int: String]
        let statusReadable: Bool
        switch statusList {
            case .failure:
                failures = [:]
                statusReadable = false
            case .success(let body):
                if let parsed = Self.failures(from: body, secret: key) {
                    failures = parsed
                    statusReadable = true
                } else {
                    failures = [:]
                    statusReadable = false
                }
        }

        let rows = indexerRows.map { row in
            Self.row(row, failures: failures, statusReadable: statusReadable, secret: key)
        }
        let enabled = rows.filter(\.enabled).count
        let failing = rows.filter { $0.enabled && $0.health == .failing }.count
        return .success(
            ProwlarrHealthSnapshot(
                version: version,
                indexers: rows,
                enabledCount: enabled,
                failingCount: failing,
                statusReadable: statusReadable,
            )
        )
    }

    private func get(base: URL, path: String, apiKey: String) async -> Result<Data, IndexerProbeFailure> {
        guard let url = IndexerEndpoint.url(base: base, path: path) else {
            return .failure(.invalidURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
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
        guard (200..<300).contains(http.status) else { return .failure(.httpStatus(http.status)) }
        return .success(http.body)
    }

    private static func version(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let version = (object["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return version?.isEmpty == false ? version : nil
    }

    private static func indexerObjects(_ data: Data) -> [[String: Any]]? {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        return rows.compactMap { $0 as? [String: Any] }
    }

    private static func failures(from data: Data, secret: String) -> [Int: String]? {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        var map: [Int: String] = [:]
        for value in rows {
            guard let row = value as? [String: Any] else { continue }
            let id = (row["indexerId"] as? Int) ?? (row["indexerId"] as? NSNumber)?.intValue
            guard let id else { continue }
            // mostRecentFailure / initialFailure / disabledTill are timestamps, not messages.
            let detail = IndexerSecretRedactor.redact(
                failureDetail(from: row),
                secrets: [secret],
            )
            map[id] = detail
        }
        return map
    }

    /// Builds human copy from indexerstatus timestamps. Does not invent a failure reason.
    private static func failureDetail(from row: [String: Any]) -> String {
        let disabledTill = dateString(row["disabledTill"])
        if let until = formatDisplayDate(disabledTill) {
            return "Recent failures · disabled until \(until)"
        }
        let recent =
            dateString(row["mostRecentFailure"])
            ?? dateString(row["initialFailure"])
        if let last = formatDisplayDate(recent) {
            return "Recent failures · last \(last)"
        }
        return "Recent failures"
    }

    private static func dateString(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func formatDisplayDate(_ raw: String?) -> String? {
        guard let raw, let date = parseAPIDate(raw) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func parseAPIDate(_ raw: String) -> Date? {
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFractional.date(from: raw) { return date }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }

    private static func row(
        _ row: [String: Any],
        failures: [Int: String],
        statusReadable: Bool,
        secret: String,
    ) -> ServiceIndexerRow {
        let idNumber = (row["id"] as? Int) ?? (row["id"] as? NSNumber)?.intValue ?? 0
        let name =
            ((row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.isEmpty ? nil : $0
            } ?? "Indexer \(idNumber)"
        let enabled = (row["enable"] as? Bool) ?? (row["enable"] as? NSNumber)?.boolValue ?? true
        let safeName = IndexerSecretRedactor.redact(name, secrets: [secret])
        if !enabled {
            return ServiceIndexerRow(
                id: String(idNumber),
                name: safeName,
                enabled: false,
                health: .disabled,
                detail: nil,
            )
        }
        if !statusReadable {
            return ServiceIndexerRow(
                id: String(idNumber),
                name: safeName,
                enabled: true,
                health: .unknown,
                detail: "Configured · live health not available",
            )
        }
        if let reason = failures[idNumber] {
            return ServiceIndexerRow(
                id: String(idNumber),
                name: safeName,
                enabled: true,
                health: .failing,
                detail: reason,
            )
        }
        return ServiceIndexerRow(
            id: String(idNumber),
            name: safeName,
            enabled: true,
            health: .healthy,
        )
    }
}

public struct ProwlarrHealthSnapshot: Equatable, Sendable {
    public var version: String?
    public var indexers: [ServiceIndexerRow]
    public var enabledCount: Int
    public var failingCount: Int
    public var statusReadable: Bool
}
