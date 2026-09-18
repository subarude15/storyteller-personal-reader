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
                saved = SavedReadingIdeas.load()
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
        suggestions = ReadingHabitIdeas.ideas(
            queries: queries,
            worksByQuery: works,
            owned: library,
        )
        saved = SavedReadingIdeas.load()
        loaded = true
    }
}

struct IdeaDetailView: View {
    let idea: ReadingIdea
    var onChange: () -> Void = {}

    @State private var isSaved = false

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
                Text(idea.reason)
                    .font(.subheadline.weight(.medium))
                if let blurb = idea.blurb, !blurb.isEmpty {
                    Text(blurb)
                        .font(.body)
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
        .onAppear {
            isSaved = SavedReadingIdeas.contains(idea.id)
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
                Text(idea.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
