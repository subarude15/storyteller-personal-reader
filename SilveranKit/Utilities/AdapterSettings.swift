import Foundation
import SQLite3

public struct AdapterSettings: Sendable {
    public static let defaultConfigs: [AdapterConfig] = [
        AdapterConfig(
            id: "audible-metadata",
            name: "Audible Metadata",
            enabled: true,
            type: "metadata",
            priority: 10,
            config: [:]
        ),
        AdapterConfig(
            id: "libgen-catalog",
            name: "LibGen Catalog",
            enabled: true,
            type: "catalog",
            priority: 20,
            config: [:]
        ),
        AdapterConfig(
            id: "openlibrary-normalizer",
            name: "OpenLibrary Normalizer",
            enabled: true,
            type: "normalizer",
            priority: 30,
            config: [:]
        ),
    ]

    private static let fastPathKey = "playtorio.adapters.v1"

    /// Directory for SQLite + Linux fast-path file. Override in tests.
    public var directory: URL

    public init(directory: URL = AdapterSettings.defaultDirectory()) {
        self.directory = directory
    }

    public static func defaultDirectory() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".playtorio", isDirectory: true)
    }

    public func load() throws -> [AdapterConfig] {
        try ensureDirectory()
        if let fromSQL = try readSQLite(), !fromSQL.isEmpty {
            return fromSQL
        }
        if let fromFast = try readFastPath(), !fromFast.isEmpty {
            return fromFast
        }
        return Self.defaultConfigs
    }

    public func save(_ configs: [AdapterConfig]) throws {
        try ensureDirectory()
        try writeSQLite(configs)
        try writeFastPath(configs)
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var sqliteURL: URL {
        directory.appendingPathComponent("settings.sqlite")
    }

    private var linuxFastPathURL: URL {
        directory.appendingPathComponent("adapters.json")
    }

    private func readSQLite() throws -> [AdapterConfig]? {
        var db: OpaquePointer?
        guard sqlite3_open(sqliteURL.path, &db) == SQLITE_OK, let db else {
            return nil
        }
        defer { sqlite3_close(db) }

        let create = """
        CREATE TABLE IF NOT EXISTS settings (
            id TEXT PRIMARY KEY,
            json TEXT NOT NULL
        );
        """
        guard sqlite3_exec(db, create, nil, nil, nil) == SQLITE_OK else { return nil }

        let sql = "SELECT json FROM settings ORDER BY id;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        var configs: [AdapterConfig] = []
        let decoder = JSONDecoder()
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cStr = sqlite3_column_text(stmt, 0) else { continue }
            let data = Data(String(cString: cStr).utf8)
            if let config = try? decoder.decode(AdapterConfig.self, from: data) {
                configs.append(config)
            }
        }
        return configs.sorted { $0.priority < $1.priority }
    }

    private func writeSQLite(_ configs: [AdapterConfig]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(sqliteURL.path, &db) == SQLITE_OK, let db else {
            throw StorageError.sqliteOpenFailed
        }
        defer { sqlite3_close(db) }

        let create = """
        CREATE TABLE IF NOT EXISTS settings (
            id TEXT PRIMARY KEY,
            json TEXT NOT NULL
        );
        """
        guard sqlite3_exec(db, create, nil, nil, nil) == SQLITE_OK else {
            throw StorageError.sqliteExecFailed
        }
        guard sqlite3_exec(db, "DELETE FROM settings;", nil, nil, nil) == SQLITE_OK else {
            throw StorageError.sqliteExecFailed
        }

        let encoder = JSONEncoder()
        let insert = "INSERT INTO settings (id, json) VALUES (?, ?);"
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for config in configs {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insert, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw StorageError.sqliteExecFailed
            }
            defer { sqlite3_finalize(stmt) }
            let json = try encoder.encode(config)
            let jsonStr = String(data: json, encoding: .utf8) ?? "{}"
            _ = config.id.withCString { sqlite3_bind_text(stmt, 1, $0, -1, transient) }
            _ = jsonStr.withCString { sqlite3_bind_text(stmt, 2, $0, -1, transient) }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw StorageError.sqliteExecFailed
            }
        }
    }

    private func readFastPath() throws -> [AdapterConfig]? {
        #if canImport(Darwin)
        if let data = UserDefaults.standard.data(forKey: Self.fastPathKey) {
            return try JSONDecoder().decode([AdapterConfig].self, from: data)
        }
        return nil
        #else
        let url = linuxFastPathURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([AdapterConfig].self, from: data)
        #endif
    }

    private func writeFastPath(_ configs: [AdapterConfig]) throws {
        let data = try JSONEncoder().encode(configs)
        #if canImport(Darwin)
        UserDefaults.standard.set(data, forKey: Self.fastPathKey)
        #else
        try data.write(to: linuxFastPathURL, options: .atomic)
        #endif
    }

    private enum StorageError: Error {
        case sqliteOpenFailed
        case sqliteExecFailed
    }
}
