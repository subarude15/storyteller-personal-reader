#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI

#if os(iOS)
struct DraggableAudioCard<FullContent: View>: View {
    @Binding var isPresented: Bool
    let alwaysShow: Bool
    let collapseTrigger: Int

    let bookTitle: String?
    let coverArt: Image?
    let ebookCoverArt: Image?
    let chapterTitle: String?
    let isPlaying: Bool
    let chapterProgress: Double
    var bookFraction: Double? = nil
    var currentPage: Int? = nil
    var totalPages: Int? = nil
    var chapterTicks: [ReaderScrubberPolicy.ChapterTick] = []
    var jumpOriginFraction: Double? = nil
    let chapterElapsedSeconds: TimeInterval?
    let chapterTotalSeconds: TimeInterval?
    let bookTimeRemaining: TimeInterval?
    let playbackRate: Double
    let hasAudioNarration: Bool
    let chapters: [ChapterItem]
    let selectedChapterHref: String?
    let sleepTimerActive: Bool
    let sleepTimerRemaining: TimeInterval?
    let sleepTimerType: SleepTimerType?
    let showMiniPlayerStats: Bool
    let supportsComicScrubber: Bool

    let onPlayPause: () -> Void
    let onSkipBackward: () -> Void
    let onSkipForward: () -> Void
    let onPrevChapter: () -> Void
    let onNextChapter: () -> Void
    let onProgressSeek: ((Double) -> Void)?
    var onBookProgressSeek: ((Double) -> Void)? = nil
    var onScrubBegan: (() -> Void)? = nil
    let onPlaybackRateChange: (Double) -> Void
    let onChapterSelected: (ChapterItem) -> Void
    let onSleepTimerStart: (TimeInterval?, SleepTimerType) -> Void
    let onSleepTimerCancel: () -> Void
    let onDismiss: () -> Void
    let onComicScrubberVisibilityChange: (Bool) -> Void
    /// Reports card states that must keep immersive chrome on screen.
    var onChromeBlockersChange: (Set<ReaderChromeBlocker>) -> Void = { _ in }
    /// Card-local controls that do not go through a parent callback (scope,
    /// expand/collapse, drag end) restart the immersive idle window.
    var onActivity: () -> Void = {}
    @ViewBuilder let fullContent: () -> FullContent

    enum CardState {
        case compact
        case scrubber
        case expanded
    }

    @State private var cardState: CardState = .compact
    @State private var dragOffset: CGFloat = 0
    @GestureState private var isDragging = false
    @State private var sliderValue: Double = 0
    @State private var isDraggingSlider = false
    @State private var scrubScope: ReaderScrubberPolicy.ScrubScope = .book
    @AppStorage("showEbookCoverInAudioView") private var showEbookCover = false

    /// Pure ebook mode (no audio narration, not a comic) uses the Apple Books bottom scrubber.
    private var isPureEbook: Bool {
        !hasAudioNarration && !supportsComicScrubber
    }

    /// When tap-revealed in a pure ebook, show the Apple Books scrubber directly without an extra tap.
    private var usesDirectEbookScrubber: Bool {
        isPureEbook && !alwaysShow
    }

    private var compactHeight: CGFloat {
        if usesDirectEbookScrubber {
            return 126
        }
        return showMiniPlayerStats ? 54 : 50
    }

    private let expandedFraction: CGFloat = 1.0
    private let scrubberFraction: CGFloat = 0.28
    private let dragThreshold: CGFloat = 40

    private var effectiveScope: ReaderScrubberPolicy.ScrubScope {
        if supportsComicScrubber {
            return .chapter
        }
        if chapterTicks.count <= 1 {
            return .chapter
        }
        return scrubScope
    }

    private var chromeBlockers: Set<ReaderChromeBlocker> {
        guard isPresented else { return [] }
        var blockers: Set<ReaderChromeBlocker> = []
        if cardState != .compact { blockers.insert(.cardExpanded) }
        if isDraggingSlider {
            blockers.insert(.scrubbing)
        } else if isDragging {
            blockers.insert(.cardDrag)
        }
        return blockers
    }

    private var activeSourceFraction: Double {
        switch effectiveScope {
            case .book:
                return min(max(bookFraction ?? chapterProgress, 0.0), 1.0)
            case .chapter:
                return min(max(chapterProgress, 0.0), 1.0)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let screenHeight = geometry.size.height
            let safeAreaBottom = geometry.safeAreaInsets.bottom
            let expandedHeight = screenHeight * expandedFraction
            let scrubberHeight = max(screenHeight * scrubberFraction, 174)

            let targetHeight: CGFloat =
                switch cardState {
                    case .compact: compactHeight + safeAreaBottom
                    case .scrubber: scrubberHeight
                    case .expanded: expandedHeight
                }

            let currentHeight =
                isDragging && !isDraggingSlider
                ? max(0, min(expandedHeight, targetHeight - dragOffset))
                : targetHeight
            let cardContentAlignment: Alignment =
                (cardState == .scrubber || usesDirectEbookScrubber) ? .top : .center

            ZStack(alignment: .bottom) {
                if isPresented {
                    VStack(spacing: 0) {
                        if cardState != .compact || usesDirectEbookScrubber {
                            dragHandleView(
                                compact: false,
                                tight: cardState == .scrubber || usesDirectEbookScrubber
                            )
                        }

                        switch cardState {
                            case .compact:
                                if usesDirectEbookScrubber {
                                    ebookScrubberContent
                                        .transition(.opacity)
                                } else {
                                    compactPlayerContent
                                        .transition(.opacity)
                                }
                            case .scrubber:
                                if supportsComicScrubber {
                                    comicScrubberContent
                                        .transition(.opacity)
                                } else {
                                    ebookScrubberContent
                                        .transition(.opacity)
                                }
                            case .expanded:
                                fullContent()
                                    .transition(.opacity)
                        }

                        if cardState == .compact && hasAudioNarration && showMiniPlayerStats {
                            compactStatsRow
                                .frame(height: safeAreaBottom)
                        } else if cardState == .scrubber || usesDirectEbookScrubber {
                            Color.clear
                                .frame(height: safeAreaBottom)
                        } else {
                            Spacer(minLength: safeAreaBottom)
                        }
                    }
                    .overlay(alignment: .top) {
                        if cardState == .compact && !usesDirectEbookScrubber {
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(Color.secondary.opacity(0.5))
                                .frame(width: 36, height: 5)
                                .padding(.top, showMiniPlayerStats ? 14 : 22)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if cardState != .compact {
                            Button(action: {
                                onActivity()
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                    cardState = .compact
                                }
                            }) {
                                Image(systemName: "chevron.down")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 12)
                            .padding(.trailing, 16)
                        }
                    }
                    .frame(height: currentHeight, alignment: cardContentAlignment)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .modifier(GlassEffectModifier())
                    .gesture(
                        DragGesture(minimumDistance: 14)
                            .updating($isDragging) { _, state, _ in
                                if !isDraggingSlider {
                                    state = true
                                }
                            }
                            .onChanged { value in
                                guard !isDraggingSlider else { return }
                                dragOffset = value.translation.height
                            }
                            .onEnded { value in
                                guard !isDraggingSlider else { return }
                                onActivity()
                                handleDragEnd(
                                    translation: value.translation.height,
                                    velocity: value.predictedEndTranslation.height
                                        - value.translation.height,
                                    screenHeight: screenHeight,
                                )
                            }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(edges: .bottom)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isPresented)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: cardState)
        .animation(.interactiveSpring(), value: dragOffset)
        .onChange(of: isDragging) { _, newValue in
            if !newValue && dragOffset != 0 {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    dragOffset = 0
                }
            }
        }
        .onChange(of: activeSourceFraction) { _, newValue in
            if !isDraggingSlider {
                sliderValue = newValue
            }
        }
        .onChange(of: collapseTrigger) { _, _ in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                cardState = .compact
            }
        }
        .onChange(of: cardState) { _, newValue in
            onComicScrubberVisibilityChange(
                isPresented && supportsComicScrubber && newValue == .scrubber
            )
        }
        .onChange(of: isPresented) { _, newValue in
            onComicScrubberVisibilityChange(
                newValue && supportsComicScrubber && cardState == .scrubber
            )
        }
        .onAppear {
            sliderValue = activeSourceFraction
            onComicScrubberVisibilityChange(
                isPresented && supportsComicScrubber && cardState == .scrubber
            )
        }
        .onChange(of: chromeBlockers, initial: true) { _, blockers in
            onChromeBlockersChange(blockers)
        }
        .onDisappear {
            onComicScrubberVisibilityChange(false)
            onChromeBlockersChange([])
        }
    }

    private func dragHandleView(compact: Bool, tight: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(Color.secondary.opacity(0.5))
            .frame(width: 36, height: 5)
            .padding(.top, tight ? 10 : (compact ? 10 : 12))
            .padding(.bottom, tight ? 6 : (compact ? 6 : 8))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
    }

    private var displayedCover: Image? {
        if showEbookCover, let ebookCover = ebookCoverArt {
            return ebookCover
        }
        return coverArt
    }

    private var canToggleCover: Bool {
        coverArt != nil && ebookCoverArt != nil
    }

    private var compactPlayerContent: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                if let cover = displayedCover {
                    cover
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 40, height: 40)
                        .overlay(
                            Image(systemName: "book.fill")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        )
                }

                VStack(alignment: .leading, spacing: 2) {
                    if let title = bookTitle {
                        Text(title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                    }

                    if let chapter = chapterTitle {
                        Text(chapter)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onActivity()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    cardState = (supportsComicScrubber || isPureEbook) ? .scrubber : .expanded
                }
            }

            Spacer(minLength: 0)

            if hasAudioNarration {
                HStack(spacing: 15) {
                    PlaybackRateButton(
                        currentRate: playbackRate,
                        onRateChange: onPlaybackRateChange,
                        showLabel: true,
                        buttonSize: showMiniPlayerStats ? 32 : 36,
                        showBackground: false,
                        compactLabel: true,
                        iconFont: showMiniPlayerStats ? .body : .title3,
                    )

                    Button(action: onPlayPause) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(showMiniPlayerStats ? .title2 : .title)
                            .frame(
                                width: showMiniPlayerStats ? 48 : 54,
                                height: showMiniPlayerStats ? 48 : 54,
                            )
                            .background(
                                Circle()
                                    .fill(Color.primary.opacity(0.1))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, showMiniPlayerStats ? 20 : 28)
    }

    /// Apple Books–style interactive bottom scrubber for ebooks with chapter tick marks,
    /// live chapter/page preview, scope toggle (`Book` vs `Chapter`), and quick chapter stepping.
    private var ebookScrubberContent: some View {
        let currentFraction = isDraggingSlider ? sliderValue : activeSourceFraction
        let liveChapterLabel: String = {
            if effectiveScope == .book,
                let tick = ReaderScrubberPolicy.activeChapter(
                    atBookFraction: currentFraction,
                    ticks: chapterTicks
                )
            {
                return tick.label
            }
            return chapterTitle ?? bookTitle ?? "Reading"
        }()

        let calloutSubtitle: String = {
            switch effectiveScope {
                case .book:
                    let pct = Int((currentFraction * 100).rounded())
                    return "\(pct)% of book"
                case .chapter:
                    if let total = totalPages, total > 0 {
                        let page = ReaderScrubberPolicy.pageNumber(
                            forChapterFraction: currentFraction,
                            totalPages: total
                        )
                        return "Page \(page) of \(total)"
                    }
                    let pct = Int((currentFraction * 100).rounded())
                    return "\(pct)% of chapter"
            }
        }()

        return VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text(liveChapterLabel)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if chapterTicks.count > 1 {
                    Button {
                        onActivity()
                        ReaderHaptics.selectionTick()
                        withAnimation(.easeInOut(duration: 0.18)) {
                            scrubScope = (scrubScope == .book) ? .chapter : .book
                            sliderValue = activeSourceFraction
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(
                                systemName: effectiveScope == .book
                                    ? "book.closed.fill" : "doc.text.fill"
                            )
                            .font(.caption2)
                            Text(effectiveScope == .book ? "Book" : "Chapter")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.secondary.opacity(0.14))
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        effectiveScope == .book
                            ? "Scrubbing entire book. Tap to scrub current chapter."
                            : "Scrubbing current chapter. Tap to scrub entire book."
                    )
                }
            }

            AppleBooksScrubberTrack(
                value: activeSourceFraction,
                scope: effectiveScope,
                chapterTicks: chapterTicks,
                totalPagesInChapter: totalPages,
                jumpOriginFraction: effectiveScope == .book ? jumpOriginFraction : nil,
                accentColor: .primary,
                trackColor: Color.secondary.opacity(0.24),
                calloutTitle: liveChapterLabel,
                calloutSubtitle: calloutSubtitle,
                onScrubBegan: {
                    isDraggingSlider = true
                    onScrubBegan?()
                },
                onScrubChanged: { newFraction in
                    sliderValue = newFraction
                    switch effectiveScope {
                        case .book:
                            if let onBookProgressSeek {
                                onBookProgressSeek(newFraction)
                            } else {
                                onProgressSeek?(newFraction)
                            }
                        case .chapter:
                            onProgressSeek?(newFraction)
                    }
                },
                onScrubEnded: { finalFraction in
                    sliderValue = finalFraction
                    isDraggingSlider = false
                    switch effectiveScope {
                        case .book:
                            if let onBookProgressSeek {
                                onBookProgressSeek(finalFraction)
                            } else {
                                onProgressSeek?(finalFraction)
                            }
                        case .chapter:
                            onProgressSeek?(finalFraction)
                    }
                }
            )

            HStack(spacing: 16) {
                Button {
                    ReaderHaptics.chapterBoundaryCrossed()
                    onPrevChapter()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.bold))
                        Text("Ch.")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                    .frame(height: 28)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Previous chapter")

                Text(ebookStatusSummary(for: currentFraction))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)

                Button {
                    ReaderHaptics.chapterBoundaryCrossed()
                    onNextChapter()
                } label: {
                    HStack(spacing: 3) {
                        Text("Ch.")
                            .font(.caption2.weight(.medium))
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(.secondary)
                    .frame(height: 28)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next chapter")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 2)
    }

    private func ebookStatusSummary(for fraction: Double) -> String {
        var parts: [String] = []
        if effectiveScope == .chapter, isDraggingSlider, let total = totalPages, total > 0 {
            let scrubbedPage = ReaderScrubberPolicy.pageNumber(
                forChapterFraction: fraction,
                totalPages: total
            )
            parts.append("Page \(scrubbedPage) of \(total)")
        } else if let current = currentPage, let total = totalPages, total > 0 {
            parts.append("Page \(current) of \(total)")
        }

        let bookPctValue: Double? = {
            if effectiveScope == .book, isDraggingSlider {
                return fraction
            }
            return bookFraction
        }()
        if let bookPctValue {
            let pct = Int((min(max(bookPctValue, 0.0), 1.0) * 100).rounded())
            parts.append("\(pct)%")
        }

        if parts.isEmpty {
            let pct = Int((min(max(fraction, 0.0), 1.0) * 100).rounded())
            return "\(pct)%"
        }
        return parts.joined(separator: " · ")
    }

    private var comicScrubberContent: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                if let cover = displayedCover {
                    cover
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 3) {
                    if let title = bookTitle {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                    if let chapterTitle {
                        Text(chapterTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }

            AppleBooksScrubberTrack(
                value: chapterProgress,
                scope: .chapter,
                chapterTicks: [],
                totalPagesInChapter: chapters.count,
                jumpOriginFraction: jumpOriginFraction,
                accentColor: .primary,
                trackColor: Color.secondary.opacity(0.24),
                calloutTitle: comicProgressLabel,
                calloutSubtitle: nil,
                onScrubBegan: {
                    isDraggingSlider = true
                    onScrubBegan?()
                },
                onScrubChanged: { newValue in
                    sliderValue = min(max(newValue, 0), 1)
                    onProgressSeek?(sliderValue)
                },
                onScrubEnded: { finalValue in
                    sliderValue = min(max(finalValue, 0), 1)
                    isDraggingSlider = false
                    onProgressSeek?(sliderValue)
                }
            )

            HStack(spacing: 20) {
                Button {
                    ReaderHaptics.selectionTick()
                    onPrevChapter()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                        .frame(width: 40, height: 34)
                }
                .buttonStyle(.plain)

                Text(comicProgressLabel)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)

                Button {
                    ReaderHaptics.selectionTick()
                    onNextChapter()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.title3.weight(.semibold))
                        .frame(width: 40, height: 34)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 2)
    }

    private var comicProgressLabel: String {
        guard !chapters.isEmpty else { return "" }
        let selectedPage = selectedChapterHref.flatMap(Int.init)
        let page =
            if isDraggingSlider {
                min(
                    max(Int((sliderValue * Double(chapters.count)).rounded(.down)) + 1, 1),
                    chapters.count,
                )
            } else if let selectedPage {
                min(max(selectedPage + 1, 1), chapters.count)
            } else {
                min(
                    max(Int((sliderValue * Double(chapters.count)).rounded(.down)) + 1, 1),
                    chapters.count,
                )
            }
        return "Page \(page) of \(chapters.count)"
    }

    private var compactStatsRow: some View {
        HStack(spacing: 24) {
            if let bookRemaining = bookTimeRemaining {
                HStack(spacing: 4) {
                    Image(systemName: "book.fill")
                        .font(.caption2)
                    Text(formatTimeHoursMinutes(bookRemaining))
                        .font(.caption2.monospacedDigit())
                }
                .foregroundStyle(.secondary)
            }

            if let chapterRemaining = chapterTimeRemaining {
                HStack(spacing: 4) {
                    Text(formatTimeMinutesSeconds(chapterRemaining))
                        .font(.caption2.monospacedDigit())
                    Image(systemName: "bookmark.fill")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }

    private var chapterTimeRemaining: TimeInterval? {
        guard let elapsed = chapterElapsedSeconds, let total = chapterTotalSeconds,
            playbackRate > 0
        else {
            return nil
        }
        return max(0, total - elapsed) / playbackRate
    }

    private func handleDragEnd(translation: CGFloat, velocity: CGFloat, screenHeight: CGFloat) {
        let velocityThreshold: CGFloat = 500

        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            dragOffset = 0

            switch cardState {
                case .compact:
                    let isSwipeUp = translation < -dragThreshold || velocity < -velocityThreshold
                    let isSwipeDown = translation > dragThreshold || velocity > velocityThreshold
                    if isSwipeUp && !usesDirectEbookScrubber {
                        cardState =
                            (supportsComicScrubber || isPureEbook) ? .scrubber : .expanded
                    } else if isSwipeDown && !alwaysShow {
                        isPresented = false
                    }

                case .scrubber:
                    let isSwipeDown = translation > dragThreshold || velocity > velocityThreshold
                    if isSwipeDown {
                        cardState = .compact
                    }

                case .expanded:
                    let isSwipeDown = translation > dragThreshold || velocity > velocityThreshold
                    if isSwipeDown {
                        cardState = .compact
                    }
            }
        }
    }
}

private struct GlassEffectModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    private let shape = UnevenRoundedRectangle(
        topLeadingRadius: 16,
        bottomLeadingRadius: 0,
        bottomTrailingRadius: 0,
        topTrailingRadius: 16,
        style: .continuous,
    )

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content
                .background(
                    shape
                        .fill(Color(uiColor: .systemBackground))
                )
                .clipShape(shape)
                .shadow(color: .black.opacity(0.15), radius: 8, y: -2)
        }
    }
}
#endif

#endif
