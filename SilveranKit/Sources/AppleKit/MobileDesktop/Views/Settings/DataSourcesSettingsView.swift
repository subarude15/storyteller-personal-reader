#if os(iOS) || os(macOS)
import PlaytorioFetcher
import SwiftUI

/// Settings → Data Sources: CRUD adapters, priority, config JSON, fetch-into-Explore.
public struct DataSourcesSettingsView: View {
    @State private var configs: [AdapterConfig] = AdapterSettings.defaultConfigs
    @State private var query: String = ""
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var isFetching = false
    @State private var libraryCount = 0
    @State private var editorTarget: SourceEditorTarget?
    @State private var showDeleteConfirm = false
    @State private var pendingDelete: AdapterConfig?

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
                        .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                }
                Text("Ingested titles: \(libraryCount)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Discover")
            } footer: {
                Text("Fetched metadata and public download URLs are stored in the Playtorio library index (Explore → Playtorio). Use Download / Import on a result to pull a format into the Storyteller pipeline.")
            }

            Section {
                ForEach($configs) { $config in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(config.name, isOn: $config.enabled)
                        HStack {
                            Text("Priority \(config.priority)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Edit") {
                                editorTarget = .edit(config)
                            }
                            .buttonStyle(.borderless)
                        }
                        if let base = config.config["baseURL"], !base.isEmpty {
                            Text(base)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onDelete(perform: deleteConfigs)

                Button {
                    editorTarget = .add
                } label: {
                    Label("Add New Source", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Adapters")
            } footer: {
                Text("Swipe to delete a source. Built-in adapters can be disabled but not removed. Changes persist in the settings SQLite store and reload on the next fetch.")
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
        .sheet(item: $editorTarget) { target in
            SourceEditorView(
                target: target,
                existingIDs: Set(configs.map(\.id))
            ) { saved in
                applyEditorSave(saved, target: target)
            }
        }
        .confirmationDialog(
            "Delete source?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let pendingDelete {
                    configs.removeAll { $0.id == pendingDelete.id }
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text("This removes the adapter from Data Sources. It will no longer run on fetch.")
        }
    }

    private func deleteConfigs(at offsets: IndexSet) {
        let removable = offsets.compactMap { index -> AdapterConfig? in
            guard configs.indices.contains(index) else { return nil }
            let config = configs[index]
            // Keep built-ins; disable instead of delete.
            if Self.builtInIDs.contains(config.id) {
                return nil
            }
            return config
        }
        if removable.count == 1, let only = removable.first {
            pendingDelete = only
            showDeleteConfirm = true
            return
        }
        configs.removeAll { config in
            removable.contains(where: { $0.id == config.id })
        }
    }

    private func applyEditorSave(_ saved: AdapterConfig, target: SourceEditorTarget) {
        switch target {
        case .add:
            configs.append(saved)
            configs.sort { $0.priority < $1.priority }
        case .edit(let original):
            if let idx = configs.firstIndex(where: { $0.id == original.id }) {
                configs[idx] = saved
                configs.sort { $0.priority < $1.priority }
            }
        }
        try? settings.save(configs)
    }

    private func reload() async {
        configs = (try? settings.load()) ?? AdapterSettings.defaultConfigs
        libraryCount = PlaytorioLibraryStore(
            databasePath: PlaytorioLibraryStore.applicationSupportPath()
        ).count()
    }

    private func runFetch() async {
        isFetching = true
        statusIsError = false
        defer { isFetching = false }
        do {
            try settings.save(configs)
            if let book = try await service.fetch(query: query, persist: true) {
                statusMessage =
                    "Saved “\(book.title.isEmpty ? book.asin : book.title)” to Explore → Playtorio"
                libraryCount = service.library.count()
            } else {
                statusMessage = "No results for that query."
            }
        } catch is AdapterConfigurationError {
            statusIsError = true
            statusMessage = "Source configuration error"
        } catch {
            statusIsError = true
            statusMessage = "Fetch failed: \(error.localizedDescription)"
        }
    }

    private static let builtInIDs: Set<String> = [
        "ravebooksearch",
        "audible-metadata",
        "libgen-catalog",
        "openlibrary-normalizer",
    ]

    private static func playtorioDirectory() -> URL {
        PlaytorioLibraryStore.applicationSupportPath().deletingLastPathComponent()
    }
}

// MARK: - Source editor

private enum SourceEditorTarget: Identifiable {
    case add
    case edit(AdapterConfig)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let c): return "edit-\(c.id)"
        }
    }
}

private struct SourceEditorView: View {
    let target: SourceEditorTarget
    let existingIDs: Set<String>
    let onSave: (AdapterConfig) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var priority: Int = 50
    @State private var configJSON: String = "{}"
    @State private var enabled: Bool = true
    @State private var adapterType: String = "custom"
    @State private var errorMessage: String?
    @State private var sourceID: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Source") {
                    TextField("Source Name", text: $name)
                    TextField("Base URL / Search Endpoint", text: $baseURL)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    #endif
                    TextField("Priority", value: $priority, format: .number)
                    Toggle("Enabled", isOn: $enabled)
                    TextField("Type (catalog / custom / rave)", text: $adapterType)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    #endif
                }
                Section {
                    TextEditor(text: $configJSON)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 120)
                } header: {
                    Text("Config JSON")
                } footer: {
                    Text("Object of string values (regex patterns, selectors, API keys). Example: {\"mode\":\"ebooks\",\"searchPath\":\"/search/all\"}. Invalid JSON shows a Source configuration error.")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { seed() }
        }
    }

    private var title: String {
        switch target {
        case .add: return "Add Source"
        case .edit: return "Edit Source"
        }
    }

    private func seed() {
        switch target {
        case .add:
            sourceID = "user-\(UUID().uuidString.prefix(8).lowercased())"
            name = ""
            baseURL = "https://"
            priority = 50
            adapterType = "custom"
            configJSON = "{}"
            enabled = true
        case .edit(let config):
            sourceID = config.id
            name = config.name
            baseURL = config.config["baseURL"] ?? ""
            priority = config.priority
            adapterType = config.type
            enabled = config.enabled
            var map = config.config
            map.removeValue(forKey: "baseURL")
            configJSON = Self.encodeConfigMap(map)
        }
    }

    private func save() {
        errorMessage = nil
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            errorMessage = "Source configuration error"
            return
        }

        if !trimmedURL.isEmpty {
            guard let url = URL(string: trimmedURL),
                  url.scheme == "http" || url.scheme == "https",
                  url.host != nil
            else {
                errorMessage = "Source configuration error"
                return
            }
        }

        guard let map = Self.decodeConfigMapStrict(configJSON) else {
            errorMessage = "Source configuration error"
            return
        }

        var configMap = map
        if !trimmedURL.isEmpty {
            configMap["baseURL"] = trimmedURL
        }

        let id: String
        switch target {
        case .add:
            id = sourceID
            if existingIDs.contains(id) {
                errorMessage = "Source configuration error"
                return
            }
        case .edit(let original):
            id = original.id
        }

        let saved = AdapterConfig(
            id: id,
            name: trimmedName,
            enabled: enabled,
            type: adapterType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "custom"
                : adapterType.trimmingCharacters(in: .whitespacesAndNewlines),
            priority: priority,
            config: configMap
        )
        onSave(saved)
        dismiss()
    }

    private static func encodeConfigMap(_ map: [String: String]) -> String {
        guard let data = try? JSONEncoder().encode(map),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    /// Returns nil when the text is not a JSON object of string values.
    private static func decodeConfigMapStrict(_ text: String) -> [String: String]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [:] }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }
}
#endif
