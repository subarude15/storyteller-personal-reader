#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI

struct ManualSearchSettingsSection: View {
    var body: some View {
        Section {
            NavigationLink {
                ManualSearchSettingsView()
            } label: {
                Label("Search providers", systemImage: "magnifyingglass")
            }
            LabeledContent("Open searches", value: "In-app browser")
            LabeledContent("Download handling", value: "Send to NAS")
        } header: {
            Text("Manual Search")
        } footer: {
            Text(
                "When LazyLibrarian or Shelfarr cannot find a book, search a website yourself. Torrents go to qBittorrent or Deluge. Direct files download on this device, then upload to Synology."
            )
        }
    }
}

struct ManualSearchSettingsView: View {
    @State private var snapshot = ManualSearchSettingsStore.shared.snapshot
    @State private var editor: ProviderEditorState?
    @State private var testResult: String?

    var body: some View {
        List {
            Section {
                ForEach(snapshot.providers) { provider in
                    Button {
                        editor = ProviderEditorState(provider: provider)
                    } label: {
                        HStack {
                            Label(provider.name, systemImage: provider.symbolName)
                            Spacer()
                            if !provider.enabled {
                                Text("Off")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .onMove(perform: move)
                .onDelete(perform: delete)
            } header: {
                Text("Providers")
            } footer: {
                Text("Built-in providers can be turned off or reset. Custom providers can be deleted.")
            }

            Section {
                Button("Add Custom Provider") {
                    editor = ProviderEditorState()
                }
            }
        }
        .navigationTitle("Manual Search")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditButton()
        }
        #endif
        .onAppear { snapshot = ManualSearchSettingsStore.shared.snapshot }
        .onReceive(NotificationCenter.default.publisher(for: .inkampManualSearchSettingsDidChange)) { _ in
            snapshot = ManualSearchSettingsStore.shared.snapshot
        }
        .sheet(item: $editor) { state in
            ManualSearchProviderEditor(
                state: state,
                onSave: { provider in
                    let error: ManualSearchTemplateError?
                    if snapshot.providers.contains(where: { $0.id == provider.id }) {
                        error = ManualSearchSettingsStore.shared.update(provider)
                    } else {
                        error = ManualSearchSettingsStore.shared.addCustom(
                            name: provider.name,
                            searchURLTemplate: provider.searchURLTemplate,
                            supportedMediaTypes: provider.supportedMediaTypes,
                            symbolName: provider.symbolName,
                        )
                    }
                    if let error {
                        testResult = label(error)
                    } else {
                        editor = nil
                        snapshot = ManualSearchSettingsStore.shared.snapshot
                    }
                },
                onReset: { id in
                    ManualSearchSettingsStore.shared.resetBuiltIn(id: id)
                    editor = nil
                    snapshot = ManualSearchSettingsStore.shared.snapshot
                },
                onDelete: { id in
                    ManualSearchSettingsStore.shared.deleteCustom(id: id)
                    editor = nil
                    snapshot = ManualSearchSettingsStore.shared.snapshot
                },
            )
        }
        .alert("Provider", isPresented: Binding(
            get: { testResult != nil },
            set: { if !$0 { testResult = nil } },
        )) {
            Button("OK", role: .cancel) { testResult = nil }
        } message: {
            Text(testResult ?? "")
        }
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        ManualSearchSettingsStore.shared.move(from: offsets, to: destination)
        snapshot = ManualSearchSettingsStore.shared.snapshot
    }

    private func delete(at offsets: IndexSet) {
        let targets = offsets.map { snapshot.providers[$0] }
        for provider in targets where !provider.isBuiltIn {
            ManualSearchSettingsStore.shared.deleteCustom(id: provider.id)
        }
        snapshot = ManualSearchSettingsStore.shared.snapshot
    }

    private func label(_ error: ManualSearchTemplateError) -> String {
        switch error {
            case .emptyTemplate: "Enter a search URL template."
            case .malformedTemplate: "That template is not a valid URL."
            case .invalidURL: "The template does not produce a valid URL."
            case .unsupportedScheme: "Use an http or https URL. Do not put credentials in the template."
        }
    }
}

private struct ProviderEditorState: Identifiable {
    var id: String
    var provider: ManualSearchProvider
    var isNew: Bool

    init(provider: ManualSearchProvider) {
        id = provider.id
        self.provider = provider
        isNew = false
    }

    init() {
        let draft = ManualSearchProvider(
            id: "draft",
            name: "",
            searchURLTemplate: "https://example.com/search?q={query}",
            sortOrder: 0,
            isBuiltIn: false,
        )
        id = draft.id
        provider = draft
        isNew = true
    }
}

private struct ManualSearchProviderEditor: View {
    @State var provider: ManualSearchProvider
    let isNew: Bool
    let onSave: (ManualSearchProvider) -> Void
    let onReset: (String) -> Void
    let onDelete: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var testMessage: String?
    @State private var ebook = true
    @State private var audiobook = true

    init(
        state: ProviderEditorState,
        onSave: @escaping (ManualSearchProvider) -> Void,
        onReset: @escaping (String) -> Void,
        onDelete: @escaping (String) -> Void,
    ) {
        _provider = State(initialValue: state.provider)
        isNew = state.isNew
        self.onSave = onSave
        self.onReset = onReset
        self.onDelete = onDelete
        _ebook = State(initialValue: state.provider.supportedMediaTypes.contains(.ebook))
        _audiobook = State(initialValue: state.provider.supportedMediaTypes.contains(.audiobook))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Enabled", isOn: $provider.enabled)
                    TextField("Name", text: $provider.name)
                    TextField("URL template", text: $provider.searchURLTemplate, axis: .vertical)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    TextField("Symbol", text: $provider.symbolName)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                } footer: {
                    Text(
                        "Placeholders: {title} {author} {isbn} {workId} {query}. {query} is title plus author. Do not put passwords or API keys in the URL."
                    )
                }

                Section("Formats") {
                    Toggle("Ebook", isOn: $ebook)
                    Toggle("Audiobook", isOn: $audiobook)
                }

                Section {
                    Button("Test Template") {
                        testMessage = testLabel()
                    }
                    Button("Save") {
                        provider.supportedMediaTypes = selectedTypes()
                        onSave(provider)
                    }
                    .disabled(provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if provider.isBuiltIn {
                        Button("Reset Built-in") {
                            onReset(provider.id)
                        }
                    } else if !isNew {
                        Button("Delete", role: .destructive) {
                            onDelete(provider.id)
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "Add Provider" : "Edit Provider")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Template", isPresented: Binding(
                get: { testMessage != nil },
                set: { if !$0 { testMessage = nil } },
            )) {
                Button("OK", role: .cancel) { testMessage = nil }
            } message: {
                Text(testMessage ?? "")
            }
        }
    }

    private func selectedTypes() -> [ManualSearchMediaType] {
        var types: [ManualSearchMediaType] = []
        if ebook { types.append(.ebook) }
        if audiobook { types.append(.audiobook) }
        return types.isEmpty ? ManualSearchMediaType.allCases : types
    }

    private func testLabel() -> String {
        switch ManualSearchProviderValidation.validateTemplate(provider.searchURLTemplate) {
            case .success(let url):
                return url.absoluteString
            case .failure(let error):
                switch error {
                    case .emptyTemplate: return "Enter a search URL template."
                    case .malformedTemplate: return "That template is not a valid URL."
                    case .invalidURL: return "The template does not produce a valid URL."
                    case .unsupportedScheme: return "Use an http or https URL."
                }
        }
    }
}
#endif
