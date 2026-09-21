#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

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
    @State private var saveError: String?

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
                        saveError = ManualSearchProviderValidation.failureReason(error)
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
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } },
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
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
    @Environment(\.openURL) private var openURL
    @State private var testResult: ManualSearchTemplateTestResult?
    @State private var saveFieldError: String?
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

    private var resolvedSymbol: (name: String, usedFallback: Bool) {
        ManualSearchSymbolName.resolve(provider.symbolName, isValidSymbol: Self.isValidSFSymbol)
    }

    private var inlineTemplateFeedback: String? {
        ManualSearchProviderValidation.inlineTemplateFeedback(provider.searchURLTemplate)
    }

    private var canSave: Bool {
        !provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (ebook || audiobook)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Enabled", isOn: $provider.enabled)
                    LabeledContent("Provider Name") {
                        TextField("Audiobook Provider", text: $provider.name)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Search URL Template")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField(
                            "https://example.com/search?q={query}",
                            text: $provider.searchURLTemplate,
                            axis: .vertical,
                        )
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .autocorrectionDisabled()
                        .textContentType(.URL)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Use placeholders to insert book information into the search.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(ManualSearchProviderValidation.placeholderHelpLines, id: \.token) { line in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(line.token)
                                        .font(.caption.monospaced())
                                    Text(line.meaning)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text("Example: \(ManualSearchProviderValidation.exampleTemplate)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                        }

                        if let inlineTemplateFeedback {
                            Label(
                                inlineTemplateFeedback,
                                systemImage: ManualSearchProviderValidation.containsSupportedPlaceholder(
                                    provider.searchURLTemplate
                                ) ? "checkmark.circle" : "exclamationmark.triangle",
                            )
                            .font(.caption)
                            .foregroundStyle(
                                ManualSearchProviderValidation.containsSupportedPlaceholder(
                                    provider.searchURLTemplate
                                ) ? Color.secondary : Color.orange
                            )
                        }
                    }
                } header: {
                    Text("Provider")
                } footer: {
                    Text("Do not put passwords or API keys in the URL.")
                }

                Section {
                    HStack(spacing: 12) {
                        Image(systemName: resolvedSymbol.name)
                            .font(.title2)
                            .frame(width: 36, height: 36)
                            .accessibilityHidden(true)
                        TextField("SF Symbol name", text: $provider.symbolName)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                    }
                    if resolvedSymbol.usedFallback,
                        !provider.symbolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        Text("Unknown symbol — using globe.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(ManualSearchSymbolName.suggestions, id: \.self) { name in
                                Button {
                                    provider.symbolName = name
                                } label: {
                                    Label(name, systemImage: name)
                                        .labelStyle(.iconOnly)
                                        .padding(8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(
                                                    resolvedSymbol.name == name
                                                        ? Color.accentColor.opacity(0.15)
                                                        : Color.secondary.opacity(0.12)
                                                )
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(name)
                            }
                        }
                    }
                } header: {
                    Text("Icon")
                } footer: {
                    Text("Uses an Apple SF Symbol. Pick a suggestion or type a symbol name.")
                }

                Section {
                    Toggle("eBooks", isOn: $ebook)
                    Toggle("Audiobooks", isOn: $audiobook)
                    if !ebook && !audiobook {
                        Text("Select at least one format.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Formats")
                } footer: {
                    Text("Choose which searches this provider should appear for.")
                }

                Section {
                    Button("Test Search") {
                        testResult = ManualSearchProviderValidation.testSearch(provider.searchURLTemplate)
                    }
                    Button("Save") {
                        attemptSave()
                    }
                    .disabled(!canSave)
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
            .alert(
                testResult?.title ?? "Test Search",
                isPresented: Binding(
                    get: { testResult != nil },
                    set: { if !$0 { testResult = nil } },
                ),
            ) {
                if let url = testResult?.exampleURL {
                    Button("Open Test Search") {
                        openURL(url)
                        testResult = nil
                    }
                }
                Button("OK", role: .cancel) { testResult = nil }
            } message: {
                Text(testResult?.detail ?? "")
            }
            .alert("Couldn't Save", isPresented: Binding(
                get: { saveFieldError != nil },
                set: { if !$0 { saveFieldError = nil } },
            )) {
                Button("OK", role: .cancel) { saveFieldError = nil }
            } message: {
                Text(saveFieldError ?? "")
            }
        }
    }

    private func attemptSave() {
        guard ebook || audiobook else {
            saveFieldError = "Select at least one format (eBooks or Audiobooks)."
            return
        }
        let symbol = resolvedSymbol.name
        var draft = provider
        draft.name = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.searchURLTemplate = provider.searchURLTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.symbolName = symbol
        draft.supportedMediaTypes = selectedTypes()
        if let error = ManualSearchProviderValidation.validateForSave(draft) {
            saveFieldError = ManualSearchProviderValidation.failureReason(error)
            return
        }
        provider = draft
        onSave(draft)
    }

    private func selectedTypes() -> [ManualSearchMediaType] {
        var types: [ManualSearchMediaType] = []
        if ebook { types.append(.ebook) }
        if audiobook { types.append(.audiobook) }
        return types
    }

    private static func isValidSFSymbol(_ name: String) -> Bool {
        #if canImport(UIKit)
        return UIImage(systemName: name) != nil
        #elseif canImport(AppKit)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #else
        return !name.isEmpty
        #endif
    }
}
#endif
