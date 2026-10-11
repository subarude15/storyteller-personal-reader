#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI

/// Book search sheet with RaveBSD (default), LazyLibrarian request, and Manual Search.
struct BookSearchView: View {
    let book: ManualSearchBookContext
    var initialProvider: BookSearchProviderKind? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var provider: BookSearchProviderKind
    @State private var query: String
    @State private var titleField: String
    @State private var authorField: String
    @State private var mediaMode: RaveBSDMediaMode
    @State private var searching = false
    @State private var results: [RaveBSDSearchResult] = []
    @State private var meta: RaveBSDSearchMeta = RaveBSDSearchMeta()
    @State private var errorMessage: String?
    @State private var activeBaseURL: String?
    @State private var activeRoute: RaveBSDNetworkRoute?
    @State private var pendingDownload: RaveBSDSearchResult?
    @State private var downloadBusy = false
    @State private var downloadMessage: String?
    @State private var browserSession: ManualSearchBrowserSession?
    @State private var searchTask: Task<Void, Never>?
    @State private var lazyLibrarianBusy = false
    @State private var lazyLibrarianMessage: String?

    init(book: ManualSearchBookContext, initialProvider: BookSearchProviderKind? = nil) {
        self.book = book
        self.initialProvider = initialProvider
        let preferred = initialProvider
            ?? BookSearchProviderKind.preference(
                from: "" // filled in onAppear from settings
            )
        _provider = State(initialValue: preferred)
        _query = State(initialValue: book.defaultQuery)
        _titleField = State(initialValue: book.title)
        _authorField = State(initialValue: book.authorDisplay)
        if let requested = book.requestedMediaType {
            _mediaMode = State(initialValue: RaveBSDMediaMode(mediaType: requested))
        } else {
            _mediaMode = State(initialValue: .ebooks)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Provider", selection: $provider) {
                        ForEach(BookSearchProviderKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("book-search-provider")
                } footer: {
                    Text("Switching providers keeps your query. Downloads never start until you confirm.")
                }

                Section {
                    Text(book.title)
                        .font(.headline)
                    if !book.authorDisplay.isEmpty {
                        Text(book.authorDisplay)
                            .foregroundStyle(.secondary)
                    }
                }

                switch provider {
                    case .raveBSD:
                        raveBSDSections
                    case .manual:
                        ManualSearchEmbeddedSection(
                            book: book,
                            query: $query,
                            onOpen: { session in browserSession = session },
                        )
                    case .lazyLibrarian:
                        lazyLibrarianSection
                }
            }
            .navigationTitle("Book Search")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        searchTask?.cancel()
                        dismiss()
                    }
                }
            }
            .task {
                let config = await SettingsActor.shared.config
                if initialProvider == nil {
                    provider = BookSearchProviderKind.preference(from: config.bookSearchDefaultProvider)
                }
            }
            .onChange(of: provider) { _, newValue in
                Task {
                    try? await SettingsActor.shared.update(
                        bookSearchDefaultProvider: newValue.rawValue
                    )
                }
            }
            .confirmationDialog(
                "Send to NAS download?",
                isPresented: Binding(
                    get: { pendingDownload != nil },
                    set: { if !$0 { pendingDownload = nil } },
                ),
                titleVisibility: .visible,
            ) {
                Button("Start download") {
                    if let pendingDownload {
                        Task { await confirmDownload(pendingDownload) }
                    }
                }
                Button("Cancel", role: .cancel) { pendingDownload = nil }
            } message: {
                if let pendingDownload {
                    Text(downloadConfirmMessage(pendingDownload))
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

    @ViewBuilder
    private var raveBSDSections: some View {
        Section {
            Picker("Format", selection: $mediaMode) {
                ForEach(RaveBSDMediaMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            TextField("Title", text: $titleField)
            TextField("Author", text: $authorField)
            TextField("Or free-text query", text: $query, axis: .vertical)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
            Button {
                searchTask?.cancel()
                searchTask = Task { await runSearch() }
            } label: {
                if searching {
                    HStack {
                        ProgressView()
                        Text("Searching RaveBSD…")
                    }
                } else {
                    Label("Search RaveBSD", systemImage: "magnifyingglass")
                }
            }
            .disabled(searching || !canSearch)
            .accessibilityIdentifier("ravebsd-search")
            if let activeRoute, let activeBaseURL {
                Text("\(activeRoute.settingsStatusLabel) · \(ServiceHealthURLSanitizer.sanitize(activeBaseURL) ?? activeBaseURL)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("RaveBSD")
        }

        if let errorMessage {
            Section {
                Text(errorMessage)
                    .foregroundStyle(.red)
                Button("Try Manual Search") {
                    provider = .manual
                }
                Button("Try LazyLibrarian") {
                    provider = .lazyLibrarian
                }
            } header: {
                Text("RaveBSD unavailable")
            } footer: {
                Text("Same query is kept. Providers never switch automatically.")
            }
        }

        if let downloadMessage {
            Section {
                Text(downloadMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if searching && results.isEmpty {
            Section {
                HStack {
                    ProgressView()
                    Text("Waiting for sources…")
                        .foregroundStyle(.secondary)
                }
            }
        }

        if !results.isEmpty {
            Section {
                ForEach(results) { result in
                    RaveBSDResultRow(result: result, busy: downloadBusy) {
                        pendingDownload = result
                    }
                }
            } header: {
                Text("Results (\(results.count))")
            } footer: {
                if meta.totalReported > 0 {
                    Text("Source hits reported: \(meta.totalReported)")
                }
            }
        } else if !searching, errorMessage == nil, activeBaseURL != nil {
            Section {
                Text("No results")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var lazyLibrarianSection: some View {
        Section {
            Text(
                "LazyLibrarian queues a request on your server. It does not show a pickable result list here."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Button {
                Task { await submitLazyLibrarian() }
            } label: {
                if lazyLibrarianBusy {
                    HStack {
                        ProgressView()
                        Text("Sending request…")
                    }
                } else {
                    Label("Request ebook + audiobook", systemImage: "paperplane")
                }
            }
            .disabled(lazyLibrarianBusy || canonicalWork() == nil)
            if let lazyLibrarianMessage {
                Text(lazyLibrarianMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("LazyLibrarian")
        }
    }

    private func submitLazyLibrarian() async {
        guard let work = canonicalWork() else { return }
        lazyLibrarianBusy = true
        defer { lazyLibrarianBusy = false }
        let submission = await BookRequests.submit(
            work: work,
            formats: [.ebook, .audiobook],
            providerOverride: .lazyLibrarian,
        )
        if let message = submission.message, !message.isEmpty {
            lazyLibrarianMessage = message
        } else if let first = submission.outcomes.first {
            lazyLibrarianMessage = "\(first.format.label): \(first.detail)"
        } else {
            lazyLibrarianMessage = "Request sent."
        }
    }

    private var canSearch: Bool {
        !titleField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !authorField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func runSearch() async {
        searching = true
        errorMessage = nil
        downloadMessage = nil
        results = []
        defer { searching = false }

        let config = await SettingsActor.shared.config
        guard config.bookSearchLANEnabled else {
            errorMessage = "RaveBSD is turned off in Settings."
            return
        }
        let apiKey = (try? await AuthenticationActor.shared.loadRaveBSDAPIKey()) ?? ""
        let selection = await RaveBSDEndpointRouting.resolveLive(
            localURL: config.bookSearchLANBaseURL,
            remoteURL: config.raveBSDRemoteURL,
        )
        guard let selection else {
            errorMessage = "RaveBSD local/remote URLs are invalid."
            return
        }
        activeBaseURL = selection.baseURL
        activeRoute = selection.route

        let free = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let composed = ManualSearchQueryValues.make(
            from: ManualSearchBookContext(
                title: titleField,
                authors: authorField.isEmpty ? [] : [authorField],
            )
        ).query
        // Prefer structured title/author when the free-text field still matches them.
        let searchQuery: RaveBSDSearchQuery
        if !free.isEmpty, free != composed {
            searchQuery = RaveBSDSearchQuery(freeText: free, mode: mediaMode)
        } else {
            searchQuery = RaveBSDSearchQuery(
                title: titleField,
                author: authorField,
                mode: mediaMode,
            )
        }

        let client = RaveBSDClient()
        do {
            let response = try await client.search(
                baseURL: selection.baseURL,
                query: searchQuery,
                apiKey: apiKey,
            )
            if Task.isCancelled { return }
            results = response.results
            meta = response.meta
            if results.isEmpty {
                downloadMessage = "Search finished with no downloadable rows."
            }
        } catch let error as RaveBSDClientError {
            if case .cancelled = error { return }
            errorMessage = error.message
        } catch {
            errorMessage = "RaveBSD search failed."
        }
    }

    private func downloadConfirmMessage(_ result: RaveBSDSearchResult) -> String {
        var parts = [result.title]
        if !result.source.isEmpty { parts.append(result.source) }
        if let format = result.formatDisplay { parts.append(format) }
        parts.append(result.acquisitionMethod.label)
        return parts.joined(separator: " · ")
    }

    private func confirmDownload(_ result: RaveBSDSearchResult) async {
        pendingDownload = nil
        guard let activeBaseURL else {
            downloadMessage = "No active RaveBSD endpoint."
            return
        }
        downloadBusy = true
        defer { downloadBusy = false }
        let client = RaveBSDClient()
        var bookContext = book
        bookContext.requestedMediaType = mediaMode.mediaType
        do {
            let candidate = try await RaveBSDAcquisition.prepareCandidate(
                result: result,
                book: bookContext,
                baseURL: activeBaseURL,
                client: client,
                preferTorrentFile: false,
            )
            let handoff = await ManualAcquisitionRouter.nasLive().submit(candidate)
            downloadMessage = handoff.message
        } catch let error as RaveBSDAcquisitionError {
            downloadMessage = error.message
        } catch let error as RaveBSDClientError {
            downloadMessage = error.message
        } catch {
            downloadMessage = "Could not start download."
        }
    }

    private func canonicalWork() -> CanonicalBookWork? {
        let title = titleField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let authors =
            authorField
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let resolvedAuthors = authors.isEmpty ? book.authors : authors
        let workID = book.openLibraryWorkID ?? "search-\(title.lowercased())"
        return CanonicalBookWork(
            workID: workID,
            title: title,
            subtitle: nil,
            authors: resolvedAuthors,
            language: nil,
            isbn: book.isbn,
            openLibraryWorkID: book.openLibraryWorkID,
            openLibraryEditionID: nil,
            publicationYear: nil,
        )
    }
}

private struct RaveBSDResultRow: View {
    let result: RaveBSDSearchResult
    var busy: Bool
    var onDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.title)
                .font(.subheadline.weight(.semibold))
            if !result.author.isEmpty {
                Text(result.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if let format = result.formatDisplay {
                    Text(format)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Text(result.acquisitionMethod.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let size = result.filesizeDisplay {
                    Text(size)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                if !result.source.isEmpty {
                    Text(result.source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !result.language.isEmpty {
                    Text(result.language)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Download") { onDownload() }
                    .disabled(busy || !result.canAttemptDownload)
                    .accessibilityIdentifier("ravebsd-download-\(result.id)")
            }
            if let warning = result.warning {
                Text(warning)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Manual Search list embedded so provider switches do not lose the shared query field.
private struct ManualSearchEmbeddedSection: View {
    let book: ManualSearchBookContext
    @Binding var query: String
    var onOpen: (ManualSearchBrowserSession) -> Void

    @State private var providers: [ManualSearchProvider] = []

    var body: some View {
        Section {
            TextField("Custom search query", text: $query, axis: .vertical)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
        } header: {
            Text("Manual Search")
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
                    open(provider: provider)
                } label: {
                    Label(provider.name, systemImage: provider.symbolName)
                }
            }
        }
        .onAppear {
            providers = ManualSearchSettingsStore.shared.enabledProviders
        }
        .onReceive(NotificationCenter.default.publisher(for: .inkampManualSearchSettingsDidChange)) { _ in
            providers = ManualSearchSettingsStore.shared.enabledProviders
        }
    }

    private func open(provider: ManualSearchProvider) {
        let values = ManualSearchQueryValues.make(from: book, customQuery: query)
        switch ManualSearchQueryTemplate.url(template: provider.searchURLTemplate, values: values) {
            case .success(let url):
                onOpen(
                    ManualSearchBrowserSession(
                        url: url,
                        book: book,
                        provider: provider,
                    )
                )
            case .failure:
                break
        }
    }
}
#endif
