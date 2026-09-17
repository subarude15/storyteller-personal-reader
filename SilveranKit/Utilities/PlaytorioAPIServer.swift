import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Minimal JSON HTTP API for PlaytorioFetcher (no Hummingbird dependency).
/// Serves:
///   GET  /api/books?query=...
///   GET  /api/settings/adapters
///   PUT  /api/settings/adapters
public struct PlaytorioAPIServer: Sendable {
    public var service: FetcherService
    public var port: Int

    public init(service: FetcherService, port: Int = 8787) {
        self.service = service
        self.port = port
    }

    public func handle(method: String, path: String, query: [String: String], body: Data?) async throws -> (Int, Data, String) {
        let normalizedPath = path.split(separator: "?").first.map(String.init) ?? path

        switch (method.uppercased(), normalizedPath) {
        case ("GET", "/api/books"):
            let q = query["query"] ?? ""
            if q.isEmpty {
                // List ingested library books.
                let books = service.library.allBooks()
                let data = try JSONEncoder().encode(books)
                return (200, data, "application/json")
            }
            let book = try await service.fetch(query: q, persist: true)
            if let book {
                let data = try JSONEncoder().encode(book)
                return (200, data, "application/json")
            }
            return (404, Data("{\"error\":\"no results\"}".utf8), "application/json")

        case ("GET", "/api/settings/adapters"):
            let configs = try service.settings.load()
            let data = try JSONEncoder().encode(configs)
            return (200, data, "application/json")

        case ("PUT", "/api/settings/adapters"):
            guard let body,
                  let configs = try? JSONDecoder().decode([AdapterConfig].self, from: body)
            else {
                return (400, Data("{\"error\":\"invalid JSON body\"}".utf8), "application/json")
            }
            try service.settings.save(configs)
            let data = try JSONEncoder().encode(configs)
            return (200, data, "application/json")

        case ("GET", "/health"):
            return (200, Data("{\"ok\":true}".utf8), "application/json")

        default:
            return (404, Data("{\"error\":\"not found\"}".utf8), "application/json")
        }
    }
}

/// Extremely small blocking HTTP listener for CLI `--serve` (Linux + macOS).
public enum PlaytorioHTTPListener {
    public static func run(server: PlaytorioAPIServer) async throws {
        let port = server.port
        #if os(Linux)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw URLError(.cannotCreateFile) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: in_addr_t(0))
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw URLError(.cannotConnectToHost)
        }
        print("playtorio-fetcher serving on http://127.0.0.1:\(port)")

        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let n = read(client, &buffer, buffer.count)
            guard n > 0 else {
                close(client)
                continue
            }
            let request = String(bytes: buffer.prefix(n), encoding: .utf8) ?? ""
            let parsed = parseHTTP(request)
            let (status, body, contentType) = try await server.handle(
                method: parsed.method,
                path: parsed.path,
                query: parsed.query,
                body: parsed.body
            )
            let reason = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Error")
            let header = """
            HTTP/1.1 \(status) \(reason)\r
            Content-Type: \(contentType)\r
            Content-Length: \(body.count)\r
            Connection: close\r
            \r

            """
            header.withCString { ptr in
                _ = write(client, ptr, strlen(ptr))
            }
            body.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    _ = write(client, base, body.count)
                }
            }
            close(client)
        }
    }

    private static func parseHTTP(_ raw: String) -> (method: String, path: String, query: [String: String], body: Data?) {
        let parts = raw.components(separatedBy: "\r\n\r\n")
        let head = parts.first ?? ""
        let bodyString = parts.dropFirst().joined(separator: "\r\n\r\n")
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        let method = requestLine.count > 0 ? String(requestLine[0]) : "GET"
        var pathWithQuery = requestLine.count > 1 ? String(requestLine[1]) : "/"
        var query: [String: String] = [:]
        if let qIndex = pathWithQuery.firstIndex(of: "?") {
            let q = String(pathWithQuery[pathWithQuery.index(after: qIndex)...])
            pathWithQuery = String(pathWithQuery[..<qIndex])
            for pair in q.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 {
                    query[kv[0].removingPercentEncoding ?? kv[0]] =
                        kv[1].removingPercentEncoding ?? kv[1]
                }
            }
        }
        let body = bodyString.isEmpty ? nil : Data(bodyString.utf8)
        return (method, pathWithQuery, query, body)
    }
}
