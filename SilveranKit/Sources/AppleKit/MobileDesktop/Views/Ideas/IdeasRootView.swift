#if os(iOS)
import SilveranKit
import SwiftUI

/// Habit-based ideas. Metadata and a local save list only — no download or import.
struct IdeasRootView: View {
    let searchText: String

    private enum IdeasMode: String, CaseIterable, Identifiable {
        case ideas = "Ideas"
        case saved = "Saved"
        case browse = "Browse"
        var id: String { rawValue }
    }

    @Environment(MediaViewModel.self) private var mediaViewModel
    @State private var suggestions: [ReadingIdea] = []
    @State private var saved: [ReadingIdea] = []
    @State private var dismissed: Set<String> = []
    @State private var loaded = false
    @State private var mode: IdeasMode = .ideas
    @State private var rails: [BrowseRail] = []
    @State private var browseLoaded = false
    @State private var searchResults: [ReadingIdea] = []
    @State private var searchLoading = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Ideas section", selection: $mode) {
                ForEach(IdeasMode.allCases) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            switch mode {
            case .saved:
                savedContent
            case .browse:
                if isSearching {
                    searchContent
                } else {
                    browseContent
                }
            case .ideas:
                if isSearching {
                    searchContent
                } else {
                    suggestionsContent
                }
            }
        }
        .task(id: mediaViewModel.libraryVersion) {
            await reload()
        }
        .onChange(of: mode) { _, newMode in
            if newMode == .browse {
                Task { await reloadBrowse() }
            }
            runSearch(searchText)
        }
        .onChange(of: searchText) { _, newValue in
            runSearch(newValue)
        }
        .onDisappear {
            searchTask?.cancel()
        }
        .navigationDestination(for: ReadingIdea.self) { idea in
            IdeaDetailView(idea: idea) {
                saved = loadSaved()
            } onNotInterested: {
                dismissIdea(idea)
            }
        }
    }

    // MARK: Suggestions

    @ViewBuilder
    private var suggestionsContent: some View {
        if visibleSuggestions.isEmpty {
            Group {
                if loaded {
                    Text("No ideas yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("ideas-empty")
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            List {
                Section("Ideas for later") {
                    ForEach(visibleSuggestions) { idea in
                        NavigationLink(value: idea) {
                            IdeaRow(idea: idea, isSaved: false)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                saveIdea(idea)
                            } label: {
                                Label("Save", systemImage: "bookmark")
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                dismissIdea(idea)
                            } label: {
                                Label("Not interested", systemImage: "hand.thumbsdown")
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: Search

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var searchContent: some View {
        if searchLoading && searchResults.isEmpty {
            ProgressView("Searching Open Library…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if searchResults.isEmpty {
            Text("No Open Library matches.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("search-empty")
        } else {
            List {
                Section("Open Library") {
                    ForEach(searchResults) { idea in
                        NavigationLink(value: idea) {
                            IdeaRow(idea: idea, isSaved: savedIDs.contains(idea.id))
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                saveIdea(idea)
                            } label: {
                                Label("Save", systemImage: "bookmark")
                            }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                dismissIdea(idea)
                            } label: {
                                Label("Not interested", systemImage: "hand.thumbsdown")
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    /// Debounce ~300ms, then run an Open Library title+author search. Owned /
    /// finished / Not-interested results are filtered out; Saved keeps its local
    /// filter (no OL search).
    private func runSearch(_ raw: String) {
        searchTask?.cancel()
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, mode != .saved else {
            searchResults = []
            searchLoading = false
            return
        }
        searchLoading = true
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let library = mediaViewModel.library.bookMetaData
            let works = await OpenLibraryIdeaLookup.searchTitles(query)
            guard !Task.isCancelled else { return }
            let ideas = works.compactMap { work -> ReadingIdea? in
                guard !work.key.isEmpty else { return nil }
                return ReadingIdea(
                    id: "ol:\(work.key)",
                    title: work.title,
                    author: work.author,
                    coverURL: work.coverURL,
                    blurb: work.blurb,
                    reason: "Open Library search",
                    score: 1.0,
                    isbn: work.isbn,
                    subjects: work.subjects,
                    year: work.year,
                )
            }
            let ownedFiltered = ReadingHabitIdeas.excludingOwned(ideas, library: library)
            searchResults = ReadingHabitIdeas.excludingDismissed(
                ownedFiltered,
                dismissed: DismissedReadingIdeas.load(),
            )
            searchLoading = false
        }
    }

    // MARK: Browse

    @ViewBuilder
    private var browseContent: some View {
        if visibleRails.isEmpty {
            Group {
                if browseLoaded {
                    Text("No browse suggestions yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(visibleRails) { rail in
                        BrowseRailView(rail: rail)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    /// Rails with dismissed titles removed (and any rail that became empty dropped).
    private var visibleRails: [BrowseRail] {
        rails.compactMap { rail in
            let ideas = rail.ideas.filter {
                !dismissed.contains(ReadingHabitIdeas.dismissKey(for: $0))
                    && matches($0)
            }
            guard !ideas.isEmpty else { return nil }
            return BrowseRail(id: rail.id, title: rail.title, ideas: ideas)
        }
    }

    private func reloadBrowse() async {
        let library = mediaViewModel.library.bookMetaData
        let fresh = await OpenLibraryBrowseRails.fetch(library: library)
        let failed = fresh.isEmpty
        if failed {
            rails = CachedBrowseRails.load()
        } else {
            CachedBrowseRails.save(fresh)
            rails = fresh
        }
        dismissed = DismissedReadingIdeas.load()
        browseLoaded = true
    }

    // MARK: Saved

    @ViewBuilder
    private var savedContent: some View {
        if visibleSaved.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "bookmark")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Nothing saved yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Tap a book, then Save idea to keep it here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("saved-empty")
        } else {
            List {
                Section {
                    ForEach(visibleSaved) { idea in
                        NavigationLink(value: idea) {
                            IdeaRow(idea: idea, isSaved: true)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                unsaveIdea(idea)
                            } label: {
                                Label("Remove", systemImage: "bookmark.slash")
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                dismissIdea(idea)
                            } label: {
                                Label("Not interested", systemImage: "hand.thumbsdown")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Saved")
                        Spacer()
                        Button("Clear all") {
                            clearAllSaved()
                        }
                        .font(.caption)
                        .foregroundStyle(.tint)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: Derived state

    private var savedIDs: Set<String> { Set(saved.map(\.id)) }

    private var visibleSuggestions: [ReadingIdea] {
        suggestions.filter {
            !savedIDs.contains($0.id)
                && !dismissed.contains(ReadingHabitIdeas.dismissKey(for: $0))
                && matches($0)
        }
    }

    private var visibleSaved: [ReadingIdea] {
        saved.filter {
            !dismissed.contains(ReadingHabitIdeas.dismissKey(for: $0))
                && matches($0)
        }
    }

    private func matches(_ idea: ReadingIdea) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let haystack = "\(idea.title) \(idea.author) \(idea.reason)"
        return haystack.localizedCaseInsensitiveContains(query)
    }

    // MARK: Actions

    private func saveIdea(_ idea: ReadingIdea) {
        SavedReadingIdeas.save(idea)
        saved = loadSaved()
    }

    private func unsaveIdea(_ idea: ReadingIdea) {
        SavedReadingIdeas.remove(idea.id)
        saved = loadSaved()
    }

    private func clearAllSaved() {
        for idea in saved {
            SavedReadingIdeas.remove(idea.id)
        }
        saved = loadSaved()
    }

    private func dismissIdea(_ idea: ReadingIdea) {
        let key = ReadingHabitIdeas.dismissKey(for: idea)
        DismissedReadingIdeas.dismiss(key)
        dismissed = DismissedReadingIdeas.load()
        // Also drop it from the saved list (already read / don't want).
        SavedReadingIdeas.remove(idea.id)
        saved = loadSaved()
        // Remove from the in-memory pool immediately so the row leaves at once.
        suggestions.removeAll { ReadingHabitIdeas.dismissKey(for: $0) == key }
        searchResults.removeAll { ReadingHabitIdeas.dismissKey(for: $0) == key }
        // Refill: if the pool has thinned out, re-run the lookup so the list
        // doesn't shrink.
        if suggestions.count < 12, !loadedSearchFailed {
            Task { await reload() }
        }
    }

    private func loadSaved() -> [ReadingIdea] {
        let library = mediaViewModel.library.bookMetaData
        return ReadingHabitIdeas.excludingDismissed(
            ReadingHabitIdeas.excludingOwned(SavedReadingIdeas.load(), library: library),
            dismissed: dismissed,
        )
    }

    // MARK: Reload

    @State private var loadedSearchFailed = false

    private func reload() async {
        let library = mediaViewModel.library.bookMetaData
        let queries = ReadingHabitIdeas.queries(from: library)
        let works = await OpenLibraryIdeaLookup.works(for: queries)
        let fresh = ReadingHabitIdeas.ideas(
            queries: queries,
            worksByQuery: works,
            owned: library,
        )
        let lookupFailed = !queries.isEmpty && works.allSatisfy(\.isEmpty)
        loadedSearchFailed = lookupFailed
        if !lookupFailed {
            CachedReadingIdeas.save(fresh)
        }
        dismissed = DismissedReadingIdeas.load()
        let presented = ReadingHabitIdeas.present(
            fresh: fresh,
            lookupFailed: lookupFailed,
            cached: CachedReadingIdeas.load(),
            owned: library,
        )
        // Keep the full pool here; dismissal filtering happens at render time so
        // dismissing reveals the next pool item (refill) until we reload.
        suggestions = presented
        saved = loadSaved()
        loaded = true
    }
}

struct IdeaDetailView: View {
    let idea: ReadingIdea
    var onChange: () -> Void = {}
    var onNotInterested: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var isSaved = false
    @State private var fetched: OpenLibraryWorkDetail?
    @State private var loadingSummary = false
    @State private var showingAudiobookOptions = false
    @State private var showingBookRequest = false

    private var description: String? {
        if let fetched, let desc = fetched.description, !desc.isEmpty { return desc }
        return idea.blurb
    }

    private var subjects: [String] {
        if let fetched, !fetched.subjects.isEmpty { return fetched.subjects }
        return idea.subjects
    }

    private var year: Int? {
        fetched?.year ?? idea.year
    }

    private var workKey: String? {
        guard idea.id.hasPrefix("ol:") else { return nil }
        let key = String(idea.id.dropFirst(3))
        return key.isEmpty ? nil : key
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                IdeaCover(url: idea.coverURL)
                    .frame(width: 120, height: 180)
                Text(idea.title)
                    .font(.title2.weight(.semibold))
                if !idea.author.isEmpty {
                    Text(idea.author)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                if !idea.reason.isEmpty {
                    Text("Why: \(idea.reason)")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                if loadingSummary {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading summary…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else if let description, !description.isEmpty {
                    Text(description)
                        .font(.body)
                } else if !subjects.isEmpty {
                    Text(subjects.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No English description on Open Library")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !subjects.isEmpty || year != nil {
                    HStack(spacing: 8) {
                        if !subjects.isEmpty {
                            Text(subjects.prefix(3).joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let year {
                            Text(String(year))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button {
                    showingAudiobookOptions = true
                } label: {
                    Label("Find audiobook options", systemImage: "headphones")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("find-audiobook-options")
                .accessibilityHint("Searches audiobook providers for this book only after you tap.")
                Button {
                    showingBookRequest = true
                } label: {
                    Label("Request", systemImage: "paperplane")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Asks LazyLibrarian or Shelfarr to search for this book.")
                Button {
                    if isSaved {
                        SavedReadingIdeas.remove(idea.id)
                    } else {
                        SavedReadingIdeas.save(idea)
                    }
                    isSaved.toggle()
                    onChange()
                } label: {
                    Label(isSaved ? "Saved" : "Save idea", systemImage: isSaved ? "bookmark.fill" : "bookmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("save-idea")

                if let onNotInterested {
                    Button(role: .destructive) {
                        onNotInterested()
                        dismiss()
                    } label: {
                        Label("Not interested", systemImage: "hand.thumbsdown")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("not-interested")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle("Idea")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingAudiobookOptions) {
            AudiobookOptionsSheet(
                work: CanonicalBookWork.idea(idea),
                book: CanonicalBookWork.idea(idea).playbackBook(),
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingBookRequest) {
            BookRequestSheet(work: CanonicalBookWork.idea(idea), owned: [])
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task {
            isSaved = SavedReadingIdeas.contains(idea.id)
            // Backfill a real description when search.json gave no first_sentence.
            if (idea.blurb ?? "").isEmpty, let workKey {
                loadingSummary = true
                fetched = await OpenLibraryIdeaLookup.fetchDetail(forKey: workKey)
                loadingSummary = false
            }
        }
    }
}

private struct IdeaRow: View {
    let idea: ReadingIdea
    let isSaved: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IdeaCover(url: idea.coverURL)
                .frame(width: 44, height: 66)
            VStack(alignment: .leading, spacing: 2) {
                Text(idea.title)
                    .font(.body)
                if !idea.author.isEmpty {
                    Text(idea.author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !idea.reason.isEmpty {
                    Text(idea.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if isSaved {
                Image(systemName: "bookmark.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .accessibilityLabel("Saved")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct BrowseRailView: View {
    let rail: BrowseRail

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(rail.title)
                .font(.headline)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(rail.ideas) { idea in
                        NavigationLink(value: idea) {
                            BrowseCardView(idea: idea)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

private struct BrowseCardView: View {
    let idea: ReadingIdea

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            IdeaCover(url: idea.coverURL)
                .frame(width: 100, height: 150)
            Text(idea.title)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .frame(width: 100, alignment: .leading)
            if !idea.author.isEmpty {
                Text(idea.author)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 100, alignment: .leading)
            }
        }
    }
}

private struct IdeaCover: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .empty:
                Color.secondary.opacity(0.15)
            case .failure(_):
                Color.secondary.opacity(0.15)
            @unknown default:
                Color.secondary.opacity(0.15)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
#endif
