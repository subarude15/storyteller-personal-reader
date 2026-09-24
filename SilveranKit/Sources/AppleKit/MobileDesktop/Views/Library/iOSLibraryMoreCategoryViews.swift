#if os(iOS)
import SwiftUI

struct MoreSeriesView: View {
    @Binding var searchText: String
    @Binding var showSettings: Bool
    @Binding var showOfflineSheet: Bool
    @Environment(MediaViewModel.self) private var mediaViewModel
    @AppStorage("viewLayout.series") private var layoutStyleRaw: String = CategoryLayoutStyle.fan
        .rawValue
    @AppStorage("coverPref.series") private var coverPrefRaw: String = CoverPreference
        .storytellerDouble
        .rawValue
    @AppStorage("series.showBookCountBadge") private var showBookCountBadge: Bool = true
    @Environment(\.mediaNavigationPath) private var navigationPath

    private var layoutStyle: CategoryLayoutStyle {
        CategoryLayoutStyle(rawValue: layoutStyleRaw) ?? .fan
    }
    private var coverPreference: CoverPreference {
        CoverPreference(rawValue: coverPrefRaw) ?? .preferEbook
    }

    static let noSeriesFilterKey = BookMetadata.noSeriesSentinel

    private var categoryGroups: [CategoryGroup] {
        let groups = mediaViewModel.booksBySeries(for: .ebook)
        return filterGroups(groups).map { group in
            let name = group.series?.name ?? "No Series"
            let id = group.series?.name ?? Self.noSeriesFilterKey
            return CategoryGroup(id: id, name: name, books: group.books, pinId: nil)
        }
    }

    private func filterGroups(_ groups: [(series: BookSeries?, books: [BookMetadata])]) -> [(
        series: BookSeries?, books: [BookMetadata]
    )] {
        guard !searchText.isEmpty else { return groups }
        let searchLower = searchText.lowercased()
        return groups.compactMap { group in
            let nameMatches = group.series?.name.lowercased().contains(searchLower) ?? false
            if nameMatches { return group }
            let filteredBooks = group.books.filter {
                $0.title.lowercased().contains(searchLower)
                    || $0.authors?.contains(where: {
                        $0.name?.lowercased().contains(searchLower) ?? false
                    }) ?? false
            }
            guard !filteredBooks.isEmpty else { return nil }
            return (series: group.series, books: filteredBooks)
        }
    }

    var body: some View {
        Group {
            switch layoutStyle {
                case .list: listContent
                case .fan, .grid: fanGridContent
            }
        }
        .navigationTitle("Series")
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
                        NavigationLink(value: SeriesNavIdentifier(name: group.id)) {
                            CategoryRowContent(
                                iconName: "books.vertical.fill",
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

    private func navigateToSeries(_ group: CategoryGroup) {
        navigationPath?.wrappedValue.append(SeriesNavIdentifier(name: group.id))
    }

    @ViewBuilder
    private var fanGridContent: some View {
        if layoutStyle == .fan {
            CategoryFanLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                onNavigate: { group, _ in navigateToSeries(group) },
            ) { headerView }
        } else {
            CategoryGridLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                showBookCountBadge: showBookCountBadge,
                onNavigate: { group, _ in navigateToSeries(group) },
            ) { headerView }
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Series").font(.storytellerTitle(size: 32))
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

struct MoreCollectionsView: View {
    @Binding var searchText: String
    @Binding var showSettings: Bool
    @Binding var showOfflineSheet: Bool
    @Environment(MediaViewModel.self) private var mediaViewModel
    @AppStorage("viewLayout.collections") private var layoutStyleRaw: String = CategoryLayoutStyle
        .fan.rawValue
    @AppStorage("coverPref.collections") private var coverPrefRaw: String = CoverPreference
        .preferEbook.rawValue
    @AppStorage("collections.showBookCountBadge") private var showBookCountBadge: Bool = true
    @Environment(\.mediaNavigationPath) private var navigationPath

    private var layoutStyle: CategoryLayoutStyle {
        CategoryLayoutStyle(rawValue: layoutStyleRaw) ?? .fan
    }
    private var coverPreference: CoverPreference {
        CoverPreference(rawValue: coverPrefRaw) ?? .preferEbook
    }

    private var categoryGroups: [CategoryGroup] {
        let groups = mediaViewModel.booksByCollection(for: .ebook)
        return filterGroups(groups).map { group in
            let name = group.collection?.name ?? "Unknown Collection"
            return CategoryGroup(id: name, name: name, books: group.books, pinId: nil)
        }
    }

    private func filterGroups(
        _ groups: [(collection: BookCollectionSummary?, books: [BookMetadata])]
    ) -> [(collection: BookCollectionSummary?, books: [BookMetadata])] {
        guard !searchText.isEmpty else { return groups }
        let searchLower = searchText.lowercased()
        return groups.compactMap { group in
            let collectionMatches =
                group.collection?.name.lowercased().contains(searchLower) ?? false
            if collectionMatches { return group }
            let filteredBooks = group.books.filter {
                $0.title.lowercased().contains(searchLower)
                    || $0.authors?.contains(where: {
                        $0.name?.lowercased().contains(searchLower) ?? false
                    }) ?? false
            }
            guard !filteredBooks.isEmpty else { return nil }
            return (collection: group.collection, books: filteredBooks)
        }
    }

    var body: some View {
        Group {
            switch layoutStyle {
                case .list: listContent
                case .fan, .grid: fanGridContent
            }
        }
        .navigationTitle("Collections")
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
                        NavigationLink(
                            value: CollectionNavIdentifier(id: group.id, name: group.name)
                        ) {
                            CategoryRowContent(
                                iconName: "rectangle.stack.fill",
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

    private func navigateToCollection(_ group: CategoryGroup) {
        navigationPath?.wrappedValue.append(
            CollectionNavIdentifier(id: group.id, name: group.name)
        )
    }

    @ViewBuilder
    private var fanGridContent: some View {
        if layoutStyle == .fan {
            CategoryFanLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                onNavigate: { group, _ in navigateToCollection(group) },
            ) { headerView }
        } else {
            CategoryGridLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                showBookCountBadge: showBookCountBadge,
                onNavigate: { group, _ in navigateToCollection(group) },
            ) { headerView }
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Server Collections").font(.storytellerTitle(size: 32))
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

struct MoreAuthorsView: View {
    @Binding var searchText: String
    @Binding var showSettings: Bool
    @Binding var showOfflineSheet: Bool
    @Environment(MediaViewModel.self) private var mediaViewModel
    @AppStorage("viewLayout.authors") private var layoutStyleRaw: String = CategoryLayoutStyle.list
        .rawValue
    @AppStorage("coverPref.authors") private var coverPrefRaw: String = CoverPreference
        .storytellerDouble
        .rawValue
    @AppStorage("authors.showBookCountBadge") private var showBookCountBadge: Bool = true
    @Environment(\.mediaNavigationPath) private var navigationPath

    private var layoutStyle: CategoryLayoutStyle {
        CategoryLayoutStyle(rawValue: layoutStyleRaw) ?? .list
    }
    private var coverPreference: CoverPreference {
        CoverPreference(rawValue: coverPrefRaw) ?? .preferEbook
    }

    private var categoryGroups: [CategoryGroup] {
        let groups = mediaViewModel.booksByAuthor(for: .ebook)
        return filterGroups(groups).map { group in
            let name = group.author?.name ?? "Unknown Author"
            return CategoryGroup(id: name, name: name, books: group.books, pinId: nil)
        }
    }

    private func filterGroups(_ groups: [(author: BookCreator?, books: [BookMetadata])]) -> [(
        author: BookCreator?, books: [BookMetadata]
    )] {
        guard !searchText.isEmpty else { return groups }
        let searchLower = searchText.lowercased()
        return groups.compactMap { group in
            let authorMatches = group.author?.name?.lowercased().contains(searchLower) ?? false
            if authorMatches { return group }
            let filteredBooks = group.books.filter { $0.title.lowercased().contains(searchLower) }
            guard !filteredBooks.isEmpty else { return nil }
            return (author: group.author, books: filteredBooks)
        }
    }

    var body: some View {
        Group {
            switch layoutStyle {
                case .list: listContent
                case .fan, .grid: fanGridContent
            }
        }
        .navigationTitle("Authors")
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
                        NavigationLink(value: group.name) {
                            CategoryRowContent(
                                iconName: "person.fill",
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

    private func navigateToAuthor(_ group: CategoryGroup) {
        navigationPath?.wrappedValue.append(group.name)
    }

    @ViewBuilder
    private var fanGridContent: some View {
        if layoutStyle == .fan {
            CategoryFanLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                onNavigate: { group, _ in navigateToAuthor(group) },
            ) { headerView }
        } else {
            CategoryGridLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                showBookCountBadge: showBookCountBadge,
                onNavigate: { group, _ in navigateToAuthor(group) },
            ) { headerView }
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Authors").font(.storytellerTitle(size: 32))
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

struct MoreNarratorsView: View {
    @Binding var searchText: String
    @Binding var showSettings: Bool
    @Binding var showOfflineSheet: Bool
    @Environment(MediaViewModel.self) private var mediaViewModel
    @AppStorage("viewLayout.narrators") private var layoutStyleRaw: String = CategoryLayoutStyle
        .list.rawValue
    @AppStorage("coverPref.narrators") private var coverPrefRaw: String = CoverPreference
        .preferEbook.rawValue
    @AppStorage("narrators.showBookCountBadge") private var showBookCountBadge: Bool = true
    @Environment(\.mediaNavigationPath) private var navigationPath

    private var layoutStyle: CategoryLayoutStyle {
        CategoryLayoutStyle(rawValue: layoutStyleRaw) ?? .list
    }
    private var coverPreference: CoverPreference {
        CoverPreference(rawValue: coverPrefRaw) ?? .preferEbook
    }

    private var categoryGroups: [CategoryGroup] {
        let groups = mediaViewModel.booksByNarrator(for: .ebook)
        return filterGroups(groups).map { group in
            let name = group.narrator?.name ?? "Unknown Narrator"
            return CategoryGroup(id: name, name: name, books: group.books, pinId: nil)
        }
    }

    private func filterGroups(_ groups: [(narrator: BookCreator?, books: [BookMetadata])]) -> [(
        narrator: BookCreator?, books: [BookMetadata]
    )] {
        guard !searchText.isEmpty else { return groups }
        let searchLower = searchText.lowercased()
        return groups.compactMap { group in
            let narratorMatches = group.narrator?.name?.lowercased().contains(searchLower) ?? false
            if narratorMatches { return group }
            let filteredBooks = group.books.filter { $0.title.lowercased().contains(searchLower) }
            guard !filteredBooks.isEmpty else { return nil }
            return (narrator: group.narrator, books: filteredBooks)
        }
    }

    var body: some View {
        Group {
            switch layoutStyle {
                case .list: listContent
                case .fan, .grid: fanGridContent
            }
        }
        .navigationTitle("Narrators")
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
                        NavigationLink(value: NarratorNavIdentifier(name: group.name)) {
                            CategoryRowContent(
                                iconName: "mic.fill",
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

    private func navigateToNarrator(_ group: CategoryGroup) {
        navigationPath?.wrappedValue.append(NarratorNavIdentifier(name: group.name))
    }

    @ViewBuilder
    private var fanGridContent: some View {
        if layoutStyle == .fan {
            CategoryFanLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                onNavigate: { group, _ in navigateToNarrator(group) },
            ) { headerView }
        } else {
            CategoryGridLayout(
                groups: categoryGroups,
                mediaKind: .ebook,
                coverPreference: coverPreference,
                showBookCountBadge: showBookCountBadge,
                onNavigate: { group, _ in navigateToNarrator(group) },
            ) { headerView }
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Narrators").font(.storytellerTitle(size: 32))
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
#endif
