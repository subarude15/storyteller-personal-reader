#if os(iOS)
import SwiftUI

struct CollectionNavIdentifier: Hashable {
    let id: String
    let name: String
}

struct BooksContentView: View {
    let searchText: String

    var body: some View {
        MediaGridView(
            title: "All Books",
            searchText: searchText,
            mediaKind: .ebook,
            viewOptionsKey: "books.ios",
            tagFilter: nil,
            seriesFilter: nil,
            statusFilter: nil,
            defaultSort: "titleAZ",
            preferredTileWidth: 110,
            minimumTileWidth: 90,
            columnBreakpoints: [
                MediaGridView.ColumnBreakpoint(columns: 3, minWidth: 0)
            ],
            initialNarrationFilterOption: .both,
            showAddBookButton: true,
        )
        .navigationTitle("Books")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DownloadedContentView: View {
    let searchText: String

    var body: some View {
        MediaGridView(
            title: "Downloaded",
            searchText: searchText,
            mediaKind: .ebook,
            viewOptionsKey: "downloaded",
            tagFilter: nil,
            seriesFilter: nil,
            statusFilter: nil,
            defaultSort: "titleAZ",
            preferredTileWidth: 110,
            minimumTileWidth: 90,
            columnBreakpoints: [
                MediaGridView.ColumnBreakpoint(columns: 3, minWidth: 0)
            ],
            initialNarrationFilterOption: .both,
            initialLocationFilter: .downloaded,
        )
        .navigationTitle("Downloaded")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CollectionsListView: View {
    @Binding var searchText: String
    @Binding var navigationPath: NavigationPath
    @Environment(MediaViewModel.self) private var mediaViewModel
    @State private var settingsViewModel = SettingsViewModel()
    @AppStorage("coverPref.collections") private var coverPrefRaw: String = CoverPreference
        .preferEbook.rawValue

    private var coverPreference: CoverPreference {
        CoverPreference(rawValue: coverPrefRaw) ?? .preferEbook
    }

    private let horizontalPadding: CGFloat = 24
    private let sectionSpacing: CGFloat = 32

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = geometry.size.width
            ScrollView {
                VStack(alignment: .leading, spacing: sectionSpacing) {
                    collectionContent(contentWidth: contentWidth)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("Server Collections")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func navigateToCollection(_ identifier: CollectionNavIdentifier) {
        navigationPath.append(identifier)
    }

    @ViewBuilder
    private func collectionContent(contentWidth: CGFloat) -> some View {
        let collectionGroups = mediaViewModel.booksByCollection(for: .ebook)
        let filteredGroups = filterCollections(collectionGroups)

        if filteredGroups.isEmpty {
            emptyStateView
        } else {
            ForEach(Array(filteredGroups.enumerated()), id: \.offset) { _, group in
                collectionSection(
                    collection: group.collection,
                    books: group.books,
                    contentWidth: contentWidth,
                )
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Text("No collections found")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(
                "Books in collections will appear here. Create collections on Storyteller to organize your library."
            )
            .font(.body)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 500)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 60)
    }

    private func filterCollections(
        _ groups: [(collection: BookCollectionSummary?, books: [BookMetadata])]
    ) -> [(
        collection: BookCollectionSummary?, books: [BookMetadata]
    )] {
        guard !searchText.isEmpty else { return groups }
        let searchLower = searchText.lowercased()
        return groups.compactMap { group in
            let collectionNameMatches =
                group.collection?.name.lowercased().contains(searchLower) ?? false
            if collectionNameMatches {
                return (collection: group.collection, books: group.books)
            }
            let filteredBooks = group.books.filter { book in
                book.title.lowercased().contains(searchLower)
                    || book.authors?.contains(where: {
                        $0.name?.lowercased().contains(searchLower) ?? false
                    }) ?? false
            }
            guard !filteredBooks.isEmpty else { return nil }
            return (collection: group.collection, books: filteredBooks)
        }
    }

    @ViewBuilder
    private func collectionSection(
        collection: BookCollectionSummary?,
        books: [BookMetadata],
        contentWidth: CGFloat,
    )
        -> some View
    {
        let collectionName = collection?.name ?? "Unknown Collection"
        let stackWidth = max(contentWidth - (horizontalPadding * 2), 100)
        let navIdentifier = CollectionNavIdentifier(id: collectionName, name: collectionName)
        let displayBooks = Array(books.prefix(30))

        VStack(alignment: .center, spacing: 12) {
            SeriesStackView(
                books: displayBooks,
                mediaKind: .ebook,
                availableWidth: stackWidth,
                showAudioIndicator: settingsViewModel.showAudioIndicator,
                coverPreference: coverPreference,
                onSelect: { _ in
                    navigateToCollection(navIdentifier)
                },
            )
            .frame(maxWidth: stackWidth, alignment: .center)

            VStack(alignment: .center, spacing: 6) {
                Button {
                    navigateToCollection(navIdentifier)
                } label: {
                    Text(collectionName)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .center)

                Text("\(books.count) book\(books.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }
}

struct AuthorsRowListView: View {
    @Binding var searchText: String
    @Environment(MediaViewModel.self) private var mediaViewModel

    private var authorGroups: [(author: BookCreator?, books: [BookMetadata])] {
        mediaViewModel.booksByAuthor(for: .ebook)
    }

    private var filteredGroups: [(author: BookCreator?, books: [BookMetadata])] {
        guard !searchText.isEmpty else { return authorGroups }
        let searchLower = searchText.lowercased()
        return authorGroups.compactMap { group in
            let authorMatches = group.author?.name?.lowercased().contains(searchLower) ?? false
            if authorMatches {
                return group
            }
            let filteredBooks = group.books.filter { book in
                book.title.lowercased().contains(searchLower)
            }
            guard !filteredBooks.isEmpty else { return nil }
            return (author: group.author, books: filteredBooks)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredGroups, id: \.author?.name) { group in
                    let authorName = group.author?.name ?? "Unknown Author"
                    NavigationLink(value: authorName) {
                        CategoryRowContent(
                            iconName: "person.fill",
                            name: authorName,
                            bookCount: group.books.count,
                            isSelected: false,
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .padding(.leading, 48)
                }
            }
            .padding(.top, 8)
        }
        .navigationTitle("Authors")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SeriesContentView: View {
    @Binding var searchText: String
    @Environment(MediaViewModel.self) private var mediaViewModel
    @State private var settingsViewModel = SettingsViewModel()
    @AppStorage("coverPref.series") private var coverPrefRaw: String = CoverPreference
        .storytellerDouble
        .rawValue

    private var coverPreference: CoverPreference {
        CoverPreference(rawValue: coverPrefRaw) ?? .preferEbook
    }

    private let horizontalPadding: CGFloat = 24
    private let sectionSpacing: CGFloat = 32

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = geometry.size.width
            ScrollView {
                VStack(alignment: .leading, spacing: sectionSpacing) {
                    seriesContent(contentWidth: contentWidth)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
        }
        .navigationTitle("Series")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func seriesContent(contentWidth: CGFloat) -> some View {
        let seriesGroups = mediaViewModel.booksBySeries(for: .ebook)
        let filteredGroups = filterSeries(seriesGroups)

        if filteredGroups.isEmpty {
            emptyStateView
        } else {
            ForEach(Array(filteredGroups.enumerated()), id: \.offset) { _, group in
                seriesSection(
                    series: group.series,
                    books: group.books,
                    contentWidth: contentWidth,
                )
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Text("No series found")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(
                "Books with series information will appear here."
            )
            .font(.body)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 500)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 60)
    }

    private func filterSeries(
        _ groups: [(series: BookSeries?, books: [BookMetadata])]
    ) -> [(series: BookSeries?, books: [BookMetadata])] {
        guard !searchText.isEmpty else { return groups }
        let searchLower = searchText.lowercased()
        return groups.compactMap { group in
            let seriesNameMatches =
                group.series?.name.lowercased().contains(searchLower) ?? false
            if seriesNameMatches {
                return (series: group.series, books: group.books)
            }
            let filteredBooks = group.books.filter { book in
                book.title.lowercased().contains(searchLower)
                    || book.authors?.contains(where: {
                        $0.name?.lowercased().contains(searchLower) ?? false
                    }) ?? false
            }
            guard !filteredBooks.isEmpty else { return nil }
            return (series: group.series, books: filteredBooks)
        }
    }

    @ViewBuilder
    private func seriesSection(
        series: BookSeries?,
        books: [BookMetadata],
        contentWidth: CGFloat,
    ) -> some View {
        let seriesName = series?.name ?? "Unknown Series"
        let stackWidth = max(contentWidth - (horizontalPadding * 2), 100)
        let displayBooks = Array(books.prefix(30))

        VStack(alignment: .center, spacing: 12) {
            SeriesStackView(
                books: displayBooks,
                mediaKind: .ebook,
                availableWidth: stackWidth,
                showAudioIndicator: settingsViewModel.showAudioIndicator,
                coverPreference: coverPreference,
                onSelect: { _ in },
            )
            .frame(maxWidth: stackWidth, alignment: .center)

            VStack(alignment: .center, spacing: 6) {
                NavigationLink(value: SeriesNavIdentifier(name: seriesName)) {
                    Text(seriesName)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .center)

                Text("\(books.count) book\(books.count == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }
}

struct NarratorsListView: View {
    @Binding var searchText: String
    @Environment(MediaViewModel.self) private var mediaViewModel

    private var narratorGroups: [(narrator: BookCreator?, books: [BookMetadata])] {
        mediaViewModel.booksByNarrator(for: .ebook)
    }

    private var filteredGroups: [(narrator: BookCreator?, books: [BookMetadata])] {
        guard !searchText.isEmpty else { return narratorGroups }
        let searchLower = searchText.lowercased()
        return narratorGroups.compactMap { group in
            let narratorMatches = group.narrator?.name?.lowercased().contains(searchLower) ?? false
            if narratorMatches {
                return group
            }
            let filteredBooks = group.books.filter { book in
                book.title.lowercased().contains(searchLower)
            }
            guard !filteredBooks.isEmpty else { return nil }
            return (narrator: group.narrator, books: filteredBooks)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredGroups, id: \.narrator?.name) { group in
                    let narratorName = group.narrator?.name ?? "Unknown Narrator"
                    NavigationLink(value: NarratorNavIdentifier(name: narratorName)) {
                        CategoryRowContent(
                            iconName: "mic.fill",
                            name: narratorName,
                            bookCount: group.books.count,
                            isSelected: false,
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .padding(.leading, 48)
                }
            }
            .padding(.top, 8)
        }
        .navigationTitle("Narrators")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct NarratorNavIdentifier: Hashable {
    let name: String
}

struct TagsListView: View {
    @Binding var searchText: String
    @Environment(MediaViewModel.self) private var mediaViewModel

    private var tagGroups: [(tag: String, books: [BookMetadata])] {
        mediaViewModel.booksByTag(for: .ebook)
    }

    private var filteredGroups: [(tag: String, books: [BookMetadata])] {
        guard !searchText.isEmpty else { return tagGroups }
        let searchLower = searchText.lowercased()
        return tagGroups.compactMap { group in
            let tagMatches = group.tag.lowercased().contains(searchLower)
            if tagMatches {
                return group
            }
            let filteredBooks = group.books.filter { book in
                book.title.lowercased().contains(searchLower)
            }
            guard !filteredBooks.isEmpty else { return nil }
            return (tag: group.tag, books: filteredBooks)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredGroups, id: \.tag) { group in
                    NavigationLink(value: TagNavIdentifier(name: group.tag)) {
                        CategoryRowContent(
                            iconName: "tag.fill",
                            name: group.tag,
                            bookCount: group.books.count,
                            isSelected: false,
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .padding(.leading, 48)
                }
            }
            .padding(.top, 8)
        }
        .navigationTitle("Tags")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct TagNavIdentifier: Hashable {
    let name: String
}

struct TranslatorNavIdentifier: Hashable {
    let name: String
}

struct PublicationYearNavIdentifier: Hashable {
    let name: String
}

struct RatingNavIdentifier: Hashable {
    let name: String
}

struct TranslatorsListView: View {
    @Binding var searchText: String
    @Environment(MediaViewModel.self) private var mediaViewModel

    private var translatorGroups: [(translator: BookCreator?, books: [BookMetadata])] {
        mediaViewModel.booksByTranslator(for: .ebook)
    }

    private var filteredGroups: [(translator: BookCreator?, books: [BookMetadata])] {
        guard !searchText.isEmpty else { return translatorGroups }
        let searchLower = searchText.lowercased()
        return translatorGroups.compactMap { group in
            let translatorMatches =
                group.translator?.name?.lowercased().contains(searchLower) ?? false
            if translatorMatches {
                return group
            }
            let filteredBooks = group.books.filter { book in
                book.title.lowercased().contains(searchLower)
            }
            guard !filteredBooks.isEmpty else { return nil }
            return (translator: group.translator, books: filteredBooks)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredGroups, id: \.translator?.name) { group in
                    let translatorName = group.translator?.name ?? "Unknown Translator"
                    NavigationLink(value: TranslatorNavIdentifier(name: translatorName)) {
                        CategoryRowContent(
                            iconName: "character.book.closed.fill",
                            name: translatorName,
                            bookCount: group.books.count,
                            isSelected: false,
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .padding(.leading, 48)
                }
            }
            .padding(.top, 8)
        }
        .navigationTitle("Translators")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PublicationYearsListView: View {
    @Binding var searchText: String
    @Environment(MediaViewModel.self) private var mediaViewModel

    private var yearGroups: [(year: String, books: [BookMetadata])] {
        mediaViewModel.booksByPublicationYear(for: .ebook)
    }

    private var filteredGroups: [(year: String, books: [BookMetadata])] {
        guard !searchText.isEmpty else { return yearGroups }
        let searchLower = searchText.lowercased()
        return yearGroups.compactMap { group in
            let yearMatches = group.year.lowercased().contains(searchLower)
            if yearMatches {
                return group
            }
            let filteredBooks = group.books.filter { book in
                book.title.lowercased().contains(searchLower)
            }
            guard !filteredBooks.isEmpty else { return nil }
            return (year: group.year, books: filteredBooks)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredGroups, id: \.year) { group in
                    NavigationLink(value: PublicationYearNavIdentifier(name: group.year)) {
                        CategoryRowContent(
                            iconName: "calendar",
                            name: group.year,
                            bookCount: group.books.count,
                            isSelected: false,
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .padding(.leading, 48)
                }
            }
            .padding(.top, 8)
        }
        .navigationTitle("Publication Year")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct RatingsListView: View {
    @Binding var searchText: String
    @Environment(MediaViewModel.self) private var mediaViewModel

    private var ratingGroups: [(rating: String, books: [BookMetadata])] {
        mediaViewModel.booksByRating(for: .ebook)
    }

    private var filteredGroups: [(rating: String, books: [BookMetadata])] {
        guard !searchText.isEmpty else { return ratingGroups }
        let searchLower = searchText.lowercased()
        return ratingGroups.compactMap { group in
            let ratingMatches = group.rating.lowercased().contains(searchLower)
            if ratingMatches {
                return group
            }
            let filteredBooks = group.books.filter { book in
                book.title.lowercased().contains(searchLower)
            }
            guard !filteredBooks.isEmpty else { return nil }
            return (rating: group.rating, books: filteredBooks)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredGroups, id: \.rating) { group in
                    NavigationLink(value: RatingNavIdentifier(name: group.rating)) {
                        CategoryRowContent(
                            iconName: "star.fill",
                            name: RatingDisplayHelper.label(for: group.rating),
                            bookCount: group.books.count,
                            isSelected: false,
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider()
                        .padding(.leading, 48)
                }
            }
            .padding(.top, 8)
        }
        .navigationTitle("Ratings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#endif
