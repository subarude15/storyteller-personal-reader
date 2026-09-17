import Foundation
import PlaytorioFetcher

@main
enum PlaytorioFetcherMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            try await run(args: args)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }

    static func run(args: [String]) async throws {
        var query: String?
        var settingsPath: String?
        var dryRun = false
        var serve = false
        var port = 8787
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--query":
                i += 1
                guard i < args.count else { throw CLIError.missingValue(arg) }
                query = args[i]
            case "--settings":
                i += 1
                guard i < args.count else { throw CLIError.missingValue(arg) }
                settingsPath = args[i]
            case "--dry-run":
                dryRun = true
            case "--serve":
                serve = true
            case "--port":
                i += 1
                guard i < args.count, let p = Int(args[i]) else { throw CLIError.missingValue(arg) }
                port = p
            case "--help", "-h":
                print(usage)
                return
            default:
                throw CLIError.unknown(arg)
            }
            i += 1
        }

        let directory: URL
        if let settingsPath {
            directory = URL(fileURLWithPath: settingsPath).deletingLastPathComponent()
        } else {
            directory = AdapterSettings.defaultDirectory()
        }

        let settings = AdapterSettings(directory: directory)
        if let settingsPath {
            let url = URL(fileURLWithPath: settingsPath)
            if FileManager.default.fileExists(atPath: url.path),
               let data = try? Data(contentsOf: url),
               let configs = try? JSONDecoder().decode([AdapterConfig].self, from: data)
            {
                try settings.save(configs)
            }
        }

        let library = PlaytorioLibraryStore(
            databasePath: directory.appendingPathComponent("library.sqlite")
        )
        let cache = BookCache(
            databasePath: directory.appendingPathComponent("cache.sqlite")
        )
        let service = FetcherService(settings: settings, cache: cache, library: library)

        if dryRun {
            print(try service.dryRunDescription())
            return
        }

        if serve {
            let api = PlaytorioAPIServer(service: service, port: port)
            try await PlaytorioHTTPListener.run(server: api)
            return
        }

        guard let query else {
            print(usage)
            Foundation.exit(2)
        }

        if let book = try await service.fetch(query: query, persist: true) {
            let data = try JSONEncoder().encode(book)
            if let text = String(data: data, encoding: .utf8) {
                print(text)
            }
        } else {
            FileHandle.standardError.write(Data("no results\n".utf8))
            Foundation.exit(1)
        }
    }

    static var usage: String {
        """
        playtorio-fetcher --query \"ASIN or title\" [--settings ./settings.json]
        playtorio-fetcher --dry-run [--settings ./settings.json]
        playtorio-fetcher --serve [--port 8787] [--settings ./settings.json]
        """
    }
}

enum CLIError: Error, CustomStringConvertible {
    case missingValue(String)
    case unknown(String)

    var description: String {
        switch self {
        case .missingValue(let flag): return "missing value for \(flag)"
        case .unknown(let arg): return "unknown argument \(arg)"
        }
    }
}
