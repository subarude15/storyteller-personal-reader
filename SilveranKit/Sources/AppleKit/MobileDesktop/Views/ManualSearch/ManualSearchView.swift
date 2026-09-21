#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI

/// Lightweight fallback search for a single book.
struct ManualSearchView: View {
    let book: ManualSearchBookContext

    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var providers: [ManualSearchProvider] = []
    @State private var browserSession: ManualSearchBrowserSession?
    @State private var choosingProviderFor: ManualSearchLaunch?

    init(book: ManualSearchBookContext) {
        self.book = book
        _query = State(initialValue: book.defaultQuery)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(book.title)
                        .font(.headline)
                    if !book.authorDisplay.isEmpty {
                        Text(book.authorDisplay)
                            .foregroundStyle(.secondary)
                    }
                    if let requested = book.requestedMediaType {
                        Text(requested.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        launch(.all)
                    } label: {
                        Label("Search All", systemImage: "rectangle.stack")
                    }
                    .disabled(providers.isEmpty)
                    .accessibilityIdentifier("manual-search-all")
                } footer: {
                    Text("Opens one site at a time. Automatic request tools are not used here.")
                }

                Section("Providers") {
                    if providers.isEmpty {
                        Text("No search providers are enabled.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(providers) { provider in
                        Button {
                            launch(.provider(provider))
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(provider.name)
                                    if let requested = book.requestedMediaType,
                                        !provider.supportedMediaTypes.contains(requested)
                                    {
                                        Text("Usually used for other formats")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: provider.symbolName)
                            }
                        }
                        .accessibilityIdentifier("manual-search-provider-\(provider.id)")
                    }
                }

                Section {
                    TextField("Custom search query", text: $query, axis: .vertical)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                    Button("Search") {
                        launch(.all)
                    }
                    .disabled(providers.isEmpty || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("manual-search-custom")
                } header: {
                    Text("Custom search query")
                } footer: {
                    Text("Uses {query} in the provider URL. Title, author, ISBN, and work ID still fill in when the template asks for them.")
                }
            }
            .navigationTitle("Manual Search")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear(perform: reloadProviders)
            .onReceive(NotificationCenter.default.publisher(for: .inkampManualSearchSettingsDidChange)) { _ in
                reloadProviders()
            }
            .sheet(item: $choosingProviderFor) { launch in
                ManualSearchProviderChooser(
                    providers: providers,
                    title: launch.chooserTitle,
                ) { provider in
                    choosingProviderFor = nil
                    open(provider: provider)
                }
            }
            #if os(iOS)
            .fullScreenCover(item: $browserSession) { session in
                ManualSearchBrowserView(session: session, router: .nasLive())
            }
            #else
            .sheet(item: $browserSession) { session in
                ManualSearchBrowserView(session: session, router: .nasLive())
                    .frame(minWidth: 720, minHeight: 640)
            }
            #endif
        }
    }

    private func reloadProviders() {
        providers = ManualSearchSettingsStore.shared.enabledProviders
    }

    private func launch(_ kind: ManualSearchLaunch.Kind) {
        let launch = ManualSearchLaunch(kind: kind)
        switch kind {
            case .provider(let provider):
                open(provider: provider)
            case .all:
                if providers.count == 1, let only = providers.first {
                    open(provider: only)
                } else {
                    choosingProviderFor = launch
                }
        }
    }

    private func open(provider: ManualSearchProvider) {
        let values = ManualSearchQueryValues.make(from: book, customQuery: query)
        switch ManualSearchQueryTemplate.url(template: provider.searchURLTemplate, values: values) {
            case .success(let url):
                browserSession = ManualSearchBrowserSession(
                    url: url,
                    book: book,
                    provider: provider,
                )
            case .failure:
                choosingProviderFor = nil
        }
    }
}

private struct ManualSearchLaunch: Identifiable, Equatable {
    enum Kind: Equatable {
        case all
        case provider(ManualSearchProvider)
    }

    let id = UUID()
    var kind: Kind

    var chooserTitle: String {
        switch kind {
            case .all: "Choose a site"
            case .provider: "Search"
        }
    }
}

private struct ManualSearchProviderChooser: View {
    let providers: [ManualSearchProvider]
    let title: String
    let onChoose: (ManualSearchProvider) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(providers) { provider in
                Button {
                    onChoose(provider)
                } label: {
                    Label(provider.name, systemImage: provider.symbolName)
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
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }
}

struct ManualSearchBrowserSession: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var book: ManualSearchBookContext
    var provider: ManualSearchProvider
}
#endif
