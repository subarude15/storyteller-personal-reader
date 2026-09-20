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
    @Published private(set) var fallbackItemID: String?
    @Published var fallbackNotice: RequestFallbackNotice?

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

    var chainIndex: RequestActivityChainIndex {
        RequestActivityChains.build(from: items)
    }

    var chainGroups: [(RequestActivitySection, [RequestActivityChain])] {
        RequestActivityChains.groups(chainIndex.chains)
    }

    func item(id: String) -> RequestActivityItem? {
        items.first { $0.id == id } ?? history.item(id: id)
    }

    func chain(id: String) -> RequestActivityChain? {
        chainIndex.chain(id: id) ?? chainIndex.chain(containingRequestID: id)
    }

    func availability(for item: RequestActivityItem) -> RequestActivityActionAvailability {
        RequestActivityActions.availability(for: item, context: actionContext)
    }

    func availability(for chain: RequestActivityChain) -> RequestActivityActionAvailability {
        RequestActivityActions.availability(for: chain, context: actionContext)
    }

    func onAppear(libraryBooks: [BookMetadata] = []) {
        self.libraryBooks = libraryBooks
        history.prune()
        _ = refreshService.applyLibraryPresence(libraryBooks: libraryBooks)
        items = history.allItems()
        Task { await self.reloadActionContext() }
        // Refresh first; evaluateAutomaticFallback runs after refreshAll so we
        // never race a stale Needs Attention row against a recovering provider.
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
            await self.evaluateAutomaticFallback()
        }
    }

    func remove(_ item: RequestActivityItem) {
        history.remove(id: item.id)
        items.removeAll { $0.id == item.id }
    }

    /// Local tracking only — removes every provider attempt in the logical chain.
    func removeChain(_ chain: RequestActivityChain) {
        let ids = Set(chain.items.map(\.id))
        for id in ids {
            history.remove(id: id)
        }
        items.removeAll { ids.contains($0.id) }
    }

    /// Per-request status check — reuses RequestActivityRefreshService.
    func checkStatus(itemID: String) {
        guard checkingItemID == nil, retryingItemID == nil, fallbackItemID == nil else { return }
        actionError = nil
        actionInfo = nil
        fallbackNotice = nil
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
            let delugeIndex = await self.refreshService.loadDelugeIndex()

            let updated = await self.refreshService.refreshOne(
                current,
                force: true,
                lazyReady: lazyReady,
                baseURL: settings.lazyLibrarianBaseURL,
                apiKey: key,
                matcher: matcher,
                delugeIndex: delugeIndex,
            )
            await MainActor.run {
                self.upsert(updated)
                self.items = self.history.allItems()
                if let error = updated.lastError, !error.isEmpty {
                    self.actionError = error
                }
            }
            await self.evaluateAutomaticFallback()
        }
    }

    /// Retry only formats RequestActivityRetryPolicy marks retryable.
    func retryRequest(itemID: String) {
        guard checkingItemID == nil, retryingItemID == nil, fallbackItemID == nil else { return }
        actionError = nil
        actionInfo = nil
        fallbackNotice = nil
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

    /// User-confirmed fallback. Re-checks the library, then submits only missing formats
    /// to the chosen provider. Does not cancel or rewrite the original row.
    func submitAlternateProvider(
        itemID: String,
        provider: BookRequestProviderKind,
        formats: [BookRequestFormat],
    ) {
        guard checkingItemID == nil, retryingItemID == nil, fallbackItemID == nil else { return }
        actionError = nil
        actionInfo = nil
        fallbackNotice = nil
        _ = refreshService.applyLibraryPresence(libraryBooks: libraryBooks)
        items = history.allItems()
        guard let current = history.item(id: itemID) else {
            actionError = "Request not found."
            return
        }
        let decision = RequestActivityFallbackPolicy.decision(
            item: current,
            provider: provider,
            formats: formats,
            history: items,
        )
        guard !decision.formats.isEmpty else {
            fallbackNotice = RequestFallbackNotice(
                sourceID: itemID,
                text: decision.message ?? RequestActivityFallbackPolicy.alreadyInLibraryMessage,
            )
            return
        }
        fallbackItemID = itemID
        let work = current.canonicalWorkForRetry()
        let fromID = current.id
        let formatsToSend = decision.formats
        let override = decision.providerOverride
        Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.fallbackItemID = nil
                }
            }
            let submission = await BookRequests.submit(
                work: work,
                formats: formatsToSend,
                history: self.history,
                providerOverride: override,
                fallbackFromRequestID: fromID,
                fallbackKind: .manual,
            )
            let created = self.history.item(
                forWorkID: current.canonicalWorkID,
                provider: override,
            )
            await MainActor.run {
                self.items = self.history.allItems()
                if let message = submission.message, !message.isEmpty {
                    self.actionError = message
                    return
                }
                if let failed = submission.outcomes.first(where: { $0.phase == .failed }) {
                    self.actionError = failed.detail
                    return
                }
                let queued = submission.outcomes.contains {
                    $0.phase == .requested || $0.phase == .searching
                }
                if queued {
                    self.fallbackNotice = RequestFallbackNotice(
                        sourceID: itemID,
                        text: RequestActivityFallbackPolicy.requestedMessage(provider: override),
                        createdID: created?.id,
                        providerName: override.shortName,
                    )
                    return
                }
                if submission.outcomes.contains(where: { $0.phase == .alreadyRequested }) {
                    self.fallbackNotice = RequestFallbackNotice(
                        sourceID: itemID,
                        text: RequestActivityFallbackPolicy.alreadyRequestedMessage(
                            provider: override
                        ),
                    )
                    return
                }
                if submission.outcomes.contains(where: { $0.phase == .alreadyAvailable }) {
                    self.fallbackNotice = RequestFallbackNotice(
                        sourceID: itemID,
                        text: RequestActivityFallbackPolicy.alreadyInLibraryMessage,
                    )
                }
            }
        }
    }

    func unavailableFallbackProviders() -> (lazyLibrarian: Bool, shelfarr: Bool) {
        (
            lazyLibrarian: ServiceHealthCache.shared.result(for: .lazyLibrarian)?.status == .unavailable,
            shelfarr: ServiceHealthCache.shared.result(for: .shelfarr)?.status == .unavailable,
        )
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
        let key = (try? await AuthenticationActor.shared.loadLazyLibrarianAPIKey()) ?? ""
        let hasKey = !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        await MainActor.run {
            self.actionContext = RequestActivityActionContext(
                config: config,
                lazyLibrarianHasAPIKey: hasKey,
            )
        }
    }

    /// Opt-in automatic one-hop fallback. Never holds the store lock across network work.
    func evaluateAutomaticFallback() async {
        await reloadActionContext()
        let context = await MainActor.run { self.actionContext }
        let books = await MainActor.run { self.libraryBooks }
        let submitted = await RequestAutomaticFallbackCoordinator.shared.evaluate(
            libraryBooks: books,
            actionContext: context,
        )
        if submitted > 0 {
            await MainActor.run {
                self.items = self.history.allItems()
            }
        }
    }
}

enum RequestActivityBrowseTarget {
    case lazyLibrarian
    case shelfarr
    case bookSearchLAN
}

struct RequestFallbackNotice: Equatable {
    var sourceID: String
    var text: String
    var createdID: String?
    var providerName: String?
}

public struct RequestActivityView: View {
    var initialRequestID: String?
    @StateObject private var model = RequestActivityViewModel()
    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel
    @State private var deepLinkChainID: String?
    @State private var deepLinkAttemptID: String?
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

            if model.chainGroups.isEmpty {
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
                ForEach(model.chainGroups, id: \.0) { group in
                    Section(group.0.title) {
                        ForEach(group.1) { chain in
                            NavigationLink {
                                RequestActivityChainDetailView(chainID: chain.id, model: model)
                            } label: {
                                RequestActivityChainRow(chain: chain)
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                model.removeChain(group.1[index])
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
                    get: { deepLinkChainID != nil },
                    set: { isActive in
                        if !isActive {
                            deepLinkChainID = nil
                            deepLinkAttemptID = nil
                        }
                    },
                )
            ) {
                if let deepLinkChainID {
                    RequestActivityChainDetailView(
                        chainID: deepLinkChainID,
                        highlightAttemptID: deepLinkAttemptID,
                        model: model,
                    )
                } else {
                    EmptyView()
                }
            } label: {
                EmptyView()
            }
            .hidden()
        }
    }

    /// Push the logical chain when the provider-row id is still in history.
    private func applyInitialDestination() {
        guard let initialRequestID else { return }
        let resolved = RequestActivityNavigation.resolvedChainDetail(
            requestID: initialRequestID,
            chainIDForRequest: { model.chainIndex.requestIDToChainID[$0] },
            itemExists: { model.item(id: $0) != nil },
        )
        switch resolved {
            case .list:
                deepLinkChainID = nil
                deepLinkAttemptID = nil
                missingRequestMessage = RequestActivityNavigation.missingHistoryMessage
            case .detail(let chainID):
                missingRequestMessage = nil
                deepLinkChainID = chainID
                deepLinkAttemptID =
                    initialRequestID == chainID ? nil : initialRequestID
        }
    }
}

private struct RequestActivityChainRow: View {
    let chain: RequestActivityChain

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(chain.title)
                .font(.headline)
            if !chain.author.isEmpty {
                Text(chain.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(chain.listFormatProviderLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(chain.currentStatusLabel)
                .font(.subheadline.weight(.semibold))
            if chain.attemptCount > 1 {
                Text("\(chain.attemptCount) attempts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let checked = chain.lastCheckedAt {
                Text("Last checked \(ServiceHealthURLSanitizer.relativeAge(from: checked))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Updated \(ServiceHealthURLSanitizer.relativeAge(from: chain.updatedAt))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

struct RequestActivityChainDetailView: View {
    let chainID: String
    var highlightAttemptID: String? = nil
    @ObservedObject var model: RequestActivityViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var confirmRemove = false
    @State private var openingAlternate = false
    @State private var showingFallback = false

    private var chain: RequestActivityChain? {
        model.chain(id: chainID)
    }

    private var actionItem: RequestActivityItem? {
        guard let chain else { return nil }
        return RequestActivityChains.actionItem(for: chain)
    }

    private var actionItemID: String? {
        actionItem?.id
    }

    private var availability: RequestActivityActionAvailability {
        guard let chain else { return RequestActivityActionAvailability() }
        return model.availability(for: chain)
    }

    private var isBusy: Bool {
        guard let actionItemID else { return openingAlternate }
        return model.checkingItemID == actionItemID || model.retryingItemID == actionItemID
            || model.fallbackItemID == actionItemID || openingAlternate
    }

    var body: some View {
        Group {
            if let chain {
                detailList(chain)
            } else {
                ContentUnavailableView(
                    "Request removed",
                    systemImage: "trash",
                    description: Text("This tracking record is no longer in history."),
                )
            }
        }
        .navigationTitle(chain?.title ?? "Request")
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
                if let chain {
                    model.removeChain(chain)
                }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Removes all local provider attempts for this request. Your LazyLibrarian / Shelfarr queue is unchanged."
            )
        }
        .sheet(isPresented: $showingFallback) {
            if let item = actionItem {
                RequestFallbackSheet(
                    item: item,
                    offer: RequestActivityFallbackPolicy.offer(
                        for: item,
                        context: model.actionContext,
                    ),
                    unavailableLazyLibrarian: model.unavailableFallbackProviders().lazyLibrarian,
                    unavailableShelfarr: model.unavailableFallbackProviders().shelfarr,
                    onSubmit: { provider, formats in
                        showingFallback = false
                        model.submitAlternateProvider(
                            itemID: item.id,
                            provider: provider,
                            formats: formats,
                        )
                    },
                    onSearch: {
                        showingFallback = false
                        Task {
                            openingAlternate = true
                            defer { openingAlternate = false }
                            if let url = await model.prepareAlternateSearchOpen() {
                                openURL(url)
                            }
                        }
                    },
                )
            }
        }
    }

    @ViewBuilder
    private func detailList(_ chain: RequestActivityChain) -> some View {
        List {
            Section("Book") {
                LabeledContent("Title", value: chain.title)
                if !chain.author.isEmpty {
                    LabeledContent("Author", value: chain.author)
                }
                LabeledContent("Requested", value: dateLabel(chain.createdAt))
                LabeledContent("Formats", value: chain.formatsLabel)
                LabeledContent("Status", value: chain.currentStatusLabel)
            }

            Section("Current Status") {
                ForEach(chain.formatStates, id: \.format) { state in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.format.label)
                            .font(.subheadline.weight(.semibold))
                        Text(state.displayStatusLabel)
                        Text(state.displayProviderLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let detail = state.detail, !detail.isEmpty,
                            detail != state.displayStatusLabel
                        {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            let downloads = chain.formatStates.compactMap { state -> (BookRequestFormat, RequestFormatDownloadState)? in
                guard let download = state.download,
                    download.status != .notFound,
                    download.status != .unknown
                else { return nil }
                return (state.format, download)
            }
            if !downloads.isEmpty {
                Section("Download") {
                    ForEach(downloads, id: \.0) { format, download in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(format.label)
                                .font(.subheadline.weight(.semibold))
                            Text("Deluge")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(download.status.label)
                            if let progress = download.progress, download.status.showsProgress {
                                ProgressView(value: min(max(progress, 0), 1))
                                if let percent = download.percentLabel {
                                    Text(percent)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let eta = download.etaLabel {
                                Text(eta)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let detail = download.detail, !detail.isEmpty,
                                detail != download.status.label
                            {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if download.delugeUnavailable {
                                Text("Deluge unavailable — showing last known state")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section("Attempts") {
                ForEach(chain.items) { item in
                    NavigationLink {
                        RequestActivityDetailView(itemID: item.id, model: model)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.provider.shortName)
                                .font(.subheadline.weight(.semibold))
                            Text(item.overallStatus.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(attemptRoleLabel(for: item, chain: chain))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowBackground(
                        highlightAttemptID == item.id
                            ? Color.accentColor.opacity(0.08)
                            : Color.clear
                    )
                }
            }

            let timeline = RequestActivityChains.combinedTimeline(for: chain)
            if !timeline.isEmpty {
                Section("History") {
                    ForEach(Array(timeline.enumerated()), id: \.element.id) { index, wrap in
                        RequestActivityChainTimelineRow(
                            wrap: wrap,
                            isLast: index == timeline.count - 1,
                            model: model,
                        )
                    }
                }
            }

            if availability.hasAnyAction, let actionItemID {
                Section("Actions") {
                    if availability.canCheckStatus {
                        Button {
                            model.checkStatus(itemID: actionItemID)
                        } label: {
                            if model.checkingItemID == actionItemID {
                                Label("Checking…", systemImage: "arrow.clockwise")
                            } else {
                                Label("Check Status", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(isBusy)
                    }

                    if availability.canRetry {
                        Button {
                            model.retryRequest(itemID: actionItemID)
                        } label: {
                            if model.retryingItemID == actionItemID {
                                Label("Retrying…", systemImage: "arrow.triangle.2.circlepath")
                            } else {
                                Label("Retry Request", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .disabled(isBusy)
                    }

                    if availability.canTryAnotherSource {
                        Button {
                            showingFallback = true
                        } label: {
                            if model.fallbackItemID == actionItemID {
                                Label("Requesting…", systemImage: "arrow.left.arrow.right")
                            } else {
                                Label("Try Another Source", systemImage: "arrow.left.arrow.right")
                            }
                        }
                        .disabled(isBusy)
                        if let notice = model.fallbackNotice, notice.sourceID == actionItemID {
                            Text(notice.text)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
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

            Section {
                Button("Remove from history", role: .destructive) {
                    confirmRemove = true
                }
            } footer: {
                Text(
                    "Removes this app’s tracking for every provider attempt in this request. It does not cancel LazyLibrarian or Shelfarr."
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

    private func attemptRoleLabel(for item: RequestActivityItem, chain: RequestActivityChain) -> String {
        if item.id == chain.rootRequestID {
            return "Original request"
        }
        switch item.fallbackKind {
            case .automatic:
                return "Automatic fallback"
            case .manual:
                return "Manual fallback"
            case nil:
                return "Provider attempt"
        }
    }

    private func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct RequestActivityChainTimelineRow: View {
    let wrap: RequestActivityChainEvent
    let isLast: Bool
    @ObservedObject var model: RequestActivityViewModel

    private var event: RequestActivityEvent { wrap.event }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: RequestActivityTimeline.systemImage(for: event.kind))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                if !isLast {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 2, height: 14)
                }
            }
            .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title ?? RequestActivityTimeline.title(for: event.kind))
                    .font(.subheadline.weight(.semibold))
                if let subtitle = RequestActivityTimeline.subtitle(for: event) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(dateLabel(event.date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if model.item(id: wrap.sourceRequestID) != nil {
                    NavigationLink {
                        RequestActivityDetailView(itemID: wrap.sourceRequestID, model: model)
                    } label: {
                        Text("View attempt")
                            .font(.caption)
                    }
                }
            }
            .padding(.bottom, isLast ? 0 : 10)
        }
        .accessibilityElement(children: .combine)
    }

    private func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// Provider-specific attempt detail. Reachable from a chain’s Attempts / History.
struct RequestActivityDetailView: View {
    let itemID: String
    @ObservedObject var model: RequestActivityViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var confirmRemove = false
    @State private var openingAlternate = false
    @State private var showingFallback = false

    private var item: RequestActivityItem? {
        model.item(id: itemID)
    }

    private var availability: RequestActivityActionAvailability {
        guard let item else { return RequestActivityActionAvailability() }
        return model.availability(for: item)
    }

    private var isBusy: Bool {
        model.checkingItemID == itemID || model.retryingItemID == itemID
            || model.fallbackItemID == itemID || openingAlternate
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
        .sheet(isPresented: $showingFallback) {
            if let item {
                RequestFallbackSheet(
                    item: item,
                    offer: RequestActivityFallbackPolicy.offer(
                        for: item,
                        context: model.actionContext,
                    ),
                    unavailableLazyLibrarian: model.unavailableFallbackProviders().lazyLibrarian,
                    unavailableShelfarr: model.unavailableFallbackProviders().shelfarr,
                    onSubmit: { provider, formats in
                        showingFallback = false
                        model.submitAlternateProvider(
                            itemID: itemID,
                            provider: provider,
                            formats: formats,
                        )
                    },
                    onSearch: {
                        showingFallback = false
                        Task {
                            openingAlternate = true
                            defer { openingAlternate = false }
                            if let url = await model.prepareAlternateSearchOpen() {
                                openURL(url)
                            }
                        }
                    },
                )
            }
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
                if item.fallbackKind == .automatic {
                    Text(fallbackOriginLabel(for: item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let pending = AutomaticFallbackPolicy.pendingMessage(
                item: item,
                settings: RequestAutomaticFallbackSettings.current,
                context: model.actionContext,
            ) {
                Section {
                    Text(pending)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let attempt = item.automaticFallbackAttempts?.last(where: {
                $0.resultingRequestID != nil
            }), let createdID = attempt.resultingRequestID {
                Section {
                    Text("Automatically tried \(attempt.targetProvider.shortName)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    NavigationLink {
                        RequestActivityDetailView(itemID: createdID, model: model)
                    } label: {
                        Label(
                            "View \(attempt.targetProvider.shortName) request",
                            systemImage: "arrow.right",
                        )
                    }
                }
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

            let timeline = RequestActivityTimeline.displayEvents(for: item)
            if !timeline.isEmpty {
                Section("History") {
                    ForEach(Array(timeline.enumerated()), id: \.element.id) { index, event in
                        RequestActivityTimelineRow(
                            event: event,
                            isLast: index == timeline.count - 1,
                            model: model,
                        )
                    }
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

                    if availability.canTryAnotherSource {
                        Button {
                            showingFallback = true
                        } label: {
                            if model.fallbackItemID == itemID {
                                Label("Requesting…", systemImage: "arrow.left.arrow.right")
                            } else {
                                Label("Try Another Source", systemImage: "arrow.left.arrow.right")
                            }
                        }
                        .disabled(isBusy)
                        if let notice = model.fallbackNotice, notice.sourceID == itemID {
                            Text(notice.text)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            if let createdID = notice.createdID, let name = notice.providerName {
                                NavigationLink {
                                    RequestActivityDetailView(itemID: createdID, model: model)
                                } label: {
                                    Label("View \(name) request", systemImage: "arrow.right")
                                }
                            }
                        }
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

            let extras = RequestActivityTimeline.extraDiagnostics(for: item)
            if let error = extras.lastError {
                Section("Last error") {
                    Text(error)
                }
            }

            if let reason = extras.attentionReason {
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

    private func fallbackOriginLabel(for item: RequestActivityItem) -> String {
        guard let parentID = item.fallbackFromRequestID,
            let parent = model.item(id: parentID)
        else {
            return "Automatic fallback"
        }
        return "Fallback from \(parent.provider.shortName)"
    }

    private func dateLabel(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct RequestActivityTimelineRow: View {
    let event: RequestActivityEvent
    let isLast: Bool
    @ObservedObject var model: RequestActivityViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: RequestActivityTimeline.systemImage(for: event.kind))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                if !isLast {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 2, height: 14)
                }
            }
            .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title ?? RequestActivityTimeline.title(for: event.kind))
                    .font(.subheadline.weight(.semibold))
                if let subtitle = RequestActivityTimeline.subtitle(for: event) {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(dateLabel(event.date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let relatedID = event.relatedRequestID,
                    model.item(id: relatedID) != nil
                {
                    NavigationLink {
                        RequestActivityDetailView(itemID: relatedID, model: model)
                    } label: {
                        Text("View request")
                            .font(.caption)
                    }
                }
            }
            .padding(.bottom, isLast ? 0 : 10)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [event.title ?? RequestActivityTimeline.title(for: event.kind)]
        if let subtitle = RequestActivityTimeline.subtitle(for: event) {
            parts.append(subtitle)
        }
        if let detail = event.detail, !detail.isEmpty {
            parts.append(detail)
        }
        parts.append(dateLabel(event.date))
        return parts.joined(separator: ", ")
    }

    private func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct RequestFallbackSheet: View {
    let item: RequestActivityItem
    let offer: RequestFallbackOffer
    let unavailableLazyLibrarian: Bool
    let unavailableShelfarr: Bool
    let onSubmit: (BookRequestProviderKind, [BookRequestFormat]) -> Void
    let onSearch: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var formats: [BookRequestFormat]
    @State private var pendingProvider: BookRequestProviderKind?

    init(
        item: RequestActivityItem,
        offer: RequestFallbackOffer,
        unavailableLazyLibrarian: Bool,
        unavailableShelfarr: Bool,
        onSubmit: @escaping (BookRequestProviderKind, [BookRequestFormat]) -> Void,
        onSearch: @escaping () -> Void,
    ) {
        self.item = item
        self.offer = offer
        self.unavailableLazyLibrarian = unavailableLazyLibrarian
        self.unavailableShelfarr = unavailableShelfarr
        self.onSubmit = onSubmit
        self.onSearch = onSearch
        let start = offer.eligibleFormats.count == 1 ? offer.eligibleFormats : []
        _formats = State(initialValue: start)
    }

    var body: some View {
        NavigationStack {
            List {
                if formats.isEmpty {
                    formatPicker
                } else if let pendingProvider {
                    confirm(pendingProvider)
                } else {
                    options
                }
            }
            .navigationTitle("Try another source")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    @ViewBuilder
    private var formatPicker: some View {
        Section {
            if Set(offer.eligibleFormats) == Set(BookRequestFormat.allCases) {
                Button("Both") {
                    formats = BookRequestFormat.allCases
                }
            }
            ForEach(offer.eligibleFormats, id: \.self) { format in
                Button(format.label) {
                    formats = [format]
                }
            }
        } header: {
            Text("Choose a format")
        } footer: {
            Text(RequestActivityFallbackPolicy.optionsHeading(item: item, formats: offer.eligibleFormats))
        }
    }

    @ViewBuilder
    private var options: some View {
        Section {
            if offer.options.isEmpty {
                Text("No alternate sources are configured.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(offer.options.enumerated()), id: \.offset) { _, option in
                optionButton(option)
            }
        } header: {
            Text("Available alternatives")
        } footer: {
            Text(RequestActivityFallbackPolicy.optionsHeading(item: item, formats: formats))
        }
    }

    @ViewBuilder
    private func optionButton(_ option: RequestFallbackOption) -> some View {
        switch option {
            case .provider(let provider):
                Button {
                    pendingProvider = provider
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Try \(provider.shortName)")
                        if isUnavailable(provider) {
                            Text("Currently unavailable")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            case .alternateSearch:
                Button("Search Alternate Sources") {
                    onSearch()
                }
        }
    }

    @ViewBuilder
    private func confirm(_ provider: BookRequestProviderKind) -> some View {
        let copy = RequestActivityFallbackPolicy.confirmation(
            bookTitle: item.title,
            formats: formats,
            alternate: provider,
            currentProviderName: RequestActivityFallbackPolicy.resolvedProvider(item)?.shortName
                ?? item.provider.shortName,
        )
        Section {
            Text(copy.prompt)
                .font(.headline)
            Text(copy.footer)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(copy.confirmTitle) {
                onSubmit(provider, formats)
            }
            Button("Back") {
                pendingProvider = nil
            }
        }
    }

    private func isUnavailable(_ provider: BookRequestProviderKind) -> Bool {
        switch provider {
            case .lazyLibrarian:
                unavailableLazyLibrarian
            case .shelfarr:
                unavailableShelfarr
            case .automatic:
                false
        }
    }
}
#endif
