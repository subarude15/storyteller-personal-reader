#if os(iOS) || os(macOS)
import PlaytorioFetcher
import SwiftUI

/// Settings → Data Sources: adapter toggles, priority, config JSON, and fetch-into-Explore.
public struct DataSourcesSettingsView: View {
    @State private var configs: [AdapterConfig] = AdapterSettings.defaultConfigs
    @State private var query: String = ""
    @State private var statusMessage: String?
    @State private var isFetching = false
    @State private var libraryCount = 0

    private var settings: AdapterSettings {
        AdapterSettings(directory: Self.playtorioDirectory())
    }

    private var service: FetcherService {
        let dir = Self.playtorioDirectory()
        return FetcherService(
            settings: AdapterSettings(directory: dir),
            cache: BookCache(databasePath: dir.appendingPathComponent("cache.sqlite")),
            library: PlaytorioLibraryStore(databasePath: PlaytorioLibraryStore.applicationSupportPath())
        )
    }

    public init() {}

    public var body: some View {
        Form {
            Section {
                TextField("ASIN, ISBN, or title", text: $query)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                #endif
                Button {
                    Task { await runFetch() }
                } label: {
                    if isFetching {
                        ProgressView()
                    } else {
                        Text("Fetch & add to Explore")
                    }
                }
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isFetching)
                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text("Ingested titles: \(libraryCount)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Discover")
            } footer: {
                Text("Fetched metadata is stored in the Playtorio library index and shown under Explore → Playtorio. URLs only — no ebook/audiobook files are downloaded.")
            }

            Section("Adapters") {
                ForEach($configs) { $config in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(config.name, isOn: $config.enabled)
                        HStack {
                            Text("Priority")
                            Spacer()
                            TextField(
                                "Priority",
                                value: $config.priority,
                                format: .number
                            )
                            .multilineTextAlignment(.trailing)
                            .frame(width: 64)
                        }
                        TextField(
                            "Config JSON object",
                            text: Binding(
                                get: { Self.encodeConfigMap(config.config) },
                                set: { config.config = Self.decodeConfigMap($0) }
                            )
                        )
                        .font(.system(.footnote, design: .monospaced))
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Data Sources")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await reload() }
        .onChange(of: configs) { _, newValue in
            try? settings.save(newValue)
        }
    }

    private func reload() async {
        configs = (try? settings.load()) ?? AdapterSettings.defaultConfigs
        libraryCount = PlaytorioLibraryStore(
            databasePath: PlaytorioLibraryStore.applicationSupportPath()
        ).count()
    }

    private func runFetch() async {
        isFetching = true
        defer { isFetching = false }
        do {
            try settings.save(configs)
            if let book = try await service.fetch(query: query, persist: true) {
                statusMessage = "Saved “\(book.title.isEmpty ? book.asin : book.title)” to Explore → Playtorio"
                libraryCount = service.library.count()
            } else {
                statusMessage = "No results for that query."
            }
        } catch {
            statusMessage = "Fetch failed: \(error.localizedDescription)"
        }
    }

    private static func playtorioDirectory() -> URL {
        PlaytorioLibraryStore.applicationSupportPath().deletingLastPathComponent()
    }

    private static func encodeConfigMap(_ map: [String: String]) -> String {
        guard let data = try? JSONEncoder().encode(map),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    private static func decodeConfigMap(_ text: String) -> [String: String] {
        guard let data = text.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
    }
}
#endif
