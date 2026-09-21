#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct MediaGridInfoSidebar: View {
    let item: BookMetadata
    let mediaKind: MediaKind?
    let onClose: () -> Void
    let onReadNow: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onSeriesSelected: ((String) -> Void)?
    let showsInspectorToolbar: Bool
    let roundsTopTrailingCorner: Bool
    let onRelatedItemChange: ((Bool) -> Void)?

    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel
    @Environment(\.colorScheme) private var colorScheme
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var animatedProgress: Double = 0
    @State private var showingSyncHistory = false
    @State private var attributedDescription: AttributedString? = nil
    @State private var descriptionTask: Task<Void, Never>? = nil
    @State private var isDescriptionExpanded = false
    @State private var isAuthorSummaryExpanded = false
    @State private var isNarratorSummaryExpanded = false
    @State private var relatedItemOverride: BookMetadata?
    @State private var coverPalette = CoverDerivedPalette.fallback()
    @State private var showingFormatLink = false
    @State private var showingAudiobookOptions = false
    @State private var showingBookRequest = false
    @State private var showingManualSearch = false
    @State private var alignmentOverride: ReadaloudAlignment?
    @State private var formatActionError: String?

    init(
        item: BookMetadata,
        mediaKind: MediaKind? = nil,
        onClose: @escaping () -> Void,
        onReadNow: @escaping () -> Void,
        onRename: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onSeriesSelected: ((String) -> Void)? = nil,
        showsInspectorToolbar: Bool = true,
        roundsTopTrailingCorner: Bool = false,
        onRelatedItemChange: ((Bool) -> Void)? = nil,
    ) {
        self.item = item
        self.mediaKind = mediaKind
        self.onClose = onClose
        self.onReadNow = onReadNow
        self.onRename = onRename
        self.onDelete = onDelete
        self.onSeriesSelected = onSeriesSelected
        self.showsInspectorToolbar = showsInspectorToolbar
        self.roundsTopTrailingCorner = roundsTopTrailingCorner
        self.onRelatedItemChange = onRelatedItemChange
    }

    private var currentItem: BookMetadata {
        let requestedItem = relatedItemOverride ?? item
        return mediaViewModel.library.bookMetaData.first { $0.id == requestedItem.id }
            ?? requestedItem
    }

    private var resolvedPalette: CoverDerivedPalette {
        coverPalette.resolved(for: colorScheme)
    }

    private var heroColors: BookDetailHeroColors {
        BookDetailHeroColors.resolved(for: colorScheme)
    }

    var body: some View {
        Group {
            #if os(macOS)
            ScrollView {
                VStack(spacing: 0) {
                    macHeroSection
                    content
                }
                .background(MacBookDetailScrollViewConfiguration())
            }
            .id(currentItem.id)
            .background {
                resolvedPalette.contentBackground
            }
            #else
            ScrollView {
                VStack(spacing: 0) {
                    iosHeroSection
                    content
                }
            }
            .id(currentItem.id)
            .background(resolvedPalette.contentBackground)
            .ignoresSafeArea(edges: showsInspectorToolbar ? [] : .top)
            #endif
        }
        .environment(\.bookDetailPalette, resolvedPalette)
        .sheet(isPresented: $showingSyncHistory) {
            SyncHistorySheet(bookId: currentItem.id, bookTitle: currentItem.title)
        }
        .sheet(isPresented: $showingFormatLink) {
            BookFormatLinkSheet(item: currentItem)
        }
        .sheet(isPresented: $showingAudiobookOptions) {
            AudiobookOptionsSheet(
                work: CanonicalBookWork.library(currentItem),
                book: currentItem,
            )
            #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            #endif
        }
        .sheet(isPresented: $showingBookRequest) {
            BookRequestSheet(
                work: CanonicalBookWork.library(currentItem),
                owned: BookRequestLibrary.ownedFormats(formatMembers),
            )
            #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            #endif
        }
        .sheet(isPresented: $showingManualSearch) {
            ManualSearchView(book: ManualSearchBookContext.from(CanonicalBookWork.library(currentItem)))
            #if os(iOS)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            #endif
        }
        .alert("Couldn't update formats", isPresented: formatErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(formatActionError ?? "")
        }
        .onAppear {
            prepareForDisplay()
            loadDescription()
        }
        .onChange(of: item.id) { _, _ in
            relatedItemOverride = nil
        }
        .onChange(of: relatedItemOverride?.id) { _, newValue in
            onRelatedItemChange?(newValue != nil)
        }
        .onChange(of: currentItem.id) { _, _ in
            coverPalette = CoverDerivedPalette.fallback()
            isAuthorSummaryExpanded = false
            isNarratorSummaryExpanded = false
            alignmentOverride = nil
            formatActionError = nil
            showingAudiobookOptions = false
            showingBookRequest = false
            showingManualSearch = false
            prepareForDisplay()
            loadDescription()
        }
        .onChange(of: currentItem.description) { _, _ in
            loadDescription()
        }
        .onChange(of: mediaViewModel.progress(for: currentItem.id)) { _, newValue in
            withAnimation(.easeOut(duration: 0.45)) {
                animatedProgress = newValue
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            #if os(macOS)
            descriptionSection
            relatedBooksSections
            macBookInfoSection
            macMediaInfoSection
            macSyncHistorySection
            #else
            iosMoreLikeThisSection
            descriptionSection
            iosBookInfoSection
            iosMediaInfoSection
            iosSyncHistorySection
            #endif
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 24)
    }

    #if os(macOS)
    private var macHeroSection: some View {
        ZStack {
            MacBookDetailHeroBackground(
                item: currentItem,
                palette: $coverPalette,
                surfaceColor: resolvedPalette.surface,
                contentBackground: resolvedPalette.contentBackground,
            )

            VStack(spacing: 13) {
                macInspectorToolbar

                BookDetailCoverArtwork(
                    item: currentItem,
                    height: 165,
                    cornerRadius: 10,
                    progress: animatedProgress,
                    progressBackgroundColor: coverPalette.accentBackground,
                )
                .tint(coverPalette.accent)

                VStack(spacing: 5) {
                    Text(currentItem.title)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    if let subtitle = currentItem.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(heroColors.secondary.opacity(0.84))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }

                    macCreatorSummary
                    macSeriesSummary
                    BookDetailRatingView(rating: currentItem.rating)
                        .padding(.top, 2)

                    if let mediaSummary = macHeroMediaSummary {
                        Text(mediaSummary)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(heroColors.secondary)
                            .padding(.top, 2)
                    }
                }

                let options = MediaGridViewUtilities.mediaDownloadOptions(for: currentItem)
                if formatMembers.count > 1 {
                    formatMemberControls
                } else if !options.isEmpty {
                    MacBookDetailMediaControls(item: currentItem, presentation: .hero)
                }
                formatLinkButton
                findAudiobookButton
                requestBookButton
                manualSearchButton
                BookRequestStatusIndicator(book: currentItem)
                formatAlignmentNote

                let tags = currentItem.tagNames
                if !tags.isEmpty {
                    MacBookDetailTagDisclosure(tags: tags)
                        .padding(.top, 2)
                }
            }
            .foregroundStyle(heroColors.primary)
            .padding(.horizontal, 16)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 16,
                topTrailingRadius: roundsTopTrailingCorner ? 16 : 0,
                style: .continuous,
            )
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.bookDetailHeroColors, heroColors)
    }

    private var macHeroMediaSummary: String? {
        var values: [String] = []
        if let pages = currentItem.pageCountValue, pages > 0 {
            values.append("\(pages) \(pages == 1 ? "page" : "pages")")
        }
        let duration = currentItem.durationDisplay
        if !duration.isEmpty {
            values.append(duration)
        }
        return values.isEmpty ? nil : values.joined(separator: " • ")
    }

    private var macInspectorToolbar: some View {
        HStack(spacing: 8) {
            if relatedItemOverride != nil {
                Button {
                    relatedItemOverride = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to previous book")
            }

            Spacer()
            BookStatusSection(item: currentItem, presentation: .toolbarMenu)
                .tint(coverPalette.accent)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(heroColors.controlFill, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close details")
        }
        .padding(.top, 10)
    }

    @ViewBuilder
    private var macCreatorSummary: some View {
        let authorNames = currentItem.authors?.compactMap(\.name) ?? []
        let narratorNames = currentItem.narrators?.compactMap(\.name) ?? []

        if !authorNames.isEmpty || !narratorNames.isEmpty {
            VStack(spacing: 2) {
                if !authorNames.isEmpty {
                    (Text("Written by ")
                        .foregroundStyle(heroColors.secondary)
                        + Text(authorNames.joined(separator: ", "))
                        .foregroundStyle(heroColors.primary.opacity(0.88)))
                        .lineLimit(isAuthorSummaryExpanded ? nil : 1)
                        .textSelection(.enabled)
                        .padding(.trailing, shouldShowAuthorDisclosure ? 18 : 0)
                        .overlay(alignment: .topTrailing) {
                            if shouldShowAuthorDisclosure {
                                creatorDisclosureButton(
                                    isExpanded: $isAuthorSummaryExpanded,
                                    role: "authors",
                                )
                            }
                        }
                }
                if !narratorNames.isEmpty {
                    (Text("Narrated by ")
                        .foregroundStyle(heroColors.secondary)
                        + Text(narratorNames.joined(separator: ", "))
                        .foregroundStyle(heroColors.primary.opacity(0.88)))
                        .lineLimit(isNarratorSummaryExpanded ? nil : 1)
                        .textSelection(.enabled)
                        .padding(.trailing, shouldShowNarratorDisclosure ? 18 : 0)
                        .overlay(alignment: .topTrailing) {
                            if shouldShowNarratorDisclosure {
                                creatorDisclosureButton(
                                    isExpanded: $isNarratorSummaryExpanded,
                                    role: "narrators",
                                )
                            }
                        }
                }
            }
            .font(.callout)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shouldShowAuthorDisclosure: Bool {
        let authorNames = currentItem.authors?.compactMap(\.name) ?? []
        return authorNames.count > 2 || authorNames.joined(separator: ", ").count > 72
    }

    private var shouldShowNarratorDisclosure: Bool {
        let narratorNames = currentItem.narrators?.compactMap(\.name) ?? []
        return narratorNames.count > 2 || narratorNames.joined(separator: ", ").count > 72
    }

    private func creatorDisclosureButton(
        isExpanded: Binding<Bool>,
        role: String,
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .rotationEffect(.degrees(isExpanded.wrappedValue ? 180 : 0))
                .frame(width: 16, height: 20)
                .offset(y: -2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(heroColors.secondary)
        .help(isExpanded.wrappedValue ? "Show fewer \(role)" : "Show all \(role)")
        .accessibilityLabel(isExpanded.wrappedValue ? "Collapse \(role)" : "Expand \(role)")
    }

    @ViewBuilder
    private var macSeriesSummary: some View {
        if let seriesList = currentItem.series, !seriesList.isEmpty {
            VStack(spacing: 3) {
                ForEach(seriesList, id: \.name) { series in
                    let label =
                        series.formattedPosition.map {
                            "\(series.name) • Book \($0)"
                        } ?? series.name

                    if let onSeriesSelected {
                        Button(label) {
                            onSeriesSelected(series.name)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(label)
                            .textSelection(.enabled)
                    }
                }
            }
            .font(.callout)
            .foregroundStyle(heroColors.primary.opacity(0.86))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var relatedBooksSections: some View {
        let series = relatedSeriesBooks
        if !series.isEmpty {
            MacBookDetailRelatedShelf(
                title: relatedSeriesTitle,
                systemImage: "books.vertical.fill",
                section: .relatedSeries,
                books: series,
                onSelect: { relatedItemOverride = $0 },
                seriesName: currentItem.series?.first?.name,
            )
        }

        let authors = relatedAuthorBooks
        if !authors.isEmpty {
            MacBookDetailRelatedShelf(
                title: relatedAuthorTitle,
                systemImage: "person.2.fill",
                section: .relatedAuthor,
                books: authors,
                onSelect: { relatedItemOverride = $0 },
            )
        }
    }

    private var macBookInfoSection: some View {
        BookDetailDisclosureCard("Book Info", systemImage: "info.circle", section: .bookInfo) {
            BookDetailMetadataRows(
                item: currentItem,
                showsTags: false,
                showsAggregateMediaValues: false,
                showsCollections: false,
            )
        }
    }

    private var macMediaInfoSection: some View {
        BookDetailDisclosureCard(
            "Media Info",
            systemImage: "rectangle.stack.fill",
            section: .mediaInfo,
        ) {
            MacBookDetailMediaControls(item: currentItem, presentation: .details)
        }
    }

    private var macSyncHistorySection: some View {
        BookDetailDisclosureCard(
            "Sync History",
            systemImage: "clock.arrow.circlepath",
            section: .syncHistory,
        ) {
            syncHistoryButton
        }
    }

    private var relatedSeriesTitle: String {
        guard let name = currentItem.series?.first?.name, !name.isEmpty else {
            return "Other Books in This Series"
        }
        return "More in \(name) series"
    }

    private var relatedAuthorTitle: String {
        guard let name = currentItem.authors?.first?.name, !name.isEmpty else {
            return "More by This Author"
        }
        return "More by \(name)"
    }

    private var relatedSeriesBooks: [BookMetadata] {
        guard let series = currentItem.series?.first else { return [] }
        let normalizedName = series.name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedName.isEmpty else { return [] }

        let group = mediaViewModel.booksBySeries(for: mediaKind ?? .ebook).first { group in
            group.series?.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == normalizedName
        }
        return Array(
            (group?.books ?? [])
                .filter { $0.id != currentItem.id }
                .prefix(12)
        )
    }

    private var relatedAuthorBooks: [BookMetadata] {
        guard let author = currentItem.authors?.first else { return [] }
        let seriesBookIDs = Set(relatedSeriesBooks.map(\.id))
        let normalizedName = author.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let normalizedName, !normalizedName.isEmpty else { return [] }

        let group = mediaViewModel.booksByAuthor(for: mediaKind ?? .ebook).first { group in
            if let authorID = author.uuid, let groupID = group.author?.uuid {
                return authorID == groupID
            }
            return group.author?.name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                == normalizedName
        }
        return Array(
            (group?.books ?? [])
                .filter { $0.id != currentItem.id && !seriesBookIDs.contains($0.id) }
                .prefix(12)
        )
    }
    #endif

    #if os(iOS)
    private var iosHeroSection: some View {
        ZStack {
            BookDetailHeroBackground(
                item: currentItem,
                palette: $coverPalette,
                surfaceColor: resolvedPalette.surface,
                contentBackground: resolvedPalette.contentBackground,
            )

            VStack(spacing: 13) {
                if showsInspectorToolbar || relatedItemOverride != nil {
                    HStack(spacing: 8) {
                        if relatedItemOverride != nil {
                            Button {
                                relatedItemOverride = nil
                            } label: {
                                Image(systemName: "chevron.left")
                                    .frame(width: 32, height: 32)
                                    .background(heroColors.controlFill, in: Circle())
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                        if showsInspectorToolbar {
                            Button(action: onClose) {
                                Image(systemName: "xmark")
                                    .frame(width: 32, height: 32)
                                    .background(heroColors.controlFill, in: Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                BookDetailCoverArtwork(
                    item: currentItem,
                    height: showsInspectorToolbar ? 180 : 230,
                    cornerRadius: 12,
                    progress: animatedProgress,
                    progressBackgroundColor: coverPalette.accentBackground,
                )
                .tint(coverPalette.accent)

                VStack(spacing: 5) {
                    Text(currentItem.title)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    if let subtitle = currentItem.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.headline)
                            .foregroundStyle(heroColors.secondary.opacity(0.84))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    BookDetailCreatorSummary(
                        authors: currentItem.authors?.compactMap(\.name) ?? [],
                        narrators: currentItem.narrators?.compactMap(\.name) ?? [],
                        labelColor: heroColors.secondary,
                        nameColor: heroColors.primary.opacity(0.9),
                    )
                    iosHeroSeriesSummary
                    BookDetailRatingView(rating: currentItem.rating)
                        .padding(.top, 2)

                    if let mediaSummary = iosHeroMediaSummary {
                        Text(mediaSummary)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(heroColors.secondary)
                            .padding(.top, 2)
                    }
                }

                if formatMembers.count > 1 {
                    iosFormatMemberControls
                } else if !MediaGridViewUtilities.mediaDownloadOptions(for: currentItem).isEmpty {
                    iOSBookDetailCompactMediaControls(item: currentItem)
                }
                formatLinkButton
                findAudiobookButton
                requestBookButton
                manualSearchButton
                BookRequestStatusIndicator(book: currentItem)
                formatAlignmentNote

                if !currentItem.tagNames.isEmpty {
                    BookDetailTagDisclosure(tags: currentItem.tagNames)
                        .padding(.top, 2)
                }
            }
            .foregroundStyle(heroColors.primary)
            .padding(.horizontal, 20)
            .padding(.top, showsInspectorToolbar ? 12 : 96)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: showsInspectorToolbar ? 16 : 0,
                bottomLeadingRadius: 16,
                bottomTrailingRadius: 16,
                topTrailingRadius: showsInspectorToolbar ? 16 : 0,
                style: .continuous,
            )
        )
        .environment(\.bookDetailHeroColors, heroColors)
    }

    private var iosHeroMediaSummary: String? {
        var values: [String] = []
        if let pages = currentItem.pageCountValue, pages > 0 {
            values.append("\(pages) \(pages == 1 ? "page" : "pages")")
        }
        let duration = currentItem.durationDisplay
        if !duration.isEmpty { values.append(duration) }
        return values.isEmpty ? nil : values.joined(separator: " • ")
    }

    @ViewBuilder
    private var iosHeroSeriesSummary: some View {
        if let seriesList = currentItem.series, !seriesList.isEmpty {
            VStack(spacing: 3) {
                ForEach(seriesList, id: \.name) { series in
                    let label =
                        series.formattedPosition.map {
                            "\(series.name) • Book \($0)"
                        } ?? series.name
                    if let onSeriesSelected {
                        Button(label) { onSeriesSelected(series.name) }
                            .buttonStyle(.plain)
                    } else {
                        NavigationLink(value: SeriesNavIdentifier(name: series.name)) {
                            Text(label)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .font(.callout)
            .foregroundStyle(heroColors.primary.opacity(0.86))
            .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var iosMoreLikeThisSection: some View {
        let recommendations = LocalBookRecommendations.recommendations(
            for: currentItem,
            in: mediaViewModel.library.bookMetaData,
        ).filter { book in
            !formatMembers.contains(where: { $0.id == book.id })
        }
        if !recommendations.isEmpty {
            BookDetailRelatedShelf(
                title: "More like this",
                systemImage: "sparkles",
                section: .moreLikeThis,
                books: recommendations,
                onSelect: { relatedItemOverride = $0 },
                seriesName: currentItem.series?.first?.name,
            )
        }
    }
    #endif

    private var syncHistoryButton: some View {
        Button {
            showingSyncHistory = true
        } label: {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                Text("View Sync History")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var descriptionSection: some View {
        if currentItem.description?.isEmpty == false {
            BookDetailDisclosureCard(
                "Description",
                systemImage: "text.alignleft",
                section: .description,
            ) {
                descriptionContent
            }
        }
    }

    #if os(iOS)
    private var iosBookInfoSection: some View {
        BookDetailDisclosureCard("Book Info", systemImage: "info.circle", section: .bookInfo) {
            BookDetailMetadataRows(
                item: currentItem,
                showsTags: true,
                showsAggregateMediaValues: false,
            )
        }
    }

    private var iosMediaInfoSection: some View {
        BookDetailDisclosureCard(
            "Media Info",
            systemImage: "rectangle.stack.fill",
            section: .mediaInfo,
        ) {
            BookDetailMediaInfoRows(item: currentItem)
        }
    }

    private var iosSyncHistorySection: some View {
        BookDetailDisclosureCard(
            "Sync History",
            systemImage: "clock.arrow.circlepath",
            section: .syncHistory,
        ) {
            syncHistoryButton
        }
    }
    #endif

    @ViewBuilder
    private var descriptionContent: some View {
        if let attributedDescription {
            VStack(alignment: .leading, spacing: 10) {
                Text(attributedDescription)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(isDescriptionExpanded ? nil : 8)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if (currentItem.description?.count ?? 0) > 280 {
                    Button(isDescriptionExpanded ? "Show Less" : "Show More") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isDescriptionExpanded.toggle()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.tint)
                }
            }
        } else {
            Text("Loading description...")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private func prepareForDisplay() {
        animatedProgress = 0
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.45)) {
                self.animatedProgress = self.mediaViewModel.progress(for: self.currentItem.id)
            }
        }
    }

    private func loadDescription() {
        descriptionTask?.cancel()
        descriptionTask = nil
        attributedDescription = nil
        isDescriptionExpanded = false

        guard let description = currentItem.description, !description.isEmpty else { return }
        let itemID = currentItem.id
        let html = description

        descriptionTask = Task.detached(priority: .userInitiated) { [html, itemID] in
            let parsed = BookDescriptionText.attributed(from: html)
            await MainActor.run {
                guard !Task.isCancelled, itemID == self.currentItem.id else {
                    self.descriptionTask = nil
                    return
                }
                self.attributedDescription = parsed
                self.descriptionTask = nil
            }
        }
    }

    private var formatMembers: [BookMetadata] {
        mediaViewModel.formatGroupMembers(for: currentItem)
    }

    private var formatAlignment: ReadaloudAlignment {
        let assessed = BookFormatAlignment.assess(formatMembers)
        guard let alignmentOverride else { return assessed }
        // A successful retry returns 204 before the book record leaves ERROR.
        // Keep that queued note only until Storyteller reports a real status.
        if assessed.phase == .failed || assessed.phase == .unavailable {
            return alignmentOverride
        }
        return assessed
    }

    private var formatErrorPresented: Binding<Bool> {
        Binding(
            get: { formatActionError != nil },
            set: { if !$0 { formatActionError = nil } },
        )
    }

    private var formatGroupHasAudiobook: Bool {
        formatMembers.contains { book in
            guard let audiobook = book.audiobook else { return false }
            return !audiobook.isMissing
        }
    }

    @ViewBuilder
    private var findAudiobookButton: some View {
        if !formatGroupHasAudiobook {
            Button {
                showingAudiobookOptions = true
            } label: {
                Label("Find audiobook options", systemImage: "headphones")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("find-audiobook-options")
            .accessibilityHint("Searches audiobook providers for this book only after you tap.")
        }
    }

    @ViewBuilder
    private var requestBookButton: some View {
        Button {
            showingBookRequest = true
        } label: {
            Label("Request", systemImage: "paperplane")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Asks LazyLibrarian or Shelfarr to search for this book.")
    }

    @ViewBuilder
    private var manualSearchButton: some View {
        Button {
            showingManualSearch = true
        } label: {
            Label("Search manually", systemImage: "globe")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("search-manually")
        .accessibilityHint("Search websites yourself when automatic tools cannot find this book.")
    }

    @ViewBuilder
    private var formatLinkButton: some View {
        if mediaViewModel.isServerBook(currentItem.id) {
            Button {
                showingFormatLink = true
            } label: {
                Label("Manage book formats", systemImage: "link")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
            .accessibilityHint(
                "Link an e-book and audiobook that are the same book. Neither file is deleted."
            )
        }
    }

    @ViewBuilder
    private var formatAlignmentNote: some View {
        let showNote =
            formatMembers.count > 1
            || formatAlignment.phase == .queued
            || formatAlignment.phase == .processing
            || formatAlignment.phase == .failed
        if showNote {
            VStack(spacing: 8) {
                Text(formatAlignment.message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(formatAlignment.message)
                if formatAlignment.canRetry {
                    Button("Retry Readaloud") {
                        Task { await retryReadaloud() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityHint("Asks Storyteller to queue alignment again. The book is not ready until Storyteller says so.")
                }
            }
        }
    }

    #if os(iOS)
    private var iosFormatMemberControls: some View {
        HStack(spacing: 8) {
            ForEach(formatControlPairs(), id: \.id) { pair in
                CompactMediaButton(item: pair.book, option: pair.option)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private struct FormatControlPair: Identifiable {
        let book: BookMetadata
        let option: MediaDownloadOption
        var id: String { "\(book.id.description)|\(option.id)" }
    }

    private func formatControlPairs() -> [FormatControlPair] {
        let booksByID = Dictionary(formatMembers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return BookFormatGrouping.playbackActions(for: formatMembers).compactMap { action in
            guard let book = booksByID[action.bookID] else { return nil }
            return FormatControlPair(book: book, option: option(for: action.kind))
        }
    }

    private func option(for kind: BookFormatPlaybackKind) -> MediaDownloadOption {
        switch kind {
            case .read:
                MediaDownloadOption(
                    category: .ebook,
                    title: kind.title,
                    openTitle: kind.title,
                    iconName: "book.fill",
                )
            case .listen:
                MediaDownloadOption(
                    category: .audio,
                    title: kind.title,
                    openTitle: kind.title,
                    iconName: "headphones",
                )
            case .readAndListen:
                MediaDownloadOption(
                    category: .synced,
                    title: kind.title,
                    openTitle: kind.title,
                    iconName: "readalong",
                    iconType: .readaloud,
                )
        }
    }
    #endif

    #if os(macOS)
    private var formatMemberControls: some View {
        VStack(spacing: 8) {
            ForEach(formatMembers) { member in
                MacBookDetailMediaControls(item: member, presentation: .hero)
            }
        }
    }
    #endif

    private func retryReadaloud() async {
        let outcome = await mediaViewModel.retryFormatReadaloud(for: currentItem)
        switch outcome {
            case .alignment(let alignment):
                alignmentOverride = alignment
                formatActionError = nil
            case .failed(let failure):
                formatActionError = failure.message(action: .retry)
            case .linked, .unlinked:
                formatActionError = nil
        }
    }

}

#if os(macOS)
private struct MacBookDetailScrollViewConfiguration: NSViewRepresentable {
    func makeNSView(context: Context) -> MacBookDetailScrollViewConfigurationView {
        MacBookDetailScrollViewConfigurationView()
    }

    func updateNSView(
        _ nsView: MacBookDetailScrollViewConfigurationView,
        context: Context,
    ) {
        nsView.applyConfiguration()
    }
}

private final class MacBookDetailScrollViewConfigurationView: NSView {
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyConfiguration()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyConfiguration()
    }

    func applyConfiguration() {
        DispatchQueue.main.async { [weak self] in
            var ancestor: NSView? = self
            while let current = ancestor {
                if let scrollView = current as? NSScrollView {
                    scrollView.scrollerStyle = .overlay
                    scrollView.hasVerticalScroller = true
                    return
                }
                ancestor = current.superview
            }
        }
    }
}
#endif

#endif
