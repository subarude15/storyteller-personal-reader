#if os(iOS) || os(macOS)
import SwiftUI
import SilveranKit

@MainActor
final class RequestActivityViewModel: ObservableObject {
    @Published private(set) var items: [RequestActivityItem] = []
    @Published private(set) var isRefreshing = false
    @Published var lazyLibrarianUnavailableMessage: String?

    private let history: RequestActivityStore
    private let refreshService: RequestActivityRefreshService
    private var task: Task<Void, Never>?
    private var libraryBooks: [BookMetadata] = []

    init(
        history: RequestActivityStore = .shared,
        refreshService: RequestActivityRefreshService = RequestActivityRefreshService(),
    ) {
        self.history = history
        self.refreshService = refreshService
        items = history.allItems()
    }

    var groups: [(RequestActivitySection, [RequestActivityItem])] {
        RequestActivityGrouping.groups(items)
    }

    func onAppear(libraryBooks: [BookMetadata] = []) {
        self.libraryBooks = libraryBooks
        history.prune()
        _ = refreshService.applyLibraryPresence(libraryBooks: libraryBooks)
        items = history.allItems()
        refresh(force: false)
    }

    func applyLibraryPresence(libraryBooks: [BookMetadata]) {
        self.libraryBooks = libraryBooks
        _ = refreshService.applyLibraryPresence(libraryBooks: libraryBooks)
        items = history.allItems()
    }

    func reloadFromStore() {
        items = history.allItems()
    }

    func refresh(force: Bool) {
        task?.cancel()
        isRefreshing = true
        let books = libraryBooks
        task = Task { [weak self] in
            guard let self else { return }
            await self.loadHealthHint()
            let updated = await self.refreshService.refreshAll(
                force: force,
                libraryBooks: books,
            ) { [weak self] item in
                await MainActor.run {
                    self?.upsert(item)
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.items = updated.isEmpty ? self.history.allItems() : updated
                self.isRefreshing = false
            }
        }
    }

    func remove(_ item: RequestActivityItem) {
        history.remove(id: item.id)
        items.removeAll { $0.id == item.id }
    }

    private func upsert(_ item: RequestActivityItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
    }

    private func loadHealthHint() async {
        let cached = ServiceHealthCache.shared.result(for: .lazyLibrarian)
        if cached?.status == .unavailable {
            lazyLibrarianUnavailableMessage = "LazyLibrarian is currently unavailable"
        } else {
            lazyLibrarianUnavailableMessage = nil
        }
    }
}

public struct RequestActivityView: View {
    @StateObject private var model = RequestActivityViewModel()
    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel

    public init() {}

    public var body: some View {
        List {
            if let message = model.lazyLibrarianUnavailableMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                }
            }

            if model.groups.isEmpty {
                Section {
                    Text("No tracked requests yet")
                        .foregroundStyle(.secondary)
                    Text(
                        "Books you request will appear here while they are being searched for and prepared."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                ForEach(model.groups, id: \.0) { group in
                    Section(group.0.title) {
                        ForEach(group.1) { item in
                            NavigationLink {
                                RequestActivityDetailView(
                                    item: item,
                                    onRemove: { model.remove(item) },
                                )
                            } label: {
                                RequestActivityRow(item: item)
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                model.remove(group.1[index])
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Request Activity")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { model.refresh(force: true) }
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.refresh(force: true)
                } label: {
                    if model.isRefreshing {
                        ProgressView()
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isRefreshing)
            }
        }
        .onAppear {
            model.onAppear(libraryBooks: mediaViewModel.library.bookMetaData)
        }
        .onChange(of: mediaViewModel.libraryVersion) { _, _ in
            model.applyLibraryPresence(libraryBooks: mediaViewModel.library.bookMetaData)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .requestActivityStoreDidChange)
        ) { _ in
            model.reloadFromStore()
        }
    }
}

private struct RequestActivityRow: View {
    let item: RequestActivityItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.headline)
            if !item.author.isEmpty {
                Text(item.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(item.formatsLabel)
                Text("·")
                Text(item.provider.shortName)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(item.overallStatus.label)
                .font(.subheadline.weight(.semibold))
            if let detail = primaryDetail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let checked = item.lastCheckedAt {
                Text("Last checked \(ServiceHealthURLSanitizer.relativeAge(from: checked))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Updated \(ServiceHealthURLSanitizer.relativeAge(from: item.updatedAt))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var primaryDetail: String? {
        item.attentionReason
            ?? item.formatStatuses.first(where: { $0.status == item.overallStatus })?.detail
            ?? item.formatStatuses.first?.detail
    }
}

public struct RequestActivityDetailView: View {
    let item: RequestActivityItem
    var onRemove: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemove = false

    public init(item: RequestActivityItem, onRemove: @escaping () -> Void) {
        self.item = item
        self.onRemove = onRemove
    }

    public var body: some View {
        List {
            Section("Book") {
                LabeledContent("Title", value: item.title)
                if !item.author.isEmpty {
                    LabeledContent("Author", value: item.author)
                }
                LabeledContent("Provider", value: item.provider.shortName)
                LabeledContent("Requested", value: dateLabel(item.createdAt))
                LabeledContent("Formats", value: item.formatsLabel)
            }

            Section("Status") {
                ForEach(item.formatStatuses, id: \.format) { format in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(format.format.label)
                            .font(.subheadline.weight(.semibold))
                        Text(format.status.label)
                        if let detail = format.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let raw = format.providerRawState {
                            Text("LazyLibrarian: \(raw)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                LabeledContent("Last checked", value: dateLabel(item.lastCheckedAt))
                if let bookID = item.providerBookID {
                    LabeledContent("Provider BookID", value: bookID)
                }
            }

            if let error = item.lastError {
                Section("Last error") {
                    Text(error)
                }
            }

            if let reason = item.attentionReason {
                Section("Needs attention") {
                    Text(reason)
                }
            }

            Section {
                Button("Remove from history", role: .destructive) {
                    confirmRemove = true
                }
            } footer: {
                Text(
                    "Removes this app’s tracking record only. It does not delete the book from LazyLibrarian or Shelfarr."
                )
            }
        }
        .navigationTitle(item.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog(
            "Remove from history?",
            isPresented: $confirmRemove,
            titleVisibility: .visible,
        ) {
            Button("Remove", role: .destructive) {
                onRemove()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Local tracking only. Your LazyLibrarian / Shelfarr queue is unchanged.")
        }
    }

    private func dateLabel(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
#endif
