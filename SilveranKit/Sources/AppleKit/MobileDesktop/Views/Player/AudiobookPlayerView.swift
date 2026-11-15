#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

public struct AudiobookPlayerView: View {
    private let bookData: PlayerBookData?
    private let onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel?
    #endif

    @State private var sessionState: AudiobookSessionState?
    @State private var chapterProgress = 0.0
    @State private var errorMessage: String?
    @State private var stateObserverID: UUID?
    @State private var showServerPositionDialog = false
    @State private var lastPendingServerPosition: AudiobookSessionServerPosition?
    @State private var showListeningHistory = false
    @State private var toastMessage: String?
    @State private var toastDismissTask: Task<Void, Never>?
    @State private var didJustBookmarkSpot = false
    #if os(iOS)
    @State private var showFormatSwitchDialog = false
    #endif

    public init(bookData: PlayerBookData?, onClose: (() -> Void)? = nil) {
        self.bookData = bookData
        self.onClose = onClose
    }

    public var body: some View {
        ZStack(alignment: .top) {
            readingSidebarView
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 8) {
                if showServerPositionDialog {
                    serverPositionBanner
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if let toastMessage {
                    toastPill(message: toastMessage)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .animation(.spring(response: 0.34, dampingFraction: 0.82), value: showServerPositionDialog)
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: toastMessage)
        }
            .inkAmpAppThemed()
            #if os(iOS)
        .formatSwitchDiscrepancyDialog()
        .toolbar(.hidden, for: .tabBar)
            #endif
            .alert("Audiobook Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") {
                    errorMessage = nil
                }
            } message: {
                if let error = errorMessage {
                    Text(error)
                }
            }
            .sheet(isPresented: $showListeningHistory) {
                if let bookData {
                    AudiobookListeningHistoryView(
                        bookID: bookData.metadata.id,
                        bookTitle: bookData.metadata.title,
                    )
                }
            }
            .onAppear {
                Task { @MainActor in
                    await openSession()
                }
            }
            .onDisappear {
                #if os(iOS)
                debugLog(
                    "[AudiobookPlayerView] onDisappear scenePhase=\(scenePhase) bookId=\(bookData?.metadata.uuid ?? "nil")"
                )
                guard scenePhase == .active else {
                    debugLog(
                        "[AudiobookPlayerView] Background disappear - preserving audio playback"
                    )
                    return
                }
                let keepsSession = PlayerPresenter.shared.cardDismissalKeepsSession()
                #else
                let keepsSession = false
                #endif

                let observerID = stateObserverID
                stateObserverID = nil
                let bookID = bookData?.metadata.id
                Task {
                    if let observerID {
                        await AudioSessionActor.shared.removeStateObserver(id: observerID)
                    }
                    if !keepsSession, let bookID {
                        await AudioSessionActor.shared.close(ifOwnedBy: bookID)
                    }
                }
            }
            #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: .appWillResignActive)) { _ in
            var backgroundTask: UIBackgroundTaskIdentifier = .invalid
            backgroundTask = UIApplication.shared.beginBackgroundTask {
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                    backgroundTask = .invalid
                }
            }
            Task {
                await AudioSessionActor.shared.flushLifecycleProgress(reason: .appBackgrounding)
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                    backgroundTask = .invalid
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    closeBook()
                } label: {
                    Label("Library", systemImage: "chevron.left")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !audiobookSwitchableFormats.isEmpty {
                    Button {
                        showFormatSwitchDialog = true
                    } label: {
                        Label("Switch Format", systemImage: "arrow.left.arrow.right")
                    }
                    .accessibilityLabel("Switch Format")
                }
                Button {
                    markCurrentSpot()
                } label: {
                    Label(
                        "Bookmark Spot",
                        systemImage: didJustBookmarkSpot ? "bookmark.fill" : "bookmark"
                    )
                }
                .accessibilityLabel("Bookmark current listening spot")
                Button {
                    showListeningHistory = true
                } label: {
                    Label("Previous Positions", systemImage: "clock.arrow.circlepath")
                }
            }
        }
        .confirmationDialog(
            "Switch Format",
            isPresented: $showFormatSwitchDialog,
            titleVisibility: .visible,
        ) {
            ForEach(audiobookSwitchableFormats, id: \.category) { format in
                Button(format.label) {
                    Task { await switchAudiobookFormat(to: format.category) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .navigationBarBackButtonHidden(true)
        #endif
    }

    #if os(iOS)
    private var audiobookSwitchableFormats: [(label: String, category: LocalMediaCategory)] {
        guard let book = bookData?.metadata, let mediaViewModel else { return [] }
        return FormatSwitchCoordinator.availableFormats(for: book, mediaViewModel: mediaViewModel)
            .filter { $0.category != .audio }
            .map { (FormatSwitchLabels.title(for: $0.category), $0.category) }
    }

    private func switchAudiobookFormat(to destination: LocalMediaCategory) async {
        guard let book = bookData?.metadata, let mediaViewModel else { return }
        await FormatSwitchCoordinator.switchFormat(
            from: book,
            sourceCategory: .audio,
            to: destination,
            mediaViewModel: mediaViewModel,
        )
    }
    #endif

    #if os(iOS)
    private func closeBook() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
    #endif

    private var readingSidebarView: some View {
        let state = sessionState
        let currentChapter = state?.currentChapterIndex.flatMap { index in
            state?.chapters[safe: index]
        }
        let chapters =
            state?.chapters.map { chapter in
                ChapterItem(
                    id: chapter.id,
                    label: chapter.title,
                    href: chapter.id,
                    level: 0,
                )
            } ?? []
        let sleepTimerType = state?.sleepTimerMode.map { mode in
            switch mode {
                case .duration: SleepTimerType.duration
                case .endOfChapter: SleepTimerType.endOfChapter
            }
        }
        let progressData = state.map { state in
            ProgressData(
                chapterId: state.currentChapterID,
                chapterLabel: currentChapter?.title,
                chapterCurrentPage: nil,
                chapterTotalPages: nil,
                chapterCurrentSecondsAudio: state.chapterElapsed,
                chapterTotalSecondsAudio: state.chapterDuration,
                bookCurrentSecondsAudio: state.currentTime,
                bookTotalSecondsAudio: state.duration,
                bookCurrentFraction: state.bookProgress,
            )
        }

        return ReadingSidebarView(
            bookData: bookData,
            model: .init(
                title: state?.title ?? bookData?.metadata.title ?? "Unknown Book",
                author: state?.author ?? bookData?.metadata.authors?.first?.name
                    ?? "Unknown Author",
                chapterTitle: currentChapter?.title ?? "Loading...",
                coverArt: bookData?.coverArt,
                ebookCoverArt: bookData?.ebookCoverArt,
                chapterDuration: state?.chapterDuration ?? 0,
                totalRemaining: max(0, (state?.duration ?? 0) - (state?.currentTime ?? 0)),
                playbackRate: state?.playbackRate ?? 1,
                volume: state?.volume ?? 1,
                isPlaying: state?.isPlaying ?? false,
                sleepTimerActive: state?.sleepTimerMode != nil,
                sleepTimerRemaining: state?.sleepTimerRemaining,
                sleepTimerType: sleepTimerType,
            ),
            mode: .audiobook,
            chapterProgress: $chapterProgress,
            chapters: chapters,
            progressData: progressData,
            onChapterSelected: { chapter in
                control(.selectChapter(chapter.id))
            },
            onPrevChapter: {
                control(.previousChapter)
            },
            onSkipBackward: {
                control(.skipBackward)
            },
            onPlayPause: {
                control(.togglePlayPause)
            },
            onSkipForward: {
                control(.skipForward)
            },
            onNextChapter: {
                control(.nextChapter)
            },
            onPlaybackRateChange: { rate in
                control(.setPlaybackRate(rate))
            },
            onVolumeChange: { volume in
                control(.setVolume(volume))
            },
            onSleepTimerStart: { duration, type in
                if type == .endOfChapter {
                    control(.startEndOfChapterSleepTimer)
                    presentToast("Sleep timer: End of chapter")
                } else if let duration {
                    control(.startSleepTimer(duration))
                    let mins = max(1, Int(round(duration / 60)))
                    presentToast("Sleep timer: \(mins) min")
                }
            },
            onSleepTimerCancel: {
                control(.cancelSleepTimer)
                presentToast("Sleep timer off")
            },
            onProgressSeek: { fraction in
                control(.seekChapterFraction(fraction))
            },
            seekWhileDragging: false,
        )
    }

    @MainActor
    private func markCurrentSpot() {
        ReaderHaptics.bookmarkToggled(added: true)
        didJustBookmarkSpot = true
        presentToast("Saved to Previous Positions")
        Task {
            await AudioSessionActor.shared.markListeningSpot()
            try? await Task.sleep(for: .seconds(1.5))
            await MainActor.run {
                didJustBookmarkSpot = false
            }
        }
    }

    @MainActor
    private func presentToast(_ message: String) {
        toastDismissTask?.cancel()
        toastMessage = message
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            if !Task.isCancelled {
                toastMessage = nil
            }
        }
    }

    private var serverPositionBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("Newer Server Position")
                    .font(.subheadline.weight(.semibold))
                Text(serverPositionCompactSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button("Stay") {
                    ReaderHaptics.selectionTick()
                    control(.declineServerPosition)
                    showServerPositionDialog = false
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Sync") {
                    ReaderHaptics.selectionTick()
                    control(.acceptServerPosition)
                    showServerPositionDialog = false
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
    }

    private func toastPill(message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            Text(message)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 3)
    }

    private var serverPositionCompactSummary: String {
        guard let position = sessionState?.pendingServerPosition else {
            return "Another device synced a newer position."
        }
        var details: [String] = []
        if let title = position.title, !title.isEmpty {
            details.append(title)
        }
        if let progression = position.totalProgression {
            details.append("\(Int(progression * 100))%")
        }
        if details.isEmpty {
            return "Another device synced a newer position."
        }
        return details.joined(separator: " · ")
    }

    @MainActor
    private func openSession() async {
        guard let bookData else {
            errorMessage = "No audiobook file available"
            return
        }
        if bookData.resolvedAudiobookID != nil {
            await openResolvedSession(bookData)
            return
        }
        guard let mediaURL = bookData.localMediaPath else {
            errorMessage = "No audiobook file available"
            return
        }

        do {
            try await AudioSessionActor.shared.openAudiobook(
                book: bookData.metadata,
                mediaURL: mediaURL,
            )
            await observeSession()
        } catch {
            errorMessage = "Failed to load audiobook: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func openResolvedSession(_ bookData: PlayerBookData) async {
        guard let context = await ResolvedAudiobookLaunch.shared.context(for: bookData.metadata.id)
        else {
            errorMessage = AudiobookResolutionFailure.playbackSourceUnavailable.message
            return
        }
        do {
            try await AudioSessionActor.shared.openResolvedAudiobook(
                book: bookData.metadata,
                prepared: context.metadata,
                playback: context.playback,
                startAt: context.startAt,
            )
            await observeSession()
        } catch {
            errorMessage = AudiobookResolutionFailure.playbackSourceUnavailable.message
        }
    }

    @MainActor
    private func observeSession() async {
        if stateObserverID == nil {
            stateObserverID = await AudioSessionActor.shared.addStateObserver { state in
                Task { @MainActor in
                    applySessionState(state)
                }
            }
        }
        applySessionState(await AudioSessionActor.shared.currentState())
    }

    @MainActor
    private func applySessionState(_ state: AudiobookSessionState?) {
        sessionState = state
        if let state {
            chapterProgress = state.chapterProgress
            if state.pendingServerPosition != lastPendingServerPosition {
                lastPendingServerPosition = state.pendingServerPosition
                showServerPositionDialog = state.pendingServerPosition != nil
            }
        } else {
            lastPendingServerPosition = nil
            showServerPositionDialog = false
        }
    }

    private func control(_ command: AudiobookSessionCommand) {
        Task {
            do {
                try await AudioSessionActor.shared.control(command)
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private var serverPositionDescription: String {
        guard let position = sessionState?.pendingServerPosition else {
            return "Another device has synced a more recent reading position."
        }
        var details: [String] = []
        if let title = position.title {
            details.append(title)
        }
        if let progression = position.totalProgression {
            details.append("\(Int(progression * 100))%")
        }
        let location = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
        return
            "Another device has synced a more recent reading position\(location). Would you like to go to that location?"
    }
}

#endif
