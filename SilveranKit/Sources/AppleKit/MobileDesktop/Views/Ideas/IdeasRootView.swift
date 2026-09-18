#if os(iOS)
import SwiftUI

/// Habit-based ideas. Metadata and a local save list only — no download or import.
struct IdeasRootView: View {
    let searchText: String

    @Environment(MediaViewModel.self) private var mediaViewModel
    @State private var suggestions: [ReadingIdea] = []
    @State private var saved: [ReadingIdea] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if visibleSuggestions.isEmpty && visibleSaved.isEmpty {
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
            } else {
                List {
                    if !visibleSuggestions.isEmpty {
                        Section("Ideas for later") {
                            ForEach(visibleSuggestions) { idea in
                                NavigationLink(value: idea) {
                                    IdeaRow(idea: idea)
                                }
                            }
                        }
                    }
                    if !visibleSaved.isEmpty {
                        Section("Saved") {
                            ForEach(visibleSaved) { idea in
                                NavigationLink(value: idea) {
                                    IdeaRow(idea: idea)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .task(id: mediaViewModel.libraryVersion) {
            await reload()
        }
        .navigationDestination(for: ReadingIdea.self) { idea in
            IdeaDetailView(idea: idea) {
                saved = ReadingHabitIdeas.excludingOwned(
                    SavedReadingIdeas.load(),
                    library: mediaViewModel.library.bookMetaData,
                )
            }
        }
    }

    private var savedIDs: Set<String> { Set(saved.map(\.id)) }

    private var visibleSuggestions: [ReadingIdea] {
        suggestions.filter { !savedIDs.contains($0.id) && matches($0) }
    }

    private var visibleSaved: [ReadingIdea] {
        saved.filter(matches)
    }

    private func matches(_ idea: ReadingIdea) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let haystack = "\(idea.title) \(idea.author) \(idea.reason)"
        return haystack.localizedCaseInsensitiveContains(query)
    }

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
        if !lookupFailed {
            CachedReadingIdeas.save(fresh)
        }
        suggestions = ReadingHabitIdeas.present(
            fresh: fresh,
            lookupFailed: lookupFailed,
            cached: CachedReadingIdeas.load(),
            owned: library,
        )
        saved = ReadingHabitIdeas.excludingOwned(SavedReadingIdeas.load(), library: library)
        loaded = true
    }
}

struct IdeaDetailView: View {
    let idea: ReadingIdea
    var onChange: () -> Void = {}

    @State private var isSaved = false
    @State private var fetched: OpenLibraryWorkDetail?

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
                if let description, !description.isEmpty {
                    Text(description)
                        .font(.body)
                } else if !subjects.isEmpty {
                    Text(subjects.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No description on Open Library")
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
                Button(isSaved ? "Saved" : "Save idea") {
                    if isSaved {
                        SavedReadingIdeas.remove(idea.id)
                    } else {
                        SavedReadingIdeas.save(idea)
                    }
                    isSaved.toggle()
                    onChange()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("save-idea")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle("Idea")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            isSaved = SavedReadingIdeas.contains(idea.id)
            // Backfill a real description when search.json gave no first_sentence.
            if (idea.blurb ?? "").isEmpty, let workKey {
                fetched = await OpenLibraryIdeaLookup.fetchDetail(forKey: workKey)
            }
        }
    }
}

private struct IdeaRow: View {
    let idea: ReadingIdea

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
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
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
