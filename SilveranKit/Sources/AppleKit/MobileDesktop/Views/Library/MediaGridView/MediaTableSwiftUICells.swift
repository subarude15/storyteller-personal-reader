#if os(macOS)
import SwiftUI
import AppKit

struct CoverCellContent: View {
    let item: BookMetadata
    let coverVariant: MediaViewModel.CoverVariant
    let mediaViewModel: MediaViewModel

    private let height: CGFloat = 40

    private var readaloudStatus: String? {
        item.readaloud?.status?.uppercased()
    }

    var body: some View {
        let coverState = mediaViewModel.coverState(for: item, variant: coverVariant)
        let width = height * coverVariant.preferredAspectRatio

        ZStack {
            Color(white: 0.2)
            if let image = coverState.image {
                image
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            }

            processingOverlay
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .task(id: coverTaskIdentifier) {
            debugLog(
                "[CoverPerf][TableCoverCell] task imageLoaded=\(coverState.image != nil) title='\(item.title)' id=\(item.id) variant=\(coverVariant)"
            )
            mediaViewModel.ensureCoverLoaded(
                for: item,
                variant: coverVariant,
                debugSource: "TableCoverCell",
            )
        }
        .onAppear {
            debugLog(
                "[CoverPerf][TableCoverCell] appear imageLoaded=\(coverState.image != nil) title='\(item.title)' id=\(item.id) variant=\(coverVariant)"
            )
        }
        .onChange(of: coverState.image != nil) { _, loaded in
            debugLog(
                "[CoverPerf][TableCoverCell] imageLoaded changed=\(loaded) title='\(item.title)' id=\(item.id) variant=\(coverVariant)"
            )
        }
        .onDisappear {
            debugLog(
                "[CoverPerf][TableCoverCell] disappear imageLoaded=\(coverState.image != nil) title='\(item.title)' id=\(item.id) variant=\(coverVariant)"
            )
            mediaViewModel.cancelCoverLoad(for: item, variant: coverVariant)
        }
    }

    private var coverTaskIdentifier: String {
        "\(item.id)-\(coverVariant)"
    }

    @ViewBuilder
    private var processingOverlay: some View {
        switch readaloudStatus {
            case "PROCESSING":
                let progress = item.readaloud?.stageProgress ?? 0
                ZStack {
                    Color.black.opacity(0.45)
                    CircularProgressRing(progress: progress)
                        .frame(width: 24, height: 24)
                }
            case "QUEUED":
                ZStack {
                    Color.black.opacity(0.45)
                    Image(systemName: "clock")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                }
            case "ERROR", "STOPPED":
                ZStack {
                    Color.black.opacity(0.45)
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.orange)
                }
            default:
                EmptyView()
        }
    }
}

struct CircularProgressRing: View {
    let progress: Double
    private let lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.3), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(progress, 0), 1)))
                .stroke(Color.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

final class HostingCellView: NSTableCellView {
    private var hostingView: NSHostingView<AnyView>?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// While option is held, become transparent to hit-testing so an option+click on an interactive
    /// pill falls through to the table view, whose `mouseDown` drives quick-edit. Without this the
    /// SwiftUI pill consumes the event and quick-edit only works on the cell's empty padding.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let flags = NSEvent.modifierFlags
        if flags.contains(.option) && !flags.contains(.command) {
            return nil
        }
        return super.hitTest(point)
    }

    func setContent<V: View>(_ view: V) {
        if let existingHostingView = hostingView {
            existingHostingView.rootView = AnyView(view)
        } else {
            let hosting = NSHostingView(rootView: AnyView(view))
            hosting.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
                hosting.topAnchor.constraint(equalTo: topAnchor),
                hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            hostingView = hosting
        }
    }
}

final class TagLayoutState: @unchecked Sendable {
    var visibleCount: Int = 0
}

struct TagFlowCellContent: View {
    let tags: [String]
    var onTagClicked: ((String) -> Void)?
    var compact: Bool = false
    @State private var showPopover = false
    @State private var layoutState = TagLayoutState()

    private var hiddenTags: [String] {
        let count = layoutState.visibleCount
        guard count < tags.count else { return [] }
        return Array(tags.suffix(from: count))
    }

    var body: some View {
        TagFlowLayout(spacing: 4, maxRows: compact ? 1 : 2, state: layoutState) {
            ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                if let onTagClicked {
                    Button {
                        if NSEvent.modifierFlags.contains(.command) {
                            onTagClicked(tag)
                        }
                    } label: {
                        Text(tag)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(tag)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
            }
            Text("\u{2026}")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.25)))
                .layoutValue(key: IsOverflowIndicator.self, value: true)
                .onHover { showPopover = $0 }
                .popover(isPresented: $showPopover) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(hiddenTags, id: \.self) { tag in
                            Text(tag).font(.system(size: 12))
                        }
                    }
                    .padding(8)
                }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct IsOverflowIndicator: LayoutValueKey {
    static let defaultValue = false
}

struct TagFlowLayout: Layout {
    var spacing: CGFloat
    var maxRows: Int
    var state: TagLayoutState

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        computeLayout(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout (),
    ) {
        let result = computeLayout(in: bounds.width, subviews: subviews)
        state.visibleCount = result.visibleCount
        for (i, subview) in subviews.enumerated() {
            if let pos = result.placements[i] {
                let ideal = subview.sizeThatFits(.unspecified)
                let cappedWidth = min(ideal.width, bounds.width)
                subview.place(
                    at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y),
                    proposal: ProposedViewSize(width: cappedWidth, height: ideal.height),
                )
            } else {
                subview.place(
                    at: CGPoint(x: bounds.minX - 10000, y: 0),
                    proposal: .init(width: 0, height: 0),
                )
            }
        }
    }

    private struct ItemInfo {
        let index: Int
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
        let row: Int
    }

    private struct LayoutResult {
        var size: CGSize
        var placements: [Int: CGPoint]
        var visibleCount: Int
    }

    private func computeLayout(in maxWidth: CGFloat, subviews: Subviews) -> LayoutResult {
        var overflowIndex: Int?
        var regularIndices: [Int] = []
        for (i, subview) in subviews.enumerated() {
            if subview[IsOverflowIndicator.self] {
                overflowIndex = i
            } else {
                regularIndices.append(i)
            }
        }

        let overflowSize = overflowIndex.map { subviews[$0].sizeThatFits(.unspecified) } ?? .zero

        var items: [ItemInfo] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var currentRow = 0

        for idx in regularIndices {
            let ideal = subviews[idx].sizeThatFits(.unspecified)
            let size = CGSize(width: min(ideal.width, maxWidth), height: ideal.height)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
                currentRow += 1
            }
            items.append(
                ItemInfo(
                    index: idx,
                    x: x,
                    y: y,
                    width: size.width,
                    height: size.height,
                    row: currentRow,
                )
            )
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        let totalRows = (items.last?.row ?? -1) + 1
        let hasOverflow = totalRows > maxRows

        if !hasOverflow {
            var placements: [Int: CGPoint] = [:]
            var maxW: CGFloat = 0
            for item in items {
                placements[item.index] = CGPoint(x: item.x, y: item.y)
                maxW = max(maxW, item.x + item.width)
            }
            let h = items.last.map { $0.y + $0.height } ?? 0
            return LayoutResult(
                size: CGSize(width: maxW, height: h),
                placements: placements,
                visibleCount: items.count,
            )
        }

        var visible = items.filter { $0.row < maxRows }

        if overflowIndex != nil {
            while let last = visible.last, last.row == maxRows - 1 {
                let afterLast = last.x + last.width + spacing
                if afterLast + overflowSize.width <= maxWidth { break }
                visible.removeLast()
            }
        }

        var placements: [Int: CGPoint] = [:]
        var maxW: CGFloat = 0
        for item in visible {
            placements[item.index] = CGPoint(x: item.x, y: item.y)
            maxW = max(maxW, item.x + item.width)
        }

        if let oi = overflowIndex {
            let ox: CGFloat
            let oy: CGFloat
            if let last = visible.last {
                ox = last.x + last.width + spacing
                oy = last.y
            } else {
                ox = 0
                oy = 0
            }
            placements[oi] = CGPoint(x: ox, y: oy)
            maxW = max(maxW, ox + overflowSize.width)
        }

        let h = visible.last.map { $0.y + $0.height } ?? overflowSize.height
        return LayoutResult(
            size: CGSize(width: maxW, height: h),
            placements: placements,
            visibleCount: visible.count,
        )
    }
}

struct MediaIndicatorCellContent: View {
    let item: BookMetadata
    let mediaViewModel: MediaViewModel

    @Environment(\.openWindow) private var openWindow
    @State private var hoveredType: MediaType?
    @State private var showConnectionAlert = false

    private let iconSize: CGFloat = 20
    private let smallIconSize: CGFloat = 16
    private let readaloudSize: CGFloat = 18
    private let buttonSize: CGFloat = 28

    private var hasConnectionError: Bool {
        mediaViewModel.hasConnectionError(forSourceID: item.sourceID)
    }

    var body: some View {
        HStack(spacing: 6) {
            mediaButton(for: .ebook)
            mediaButton(for: .audio)
            mediaButton(for: .synced)
        }
        .padding(.horizontal, 4)
        .alert("Connection Error", isPresented: $showConnectionAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Cannot download media while disconnected from the server.")
        }
    }

    private enum MediaType: CaseIterable {
        case ebook, audio, synced

        var category: LocalMediaCategory {
            switch self {
                case .ebook: return .ebook
                case .audio: return .audio
                case .synced: return .synced
            }
        }

        var iconName: String {
            switch self {
                case .ebook: return "book.fill"
                case .audio: return "headphones"
                case .synced: return "text.bubble"
            }
        }
    }

    private enum MediaStatus: Equatable {
        case unavailable
        case availableNotDownloaded
        case downloaded
        case downloading(progress: Double?)

        var color: Color {
            switch self {
                case .unavailable: return .gray.opacity(0.3)
                case .availableNotDownloaded: return .blue
                case .downloaded: return .green
                case .downloading: return .blue
            }
        }
    }

    private func mediaStatus(for type: MediaType) -> MediaStatus {
        let category = type.category

        if mediaViewModel.isCategoryDownloadInProgress(for: item, category: category) {
            let progress = mediaViewModel.downloadProgressFraction(for: item, category: category)
            return .downloading(progress: progress)
        }

        if mediaViewModel.isCategoryDownloaded(category, for: item) {
            return .downloaded
        }

        let available: Bool
        switch type {
            case .ebook: available = item.hasAvailableEbook
            case .audio: available = item.hasAvailableAudiobook
            case .synced: available = item.hasAvailableReadaloud
        }

        return available ? .availableNotDownloaded : .unavailable
    }

    @ViewBuilder
    private func mediaButton(for type: MediaType) -> some View {
        let status = mediaStatus(for: type)
        let isHovered = hoveredType == type

        Button {
            handleTap(for: type, status: status)
        } label: {
            ZStack {
                if case .downloading(let progress) = status {
                    DownloadCancelProgressIcon(
                        progress: progress,
                        color: status.color,
                        size: iconSize,
                        lineWidth: 2.5,
                        showsCancel: isHovered,
                    )
                } else if isHovered && status == .availableNotDownloaded {
                    if hasConnectionError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: smallIconSize))
                            .foregroundStyle(.red)
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: iconSize))
                    }
                } else if isHovered && status == .downloaded {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: iconSize))
                } else {
                    if type == .synced {
                        ReadaloudIcon(size: readaloudSize)
                    } else {
                        Image(systemName: type.iconName)
                            .font(.system(size: smallIconSize))
                    }
                }
            }
            .foregroundStyle(status.color)
            .frame(width: buttonSize, height: buttonSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(status == .unavailable)
        .onHover { hovering in
            hoveredType = hovering ? type : nil
        }
        .contextMenu {
            if status == .downloaded && mediaViewModel.hasCachedMedia(type.category, for: item) {
                Button(role: .destructive) {
                    mediaViewModel.deleteDownload(for: item, category: type.category)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func handleTap(for type: MediaType, status: MediaStatus) {
        let category = type.category

        switch status {
            case .availableNotDownloaded:
                if hasConnectionError {
                    showConnectionAlert = true
                } else {
                    mediaViewModel.startDownload(for: item, category: category)
                }
            case .downloaded:
                openMedia(for: category)
            case .downloading:
                mediaViewModel.cancelDownload(for: item, category: category)
            case .unavailable:
                break
        }
    }

    private func openMedia(for category: LocalMediaCategory) {
        guard #available(macOS 13.0, *) else { return }
        let windowID: String
        switch category {
            case .audio:
                windowID = "AudiobookPlayer"
            case .ebook, .synced:
                windowID = "EbookPlayer"
        }
        let path = mediaViewModel.localMediaPath(for: item.id, category: category)
        let variant: MediaViewModel.CoverVariant =
            item.hasAvailableAudiobook ? .audioSquare : .standard
        let cover = mediaViewModel.coverImage(for: item, variant: variant)
        let ebookCover =
            item.hasAvailableAudiobook
            ? mediaViewModel.coverImage(for: item, variant: .standard)
            : nil
        let bookData = PlayerBookData(
            metadata: item,
            localMediaPath: path,
            category: category,
            coverArt: cover,
            ebookCoverArt: ebookCover,
        )
        openWindow(id: windowID, value: bookData)
    }
}

#endif
