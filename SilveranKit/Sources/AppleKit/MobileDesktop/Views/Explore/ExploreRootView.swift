#if os(iOS)
import SilveranKit
import SwiftUI

/// Explore catalog root: source picker, cover grid, search, source management.
public struct ExploreRootView: View {
    @Bindable var store: ExploreCatalogStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var showAddSource = false
    @State private var showManageSources = false
    @State private var showDirectLink = false

    public init(store: ExploreCatalogStore) {
        self.store = store
    }

    public var body: some View {
        Group {
            content
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("Source") {
                        ForEach(store.sources) { source in
                            Button {
                                store.selectSource(id: source.id)
                            } label: {
                                if source.id == store.selectedSourceID {
                                    Label(source.name, systemImage: "checkmark")
                                } else {
                                    Text(source.name)
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Add OPDS Catalog…", systemImage: "plus") {
                        showAddSource = true
                    }
                    Button("Manage Sources…", systemImage: "slider.horizontal.3") {
                        showManageSources = true
                    }
                    Button("Open EPUB Link…", systemImage: "link") {
                        showDirectLink = true
                    }
                    if store.errorMessage != nil || store.filteredBooks.isEmpty {
                        Button("Retry", systemImage: "arrow.clockwise") {
                            Task { await store.reload(forceNetwork: true) }
                        }
                    }
                } label: {
                    Label("Explore Options", systemImage: "ellipsis.circle")
                }
            }
        }
        .task {
            if store.books.isEmpty && !store.isLoading {
                await store.reload(forceNetwork: true)
            }
        }
        .sheet(isPresented: $showAddSource) {
            NavigationStack {
                ExploreAddSourceView(store: store)
            }
            .punkRallyMiniPlayerInset()
        }
        .sheet(isPresented: $showManageSources) {
            NavigationStack {
                ExploreManageSourcesView(store: store)
            }
            .punkRallyMiniPlayerInset()
        }
        .sheet(isPresented: $showDirectLink) {
            NavigationStack {
                ExploreDirectEPUBLinkView(store: store)
            }
            .punkRallyMiniPlayerInset()
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading && store.filteredBooks.isEmpty {
            ProgressView("Loading catalog…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.errorMessage, store.filteredBooks.isEmpty {
            ExploreStatusView(
                title: "Couldn’t load catalog",
                message: error,
                systemImage: "wifi.exclamationmark",
                retry: { Task { await store.reload(forceNetwork: true) } }
            )
        } else if store.filteredBooks.isEmpty {
            ExploreStatusView(
                title: store.searchText.isEmpty ? "No books" : "No matches",
                message: store.searchText.isEmpty
                    ? "This source didn’t return any titles."
                    : "Nothing in this catalog matches “\(store.searchText)”.",
                systemImage: "books.vertical",
                retry: store.searchText.isEmpty
                    ? { Task { await store.reload(forceNetwork: true) } }
                    : nil
            )
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 12)
                    ],
                    spacing: 16
                ) {
                    ForEach(store.filteredBooks) { book in
                        NavigationLink(value: book) {
                            ExploreCoverCell(book: book)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if book.id == store.filteredBooks.last?.id {
                                Task { await store.loadMoreIfNeeded() }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if store.isShowingCachedResults {
                    Text("Showing cached catalog · may be out of date")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                }
                if store.isLoadingMore {
                    ProgressView()
                        .padding(.bottom, 16)
                }
            }
        }
    }
}

private struct ExploreCoverCell: View {
    let book: ExploreBook

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ExploreRemoteCover(url: book.coverURL)
                .aspectRatio(0.67, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(book.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Text(book.authorDisplay)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(book.title), \(book.authorDisplay)")
    }
}

struct ExploreRemoteCover: View {
    let url: URL?

    var body: some View {
        ZStack {
            Color(white: 0.2)
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Image(systemName: "book.closed.fill")
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                }
            } else {
                Image(systemName: "book.closed.fill")
                    .foregroundStyle(Color.white.opacity(0.55))
            }
        }
        .clipped()
    }
}

struct ExploreStatusView: View {
    let title: String
    let message: String
    let systemImage: String
    var retry: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if let retry {
                Button("Retry", action: retry)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ExploreAddSourceView: View {
    @Bindable var store: ExploreCatalogStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var urlText = ""
    @State private var isBusy = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                TextField("HTTPS OPDS URL", text: $urlText)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
            } footer: {
                Text("Public, unauthenticated HTTPS Atom/OPDS feeds only.")
            }
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Add Catalog")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    Task { await add() }
                }
                .disabled(isBusy || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .interactiveDismissDisabled(isBusy)
    }

    private func add() async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = ExploreCatalogError.invalidURL.localizedDescription
            return
        }
        do {
            try await store.addSource(name: name, feedURL: url)
            dismiss()
        } catch {
            errorMessage = (error as? ExploreCatalogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }
}

struct ExploreManageSourcesView: View {
    @Bindable var store: ExploreCatalogStore
    @Environment(\.dismiss) private var dismiss
    @State private var renameTarget: ExploreCatalogSource?
    @State private var renameText = ""

    var body: some View {
        List {
            ForEach(store.sources) { source in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(source.name)
                            .font(.body.weight(.medium))
                        if source.isBuiltIn {
                            Text("Built-in")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if source.id == store.selectedSourceID {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                    Text(source.feedURL.absoluteString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    store.selectSource(id: source.id)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if !source.isBuiltIn {
                        Button("Rename") {
                            renameTarget = source
                            renameText = source.name
                        }
                        .tint(.indigo)
                        Button("Remove", role: .destructive) {
                            store.removeSource(id: source.id)
                        }
                    }
                }
            }
        }
        .navigationTitle("Sources")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .alert(
            "Rename Source",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let id = renameTarget?.id {
                    store.renameSource(id: id, name: renameText)
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }
}

struct ExploreDirectEPUBLinkView: View {
    @Bindable var store: ExploreCatalogStore
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var previewBook: ExploreBook?

    var body: some View {
        Form {
            Section {
                TextField("HTTPS EPUB URL", text: $urlText)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
            } footer: {
                Text("Downloads and validates the EPUB, then opens a preview. It is not added to your library until you choose Add to Library.")
            }
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            if isBusy {
                Section {
                    ProgressView("Downloading…")
                }
            }
        }
        .navigationTitle("Open EPUB Link")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Open") {
                    Task { await open() }
                }
                .disabled(isBusy || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationDestination(item: $previewBook) { book in
            ExploreBookDetailView(book: book)
        }
    }

    private func open() async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = ExploreCatalogError.invalidURL.localizedDescription
            return
        }
        do {
            previewBook = try await store.makeDirectEPUBBook(url: url)
        } catch {
            errorMessage = (error as? ExploreCatalogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }
}
#endif
