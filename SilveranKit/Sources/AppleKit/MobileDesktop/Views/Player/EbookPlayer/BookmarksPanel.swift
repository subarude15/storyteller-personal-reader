#if os(iOS) || os(macOS)
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@available(macOS 14.0, iOS 17.0, *)
struct BookmarksPanel: View {
    let bookmarks: [Highlight]
    let highlights: [Highlight]
    let bookTitle: String?
    let bookAuthor: String?
    let onNavigate: (Highlight) -> Void
    let onDelete: (Highlight) -> Void
    let onAddBookmark: () -> Void
    let onEdit: ((Highlight) -> Void)?
    let onChangeColor: ((Highlight, HighlightColor) -> Void)?
    let highlightColorResolver: (HighlightColor?) -> Color

    @State private var selectedTab: Tab = .bookmarks
    @State private var selectedHighlightID: UUID?
    @State private var searchText: String = ""
    @State private var selectedColorFilter: HighlightColor?
    @State private var onlyWithNotes: Bool = false

    init(
        bookmarks: [Highlight],
        highlights: [Highlight],
        bookTitle: String? = nil,
        bookAuthor: String? = nil,
        onDismiss _: @escaping () -> Void,
        onNavigate: @escaping (Highlight) -> Void,
        onDelete: @escaping (Highlight) -> Void,
        onAddBookmark: @escaping () -> Void,
        onEdit: ((Highlight) -> Void)? = nil,
        onChangeColor: ((Highlight, HighlightColor) -> Void)? = nil,
        highlightColorResolver: @escaping (HighlightColor?) -> Color,
        initialTab: Tab = .bookmarks,
    ) {
        self.bookmarks = bookmarks
        self.highlights = highlights
        self.bookTitle = bookTitle
        self.bookAuthor = bookAuthor
        self.onNavigate = onNavigate
        self.onDelete = onDelete
        self.onAddBookmark = onAddBookmark
        self.onEdit = onEdit
        self.onChangeColor = onChangeColor
        self.highlightColorResolver = highlightColorResolver
        self._selectedTab = State(initialValue: initialTab)
    }

    enum Tab: String, CaseIterable {
        case bookmarks = "Bookmarks"
        case highlights = "Highlights"
    }

    private var selectedHighlight: Highlight? {
        guard let selectedHighlightID else { return nil }
        return (highlights + bookmarks).first { $0.id == selectedHighlightID }
    }

    private var filteredBookmarks: [Highlight] {
        HighlightExportPolicy.filterBookmarks(bookmarks, searchText: searchText)
    }

    private var filteredHighlights: [Highlight] {
        HighlightExportPolicy.filterHighlights(
            highlights,
            searchText: searchText,
            selectedColor: selectedColorFilter,
            onlyWithNotes: onlyWithNotes
        )
    }

    private var availableColors: [HighlightColor] {
        HighlightExportPolicy.availableColors(in: highlights)
    }

    private var hasAnyNotes: Bool {
        highlights.contains {
            guard let note = $0.note?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return !note.isEmpty
        }
    }

    private var notebookMarkdown: String {
        HighlightExportPolicy.markdownNotebook(
            bookTitle: bookTitle,
            author: bookAuthor,
            highlights: highlights,
            bookmarks: bookmarks
        )
    }

    private var emptyStateDescription: String {
        #if os(iOS)
        selectedTab == .bookmarks
            ? "Tap the button below to bookmark the current page"
            : "Long-press on text to create a highlight"
        #else
        selectedTab == .bookmarks
            ? "Click the button below to bookmark the current page"
            : "Select text and right-click to create a highlight"
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            if let highlight = selectedHighlight {
                HighlightDetailView(
                    highlight: highlight,
                    bookTitle: bookTitle,
                    bookAuthor: bookAuthor,
                    highlightColorResolver: highlightColorResolver,
                    onBack: { selectedHighlightID = nil },
                    onNavigate: {
                        onNavigate(highlight)
                    },
                    onEdit: onEdit.map { editCallback in
                        { editCallback(highlight) }
                    },
                    onChangeColor: onChangeColor.map { colorCallback in
                        { newColor in
                            ReaderHaptics.selectionTick()
                            colorCallback(highlight, newColor)
                        }
                    },
                    onDelete: {
                        onDelete(highlight)
                        selectedHighlightID = nil
                    },
                )
            } else {
                tabPicker
                Divider()
                if !bookmarks.isEmpty || !highlights.isEmpty {
                    searchAndFilterBar
                    Divider()
                }
                content
            }
        }
        #if os(macOS)
        .frame(width: 360, height: 480)
        #endif
    }

    private var tabPicker: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button {
                    ReaderHaptics.selectionTick()
                    selectedTab = tab
                } label: {
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            Text(tab.rawValue)
                                .font(.subheadline)
                                .fontWeight(selectedTab == tab ? .semibold : .regular)

                            let count = tab == .bookmarks ? bookmarks.count : highlights.count
                            if count > 0 {
                                Text("\(count)")
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(
                                        Capsule()
                                            .fill(
                                                selectedTab == tab
                                                    ? Color.accentColor
                                                    : Color.secondary.opacity(0.3)
                                            )
                                    )
                                    .foregroundStyle(selectedTab == tab ? .white : .secondary)
                            }
                        }
                        .foregroundStyle(selectedTab == tab ? .primary : .secondary)

                        Rectangle()
                            .fill(selectedTab == tab ? Color.accentColor : Color.clear)
                            .frame(height: 2)
                    }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
    }

    private var searchAndFilterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField(
                        selectedTab == .bookmarks
                            ? "Filter bookmarks..."
                            : "Search highlights & notes...",
                        text: $searchText
                    )
                    .textFieldStyle(.plain)
                    .font(.subheadline)

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.12))
                )

                ShareLink(
                    item: notebookMarkdown,
                    subject: Text(bookTitle ?? "Reading Notebook")
                ) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.subheadline)
                        .padding(7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.secondary.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
                .help("Export Notes & Highlights as Markdown")
            }

            if selectedTab == .highlights && (availableColors.count > 1 || hasAnyNotes) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        filterChip(
                            label: "All",
                            isSelected: selectedColorFilter == nil && !onlyWithNotes
                        ) {
                            ReaderHaptics.selectionTick()
                            selectedColorFilter = nil
                            onlyWithNotes = false
                        }

                        if hasAnyNotes {
                            filterChip(
                                label: "Notes",
                                systemImage: "note.text",
                                isSelected: onlyWithNotes
                            ) {
                                ReaderHaptics.selectionTick()
                                onlyWithNotes.toggle()
                            }
                        }

                        ForEach(availableColors, id: \.self) { color in
                            Button {
                                ReaderHaptics.selectionTick()
                                if selectedColorFilter == color {
                                    selectedColorFilter = nil
                                } else {
                                    selectedColorFilter = color
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(highlightColorResolver(color))
                                        .frame(width: 10, height: 10)
                                    Text(color.rawValue.capitalized)
                                        .font(.caption2.weight(.medium))
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(
                                            selectedColorFilter == color
                                                ? Color.accentColor.opacity(0.18)
                                                : Color.secondary.opacity(0.1)
                                        )
                                )
                                .overlay(
                                    Capsule()
                                        .strokeBorder(
                                            selectedColorFilter == color
                                                ? Color.accentColor
                                                : Color.clear,
                                            lineWidth: 1
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func filterChip(
        label: String,
        systemImage: String? = nil,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption2)
                }
                Text(label)
                    .font(.caption2.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(
                        isSelected
                            ? Color.accentColor
                            : Color.secondary.opacity(0.12)
                    )
            )
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
            case .bookmarks:
                bookmarksContent
            case .highlights:
                highlightsContent
        }
    }

    @ViewBuilder
    private var bookmarksContent: some View {
        if bookmarks.isEmpty {
            VStack(spacing: 16) {
                ContentUnavailableView(
                    "No Bookmarks",
                    systemImage: "bookmark",
                    description: Text(emptyStateDescription),
                )

                Button {
                    onAddBookmark()
                } label: {
                    Label("Bookmark Current Page", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredBookmarks.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                Section {
                    Button {
                        onAddBookmark()
                    } label: {
                        Label("Bookmark Current Page", systemImage: "plus")
                            .foregroundStyle(Color.accentColor)
                    }
                }

                Section {
                    ForEach(filteredBookmarks) { bookmark in
                        BookmarkRow(
                            highlight: bookmark,
                            bookTitle: bookTitle,
                            bookAuthor: bookAuthor,
                            onTap: { selectedHighlightID = bookmark.id },
                            onNavigate: { onNavigate(bookmark) },
                            onEdit: onEdit.map { editCallback in
                                { editCallback(bookmark) }
                            },
                            onDelete: { onDelete(bookmark) },
                        )
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                onNavigate(bookmark)
                            } label: {
                                Label("Go", systemImage: "arrow.right.circle")
                            }
                            .tint(.accentColor)

                            if let onEdit {
                                Button {
                                    onEdit(bookmark)
                                } label: {
                                    Label("Note", systemImage: "square.and.pencil")
                                }
                                .tint(.orange)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                onDelete(bookmark)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
        }
    }

    @ViewBuilder
    private var highlightsContent: some View {
        if highlights.isEmpty {
            VStack {
                ContentUnavailableView(
                    "No Highlights",
                    systemImage: "highlighter",
                    description: Text(emptyStateDescription),
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredHighlights.isEmpty {
            VStack(spacing: 12) {
                ContentUnavailableView(
                    "No Matching Highlights",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Try clearing your search or color filter.")
                )
                Button("Reset Filters") {
                    searchText = ""
                    selectedColorFilter = nil
                    onlyWithNotes = false
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(filteredHighlights) { highlight in
                    HighlightRow(
                        highlight: highlight,
                        bookTitle: bookTitle,
                        bookAuthor: bookAuthor,
                        highlightColorResolver: highlightColorResolver,
                        onTap: { selectedHighlightID = highlight.id },
                        onNavigate: { onNavigate(highlight) },
                        onEdit: onEdit.map { editCallback in
                            { editCallback(highlight) }
                        },
                        onDelete: { onDelete(highlight) },
                    )
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            onNavigate(highlight)
                        } label: {
                            Label("Go", systemImage: "arrow.right.circle")
                        }
                        .tint(.accentColor)

                        if let onEdit {
                            Button {
                                onEdit(highlight)
                            } label: {
                                Label("Edit", systemImage: "square.and.pencil")
                            }
                            .tint(.orange)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            onDelete(highlight)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
        }
    }
}

@available(macOS 14.0, iOS 17.0, *)
private struct BookmarkRow: View {
    let highlight: Highlight
    let bookTitle: String?
    let bookAuthor: String?
    let onTap: () -> Void
    let onNavigate: () -> Void
    let onEdit: (() -> Void)?
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    Image(systemName: "bookmark.fill")
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 4) {
                        if let chapter = highlight.chapterTitle {
                            Text(chapter)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            if !highlight.displayText.isEmpty {
                                Text(highlight.displayText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        } else {
                            Text(highlight.displayText)
                                .font(.subheadline)
                                .lineLimit(2)
                        }

                        if let note = highlight.note, !note.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "note.text")
                                    .font(.caption2)
                                Text(note)
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 6) {
                            if let percent = HighlightExportPolicy.progressPercentText(for: highlight) {
                                Text(percent)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            Text(highlight.createdAt, style: .date)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onNavigate) {
                Image(systemName: "arrow.right.circle")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Go to bookmark")
        }
        .contextMenu {
            Button(action: onNavigate) {
                Label("Go to Bookmark", systemImage: "arrow.right.circle")
            }
            if let onEdit {
                Button(action: onEdit) {
                    Label("Edit Note", systemImage: "square.and.pencil")
                }
            }
            Button {
                copyToClipboard(
                    HighlightExportPolicy.markdownQuote(
                        for: highlight,
                        bookTitle: bookTitle,
                        author: bookAuthor
                    )
                )
            } label: {
                Label("Copy Quote", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

@available(macOS 14.0, iOS 17.0, *)
private struct HighlightRow: View {
    let highlight: Highlight
    let bookTitle: String?
    let bookAuthor: String?
    let highlightColorResolver: (HighlightColor?) -> Color
    let onTap: () -> Void
    let onNavigate: () -> Void
    let onEdit: (() -> Void)?
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(highlightColorResolver(highlight.color))
                        .frame(width: 6)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(highlight.displayText)
                            .font(.subheadline)
                            .lineLimit(2)

                        if let note = highlight.note, !note.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "note.text")
                                    .font(.caption2)
                                Text(note)
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 6) {
                            if let chapter = highlight.chapterTitle {
                                Text(chapter)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            if let percent = HighlightExportPolicy.progressPercentText(for: highlight) {
                                Text(percent)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }

                            Text(highlight.createdAt, style: .date)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onNavigate) {
                Image(systemName: "arrow.right.circle")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Go to highlight")
        }
        .contextMenu {
            Button(action: onNavigate) {
                Label("Go to Highlight", systemImage: "arrow.right.circle")
            }
            if let onEdit {
                Button(action: onEdit) {
                    Label("Edit Highlight & Note", systemImage: "square.and.pencil")
                }
            }
            Button {
                copyToClipboard(
                    HighlightExportPolicy.markdownQuote(
                        for: highlight,
                        bookTitle: bookTitle,
                        author: bookAuthor
                    )
                )
            } label: {
                Label("Copy Quote", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

@available(macOS 14.0, iOS 17.0, *)
private struct HighlightDetailView: View {
    let highlight: Highlight
    let bookTitle: String?
    let bookAuthor: String?
    let highlightColorResolver: (HighlightColor?) -> Color
    let onBack: () -> Void
    let onNavigate: () -> Void
    let onEdit: (() -> Void)?
    let onChangeColor: ((HighlightColor) -> Void)?
    let onDelete: () -> Void

    @State private var didCopyQuote = false

    private var formattedQuote: String {
        HighlightExportPolicy.markdownQuote(
            for: highlight,
            bookTitle: bookTitle,
            author: bookAuthor
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    copyToClipboard(formattedQuote)
                    ReaderHaptics.selectionTick()
                    withAnimation {
                        didCopyQuote = true
                    }
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.5))
                        withAnimation {
                            didCopyQuote = false
                        }
                    }
                } label: {
                    Image(systemName: didCopyQuote ? "checkmark.circle.fill" : "doc.on.doc")
                        .foregroundStyle(didCopyQuote ? .green : .primary)
                }
                .buttonStyle(.plain)
                .help("Copy Quote")

                ShareLink(item: formattedQuote) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .help("Share Quote")

                if let onEdit {
                    Button(action: onEdit) {
                        Image(systemName: "square.and.pencil")
                    }
                    .buttonStyle(.plain)
                    .help("Edit Highlight & Note")
                }

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Delete")
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(highlightColorResolver(highlight.color))
                            .frame(width: 6)

                        Text(highlight.text)
                            .font(.body)
                            .textSelection(.enabled)
                    }

                    if let onChangeColor {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Highlight Color")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)

                            HStack(spacing: 12) {
                                ForEach(HighlightColor.allCases, id: \.self) { color in
                                    Button {
                                        onChangeColor(color)
                                    } label: {
                                        Circle()
                                            .fill(highlightColorResolver(color))
                                            .frame(width: 28, height: 28)
                                            .overlay {
                                                if highlight.color == color {
                                                    Image(systemName: "checkmark")
                                                        .font(.caption2.weight(.bold))
                                                        .foregroundStyle(.primary)
                                                }
                                            }
                                            .overlay {
                                                Circle()
                                                    .strokeBorder(
                                                        highlight.color == color
                                                            ? Color.primary : Color.clear,
                                                        lineWidth: 2
                                                    )
                                            }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    if let note = highlight.note, !note.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Note")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                Spacer()
                                if let onEdit {
                                    Button("Edit", action: onEdit)
                                        .font(.caption.weight(.medium))
                                }
                            }

                            Text(note)
                                .font(.subheadline)
                                .textSelection(.enabled)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(8)
                    } else if let onEdit {
                        Button(action: onEdit) {
                            Label("Add a Note...", systemImage: "square.and.pencil")
                                .font(.subheadline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color.secondary.opacity(0.08))
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: 8) {
                        if let chapter = highlight.chapterTitle {
                            Text(chapter)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let percent = HighlightExportPolicy.progressPercentText(for: highlight) {
                            Text(percent)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }

                        Text(highlight.createdAt, style: .date)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding()
            }

            Divider()

            Button(action: onNavigate) {
                Label(
                    highlight.isBookmark ? "Go to Bookmark" : "Go to Highlight",
                    systemImage: "arrow.right.circle"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
    }
}

private func copyToClipboard(_ text: String) {
    #if os(iOS)
    UIPasteboard.general.string = text
    #elseif os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}

#endif
