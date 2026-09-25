#if os(macOS)
import SwiftUI
import AppKit

private let tableTrailingPadding: CGFloat = 12

private final class ImmediateSelectTableView: NSTableView {
    var onRowDoubleClicked: ((Int) -> Void)?
    var onLinkClicked: ((MetadataLinkTarget) -> Void)?
    var onQuickEditCell: ((Int, String) -> Void)?
    fileprivate var isFitting = false
    fileprivate var suppressColumnWidthPersistence = false
    fileprivate var activeIdealWidths: [String: CGFloat] = [:]
    private var lastClipWidth: CGFloat = 0

    private func columnTargetWidth() -> CGFloat? {
        guard let clipView = enclosingScrollView?.contentView else { return nil }
        let availableWidth = clipView.bounds.width
        guard availableWidth > 0 else { return nil }
        let visibleColumns = tableColumns.filter { !$0.isHidden }
        guard !visibleColumns.isEmpty else { return nil }
        let spacingTotal = intercellSpacing.width * CGFloat(max(visibleColumns.count - 1, 0))
        return max(availableWidth - spacingTotal - tableTrailingPadding, 0)
    }

    fileprivate func fitDocumentWidthToClipView() {
        guard let clipView = enclosingScrollView?.contentView else { return }
        let width = clipView.bounds.width
        guard width > 0, abs(frame.width - width) > 0.5 else { return }
        setFrameSize(NSSize(width: width, height: frame.height))
    }

    fileprivate func applyIdealWidthsAndTile() {
        suppressColumnWidthPersistence = true
        defer { suppressColumnWidthPersistence = false }

        fitDocumentWidthToClipView()
        if !activeIdealWidths.isEmpty {
            applyWidths(activeIdealWidths)
        }
        tile()
    }

    override func layout() {
        super.layout()
        guard let clipView = enclosingScrollView?.contentView else { return }
        let width = clipView.bounds.width
        guard width > 0, abs(width - lastClipWidth) > 0.5 else { return }
        lastClipWidth = width
        applyIdealWidthsAndTile()
    }

    override func tile() {
        super.tile()
        guard !isFitting else { return }
        guard let targetWidth = columnTargetWidth() else { return }

        let visibleColumns = tableColumns.filter { !$0.isHidden }
        guard visibleColumns.count >= 2 else { return }

        let totalWidth = visibleColumns.reduce(0) { $0 + $1.width }
        var remaining = targetWidth - totalWidth
        guard abs(remaining) > 1 else { return }

        isFitting = true
        let previousSuppression = suppressColumnWidthPersistence
        suppressColumnWidthPersistence = true
        defer {
            suppressColumnWidthPersistence = previousSuppression
            isFitting = false
        }

        for column in visibleColumns.reversed() {
            guard abs(remaining) > 0.5 else { break }
            let newWidth = column.width + remaining
            let clamped = min(max(newWidth, column.minWidth), column.maxWidth)
            let delta = clamped - column.width
            if abs(delta) > 0.1 {
                remaining -= delta
                column.width = clamped
            }
        }
    }

    fileprivate func applyWidths(_ widths: [String: CGFloat]) {
        isFitting = true
        defer { isFitting = false }

        for column in tableColumns {
            let id = column.identifier.rawValue
            if let w = widths[id] {
                column.width = min(max(w, column.minWidth), column.maxWidth)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)

        let isOptionClick =
            event.modifierFlags.contains(.option) && !event.modifierFlags.contains(.command)
        if isOptionClick, clickedRow >= 0 {
            let clickedCol = column(at: point)
            if clickedCol >= 0 {
                let colID = tableColumns[clickedCol].identifier.rawValue
                if MediaTableView.quickEditField(forColumnID: colID) != nil {
                    if window?.firstResponder !== self {
                        window?.makeFirstResponder(self)
                    }
                    selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
                    onQuickEditCell?(clickedRow, colID)
                    return
                }
            }
        }

        if clickedRow >= 0 {
            if window?.firstResponder !== self {
                window?.makeFirstResponder(self)
                selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
            }

            let isCmdClick = event.modifierFlags.contains(.command)
            let clickedCol = column(at: point)
            if clickedCol >= 0 && isCmdClick {
                let colID = tableColumns[clickedCol].identifier.rawValue
                if colID == "tags" {
                    super.mouseDown(with: event)
                    return
                }
                if let cellView = view(
                    atColumn: clickedCol,
                    row: clickedRow,
                    makeIfNecessary: false,
                ) {
                    if let linkCell = cellView as? LinkTextCellView,
                        let target = linkCell.linkTarget
                    {
                        onLinkClicked?(target)
                        super.mouseDown(with: event)
                        return
                    }
                    if let seriesCell = cellView as? SeriesCellView,
                        let target = seriesCell.linkTarget
                    {
                        onLinkClicked?(target)
                        super.mouseDown(with: event)
                        return
                    }
                    if let titleCell = cellView as? TitleAuthorCellView,
                        let target = titleCell.secondaryLinkTarget
                    {
                        let pointInCell = cellView.convert(point, from: self)
                        if titleCell.secondaryLabelContainsPoint(pointInCell) {
                            onLinkClicked?(target)
                            super.mouseDown(with: event)
                            return
                        }
                    }
                }
            }
        }

        super.mouseDown(with: event)

        if event.clickCount == 2 && clickedRow >= 0 {
            onRowDoubleClicked?(clickedRow)
        }
    }

}

struct MediaTableView: NSViewRepresentable {
    let items: [BookMetadata]
    let coverPreference: CoverPreference
    let mediaViewModel: MediaViewModel
    let tableContext: String
    let isDetailSidebarOpen: Bool
    var columnResetToken: Int = 0
    @Binding var selection: BookMetadata.ID?
    @Binding var columnCustomization: TableColumnCustomization<BookMetadata>
    @Binding var sortOrder: [KeyPathComparator<BookMetadata>]
    @Binding var creatorSortRoleCode: String?
    var enabledCreatorRoles: Set<String>
    let onSelect: (BookMetadata) -> Void
    let onInfo: (BookMetadata) -> Void
    var onMetadataLinkClicked: ((MetadataLinkTarget) -> Void)?
    var onEditMetadata: (([BookID]) -> Void)?
    var onQuickEdit: ((BookID, MetadataQuickEditField) -> Void)?
    var onManageServerMedia: ((BookID) -> Void)?
    var onCreateLocalReadaloud: ((ReadaloudGeneratorData) -> Void)?
    var onCopyBook: ((CopyBookData) -> Void)?

    init(
        items: [BookMetadata],
        coverPreference: CoverPreference,
        mediaViewModel: MediaViewModel,
        tableContext: String = "main",
        isDetailSidebarOpen: Bool = false,
        columnResetToken: Int = 0,
        selection: Binding<BookMetadata.ID?>,
        columnCustomization: Binding<TableColumnCustomization<BookMetadata>>,
        sortOrder: Binding<[KeyPathComparator<BookMetadata>]>,
        creatorSortRoleCode: Binding<String?> = .constant(nil),
        enabledCreatorRoles: Set<String> = [],
        onSelect: @escaping (BookMetadata) -> Void,
        onInfo: @escaping (BookMetadata) -> Void,
        onMetadataLinkClicked: ((MetadataLinkTarget) -> Void)? = nil,
        onEditMetadata: (([BookID]) -> Void)? = nil,
        onQuickEdit: ((BookID, MetadataQuickEditField) -> Void)? = nil,
        onManageServerMedia: ((BookID) -> Void)? = nil,
        onCreateLocalReadaloud: ((ReadaloudGeneratorData) -> Void)? = nil,
        onCopyBook: ((CopyBookData) -> Void)? = nil,
    ) {
        self.items = items
        self.coverPreference = coverPreference
        self.mediaViewModel = mediaViewModel
        self.tableContext = tableContext
        self.isDetailSidebarOpen = isDetailSidebarOpen
        self.columnResetToken = columnResetToken
        self._selection = selection
        self._columnCustomization = columnCustomization
        self._sortOrder = sortOrder
        self._creatorSortRoleCode = creatorSortRoleCode
        self.enabledCreatorRoles = enabledCreatorRoles
        self.onSelect = onSelect
        self.onInfo = onInfo
        self.onMetadataLinkClicked = onMetadataLinkClicked
        self.onEditMetadata = onEditMetadata
        self.onQuickEdit = onQuickEdit
        self.onManageServerMedia = onManageServerMedia
        self.onCreateLocalReadaloud = onCreateLocalReadaloud
        self.onCopyBook = onCopyBook
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self, mediaViewModel: mediaViewModel)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let tableView = ImmediateSelectTableView()
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 48
        tableView.usesAutomaticRowHeights = false
        tableView.intercellSpacing = NSSize(width: 8, height: 0)
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsColumnSelection = false
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.backgroundColor = .clear
        tableView.headerView = NSTableHeaderView()
        tableView.autoresizingMask = [.width]

        setupColumns(tableView: tableView, context: context)

        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator

        let menu = NSMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        context.coordinator.scrollView = scrollView

        let coordinator = context.coordinator
        tableView.onRowDoubleClicked = { [weak coordinator] row in
            coordinator?.handleRowDoubleClicked(row)
        }
        tableView.onLinkClicked = { [weak coordinator] target in
            coordinator?.handleLinkClicked(target)
        }
        tableView.onQuickEditCell = { [weak coordinator] row, columnID in
            coordinator?.handleQuickEditCell(row: row, columnID: columnID)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tableView = scrollView.documentView as? NSTableView else { return }

        let coordinator = context.coordinator
        let oldItems = coordinator.items
        let newItems = items
        let oldCoverPreference = coordinator.coverPreference
        let oldCoverHidden = coordinator.isCoverHidden

        let oldSidebarOpen = coordinator.isDetailSidebarOpen

        coordinator.parent = self
        coordinator.items = items
        coordinator.coverPreference = coverPreference
        coordinator.mediaViewModel = mediaViewModel
        coordinator.enabledCreatorRoles = enabledCreatorRoles

        let newCoverHidden = isCoverColumnHidden
        coordinator.isCoverHidden = newCoverHidden
        coordinator.isDetailSidebarOpen = isDetailSidebarOpen

        if let immediateTable = tableView as? ImmediateSelectTableView {
            immediateTable.activeIdealWidths = loadColumnWidths()
        }

        if oldSidebarOpen != isDetailSidebarOpen {
            scrollView.layoutSubtreeIfNeeded()
            if let immediateTable = tableView as? ImmediateSelectTableView {
                immediateTable.applyIdealWidthsAndTile()
            }
        }

        if coordinator.columnResetToken != columnResetToken {
            coordinator.columnResetToken = columnResetToken
            reorderColumnsToDefault(tableView: tableView)
            if let immediateTable = tableView as? ImmediateSelectTableView {
                immediateTable.activeIdealWidths = [:]
                immediateTable.applyIdealWidthsAndTile()
            }
        }

        updateColumnVisibility(tableView: tableView, coordinator: coordinator)

        let oldIDs = oldItems.map(\.id)
        let newIDs = newItems.map(\.id)

        if oldIDs != newIDs {
            tableView.reloadData()
        } else if oldCoverHidden != newCoverHidden {
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<newItems.count))
            tableView.reloadData()
        } else if oldCoverPreference != coverPreference {
            tableView.reloadData()
        } else if oldItems != newItems {
            var changedRows = IndexSet()
            for i in 0..<min(oldItems.count, newItems.count) {
                if oldItems[i] != newItems[i] {
                    changedRows.insert(i)
                }
            }
            if !changedRows.isEmpty {
                let allColumns = IndexSet(integersIn: 0..<tableView.numberOfColumns)
                tableView.reloadData(forRowIndexes: changedRows, columnIndexes: allColumns)
            }
        }

        if let selectedID = selection {
            if let index = items.firstIndex(where: { $0.id == selectedID }) {
                if tableView.selectedRow != index {
                    tableView.selectRowIndexes(
                        IndexSet(integer: index),
                        byExtendingSelection: false,
                    )
                }
            }
        } else if tableView.selectedRow != -1 {
            tableView.deselectAll(nil)
        }

        updateSortIndicators(tableView: tableView, context: context)
    }

    private var isCoverColumnHidden: Bool {
        let visibility = columnCustomization[visibility: "cover"]
        switch visibility {
            case .visible:
                return false
            case .hidden:
                return true
            default:
                return !Self.defaultVisibleColumns.contains("cover")
        }
    }

    private static let defaultVisibleColumns: Set<String> = ["cover", "title", "series", "media"]
    private static let defaultColumnOrder = [
        "cover", "title", "subtitle", "author", "narrator", "series", "publicationYear",
        "language", "pages", "duration",
        "tags", "collections", "added", "lastRead", "status", "progress", "fileSize", "source",
        "media", "allCreators", "alignedAt", "alignedByVersion", "alignedWith",
    ]

    /// The table column id a canonical metadata field maps to, or nil if the field has no single
    /// column (Creators/Alignment are submenus; Location is filter-only).
    static func columnID(for field: LibraryMetadataField) -> String? {
        switch field {
            case .title: return "title"
            case .subtitle: return "subtitle"
            case .author: return "author"
            case .narrator: return "narrator"
            case .series: return "series"
            case .publicationDate: return "publicationYear"
            case .language: return "language"
            case .pages: return "pages"
            case .duration: return "duration"
            case .tags: return "tags"
            case .collections: return "collections"
            case .dateAdded: return "added"
            case .dateRead: return "lastRead"
            case .status: return "status"
            case .progress: return "progress"
            case .fileSize: return "fileSize"
            case .source: return "source"
            case .creators, .alignment, .location: return nil
        }
    }

    /// The quick-edit field an option-clicked column maps to, or nil for read-only columns
    /// (cover, progress, pages, duration, file size, dates, media, aggregate creators, alignment,
    /// source) which have no inline editor.
    static func quickEditField(forColumnID id: String) -> MetadataQuickEditField? {
        switch id {
            case "title": return .scalar(key: "title", label: "Title")
            case "subtitle": return .scalar(key: "subtitle", label: "Subtitle")
            case "language": return .scalar(key: "language", label: "Language")
            case "author": return .stringList(key: "authors", label: "Author")
            case "narrator": return .stringList(key: "narrators", label: "Narrator(s)")
            case "tags": return .stringList(key: "tags", label: "Tags")
            case "series": return .series
            case "publicationYear": return .publicationDate
            case "status": return .status
            case "collections": return .collections
            case "allCreators": return .creators(roleLabel: "Creators")
            default:
                if let roleCode = creatorRoleCode(from: id) {
                    return .creators(roleLabel: labelForRole(roleCode))
                }
                return nil
        }
    }

    static func creatorColumnID(for roleCode: String) -> String {
        "creator_\(roleCode)"
    }

    static func creatorRoleCode(from columnID: String) -> String? {
        guard columnID.hasPrefix("creator_") else { return nil }
        return String(columnID.dropFirst("creator_".count))
    }

    private var columnWidthsKey: String {
        let base = "library.table.\(tableContext).columnWidths"
        return isDetailSidebarOpen ? "\(base).detail" : base
    }
    private var columnOrderKey: String { "library.table.\(tableContext).columnOrder" }

    fileprivate func columnWidths(from tableView: NSTableView) -> [String: Double] {
        Dictionary(
            uniqueKeysWithValues: tableView.tableColumns.map {
                ($0.identifier.rawValue, Double($0.width))
            }
        )
    }

    fileprivate func saveColumnWidths(_ widths: [String: Double], forKey key: String) {
        UserDefaults.standard.set(widths, forKey: key)
    }

    static func resetColumnDefaults(tableContext: String) {
        let base = "library.table.\(tableContext).columnWidths"
        UserDefaults.standard.removeObject(forKey: base)
        UserDefaults.standard.removeObject(forKey: "\(base).detail")
        UserDefaults.standard.removeObject(forKey: "library.table.\(tableContext).columnOrder")
    }

    fileprivate func saveColumnOrder(from tableView: NSTableView) {
        let order = tableView.tableColumns.map { $0.identifier.rawValue }
        UserDefaults.standard.set(order, forKey: columnOrderKey)
    }

    private func loadColumnWidths() -> [String: CGFloat] {
        guard
            let dict = UserDefaults.standard.dictionary(forKey: columnWidthsKey)
                as? [String: Double]
        else {
            return [:]
        }
        return dict.mapValues { CGFloat($0) }
    }

    private func loadColumnOrder() -> [String] {
        UserDefaults.standard.stringArray(forKey: columnOrderKey) ?? Self.defaultColumnOrder
    }

    private func reorderColumnsToDefault(tableView: NSTableView) {
        let currentIDs = tableView.tableColumns.map { $0.identifier.rawValue }
        var targetOrder = Self.defaultColumnOrder
        let extras = currentIDs.filter { !targetOrder.contains($0) }
        targetOrder.append(contentsOf: extras)

        for (targetIndex, id) in targetOrder.enumerated() {
            guard
                let currentIndex = tableView.tableColumns.firstIndex(where: {
                    $0.identifier.rawValue == id
                })
            else { continue }
            if currentIndex != targetIndex {
                tableView.moveColumn(currentIndex, toColumn: targetIndex)
            }
        }

        for column in tableView.tableColumns {
            if let def = Self.staticColumnDefs[column.identifier.rawValue] {
                column.width = def.width
            }
        }
    }

    private func updateColumnVisibility(tableView: NSTableView, coordinator: Coordinator) {
        let existingIDs = Set(tableView.tableColumns.map { $0.identifier.rawValue })
        for role in coordinator.enabledCreatorRoles {
            let id = Self.creatorColumnID(for: role)
            if !existingIDs.contains(id) {
                let label = Self.labelForRole(role)
                addColumn(
                    to: tableView,
                    id: id,
                    title: label,
                    minWidth: 80,
                    width: 120,
                    maxWidth: 10000,
                )
            }
        }

        var newVisibleIDs: Set<String> = []
        for column in tableView.tableColumns {
            let id = column.identifier.rawValue
            let visibility = columnCustomization[visibility: id]
            let isVisible: Bool
            switch visibility {
                case .visible:
                    isVisible = true
                case .hidden:
                    isVisible = false
                default:
                    isVisible = Self.defaultVisibleColumns.contains(id)
            }
            column.isHidden = !isVisible
            if isVisible {
                newVisibleIDs.insert(id)
            }
        }

        if !coordinator.visibleColumnIDs.isEmpty && newVisibleIDs != coordinator.visibleColumnIDs {
            if let immediateTable = tableView as? ImmediateSelectTableView {
                let previousSuppression = immediateTable.suppressColumnWidthPersistence
                immediateTable.suppressColumnWidthPersistence = true
                defer { immediateTable.suppressColumnWidthPersistence = previousSuppression }

                let savedWidths = loadColumnWidths()
                for column in tableView.tableColumns where !column.isHidden {
                    let id = column.identifier.rawValue
                    if !coordinator.visibleColumnIDs.contains(id),
                        let savedWidth = savedWidths[id]
                    {
                        column.width = savedWidth
                    }
                }
                immediateTable.tile()
            }
        }
        coordinator.visibleColumnIDs = newVisibleIDs
    }

    private static let staticColumnDefs:
        [String: (title: String, minWidth: CGFloat, width: CGFloat, maxWidth: CGFloat)] = [
            "cover": ("", 30, 50, 70),
            "title": ("Title", 100, 200, 10000),
            "subtitle": ("Subtitle", 80, 150, 10000),
            "author": ("Author", 80, 150, 10000),
            "series": ("Series", 80, 140, 10000),
            "progress": ("Progress", 60, 100, 140),
            "narrator": ("Narrator", 80, 120, 10000),
            "language": ("Language", 50, 80, 10000),
            "pages": ("Pages", 50, 70, 10000),
            "duration": ("Duration", 60, 90, 10000),
            "fileSize": ("File Size", 60, 90, 10000),
            "collections": ("Collections", 80, 120, 10000),
            "publicationYear": ("Published", 80, 100, 10000),
            "status": ("Status", 60, 80, 10000),
            "added": ("Added", 80, 100, 10000),
            "lastRead": ("Last Read", 80, 100, 10000),
            "tags": ("Tags", 80, 120, 10000),
            "media": ("Media", 100, 120, 150),
            "allCreators": ("Creators", 80, 140, 10000),
            "alignedAt": ("Aligned Date", 80, 115, 10000),
            "alignedByVersion": ("ST Version", 60, 90, 10000),
            "alignedWith": ("Engine", 60, 100, 10000),
            "source": ("Source", 80, 120, 10000),
        ]

    private static let ascendingSortColumns: Set<String> = [
        "title", "subtitle", "author", "series", "narrator", "language", "collections",
        "publicationYear", "status", "added", "tags", "allCreators", "pages",
        "alignedByVersion", "alignedWith", "source",
    ]
    private static let descendingSortColumns: Set<String> = [
        "lastRead", "progress", "alignedAt", "duration", "fileSize",
    ]

    private func setupColumns(tableView: NSTableView, context: Context) {
        let savedWidths = loadColumnWidths()
        let savedOrder = loadColumnOrder()

        let migratedOrder = savedOrder.map { $0 == "translator" ? "creator_trl" : $0 }
        let migratedWidths = Dictionary(
            uniqueKeysWithValues: savedWidths.map { key, value in
                (key == "translator" ? "creator_trl" : key, value)
            }
        )

        let staticOrder = migratedOrder.filter { Self.staticColumnDefs[$0] != nil }
        let missingStatic = Self.defaultColumnOrder.filter { !staticOrder.contains($0) }
        let finalStaticOrder = staticOrder + missingStatic

        let creatorIDs = migratedOrder.filter { Self.creatorRoleCode(from: $0) != nil }

        for id in finalStaticOrder {
            guard let def = Self.staticColumnDefs[id] else { continue }
            addColumn(
                to: tableView,
                id: id,
                title: def.title,
                minWidth: def.minWidth,
                width: migratedWidths[id] ?? def.width,
                maxWidth: def.maxWidth,
            )
        }

        for id in creatorIDs {
            guard let roleCode = Self.creatorRoleCode(from: id) else { continue }
            let label = Self.labelForRole(roleCode)
            addColumn(
                to: tableView,
                id: id,
                title: label,
                minWidth: 80,
                width: migratedWidths[id] ?? 120,
                maxWidth: 10000,
            )
        }
    }

    private func addColumn(
        to tableView: NSTableView,
        id: String,
        title: String,
        minWidth: CGFloat,
        width: CGFloat,
        maxWidth: CGFloat,
    ) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.minWidth = minWidth
        column.width = width
        column.maxWidth = maxWidth
        column.isEditable = false

        if Self.ascendingSortColumns.contains(id) || Self.creatorRoleCode(from: id) != nil {
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
        } else if Self.descendingSortColumns.contains(id) {
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: false)
        }

        tableView.addTableColumn(column)
    }

    static let marcRelatorLabels: [String: String] = [
        "abr": "Abridger", "act": "Actor", "adp": "Adapter", "anm": "Animator",
        "ann": "Annotator", "arc": "Architect", "arr": "Arranger", "art": "Artist",
        "aut": "Author", "aui": "Author of Introduction", "blw": "Blurb Writer",
        "bkd": "Book Designer", "bkp": "Book Producer", "clr": "Colorist",
        "cmm": "Commentator", "com": "Compiler", "cmp": "Composer", "cnd": "Conductor",
        "ctb": "Contributor", "cov": "Cover Designer", "cre": "Creator", "cur": "Curator",
        "drt": "Director", "dsr": "Designer", "edt": "Editor", "edc": "Editor of Compilation",
        "eng": "Engineer", "ill": "Illustrator", "ink": "Inker", "itr": "Instrumentalist",
        "ive": "Interviewee", "ivr": "Interviewer", "lbt": "Librettist", "ltr": "Letterer",
        "lyr": "Lyricist", "mus": "Musician", "nrt": "Narrator", "pbl": "Publisher",
        "pnc": "Penciller", "pht": "Photographer", "prf": "Performer", "pro": "Producer",
        "prg": "Programmer", "pfr": "Proofreader", "red": "Redaktor", "rev": "Reviewer",
        "sce": "Scenarist", "sng": "Singer", "spk": "Speaker", "stl": "Storyteller",
        "trc": "Transcriber", "trl": "Translator", "vac": "Voice Actor",
        "wam": "Writer of Accompanying Material", "waw": "Writer of Afterword",
        "wfw": "Writer of Foreword", "win": "Writer of Introduction",
        "wpr": "Writer of Preface",
    ]

    static func labelForRole(_ code: String) -> String {
        marcRelatorLabels[code] ?? code.uppercased()
    }

    private func updateSortIndicators(tableView: NSTableView, context: Context) {
        for column in tableView.tableColumns {
            tableView.setIndicatorImage(nil, in: column)
        }

        guard let comparator = sortOrder.first else { return }

        let keyPathToColumn: [AnyKeyPath: String] = [
            \BookMetadata.title: "title",
            \BookMetadata.sortableSubtitle: "subtitle",
            \BookMetadata.sortableAuthor: "author",
            \BookMetadata.sortableSeries: "series",
            \BookMetadata.progress: "progress",
            \BookMetadata.sortableNarrator: "narrator",
            \BookMetadata.sortableLanguage: "language",
            \BookMetadata.sortablePages: "pages",
            \BookMetadata.sortableDuration: "duration",
            \BookMetadata.sortableFileSize: "fileSize",
            \BookMetadata.sortableCollections: "collections",
            \BookMetadata.sortablePublicationDate: "publicationYear",
            \BookMetadata.sortableStatus: "status",
            \BookMetadata.sortableAdded: "added",
            \BookMetadata.sortableLastRead: "lastRead",
            \BookMetadata.sortableTags: "tags",
            \BookMetadata.sortableAllCreators: "allCreators",
            \BookMetadata.sortableAlignedAt: "alignedAt",
            \BookMetadata.sortableAlignedByVersion: "alignedByVersion",
            \BookMetadata.sortableAlignedWith: "alignedWith",
            \BookMetadata.sortableSource: "source",
        ]

        let columnID: String?
        if let mapped = keyPathToColumn[comparator.keyPath] {
            columnID = mapped
        } else if let ctx = context.coordinator.creatorSortRoleCode {
            columnID = Self.creatorColumnID(for: ctx)
        } else {
            columnID = nil
        }

        guard let columnID,
            let column = tableView.tableColumn(
                withIdentifier: NSUserInterfaceItemIdentifier(columnID)
            )
        else {
            return
        }

        let image =
            comparator.order == .forward
            ? NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Ascending")
            : NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Descending")
        tableView.setIndicatorImage(image, in: column)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: MediaTableView
        var items: [BookMetadata]
        var coverPreference: CoverPreference
        var mediaViewModel: MediaViewModel
        var isCoverHidden: Bool = false
        var isDetailSidebarOpen: Bool = false
        var columnResetToken: Int = 0
        var visibleColumnIDs: Set<String> = []
        var creatorSortRoleCode: String?
        var enabledCreatorRoles: Set<String> = []
        weak var tableView: NSTableView?
        weak var scrollView: NSScrollView?
        private var isHandlingColumnResize = false
        private var saveWidthsWorkItem: DispatchWorkItem?
        private var saveOrderWorkItem: DispatchWorkItem?

        init(parent: MediaTableView, mediaViewModel: MediaViewModel) {
            self.parent = parent
            self.items = parent.items
            self.coverPreference = parent.coverPreference
            self.mediaViewModel = mediaViewModel
            self.isCoverHidden = parent.isCoverColumnHidden
            super.init()
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            guard let tv = notification.object as? NSTableView else { return }
            if let immediateTable = tv as? ImmediateSelectTableView,
                immediateTable.suppressColumnWidthPersistence
            {
                return
            }
            guard !isHandlingColumnResize else { return }
            isHandlingColumnResize = true
            defer { isHandlingColumnResize = false }

            let parent = self.parent
            let key = parent.columnWidthsKey
            let currentWidths = parent.columnWidths(from: tv).mapValues { CGFloat($0) }
            var idealWidths =
                (tv as? ImmediateSelectTableView)?.activeIdealWidths
                ?? parent.loadColumnWidths()

            for (id, width) in currentWidths where idealWidths[id] == nil {
                idealWidths[id] = width
            }
            if let resizedColumn = notification.userInfo?["NSTableColumn"] as? NSTableColumn {
                idealWidths[resizedColumn.identifier.rawValue] = resizedColumn.width
            } else {
                idealWidths = currentWidths
            }

            (tv as? ImmediateSelectTableView)?.activeIdealWidths = idealWidths
            (tv as? ImmediateSelectTableView)?.tile()

            saveWidthsWorkItem?.cancel()
            let widthsToSave = idealWidths.mapValues { Double($0) }
            let work = DispatchWorkItem { [weak tv] in
                MainActor.assumeIsolated {
                    guard let tv = tv else { return }
                    parent.saveColumnWidths(widthsToSave, forKey: key)
                    if let immediateTable = tv as? ImmediateSelectTableView {
                        immediateTable.activeIdealWidths = idealWidths
                    }
                }
            }
            saveWidthsWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            guard let tv = notification.object as? NSTableView else { return }
            saveOrderWorkItem?.cancel()
            let parent = self.parent
            let work = DispatchWorkItem {
                MainActor.assumeIsolated {
                    parent.saveColumnOrder(from: tv)
                }
            }
            saveOrderWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            items.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
            -> NSView?
        {
            guard let columnID = tableColumn?.identifier.rawValue, row < items.count else {
                return nil
            }
            let item = items[row]
            let cellID = NSUserInterfaceItemIdentifier("\(columnID)Cell")

            switch columnID {
                case "cover":
                    return makeCoverCell(tableView: tableView, cellID: cellID, item: item)
                case "title":
                    return makeTitleCell(tableView: tableView, cellID: cellID, item: item)
                case "subtitle":
                    return makeTextCell(
                        tableView: tableView,
                        cellID: cellID,
                        text: item.subtitle ?? "",
                        secondary: true,
                    )
                case "author":
                    return makeCreatorPillsCell(
                        tableView: tableView,
                        cellID: cellID,
                        names: creatorNames(item.authors),
                        linkBuilder: { .author($0) },
                    )
                case "series":
                    return makeSeriesCell(tableView: tableView, cellID: cellID, item: item)
                case "progress":
                    return makeProgressCell(tableView: tableView, cellID: cellID, item: item)
                case "narrator":
                    return makeCreatorPillsCell(
                        tableView: tableView,
                        cellID: cellID,
                        names: creatorNames(item.narrators),
                        linkBuilder: { .narrator($0) },
                    )
                case "language":
                    return makeTextCell(
                        tableView: tableView,
                        cellID: cellID,
                        text: item.language ?? "",
                        secondary: true,
                    )
                case "pages":
                    return makeTextCell(
                        tableView: tableView,
                        cellID: cellID,
                        text: item.pagesDisplay,
                        secondary: true,
                    )
                case "duration":
                    return makeTextCell(
                        tableView: tableView,
                        cellID: cellID,
                        text: item.durationDisplay,
                        secondary: true,
                    )
                case "fileSize":
                    return makeTextCell(
                        tableView: tableView,
                        cellID: cellID,
                        text: item.fileSizeDisplay,
                        secondary: true,
                    )
                case "collections":
                    let names = item.collections?.map(\.name).joined(separator: ", ") ?? ""
                    return makeTextCell(
                        tableView: tableView,
                        cellID: cellID,
                        text: names,
                        secondary: true,
                    )
                case "publicationYear":
                    let year = item.sortablePublicationYear
                    let target: MetadataLinkTarget? = year.isEmpty ? nil : .publicationYear(year)
                    return makeLinkDateCell(
                        tableView: tableView,
                        cellID: cellID,
                        dateString: item.publicationDate,
                        linkTarget: target,
                        field: .publicationDate,
                    )
                case "status":
                    let statusName = item.status?.name ?? ""
                    let target: MetadataLinkTarget? = statusName.isEmpty ? nil : .status(statusName)
                    return makeLinkTextCell(
                        tableView: tableView,
                        cellID: cellID,
                        text: statusName,
                        linkTarget: target,
                    )
                case "added":
                    return makeDateCell(
                        tableView: tableView,
                        cellID: cellID,
                        dateString: item.createdAt,
                        field: .createdAt,
                    )
                case "lastRead":
                    return makeDateCell(
                        tableView: tableView,
                        cellID: cellID,
                        dateString: item.position?.updatedAt,
                        field: .lastRead,
                    )
                case "tags":
                    return makeTagsCell(tableView: tableView, cellID: cellID, item: item)
                case "media":
                    return makeMediaCell(tableView: tableView, cellID: cellID, item: item)
                case "allCreators":
                    return makeAllCreatorsCell(
                        tableView: tableView,
                        cellID: cellID,
                        item: item,
                    )
                case "alignedAt":
                    return makeDateCell(
                        tableView: tableView,
                        cellID: cellID,
                        dateString: item.alignedAt,
                        field: .alignedAt,
                    )
                case "alignedByVersion":
                    return makeTextCell(
                        tableView: tableView,
                        cellID: cellID,
                        text: item.alignedByStorytellerVersion ?? "",
                        secondary: true,
                    )
                case "alignedWith":
                    return makeTextCell(
                        tableView: tableView,
                        cellID: cellID,
                        text: item.alignedWith ?? "",
                        secondary: true,
                    )
                case "source":
                    return makeTextCell(
                        tableView: tableView,
                        cellID: cellID,
                        text: item.source ?? "",
                        secondary: true,
                    )
                default:
                    if let roleCode = MediaTableView.creatorRoleCode(from: columnID) {
                        let name = item.sortableCreator(role: roleCode)
                        return makeTextCell(
                            tableView: tableView,
                            cellID: cellID,
                            text: name,
                            secondary: true,
                        )
                    }
                    return nil
            }
        }

        func tableView(
            _ tableView: NSTableView,
            sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor],
        ) {
            guard let descriptor = tableView.sortDescriptors.first,
                let key = descriptor.key
            else { return }

            let order: SortOrder = descriptor.ascending ? .forward : .reverse

            switch key {
                case "title":
                    parent.sortOrder = [KeyPathComparator(\BookMetadata.title, order: order)]
                case "subtitle":
                    parent.sortOrder = [
                        KeyPathComparator(\BookMetadata.sortableSubtitle, order: order)
                    ]
                case "author":
                    parent.sortOrder = [
                        KeyPathComparator(\BookMetadata.sortableAuthor, order: order)
                    ]
                case "series":
                    parent.sortOrder = [
                        KeyPathComparator(\BookMetadata.sortableSeries, order: order)
                    ]
                case "progress":
                    parent.sortOrder = [
                        KeyPathComparator(\BookMetadata.sortableProgress, order: order)
                    ]
                case "narrator":
                    parent.sortOrder = [
                        KeyPathComparator(\BookMetadata.sortableNarrator, order: order)
                    ]
                case "language":
                    parent.sortOrder = [
                        KeyPathComparator(\BookMetadata.sortableLanguage, order: order)
                    ]
                case "pages":
                    parent.sortOrder = [
                        KeyPathComparator(\BookMetadata.sortablePages, order: order)
                    ]
                case "duration":
                    parent.sortOrder = [
                        KeyPathComparator(\BookMetadata.sortableDuration, order: order)
                    ]
                case "fileSize":
                    parent.sortOrder = [
                        KeyPathComparator(\BookMetadata.sortableFileSize, order: order)
                    ]
                case "collections":
                    parent.sortOrder = [
                        KeyPathComparator(\BookMetadata.sortableCollections, order: order)
                    ]
                case "publicationYear":
                    parent.sortOrder = [
                        KeyPathComparator(\BookMetadata.sortablePublicationDate, order: order)
                    ]
                case "status":
                    parent.sortOrder = [
                        KeyPathComparator(\BookMetadata.sortableStatus, order: order)
                    ]
                case "added":
                    parent.sortOrder = [
                        KeyPathComparator(\BookMetadata.sortableAdded, order: order)
                    ]
                case "lastRead":
                    parent.sortOrder = [
                        KeyPathComparator(\BookMetadata.sortableLastRead, order: order)
                    ]
                case "tags":
                    parent.sortOrder = [
                        KeyPathComparator(\BookMetadata.sortableTags, order: order)
                    ]
                case "allCreators":
                    parent.sortOrder = [
                        KeyPathComparator(\BookMetadata.sortableAllCreators, order: order)
                    ]
                case "alignedAt":
                    parent.sortOrder = [
                        KeyPathComparator(\BookMetadata.sortableAlignedAt, order: order)
                    ]
                case "alignedByVersion":
                    parent.sortOrder = [
                        KeyPathComparator(\BookMetadata.sortableAlignedByVersion, order: order)
                    ]
                case "alignedWith":
                    parent.sortOrder = [
                        KeyPathComparator(\BookMetadata.sortableAlignedWith, order: order)
                    ]
                case "source":
                    parent.sortOrder = [
                        KeyPathComparator(\BookMetadata.sortableSource, order: order)
                    ]
                default:
                    if let roleCode = MediaTableView.creatorRoleCode(from: key) {
                        creatorSortRoleCode = roleCode
                        parent.creatorSortRoleCode = roleCode
                        parent.sortOrder = [
                            KeyPathComparator(\BookMetadata.sortableTranslator, order: order)
                        ]
                        return
                    }
            }
            creatorSortRoleCode = nil
            parent.creatorSortRoleCode = nil
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView = notification.object as? NSTableView else { return }
            let selectedIndexes = tableView.selectedRowIndexes
            if let lastIndex = selectedIndexes.last, lastIndex < items.count {
                let item = items[lastIndex]
                parent.selection = item.id
                parent.onSelect(item)
            } else if selectedIndexes.isEmpty {
                parent.selection = nil
            }
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            return true
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            isCoverHidden ? 28 : 48
        }

        func handleRowDoubleClicked(_ row: Int) {
            guard row >= 0 && row < items.count else { return }
            let item = items[row]
            parent.onInfo(item)
        }

        func handleLinkClicked(_ target: MetadataLinkTarget) {
            parent.onMetadataLinkClicked?(target)
        }

        func handleQuickEditCell(row: Int, columnID: String) {
            guard row >= 0, row < items.count,
                let field = MediaTableView.quickEditField(forColumnID: columnID)
            else { return }
            parent.onQuickEdit?(items[row].id, field)
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView, tableView.clickedRow >= 0,
                tableView.clickedRow < items.count
            else { return }

            let item = items[tableView.clickedRow]

            let showInfo = NSMenuItem(
                title: "Show Book Information",
                action: #selector(showBookInfo(_:)),
                keyEquivalent: "",
            )
            showInfo.target = self
            showInfo.representedObject = item
            menu.addItem(showInfo)

            let editMeta = NSMenuItem(
                title: "Edit Metadata...",
                action: #selector(editMetadata(_:)),
                keyEquivalent: "",
            )
            editMeta.target = self
            menu.addItem(editMeta)

            let ebookCached = mediaViewModel.hasCachedMedia(.ebook, for: item)
            let audioCached = mediaViewModel.hasCachedMedia(.audio, for: item)
            let syncedCached = mediaViewModel.hasCachedMedia(.synced, for: item)
            let isFolderBook = mediaViewModel.isLocalFolderBook(item.id)

            if isFolderBook
                && (item.hasAvailableEbook || item.hasAvailableAudiobook
                    || item.hasAvailableReadaloud)
            {
                menu.addItem(.separator())
                let deleteMenu = NSMenu()
                if item.hasAvailableEbook {
                    deleteMenu.addItem(
                        sourceDeleteItem(
                            title: "Delete Ebook",
                            action: #selector(deleteSourceEbook(_:)),
                            item: item,
                        )
                    )
                }
                if item.hasAvailableAudiobook {
                    deleteMenu.addItem(
                        sourceDeleteItem(
                            title: "Delete Audiobook",
                            action: #selector(deleteSourceAudiobook(_:)),
                            item: item,
                        )
                    )
                }
                if item.hasAvailableReadaloud {
                    deleteMenu.addItem(
                        sourceDeleteItem(
                            title: "Delete Readaloud",
                            action: #selector(deleteSourceReadaloud(_:)),
                            item: item,
                        )
                    )
                }
                deleteMenu.addItem(.separator())
                let sourceBookDeleteItems = selectedFolderSourceItems(fallback: item)
                let deleteAllTitle =
                    sourceBookDeleteItems.count > 1
                    ? "Delete \(sourceBookDeleteItems.count) Selected Books"
                    : "Delete All"
                let del = NSMenuItem(
                    title: deleteAllTitle,
                    action: #selector(deleteSourceBook(_:)),
                    keyEquivalent: "",
                )
                del.target = self
                del.representedObject = item
                del.attributedTitle = NSAttributedString(
                    string: deleteAllTitle,
                    attributes: [.foregroundColor: NSColor.systemRed],
                )
                deleteMenu.addItem(del)

                let deleteMenuItem = NSMenuItem(
                    title: "Delete from Folder",
                    action: nil,
                    keyEquivalent: "",
                )
                deleteMenuItem.submenu = deleteMenu
                menu.addItem(deleteMenuItem)
            } else {
                if ebookCached || audioCached || syncedCached {
                    menu.addItem(.separator())
                }

                if ebookCached {
                    let del = NSMenuItem(
                        title: "Delete Local Ebook",
                        action: #selector(deleteLocalEbook(_:)),
                        keyEquivalent: "",
                    )
                    del.target = self
                    del.representedObject = item
                    menu.addItem(del)
                }
                if audioCached {
                    let del = NSMenuItem(
                        title: "Delete Local Audiobook",
                        action: #selector(deleteLocalAudiobook(_:)),
                        keyEquivalent: "",
                    )
                    del.target = self
                    del.representedObject = item
                    menu.addItem(del)
                }
                if syncedCached {
                    let del = NSMenuItem(
                        title: "Delete Local Readaloud",
                        action: #selector(deleteLocalReadaloud(_:)),
                        keyEquivalent: "",
                    )
                    del.target = self
                    del.representedObject = item
                    menu.addItem(del)
                }
            }

            if item.hasAvailableEbook && item.hasAvailableAudiobook
                && (mediaViewModel.isServerBook(item.id)
                    || mediaViewModel.isLocalFolderBook(item.id))
            {
                menu.addItem(.separator())
                let local = NSMenuItem(
                    title: item.hasAvailableReadaloud
                        ? "Recreate Readaloud Locally" : "Create Readaloud Locally",
                    action: #selector(createLocalReadaloud(_:)),
                    keyEquivalent: "",
                )
                local.target = self
                local.representedObject = item
                menu.addItem(local)
            }

            let copyDestinations = mediaViewModel.copyDestinations(for: item)
            if !copyDestinations.isEmpty {
                menu.addItem(.separator())
                let copyMenu = NSMenu()
                for destination in copyDestinations {
                    let copyItem = NSMenuItem(
                        title: destination.name,
                        action: #selector(copyBookTo(_:)),
                        keyEquivalent: "",
                    )
                    copyItem.target = self
                    copyItem.representedObject = CopyBookData(
                        bookID: item.id,
                        destinationSourceID: destination.id,
                    )
                    copyMenu.addItem(copyItem)
                }
                let copyMenuItem = NSMenuItem(title: "Copy To...", action: nil, keyEquivalent: "")
                copyMenuItem.submenu = copyMenu
                menu.addItem(copyMenuItem)
            }

            let serverActions = NSMenu()
            if addServerActionItems(to: serverActions, for: item) > 0 {
                menu.addItem(.separator())
                let serverActionsItem = NSMenuItem(
                    title: "Server Actions",
                    action: nil,
                    keyEquivalent: "",
                )
                serverActionsItem.submenu = serverActions
                menu.addItem(serverActionsItem)
            }
        }

        @objc private func editMetadata(_ sender: NSMenuItem) {
            guard let tableView else { return }
            var bookIds: [BookID] = []
            let selectedIndexes = tableView.selectedRowIndexes
            if selectedIndexes.count > 1 {
                for index in selectedIndexes where index < items.count {
                    bookIds.append(items[index].id)
                }
            } else {
                let clickedRow = tableView.clickedRow
                if clickedRow >= 0 && clickedRow < items.count {
                    bookIds.append(items[clickedRow].id)
                }
            }
            guard !bookIds.isEmpty else { return }
            parent.onEditMetadata?(bookIds)
        }

        @objc private func showBookInfo(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? BookMetadata else { return }
            parent.onInfo(item)
        }

        private func addReprocessItems(to menu: NSMenu, item: BookMetadata) {
            let sync = NSMenuItem(
                title: "Re-align Readaloud (Fast)",
                action: #selector(reprocessSync(_:)),
                keyEquivalent: "",
            )
            sync.target = self
            sync.representedObject = item
            menu.addItem(sync)

            let transcribe = NSMenuItem(
                title: "Re-transcribe & Align Readaloud",
                action: #selector(reprocessTranscription(_:)),
                keyEquivalent: "",
            )
            transcribe.target = self
            transcribe.representedObject = item
            menu.addItem(transcribe)

            let full = NSMenuItem(
                title: "Fully Reprocess Readaloud",
                action: #selector(reprocessFull(_:)),
                keyEquivalent: "",
            )
            full.target = self
            full.representedObject = item
            menu.addItem(full)
        }

        @discardableResult
        private func addServerActionItems(to menu: NSMenu, for item: BookMetadata) -> Int {
            guard mediaViewModel.isServerBook(item.id) else { return 0 }

            let initialCount = menu.items.count
            let status = item.readaloud?.status?.uppercased() ?? ""
            let hasEbookAndAudio = item.hasAvailableEbook && item.hasAvailableAudiobook

            if status == "PROCESSING" || status == "QUEUED" {
                let cancel = NSMenuItem(
                    title: "Cancel Readaloud Processing",
                    action: #selector(cancelProcessing(_:)),
                    keyEquivalent: "",
                )
                cancel.target = self
                cancel.representedObject = item
                menu.addItem(cancel)
            } else if status == "ALIGNED" {
                addReprocessItems(to: menu, item: item)
            } else if status == "ERROR" || status == "STOPPED" {
                let retry = NSMenuItem(
                    title: "Retry Readaloud Processing",
                    action: #selector(reprocessFull(_:)),
                    keyEquivalent: "",
                )
                retry.target = self
                retry.representedObject = item
                menu.addItem(retry)

                let realign = NSMenuItem(
                    title: "Re-align Readaloud Only",
                    action: #selector(reprocessSync(_:)),
                    keyEquivalent: "",
                )
                realign.target = self
                realign.representedObject = item
                menu.addItem(realign)
            } else if hasEbookAndAudio {
                let create = NSMenuItem(
                    title: "Create Readaloud",
                    action: #selector(createReadaloud(_:)),
                    keyEquivalent: "",
                )
                create.target = self
                create.representedObject = item
                menu.addItem(create)
            }

            if item.canUpgradeToEpub3 {
                if menu.items.count > initialCount {
                    menu.addItem(.separator())
                }
                let upgrade = NSMenuItem(
                    title: "Convert to EPUB 3",
                    action: #selector(upgradeEpub(_:)),
                    keyEquivalent: "",
                )
                upgrade.target = self
                upgrade.representedObject = item
                menu.addItem(upgrade)
            }

            if menu.items.count > initialCount {
                menu.addItem(.separator())
            }
            let manage = NSMenuItem(
                title: "Manage Server Media...",
                action: #selector(manageServerMedia(_:)),
                keyEquivalent: "",
            )
            manage.target = self
            manage.representedObject = item.id
            menu.addItem(manage)

            return menu.items.count - initialCount
        }

        @objc private func createReadaloud(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? BookMetadata else { return }
            Task {
                _ = await BookServiceActor.shared.startAlignment(
                    for: item.id,
                    restart: item.hasAvailableReadaloud ? .sync : .none,
                )
                await BookServiceActor.shared.fetchLibraryInformation()
            }
        }

        @objc private func createLocalReadaloud(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? BookMetadata else { return }
            guard
                let data = LocalReadaloudAlignmentLauncher.data(
                    for: item,
                    mediaViewModel: mediaViewModel,
                )
            else { return }
            parent.onCreateLocalReadaloud?(data)
        }

        @objc private func copyBookTo(_ sender: NSMenuItem) {
            guard let data = sender.representedObject as? CopyBookData else { return }
            parent.onCopyBook?(data)
        }

        @objc private func reprocessSync(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? BookMetadata else { return }
            Task {
                _ = await BookServiceActor.shared.startAlignment(
                    for: item.id,
                    restart: .sync,
                )
                await BookServiceActor.shared.fetchLibraryInformation()
            }
        }

        @objc private func reprocessTranscription(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? BookMetadata else { return }
            Task {
                _ = await BookServiceActor.shared.startAlignment(
                    for: item.id,
                    restart: .transcription,
                )
                await BookServiceActor.shared.fetchLibraryInformation()
            }
        }

        @objc private func reprocessFull(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? BookMetadata else { return }
            Task {
                _ = await BookServiceActor.shared.startAlignment(
                    for: item.id,
                    restart: .full,
                )
                await BookServiceActor.shared.fetchLibraryInformation()
            }
        }

        @objc private func cancelProcessing(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? BookMetadata else { return }
            Task {
                _ = await BookServiceActor.shared.cancelAlignment(
                    for: item.id
                )
                await BookServiceActor.shared.fetchLibraryInformation()
            }
        }

        @objc private func upgradeEpub(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? BookMetadata else { return }
            Task {
                _ = await BookServiceActor.shared.upgradeEpub(
                    for: item.id
                )
                await BookServiceActor.shared.fetchLibraryInformation()
            }
        }

        @objc private func manageServerMedia(_ sender: NSMenuItem) {
            guard let bookId = sender.representedObject as? BookID else { return }
            parent.onManageServerMedia?(bookId)
        }

        @objc private func deleteLocalEbook(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? BookMetadata else { return }
            guard
                confirmDestructiveAction(
                    title: "Delete Local Ebook?",
                    message: "This will remove the downloaded ebook from this device.",
                    buttonTitle: "Delete",
                )
            else { return }
            mediaViewModel.deleteDownload(for: item, category: .ebook)
        }

        @objc private func deleteLocalAudiobook(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? BookMetadata else { return }
            guard
                confirmDestructiveAction(
                    title: "Delete Local Audiobook?",
                    message: "This will remove the downloaded audiobook from this device.",
                    buttonTitle: "Delete",
                )
            else { return }
            mediaViewModel.deleteDownload(for: item, category: .audio)
        }

        @objc private func deleteLocalReadaloud(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? BookMetadata else { return }
            guard
                confirmDestructiveAction(
                    title: "Delete Local Readaloud?",
                    message: "This will remove the downloaded readaloud from this device.",
                    buttonTitle: "Delete",
                )
            else { return }
            mediaViewModel.deleteDownload(for: item, category: .synced)
        }

        @objc private func deleteSourceEbook(_ sender: NSMenuItem) {
            deleteSourceAsset(sender, format: .ebook)
        }

        @objc private func deleteSourceAudiobook(_ sender: NSMenuItem) {
            deleteSourceAsset(sender, format: .audiobook)
        }

        @objc private func deleteSourceReadaloud(_ sender: NSMenuItem) {
            deleteSourceAsset(sender, format: .readaloud)
        }

        @objc private func deleteSourceBook(_ sender: NSMenuItem) {
            guard let item = sender.representedObject as? BookMetadata else { return }
            let itemsToDelete = selectedFolderSourceItems(fallback: item)
            let isBulkDelete = itemsToDelete.count > 1
            let title = isBulkDelete ? "\(itemsToDelete.count) selected books" : item.title
            let buttonTitle =
                isBulkDelete ? "Delete \(itemsToDelete.count) Selected Books" : "Delete All"
            guard
                confirmDestructiveAction(
                    title: "Delete All from Folder?",
                    message:
                        "This will permanently delete \(title) and all media from the folder source. This cannot be undone.",
                    buttonTitle: buttonTitle,
                )
            else { return }
            Task {
                var deletedCount = 0
                var failedCount = 0
                for itemToDelete in itemsToDelete {
                    let success = await mediaViewModel.deleteBookFromSource(itemToDelete)
                    if success {
                        deletedCount += 1
                    } else {
                        failedCount += 1
                    }
                }

                let success = failedCount == 0
                mediaViewModel.showSyncNotification(
                    SyncNotification(
                        message: deleteSourceBookNotificationMessage(
                            requestedCount: itemsToDelete.count,
                            deletedCount: deletedCount,
                            failedCount: failedCount,
                            fallbackTitle: item.title,
                        ),
                        type: success ? .success : .error,
                    )
                )
            }
        }

        private func selectedFolderSourceItems(fallback item: BookMetadata) -> [BookMetadata] {
            guard let tableView else { return [item] }
            let selectedIndexes = tableView.selectedRowIndexes
            let clickedRow = tableView.clickedRow
            guard selectedIndexes.count > 1,
                clickedRow >= 0,
                selectedIndexes.contains(clickedRow)
            else {
                return [item]
            }

            let selectedItems = selectedIndexes.compactMap { index -> BookMetadata? in
                guard index >= 0, index < items.count else { return nil }
                let selectedItem = items[index]
                return mediaViewModel.isLocalFolderBook(selectedItem.id) ? selectedItem : nil
            }

            return selectedItems.isEmpty ? [item] : selectedItems
        }

        private func deleteSourceBookNotificationMessage(
            requestedCount: Int,
            deletedCount: Int,
            failedCount: Int,
            fallbackTitle: String,
        ) -> String {
            guard requestedCount > 1 else {
                return failedCount == 0
                    ? "Deleted \(fallbackTitle) from folder source"
                    : "Failed to delete \(fallbackTitle)"
            }

            if failedCount == 0 {
                return "Deleted \(deletedCount) books from folder source"
            }
            if deletedCount == 0 {
                return "Failed to delete \(failedCount) selected books"
            }
            return "Deleted \(deletedCount) books; \(failedCount) failed"
        }

        private func deleteSourceAsset(_ sender: NSMenuItem, format: StorytellerBookFormat) {
            guard let item = sender.representedObject as? BookMetadata else { return }
            let label = mediaViewModel.folderAssetLabel(format)
            guard
                confirmDestructiveAction(
                    title: "Delete \(label) from Folder?",
                    message:
                        "This will permanently delete the \(label.lowercased()) file from the folder source. This cannot be undone.",
                    buttonTitle: "Delete",
                )
            else { return }
            Task {
                _ = await mediaViewModel.deleteFolderAsset(for: item, format: format)
            }
        }

        private func sourceDeleteItem(
            title: String,
            action: Selector,
            item: BookMetadata,
        ) -> NSMenuItem {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item
            menuItem.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.foregroundColor: NSColor.systemRed],
            )
            return menuItem
        }

        private func confirmDestructiveAction(
            title: String,
            message: String,
            buttonTitle: String,
        ) -> Bool {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: buttonTitle)
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }

        private func makeCoverCell(
            tableView: NSTableView,
            cellID: NSUserInterfaceItemIdentifier,
            item: BookMetadata,
        ) -> NSView {
            let coverVariant = resolveCoverVariant(for: item)

            let cell =
                tableView.makeView(withIdentifier: cellID, owner: self) as? HostingCellView
                ?? HostingCellView(identifier: cellID)
            let content = CoverCellContent(
                item: item,
                coverVariant: coverVariant,
                mediaViewModel: mediaViewModel,
            )
            cell.setContent(content)
            cell.toolTip = item.readaloud?.processingTooltip
            return cell
        }

        private func makeTitleCell(
            tableView: NSTableView,
            cellID: NSUserInterfaceItemIdentifier,
            item: BookMetadata,
        ) -> NSView {
            let stackedCellID = NSUserInterfaceItemIdentifier("titleStackedCell")
            let cell =
                tableView.makeView(withIdentifier: stackedCellID, owner: self)
                as? TitleAuthorCellView
                ?? TitleAuthorCellView(identifier: stackedCellID)
            let coverColumn = tableView.tableColumn(
                withIdentifier: NSUserInterfaceItemIdentifier("cover")
            )
            let showAuthor = !(coverColumn?.isHidden ?? false)
            let subtitle = item.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            let secondaryText = subtitle?.isEmpty == false ? subtitle : item.authors?.first?.name
            let secondaryLinkTarget =
                subtitle?.isEmpty == false
                ? nil : item.authors?.first?.name.map(MetadataLinkTarget.author)
            cell.configure(
                title: item.title,
                secondaryText: secondaryText,
                secondaryLinkTarget: secondaryLinkTarget,
                showSecondary: showAuthor,
            )
            return cell
        }

        private func makeTextCell(
            tableView: NSTableView,
            cellID: NSUserInterfaceItemIdentifier,
            text: String,
            secondary: Bool,
        ) -> NSView {
            let cell =
                tableView.makeView(withIdentifier: cellID, owner: self) as? TextCellView
                ?? TextCellView(identifier: cellID)
            cell.configure(text: text, secondary: secondary)
            return cell
        }

        private func makeLinkTextCell(
            tableView: NSTableView,
            cellID: NSUserInterfaceItemIdentifier,
            text: String,
            linkTarget: MetadataLinkTarget?,
        ) -> NSView {
            let cell =
                tableView.makeView(withIdentifier: cellID, owner: self) as? LinkTextCellView
                ?? LinkTextCellView(identifier: cellID)
            cell.configure(text: text, linkTarget: linkTarget)
            return cell
        }

        private func makeSeriesCell(
            tableView: NSTableView,
            cellID: NSUserInterfaceItemIdentifier,
            item: BookMetadata,
        ) -> NSView {
            let cell =
                tableView.makeView(withIdentifier: cellID, owner: self) as? SeriesCellView
                ?? SeriesCellView(identifier: cellID)
            cell.configure(series: item.series?.first)
            return cell
        }

        private func makeProgressCell(
            tableView: NSTableView,
            cellID: NSUserInterfaceItemIdentifier,
            item: BookMetadata,
        ) -> NSView {
            let cell =
                tableView.makeView(withIdentifier: cellID, owner: self) as? ProgressCellView
                ?? ProgressCellView(identifier: cellID)
            let progress = mediaViewModel.progress(for: item.id)
            cell.configure(progress: progress)
            return cell
        }

        private func makeTagsCell(
            tableView: NSTableView,
            cellID: NSUserInterfaceItemIdentifier,
            item: BookMetadata,
        ) -> NSView {
            let cell =
                tableView.makeView(withIdentifier: cellID, owner: self) as? HostingCellView
                ?? HostingCellView(identifier: cellID)
            let onLinkClicked = parent.onMetadataLinkClicked
            let content = TagFlowCellContent(
                tags: item.tagNames.sorted {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                },
                onTagClicked: onLinkClicked != nil ? { tag in onLinkClicked?(.tag(tag)) } : nil,
                compact: isCoverHidden,
            )
            cell.setContent(content)
            return cell
        }

        private func creatorNames(_ creators: [BookCreator]?) -> [String] {
            (creators ?? []).compactMap {
                $0.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        }

        private func makeCreatorPillsCell(
            tableView: NSTableView,
            cellID: NSUserInterfaceItemIdentifier,
            names: [String],
            linkBuilder: @escaping (String) -> MetadataLinkTarget,
        ) -> NSView {
            let cell =
                tableView.makeView(withIdentifier: cellID, owner: self) as? HostingCellView
                ?? HostingCellView(identifier: cellID)
            let onLinkClicked = parent.onMetadataLinkClicked
            let content = TagFlowCellContent(
                tags: names,
                onTagClicked: onLinkClicked != nil
                    ? { name in onLinkClicked?(linkBuilder(name)) } : nil,
                compact: isCoverHidden,
            )
            cell.setContent(content)
            return cell
        }

        private func makeAllCreatorsCell(
            tableView: NSTableView,
            cellID: NSUserInterfaceItemIdentifier,
            item: BookMetadata,
        ) -> NSView {
            let cell =
                tableView.makeView(withIdentifier: cellID, owner: self) as? HostingCellView
                ?? HostingCellView(identifier: cellID)
            let excludedRoles: Set<String> = Set(
                visibleColumnIDs.compactMap { MediaTableView.creatorRoleCode(from: $0) }
            )
            let creators = (item.creators ?? []).compactMap { creator -> String? in
                if let role = creator.role, excludedRoles.contains(role) { return nil }
                guard let name = creator.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !name.isEmpty
                else { return nil }
                if let role = creator.role {
                    let label = MediaTableView.labelForRole(role)
                    return "\(name) (\(label))"
                }
                return name
            }
            let content = TagFlowCellContent(
                tags: creators,
                compact: isCoverHidden,
            )
            cell.setContent(content)
            return cell
        }

        private func makeMediaCell(
            tableView: NSTableView,
            cellID: NSUserInterfaceItemIdentifier,
            item: BookMetadata,
        ) -> NSView {
            let cell =
                tableView.makeView(withIdentifier: cellID, owner: self) as? HostingCellView
                ?? HostingCellView(identifier: cellID)
            let content = MediaIndicatorCellContent(item: item, mediaViewModel: mediaViewModel)
            cell.setContent(content)
            return cell
        }

        private func makeDateCell(
            tableView: NSTableView,
            cellID: NSUserInterfaceItemIdentifier,
            dateString: String?,
            field: SilveranDate.Field = .generic,
        ) -> NSView {
            let cell =
                tableView.makeView(withIdentifier: cellID, owner: self) as? DateCellView
                ?? DateCellView(identifier: cellID)
            let parsedDate = SilveranDate.parse(dateString, field: field)
            cell.configure(date: parsedDate, rawString: dateString ?? "")
            return cell
        }

        private func makeLinkDateCell(
            tableView: NSTableView,
            cellID: NSUserInterfaceItemIdentifier,
            dateString: String?,
            linkTarget: MetadataLinkTarget?,
            field: SilveranDate.Field = .generic,
        ) -> NSView {
            let cell =
                tableView.makeView(withIdentifier: cellID, owner: self) as? LinkDateCellView
                ?? LinkDateCellView(identifier: cellID)
            let parsedDate = SilveranDate.parse(dateString, field: field)
            cell.configure(date: parsedDate, rawString: dateString ?? "", linkTarget: linkTarget)
            return cell
        }

        private func resolveCoverVariant(for item: BookMetadata) -> MediaViewModel.CoverVariant {
            mediaViewModel.coverVariant(for: item, preference: coverPreference)
        }
    }
}

#endif
