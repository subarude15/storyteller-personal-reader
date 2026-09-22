#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI

struct BookRequestSheet: View {
    let work: CanonicalBookWork
    let owned: Set<BookRequestFormat>

    @Environment(\.dismiss) private var dismiss
    @State private var sending = false
    @State private var submission: BookRequestSubmission?
    @State private var providerName: String?
    @State private var tracked: RequestActivityItem?
    @State private var showingManualSearch = false
    @State private var showingMatches = false
    @State private var resolving = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(work.title)
                        .font(.headline)
                    if let author = work.authors.first, !author.isEmpty {
                        Text(author)
                            .foregroundStyle(.secondary)
                    }
                    if let providerName {
                        Text("Using \(providerName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let tracked, !tracked.formatStatuses.isEmpty {
                    Section("Current request") {
                        ForEach(tracked.formatStatuses, id: \.format) { format in
                            HStack {
                                Text(format.format.label)
                                Spacer()
                                Text(format.status.label)
                                    .foregroundStyle(.secondary)
                            }
                            if let detail = format.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let reason = tracked.matchReason, tracked.matchAttention == nil {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        LazyLibrarianMatchActionButtons(
                            item: tracked,
                            isBusy: sending || resolving,
                            resolving: resolving,
                            onReview: { showingMatches = true },
                            onUseBest: { useBest(tracked) },
                        )
                    }
                }

                Section {
                    formatRow(.ebook)
                    formatRow(.audiobook)
                    Button("Both") { send(missing(from: [.ebook, .audiobook])) }
                        .disabled(sending || missing(from: [.ebook, .audiobook]).isEmpty)
                } header: {
                    Text("Request")
                } footer: {
                    Text(
                        "Request accepted means the server will search. It does not mean the book is downloaded."
                    )
                }

                Section {
                    Button {
                        showingManualSearch = true
                    } label: {
                        Label("Search manually", systemImage: "globe")
                    }
                    .accessibilityIdentifier("search-manually")
                } footer: {
                    Text("Look on a website yourself if LazyLibrarian or Shelfarr cannot find it.")
                }
                if sending {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Sending request")
                        }
                    }
                }
                if let submission {
                    Section {
                        if let message = submission.message {
                            Text(message)
                        }
                        ForEach(submission.outcomes, id: \.format) { outcome in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(outcome.format.label)
                                    .font(.subheadline.weight(.semibold))
                                Text(label(outcome.phase))
                                    .font(.subheadline)
                                Text(outcome.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let reason = outcome.matchReason {
                                    Text(reason)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Request")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showingManualSearch) {
            ManualSearchView(book: ManualSearchBookContext.from(work))
            #if os(iOS)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            #endif
        }
        .sheet(isPresented: $showingMatches) {
            if let tracked {
                LazyLibrarianMatchReviewSheet(candidates: tracked.matchCandidates ?? []) { candidate in
                    resolve(tracked, candidate: candidate)
                }
                #if os(iOS)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                #endif
            }
        }
        .task {
            await loadProvider()
            tracked = RequestActivityStore.shared.item(
                forWorkID: work.openLibraryWorkID ?? work.workID
            )
        }
    }

    private func formatRow(_ format: BookRequestFormat) -> some View {
        HStack {
            Text(format.label)
            Spacer()
            if owned.contains(format) {
                Text("Already in library")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if let status = tracked?.status(for: format) {
                switch status.status {
                    case .availableInLibrary, .available, .alreadyAvailable, .downloaded:
                        Text(status.status.label)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    case .wanted, .searching, .snatched, .requested, .alreadyRequested:
                        Text(status.status.label)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    case .failed, .needsAttention, .unknown:
                        Button("Request") { send([format]) }
                            .disabled(sending)
                }
            } else {
                Button("Request") { send([format]) }
                    .disabled(sending)
            }
        }
    }

    private func missing(from formats: [BookRequestFormat]) -> [BookRequestFormat] {
        formats.filter { format in
            if owned.contains(format) { return false }
            guard let status = tracked?.status(for: format) else { return true }
            switch status.status {
                case .availableInLibrary, .available, .alreadyAvailable, .downloaded,
                    .wanted, .searching, .snatched, .requested, .alreadyRequested:
                    return false
                case .failed, .needsAttention, .unknown:
                    return true
            }
        }
    }

    private func send(_ formats: [BookRequestFormat]) {
        guard !formats.isEmpty else { return }
        sending = true
        submission = nil
        Task {
            let result = await BookRequests.submit(work: work, formats: formats)
            submission = result
            providerName = result.provider?.shortName ?? providerName
            tracked = RequestActivityStore.shared.item(
                forWorkID: work.openLibraryWorkID ?? work.workID
            )
            sending = false
        }
    }

    private func useBest(_ item: RequestActivityItem) {
        guard let candidate = LazyLibrarianMatcher.bestResolvable(
            work: item.canonicalWorkForRetry(),
            candidates: item.matchCandidates ?? [],
        ) else { return }
        resolve(item, candidate: candidate)
    }

    private func resolve(_ item: RequestActivityItem, candidate: LazyLibrarianCandidate) {
        guard !resolving else { return }
        resolving = true
        Task {
            let result = await BookRequests.resolveLazyLibrarianMatch(item: item, candidate: candidate)
            submission = result
            tracked = RequestActivityStore.shared.item(id: item.id)
                ?? RequestActivityStore.shared.item(forWorkID: work.openLibraryWorkID ?? work.workID)
            resolving = false
        }
    }

    private func loadProvider() async {
        let settings = await SettingsActor.shared.config
        let keySaved = await AuthenticationActor.shared.hasLazyLibrarianAPIKey()
        let lazyReady =
            settings.lazyLibrarianEnabled
            && !settings.lazyLibrarianBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && keySaved
        let shelfReady =
            !settings.shelfarrBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.shelfarrAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let chosen = BookRequestRouting.choose(
            preference: .preference(from: settings.bookRequestProvider),
            lazyLibrarianReady: lazyReady,
            shelfarrReady: shelfReady,
        )
        providerName = chosen?.shortName
    }

    private func label(_ phase: BookRequestPhase) -> String {
        switch phase {
            case .requested: "Requested"
            case .searching: "Searching"
            case .alreadyRequested: "Already requested"
            case .alreadyAvailable: "Already available"
            case .failed: "Failed"
            case .needsAttention: "Needs attention"
        }
    }
}
#endif
