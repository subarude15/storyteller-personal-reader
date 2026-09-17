// PlaytorioLibraryStore — durable ingest index for fetched NormalizedBooks.
// This is the Playtorio library database (not the query TTL cache). Explore
// reads from here so ingested titles appear in Library/Explore.

import Foundation
import SQLite3

public struct PlaytorioLibraryStore: Sendable {
    public var databasePath: URL

    public init(databasePath: URL = PlaytorioLibraryStore.defaultDatabasePath()) {
        self.databasePath = databasePath
    }

    public static func defaultDatabasePath() -> URL {
        PlaytorioPaths.dataDirectory().appendingPathComponent("library.sqlite")
    }

    /// Application Support path for the iOS/macOS app (when available).
    public static func applicationSupportPath() -> URL {
        PlaytorioPaths.dataDirectory().appendingPathComponent("library.sqlite")
    }

    public func upsert(_ book: NormalizedBook) {
        let key = Self.bookKey(for: book)
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        createTable(db)
        guard let json = try? JSONEncoder().encode(book),
              let jsonStr = String(data: json, encoding: .utf8)
        else { return }
        let now = Int64(Date().timeIntervalSince1970)
        let sql = """
        INSERT INTO library (book_key, book_json, ingested_at) VALUES (?, ?, ?)
        ON CONFLICT(book_key) DO UPDATE SET book_json = excluded.book_json, ingested_at = excluded.ingested_at;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        bindText(stmt, 2, jsonStr)
        sqlite3_bind_int64(stmt, 3, now)
        _ = sqlite3_step(stmt)
    }

    public func allBooks() -> [NormalizedBook] {
        guard let db = openDB() else { return [] }
        defer { sqlite3_close(db) }
        createTable(db)
        let sql = "SELECT book_json FROM library ORDER BY ingested_at DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var books: [NormalizedBook] = []
        let decoder = JSONDecoder()
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cStr = sqlite3_column_text(stmt, 0) else { continue }
            let data = Data(String(cString: cStr).utf8)
            if let book = try? decoder.decode(NormalizedBook.self, from: data) {
                books.append(book)
            }
        }
        return books
    }

    public func count() -> Int {
        allBooks().count
    }

    public static func bookKey(for book: NormalizedBook) -> String {
        if !book.asin.isEmpty { return "asin:\(book.asin.uppercased())" }
        if !book.isbn.isEmpty { return "isbn:\(book.isbn)" }
        let title = book.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let author = book.author.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return "title:\(title)|\(author)"
    }

    public func toExploreBooks(sourceID: String = "playtorio", sourceName: String = "Playtorio") -> [[String: Any]] {
        // Lightweight dictionary form for callers that don't import Explore models.
        allBooks().map { book in
            var dict: [String: Any] = [
                "itemID": Self.bookKey(for: book),
                "sourceID": sourceID,
                "sourceName": sourceName,
                "title": book.title.isEmpty ? "Untitled" : book.title,
                "author": book.author,
                "coverURL": book.cover_url,
                "epubURL": book.formats.first { $0.format.lowercased() == "epub" }?.url ?? "",
                "sampleAudioURL": book.sample_audio_url,
                "asin": book.asin,
                "isbn": book.isbn,
                "durationMin": book.duration_min,
                "metadataSources": book.metadata_sources,
            ]
            dict["formats"] = book.formats.map {
                ["source": $0.source, "format": $0.format, "url": $0.url, "size_mb": $0.size_mb]
            }
            return dict
        }
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
        CREATE TABLE IF NOT EXISTS library (
            book_key TEXT PRIMARY KEY,
            book_json TEXT NOT NULL,
            ingested_at INTEGER NOT NULL
        );
        """
        _ = sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func bindText(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = value.withCString { sqlite3_bind_text(stmt, index, $0, -1, transient) }
    }
}
