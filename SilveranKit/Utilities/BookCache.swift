// BookCache — SQLite-backed NormalizedBook cache.
// Hash: 64-bit FNV-1a hex (Crypto/CryptoKit not linked for Wave 1 Linux slice).

import Foundation
import SQLite3

public struct BookCache: Sendable {
    public var ttlSeconds: TimeInterval
    public var databasePath: URL

    public init(
        ttlSeconds: TimeInterval = 86_400,
        databasePath: URL = BookCache.defaultDatabasePath()
    ) {
        self.ttlSeconds = ttlSeconds
        self.databasePath = databasePath
    }

    public static func defaultDatabasePath() -> URL {
        PlaytorioPaths.dataDirectory().appendingPathComponent("cache.sqlite")
    }

    public func get(query: String) -> NormalizedBook? {
        let hash = Self.queryHash(query)
        guard let db = openDB() else { return nil }
        defer { sqlite3_close(db) }
        createTable(db)

        let sql = "SELECT book_json, fetched_at FROM cache WHERE query_hash = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, hash)

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cStr = sqlite3_column_text(stmt, 0)
        else {
            return nil
        }
        let fetchedAt = sqlite3_column_int64(stmt, 1)
        let now = Int64(Date().timeIntervalSince1970)
        if now - fetchedAt > Int64(ttlSeconds) {
            return nil
        }
        let data = Data(String(cString: cStr).utf8)
        return try? JSONDecoder().decode(NormalizedBook.self, from: data)
    }

    public func set(query: String, book: NormalizedBook) {
        let hash = Self.queryHash(query)
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        createTable(db)

        guard let json = try? JSONEncoder().encode(book),
              let jsonStr = String(data: json, encoding: .utf8)
        else {
            return
        }
        let now = Int64(Date().timeIntervalSince1970)
        let sql = """
        INSERT INTO cache (query_hash, book_json, fetched_at) VALUES (?, ?, ?)
        ON CONFLICT(query_hash) DO UPDATE SET book_json = excluded.book_json, fetched_at = excluded.fetched_at;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, hash)
        bindText(stmt, 2, jsonStr)
        sqlite3_bind_int64(stmt, 3, now)
        _ = sqlite3_step(stmt)
    }

    /// Normalized query → 64-bit FNV-1a as 16-char hex.
    public static func queryHash(_ query: String) -> String {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(format: "%016llx", hash)
    }

    private func openDB() -> OpaquePointer? {
        let dir = databasePath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(databasePath.path, &db) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        return db
    }

    private func createTable(_ db: OpaquePointer) {
        let sql = """
        CREATE TABLE IF NOT EXISTS cache (
            query_hash TEXT PRIMARY KEY,
            book_json TEXT NOT NULL,
            fetched_at INTEGER NOT NULL
        );
        """
        _ = sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = value.withCString { sqlite3_bind_text(stmt, index, $0, -1, transient) }
    }
}
