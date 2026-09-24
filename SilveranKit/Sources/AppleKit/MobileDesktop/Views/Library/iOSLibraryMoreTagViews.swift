#if os(iOS)
import SwiftUI

struct MoreTagsView: View {
    @Binding var searchText: String
    @Binding var showSettings: Bool
    @Binding var showOfflineSheet: Bool
    @Environment(MediaViewModel.self) private var mediaViewModel
    @AppStorage("viewLayout.tags") private var layoutStyleRaw: String = CategoryLayoutStyle.list
        .rawValue
    @AppStorage("coverPref.tags") private var coverPrefRaw: String = CoverPreference
        .storytellerDouble
        .rawValue
    @AppStorage("tags.showBookCountBadge") private var showBookCountBadge: Bool = true
    @Environment(\.mediaNavigationPath) private var navigationPath

    private var layoutStyle: CategoryLayoutStyle {
        CategoryLayoutStyle(rawValue: layoutStyleRaw) ?? .list
    }
    private var coverPreference: CoverPreference {
        CoverPreference(rawValue: coverPrefRaw) ?? .preferEbook
    }

    private var categoryGroups: [CategoryGroup] {
        let groups = mediaViewModel.booksByTag(for: .ebook)
        return filterGroups(groups).map { group in
            return CategoryGroup(id: group.tag, name: group.tag, books: group.books, pinId: nil)
        }
    }

    private func filterGroups(_ groups: [(tag: String, books: [BookMetadata])]) -> [(
        tag: String, books: [BookMetadata]
    )] {
        guard !searchText.isEmpty else { return groups }
        let searchLower = searchText.lowercased()
        return groups.compactMap { group in
            let tagMatches = group.tag.lowercased().contains(searchLower)
            if tagMatches { return group }
            let filteredBooks = group.books.filter { $0.title.lowercased().contains(searchLower) }
            guard !filteredBooks.isEmpty else { return nil }
            return (tag: group.tag, books: filteredBooks)
        }
    }

    var body: some View {
        Group {
            switch layoutStyle {
                case .list: listContent
                case .fan, .grid: fanGridContent
            }
        }
        .navigationTitle("Tags")
        .navigationBarTitleDisplayMode(.inline)
        .iOSLibraryToolbar(showSettings: $showSettings, showOfflineSheet: $showOfflineSheet)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search",
        )
    }

    private var listContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerView.padding(.horizontal).padding(.bottom, 16)
                LazyVStack(spacing: 0) {
                    ForEach(categoryGroups) { group in
                        NavigationLink(value: TagNavIdentifier(name: group.name)) {
                            CategoryRowContent(
                                iconName: "tag.fill",
                                name: group.name,
                                bookCount: group.books.count,
                                isSelected: false,
                            ).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 48)
                    }
                }
            }.padding(.top, 8)
        }
    }

    private func navigateToTag(_ group: CategoryGroup) {
        navigationPath?.wrappedValue.append(TagNavIdentifier(name: group.name))
    }

    @ViewBuilder
    private var fanGridContent: some View {
        if layoutStyle == .fan {
            CategoryFanLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                onNavigate: { group, _ in navigateToTag(group) },
            ) { headerView }
        } else {
            CategoryGridLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                showBookCountBadge: showBookCountBadge,
                onNavigate: { group, _ in navigateToTag(group) },
            ) { headerView }
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags").font(.storytellerTitle(size: 32))
            HStack {
                CategoryViewOptionsMenu(
                    layoutStyle: Binding(
                        get: { layoutStyle },
                        set: { layoutStyleRaw = $0.rawValue },
                    ),
                    coverPreference: Binding(
                        get: { coverPreference },
                        set: { coverPrefRaw = $0.rawValue },
                    ),
                    showBookCountBadge: $showBookCountBadge,
                )
                Spacer()
            }.font(.callout)
        }
    }
}

struct MoreTranslatorsView: View {
    @Binding var searchText: String
    @Binding var showSettings: Bool
    @Binding var showOfflineSheet: Bool
    @Environment(MediaViewModel.self) private var mediaViewModel
    @AppStorage("viewLayout.translators") private var layoutStyleRaw: String = CategoryLayoutStyle
        .list.rawValue
    @AppStorage("coverPref.translators") private var coverPrefRaw: String = CoverPreference
        .preferEbook.rawValue
    @AppStorage("translators.showBookCountBadge") private var showBookCountBadge: Bool = true
    @Environment(\.mediaNavigationPath) private var navigationPath

    private var layoutStyle: CategoryLayoutStyle {
        CategoryLayoutStyle(rawValue: layoutStyleRaw) ?? .list
    }
    private var coverPreference: CoverPreference {
        CoverPreference(rawValue: coverPrefRaw) ?? .preferEbook
    }

    private var categoryGroups: [CategoryGroup] {
        let groups = mediaViewModel.booksByTranslator(for: .ebook)
        return filterGroups(groups).map { group in
            let name = group.translator?.name ?? "Unknown Translator"
            return CategoryGroup(id: name, name: name, books: group.books, pinId: nil)
        }
    }

    private func filterGroups(_ groups: [(translator: BookCreator?, books: [BookMetadata])]) -> [(
        translator: BookCreator?, books: [BookMetadata]
    )] {
        guard !searchText.isEmpty else { return groups }
        let searchLower = searchText.lowercased()
        return groups.compactMap { group in
            let translatorMatches =
                group.translator?.name?.lowercased().contains(searchLower) ?? false
            if translatorMatches { return group }
            let filteredBooks = group.books.filter { $0.title.lowercased().contains(searchLower) }
            guard !filteredBooks.isEmpty else { return nil }
            return (translator: group.translator, books: filteredBooks)
        }
    }

    var body: some View {
        Group {
            switch layoutStyle {
                case .list: listContent
                case .fan, .grid: fanGridContent
            }
        }
        .navigationTitle("Translators")
        .navigationBarTitleDisplayMode(.inline)
        .iOSLibraryToolbar(showSettings: $showSettings, showOfflineSheet: $showOfflineSheet)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search",
        )
    }

    private var listContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerView.padding(.horizontal).padding(.bottom, 16)
                LazyVStack(spacing: 0) {
                    ForEach(categoryGroups) { group in
                        NavigationLink(value: TranslatorNavIdentifier(name: group.name)) {
                            CategoryRowContent(
                                iconName: "character.book.closed.fill",
                                name: group.name,
                                bookCount: group.books.count,
                                isSelected: false,
                            ).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 48)
                    }
                }
            }.padding(.top, 8)
        }
    }

    private func navigateToTranslator(_ group: CategoryGroup) {
        navigationPath?.wrappedValue.append(TranslatorNavIdentifier(name: group.name))
    }

    @ViewBuilder
    private var fanGridContent: some View {
        if layoutStyle == .fan {
            CategoryFanLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                onNavigate: { group, _ in navigateToTranslator(group) },
            ) { headerView }
        } else {
            CategoryGridLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                showBookCountBadge: showBookCountBadge,
                onNavigate: { group, _ in navigateToTranslator(group) },
            ) { headerView }
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Translators").font(.storytellerTitle(size: 32))
            HStack {
                CategoryViewOptionsMenu(
                    layoutStyle: Binding(
                        get: { layoutStyle },
                        set: { layoutStyleRaw = $0.rawValue },
                    ),
                    coverPreference: Binding(
                        get: { coverPreference },
                        set: { coverPrefRaw = $0.rawValue },
                    ),
                    showBookCountBadge: $showBookCountBadge,
                )
                Spacer()
            }.font(.callout)
        }
    }
}

struct MorePublicationYearsView: View {
    @Binding var searchText: String
    @Binding var showSettings: Bool
    @Binding var showOfflineSheet: Bool
    @Environment(MediaViewModel.self) private var mediaViewModel
    @AppStorage("viewLayout.years") private var layoutStyleRaw: String = CategoryLayoutStyle.list
        .rawValue
    @AppStorage("coverPref.years") private var coverPrefRaw: String = CoverPreference
        .storytellerDouble
        .rawValue
    @AppStorage("years.showBookCountBadge") private var showBookCountBadge: Bool = true
    @Environment(\.mediaNavigationPath) private var navigationPath

    private var layoutStyle: CategoryLayoutStyle {
        CategoryLayoutStyle(rawValue: layoutStyleRaw) ?? .list
    }
    private var coverPreference: CoverPreference {
        CoverPreference(rawValue: coverPrefRaw) ?? .preferEbook
    }

    private var categoryGroups: [CategoryGroup] {
        let groups = mediaViewModel.booksByPublicationYear(for: .ebook)
        return filterGroups(groups).map { group in
            return CategoryGroup(id: group.year, name: group.year, books: group.books, pinId: nil)
        }
    }

    private func filterGroups(_ groups: [(year: String, books: [BookMetadata])]) -> [(
        year: String, books: [BookMetadata]
    )] {
        guard !searchText.isEmpty else { return groups }
        let searchLower = searchText.lowercased()
        return groups.compactMap { group in
            let yearMatches = group.year.lowercased().contains(searchLower)
            if yearMatches { return group }
            let filteredBooks = group.books.filter { $0.title.lowercased().contains(searchLower) }
            guard !filteredBooks.isEmpty else { return nil }
            return (year: group.year, books: filteredBooks)
        }
    }

    var body: some View {
        Group {
            switch layoutStyle {
                case .list: listContent
                case .fan, .grid: fanGridContent
            }
        }
        .navigationTitle("Publication Year")
        .navigationBarTitleDisplayMode(.inline)
        .iOSLibraryToolbar(showSettings: $showSettings, showOfflineSheet: $showOfflineSheet)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search",
        )
    }

    private var listContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerView.padding(.horizontal).padding(.bottom, 16)
                LazyVStack(spacing: 0) {
                    ForEach(categoryGroups) { group in
                        NavigationLink(value: PublicationYearNavIdentifier(name: group.name)) {
                            CategoryRowContent(
                                iconName: "calendar",
                                name: group.name,
                                bookCount: group.books.count,
                                isSelected: false,
                            ).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 48)
                    }
                }
            }.padding(.top, 8)
        }
    }

    private func navigateToYear(_ group: CategoryGroup) {
        navigationPath?.wrappedValue.append(PublicationYearNavIdentifier(name: group.name))
    }

    @ViewBuilder
    private var fanGridContent: some View {
        if layoutStyle == .fan {
            CategoryFanLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                onNavigate: { group, _ in navigateToYear(group) },
            ) { headerView }
        } else {
            CategoryGridLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                showBookCountBadge: showBookCountBadge,
                onNavigate: { group, _ in navigateToYear(group) },
            ) { headerView }
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Years").font(.storytellerTitle(size: 32))
            HStack {
                CategoryViewOptionsMenu(
                    layoutStyle: Binding(
                        get: { layoutStyle },
                        set: { layoutStyleRaw = $0.rawValue },
                    ),
                    coverPreference: Binding(
                        get: { coverPreference },
                        set: { coverPrefRaw = $0.rawValue },
                    ),
                    showBookCountBadge: $showBookCountBadge,
                )
                Spacer()
            }.font(.callout)
        }
    }
}

struct MoreRatingsView: View {
    @Binding var searchText: String
    @Binding var showSettings: Bool
    @Binding var showOfflineSheet: Bool
    @Environment(MediaViewModel.self) private var mediaViewModel
    @AppStorage("viewLayout.ratings") private var layoutStyleRaw: String = CategoryLayoutStyle.list
        .rawValue
    @AppStorage("coverPref.ratings") private var coverPrefRaw: String = CoverPreference
        .storytellerDouble
        .rawValue
    @AppStorage("ratings.showBookCountBadge") private var showBookCountBadge: Bool = true
    @Environment(\.mediaNavigationPath) private var navigationPath

    private var layoutStyle: CategoryLayoutStyle {
        CategoryLayoutStyle(rawValue: layoutStyleRaw) ?? .list
    }
    private var coverPreference: CoverPreference {
        CoverPreference(rawValue: coverPrefRaw) ?? .preferEbook
    }

    private var categoryGroups: [CategoryGroup] {
        let groups = mediaViewModel.booksByRating(for: .ebook)
        return filterGroups(groups).map { group in
            return CategoryGroup(
                id: group.rating,
                name: RatingDisplayHelper.label(for: group.rating),
                books: group.books,
                pinId: nil,
            )
        }
    }

    private func filterGroups(_ groups: [(rating: String, books: [BookMetadata])]) -> [(
        rating: String, books: [BookMetadata]
    )] {
        guard !searchText.isEmpty else { return groups }
        let searchLower = searchText.lowercased()
        return groups.compactMap { group in
            let ratingMatches = group.rating.lowercased().contains(searchLower)
            if ratingMatches { return group }
            let filteredBooks = group.books.filter { $0.title.lowercased().contains(searchLower) }
            guard !filteredBooks.isEmpty else { return nil }
            return (rating: group.rating, books: filteredBooks)
        }
    }

    var body: some View {
        Group {
            switch layoutStyle {
                case .list: listContent
                case .fan, .grid: fanGridContent
            }
        }
        .navigationTitle("Ratings")
        .navigationBarTitleDisplayMode(.inline)
        .iOSLibraryToolbar(showSettings: $showSettings, showOfflineSheet: $showOfflineSheet)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search",
        )
    }

    private var listContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerView.padding(.horizontal).padding(.bottom, 16)
                LazyVStack(spacing: 0) {
                    ForEach(categoryGroups) { group in
                        NavigationLink(value: RatingNavIdentifier(name: group.id)) {
                            CategoryRowContent(
                                iconName: "star.fill",
                                name: group.name,
                                bookCount: group.books.count,
                                isSelected: false,
                            ).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 48)
                    }
                }
            }.padding(.top, 8)
        }
    }

    private func navigateToRating(_ group: CategoryGroup) {
        navigationPath?.wrappedValue.append(RatingNavIdentifier(name: group.id))
    }

    @ViewBuilder
    private var fanGridContent: some View {
        if layoutStyle == .fan {
            CategoryFanLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                onNavigate: { group, _ in navigateToRating(group) },
            ) { headerView }
        } else {
            CategoryGridLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                showBookCountBadge: showBookCountBadge,
                onNavigate: { group, _ in navigateToRating(group) },
            ) { headerView }
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ratings").font(.storytellerTitle(size: 32))
            HStack {
                CategoryViewOptionsMenu(
                    layoutStyle: Binding(
                        get: { layoutStyle },
                        set: { layoutStyleRaw = $0.rawValue },
                    ),
                    coverPreference: Binding(
                        get: { coverPreference },
                        set: { coverPrefRaw = $0.rawValue },
                    ),
                    showBookCountBadge: $showBookCountBadge,
                )
                Spacer()
            }.font(.callout)
        }
    }
}

struct SourceNavIdentifier: Hashable {
    let id: BookSourceID
    let name: String
}

struct MoreSourcesView: View {
    @Binding var searchText: String
    @Binding var showSettings: Bool
    @Binding var showOfflineSheet: Bool
    @Environment(MediaViewModel.self) private var mediaViewModel

    private func iconName(for source: BookSourceRecord) -> String {
        switch source.kind {
            case .storyteller: "server.rack"
            case .localFolder: "folder.fill"
        }
    }

    private func bookCount(for sourceID: BookSourceID) -> Int {
        mediaViewModel.library.bookMetaData.filter { $0.sourceID == sourceID }.count
    }

    private var filteredSources: [BookSourceRecord] {
        guard !searchText.isEmpty else { return mediaViewModel.bookSources }
        let searchLower = searchText.lowercased()
        return mediaViewModel.bookSources.filter { $0.name.lowercased().contains(searchLower) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredSources) { source in
                    NavigationLink(value: SourceNavIdentifier(id: source.id, name: source.name)) {
                        CategoryRowContent(
                            iconName: iconName(for: source),
                            name: source.name,
                            bookCount: bookCount(for: source.id),
                            isSelected: false,
                        ).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 48)
                }
            }
            .padding(.top, 8)
        }
        .navigationTitle("Sources")
        .navigationBarTitleDisplayMode(.inline)
        .iOSLibraryToolbar(showSettings: $showSettings, showOfflineSheet: $showOfflineSheet)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search",
        )
    }
}

#endif
