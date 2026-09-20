#if os(iOS) || os(macOS)
import SwiftUI
import SilveranKit

@MainActor
final class RequestActivityViewModel: ObservableObject {
    @Published private(set) var items: [RequestActivityItem] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var checkingItemID: String?
    @Published private(set) var retryingItemID: String?
    @Published var lazyLibrarianUnavailableMessage: String?
    @Published var actionError: String?
    @Published var actionInfo: String?
    @Published private(set) var actionContext = RequestActivityActionContext()

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

    func item(id: String) -> RequestActivityItem? {
        items.first { $0.id == id } ?? history.item(id: id)
    }

    func availability(for item: RequestActivityItem) -> RequestActivityActionAvailability {
        RequestActivityActions.availability(for: item, context: actionContext)
    }

    func onAppear(libraryBooks: [BookMetadata] = []) {
        self.libraryBooks = libraryBooks
        history.prune()
        _ = refreshService.applyLibraryPresence(libraryBooks: libraryBooks)
        items = history.allItems()
        Task { await self.reloadActionContext() }
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
            await self.reloadActionContext()
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

    /// Per-request status check — reuses RequestActivityRefreshService.
    func checkStatus(itemID: String) {
        guard checkingItemID == nil, retryingItemID == nil else { return }
        actionError = nil
        actionInfo = nil
        checkingItemID = itemID
        let books = libraryBooks
        Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.checkingItemID = nil
                }
            }
            await self.reloadActionContext()
            guard var current = self.history.item(id: itemID) else {
                await MainActor.run { self.actionError = "Request not found." }
                return
            }
            // Storyteller presence first.
            let matcher = RequestLibraryMatcher(books: books)
            current = RequestLibraryPresence.apply(current, matcher: matcher, now: Date())
            if current != self.history.item(id: itemID) {
                self.history.upsert(current)
            }

            let settings = await SettingsActor.shared.config
            let key = (try? await AuthenticationActor.shared.loadLazyLibrarianAPIKey()) ?? ""
            let lazyReady =
                settings.lazyLibrarianEnabled
                && !settings.lazyLibrarianBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
                && !key.isEmpty

            let updated = await self.refreshService.refreshOne(
                current,
                force: true,
                lazyReady: lazyReady,
                baseURL: settings.lazyLibrarianBaseURL,
                apiKey: key,
                matcher: matcher,
            )
            await MainActor.run {
                self.upsert(updated)
                self.items = self.history.allItems()
                if let error = updated.lastError, !error.isEmpty {
                    self.actionError = error
                }
            }
        }
    }

    /// Retry only formats RequestActivityRetryPolicy marks retryable.
    func retryRequest(itemID: String) {
        guard checkingItemID == nil, retryingItemID == nil else { return }
        actionError = nil
        actionInfo = nil
        // Re-check Storyteller before offering/sending a retry.
        _ = refreshService.applyLibraryPresence(libraryBooks: libraryBooks)
        items = history.allItems()
        guard let current = history.item(id: itemID) else {
            actionError = "Request not found."
            return
        }
        let formats = RequestActivityRetryPolicy.retryableFormats(for: current)
        guard !formats.isEmpty else {
            actionError = "Nothing to retry."
            return
        }
        retryingItemID = itemID
        Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.retryingItemID = nil
                }
            }
            let submission = await BookRequests.retry(
                item: current,
                formats: formats,
                history: self.history,
            )
            await MainActor.run {
                self.items = self.history.allItems()
                if let message = submission.message, !message.isEmpty {
                    self.actionError = message
                } else if let failed = submission.outcomes.first(where: { $0.phase == .failed }) {
                    self.actionError = failed.detail
                }
            }
        }
    }

    func browseURL(for action: RequestActivityBrowseTarget) -> URL? {
        switch action {
            case .lazyLibrarian:
                RequestActivityExternalLinks.lazyLibrarianHome(
                    baseURL: actionContext.lazyLibrarianBaseURL
                )
            case .shelfarr:
                RequestActivityExternalLinks.shelfarrHome(baseURL: actionContext.shelfarrBaseURL)
            case .bookSearchLAN:
                RequestActivityExternalLinks.bookSearchLAN(
                    baseURL: actionContext.bookSearchLANBaseURL
                )
        }
    }

    /// Open LAN helper after a lightweight reachability ping.
    /// Unreachable / off-LAN is informational — never Needs Attention.
    func prepareAlternateSearchOpen() async -> URL? {
        actionError = nil
        actionInfo = nil
        await reloadActionContext()
        guard actionContext.bookSearchLANEnabled,
            let url = RequestActivityExternalLinks.bookSearchLAN(
                baseURL: actionContext.bookSearchLANBaseURL
            )
        else {
            actionInfo = "Could not open the local book-search helper."
            return nil
        }
        let snapshot = ServiceHealthSettingsSnapshot(
            bookSearchLANEnabled: actionContext.bookSearchLANEnabled,
            bookSearchLANBaseURL: actionContext.bookSearchLANBaseURL,
        )
        let result = await BookSearchLANHealthChecker().check(settings: snapshot)
        if result.status == .healthy {
            return url
        }
        actionInfo = "Book Search is only available on your home network."
        return nil
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

    private func reloadActionContext() async {
        let config = await SettingsActor.shared.config
        await MainActor.run {
            self.actionContext = RequestActivityActionContext(config: config)
        }
    }
}

enum RequestActivityBrowseTarget {
    case lazyLibrarian
    case shelfarr
    case bookSearchLAN
}

public struct RequestActivityView: View {
    var initialRequestID: String?
    @StateObject private var model = RequestActivityViewModel()
    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel
    @State private var deepLinkID: String?
    @State private var missingRequestMessage: String?

    public init(initialRequestID: String? = nil) {
        self.initialRequestID = initialRequestID
    }

    public var body: some View {
        List {
            if let missingRequestMessage {
                Section {
                    Text(missingRequestMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

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
                                RequestActivityDetailView(itemID: item.id, model: model)
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
            applyInitialDestination()
        }
        .onChange(of: initialRequestID) { _, _ in
            applyInitialDestination()
        }
        .onChange(of: mediaViewModel.libraryVersion) { _, _ in
            model.applyLibraryPresence(libraryBooks: mediaViewModel.library.bookMetaData)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .requestActivityStoreDidChange)
        ) { _ in
            model.reloadFromStore()
        }
        .background {
            NavigationLink(
                isActive: Binding(
                    get: { deepLinkID != nil },
                    set: { isActive in
                        if !isActive { deepLinkID = nil }
                    },
                )
            ) {
                if let deepLinkID {
                    RequestActivityDetailView(itemID: deepLinkID, model: model)
                } else {
                    EmptyView()
                }
            } label: {
                EmptyView()
            }
            .hidden()
        }
    }

    /// Push the shared detail when the id is still in history. Otherwise stay on the list.
    private func applyInitialDestination() {
        guard let initialRequestID else { return }
        let resolved = RequestActivityNavigation.resolved(
            .detail(requestID: initialRequestID),
            itemExists: { model.item(id: $0) != nil },
        )
        switch resolved {
            case .list:
                deepLinkID = nil
                missingRequestMessage = RequestActivityNavigation.missingHistoryMessage
            case .detail(let requestID):
                missingRequestMessage = nil
                deepLinkID = requestID
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

struct RequestActivityDetailView: View {
    let itemID: String
    @ObservedObject var model: RequestActivityViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var confirmRemove = false
    @State private var openingAlternate = false

    private var item: RequestActivityItem? {
        model.item(id: itemID)
    }

    private var availability: RequestActivityActionAvailability {
        guard let item else { return RequestActivityActionAvailability() }
        return model.availability(for: item)
    }

    private var isBusy: Bool {
        model.checkingItemID == itemID || model.retryingItemID == itemID || openingAlternate
    }

    var body: some View {
        Group {
            if let item {
                detailList(item)
            } else {
                ContentUnavailableView(
                    "Request removed",
                    systemImage: "trash",
                    description: Text("This tracking record is no longer in history."),
                )
            }
        }
        .navigationTitle(item?.title ?? "Request")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("Something went wrong", isPresented: actionErrorBinding) {
            Button("OK", role: .cancel) { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
        .alert("Book Search", isPresented: actionInfoBinding) {
            Button("OK", role: .cancel) { model.actionInfo = nil }
        } message: {
            Text(model.actionInfo ?? "")
        }
        .confirmationDialog(
            "Remove from history?",
            isPresented: $confirmRemove,
            titleVisibility: .visible,
        ) {
            Button("Remove", role: .destructive) {
                if let item {
                    model.remove(item)
                }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Local tracking only. Your LazyLibrarian / Shelfarr queue is unchanged.")
        }
    }

    @ViewBuilder
    private func detailList(_ item: RequestActivityItem) -> some View {
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

            if availability.hasAnyAction {
                Section("Actions") {
                    if availability.canCheckStatus {
                        Button {
                            model.checkStatus(itemID: itemID)
                        } label: {
                            if model.checkingItemID == itemID {
                                Label("Checking…", systemImage: "arrow.clockwise")
                            } else {
                                Label("Check Status", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(isBusy)
                    }

                    if availability.canRetry {
                        Button {
                            model.retryRequest(itemID: itemID)
                        } label: {
                            if model.retryingItemID == itemID {
                                Label("Retrying…", systemImage: "arrow.triangle.2.circlepath")
                            } else {
                                Label("Retry Request", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .disabled(isBusy)
                    }

                    if availability.canOpenLazyLibrarian {
                        Button {
                            openBrowse(.lazyLibrarian)
                        } label: {
                            Label("Open in LazyLibrarian", systemImage: "safari")
                        }
                        .disabled(isBusy)
                    }

                    if availability.canOpenShelfarr {
                        Button {
                            openBrowse(.shelfarr)
                        } label: {
                            Label("Open in Shelfarr", systemImage: "safari")
                        }
                        .disabled(isBusy)
                    }

                    if availability.canOpenAlternateSearch {
                        Button {
                            Task {
                                openingAlternate = true
                                defer { openingAlternate = false }
                                if let url = await model.prepareAlternateSearchOpen() {
                                    openURL(url)
                                }
                            }
                        } label: {
                            if openingAlternate {
                                Label("Checking…", systemImage: "network")
                            } else {
                                Label("Search Alternate Sources", systemImage: "network")
                            }
                        }
                        .disabled(isBusy)
                    }
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
    }

    private var actionErrorBinding: Binding<Bool> {
        Binding(
            get: { model.actionError != nil },
            set: { if !$0 { model.actionError = nil } },
        )
    }

    private var actionInfoBinding: Binding<Bool> {
        Binding(
            get: { model.actionInfo != nil },
            set: { if !$0 { model.actionInfo = nil } },
        )
    }

    private func openBrowse(_ target: RequestActivityBrowseTarget) {
        model.actionError = nil
        model.actionInfo = nil
        guard let url = model.browseURL(for: target) else {
            model.actionError = "Could not open that link."
            return
        }
        openURL(url)
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
