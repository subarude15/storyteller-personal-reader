//
//  ContinueWidgetPublisher.swift
//  SilveranAppleKit
//
//  Pushes Home Continue / Now Playing into the App Group for WidgetKit.
//

#if os(iOS)
import Foundation
import SilveranAppleWidgets
import SilveranKit
import UIKit

@MainActor
public enum ContinueWidgetPublisher {
    private static var installed = false
    private static var publishTask: Task<Void, Never>?

    /// Call once from the host shell. Installs Darwin toggle/open observers and
    /// starts mirroring the audio session into the Continue widget snapshot.
    public static func install() {
        guard !installed else { return }
        installed = true

        ContinueWidgetBridge.installAppObservers(
            onToggle: {
                Task { @MainActor in
                    await handleToggleFromWidget()
                }
            },
            onOpen: {
                Task { @MainActor in
                    InkAmpPendingDeepLinkStore.shared.set(.continueItem(nil))
                    InkAmpContinueLink.notifyPendingDeepLinkReady()
                }
            },
        )

        AudioSessionMonitor.shared.start()
        Task {
            await AudioSessionActor.shared.addSnapshotObserver { snapshot in
                Task { @MainActor in
                    schedulePublishFromSession(snapshot)
                }
            }
        }
    }

    /// Refresh from Home Continue. Live audio session always wins the Now card
    /// (books via cachedCoverData); otherwise write the Home continueItem even
    /// when cover bytes are nil. `upNext` is the following Home mixed-queue rows
    /// (at most 3). Pass `[]` to clear them. Session-only republishes keep the
    /// last Up next by calling the snapshot store with `upNext: nil`.
    public static func publishHomeContinue(
        title: String?,
        subtitle: String?,
        kind: ContinueWidgetKindTag?,
        coverData: Data?,
        progress: Double? = nil,
        durationSeconds: Double? = nil,
        upNext: [ContinueWidgetUpNextDraft] = [],
    ) {
        Task { @MainActor in
            let session = await AudioSessionActor.shared.currentSnapshot()
            if session != nil {
                await publishSession(session, upNext: upNext)
                return
            }
            ContinueWidgetSnapshotStore.publish(
                title: title,
                subtitle: subtitle,
                isPlaying: false,
                kind: kind,
                coverData: coverData,
                progress: progress,
                durationSeconds: durationSeconds,
                hasLiveSession: false,
                upNext: upNext,
            )
        }
    }

    public static func consumePendingWidgetCommands() {
        if ContinueWidgetBridge.consumePendingToggle() {
            Task { await handleToggleFromWidget() }
        }
        if ContinueWidgetBridge.consumePendingOpen() {
            InkAmpPendingDeepLinkStore.shared.set(.continueItem(nil))
            InkAmpContinueLink.notifyPendingDeepLinkReady()
        }
    }

    private static func schedulePublishFromSession(_ snapshot: AudioSessionSnapshot?) {
        publishTask?.cancel()
        publishTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            // Keep the Home queue rows already in the snapshot.
            await publishSession(snapshot, upNext: nil)
        }
    }

    private static func publishSession(
        _ snapshot: AudioSessionSnapshot?,
        upNext: [ContinueWidgetUpNextDraft]? = nil,
    ) async {
        guard let snapshot else {
            // Session ended — keep title/cover, clear playing so the tile isn't stuck.
            let last = ContinueWidgetSnapshotStore.loadSnapshot()
            guard last.isPlaying || (last.hasLiveSession ?? false) || upNext != nil else { return }
            ContinueWidgetSnapshotStore.publish(
                title: last.title,
                subtitle: last.subtitle,
                isPlaying: false,
                kind: last.kind,
                coverData: nil,
                progress: last.progress,
                elapsedSeconds: last.elapsedSeconds,
                durationSeconds: last.durationSeconds,
                hasLiveSession: false,
                rate: last.rate,
                upNext: upNext,
            )
            return
        }

        let kind: ContinueWidgetKindTag
        switch snapshot.kind {
            case .audiobook: kind = .audiobook
            case .readaloud: kind = .readaloud
            case .podcast: kind = .podcast
        }

        var coverData: Data?
        if case .podcast = snapshot.kind {
            if let image = AudioSessionMonitor.shared.coverImage {
                coverData = image.jpegData(compressionQuality: 0.82)
            }
            if coverData == nil, let url = PodcastPlayerPresenter.shared.artworkURL {
                coverData = try? await URLSession.shared.data(from: url).0
            }
        } else {
            let bookID = snapshot.kind.bookID
            coverData = await BookServiceActor.shared.cachedCoverData(for: bookID, audio: true)
            if coverData == nil {
                coverData = await BookServiceActor.shared.cachedCoverData(for: bookID, audio: false)
            }
        }

        let queue = upNext?.filter { draft in
            draft.title.trimmingCharacters(in: .whitespacesAndNewlines) != snapshot.title
        }
        ContinueWidgetSnapshotStore.publish(
            title: snapshot.title,
            subtitle: snapshot.author ?? snapshot.chapterLabel,
            isPlaying: snapshot.isPlaying,
            kind: kind,
            coverData: coverData,
            progress: snapshot.bookProgress,
            elapsedSeconds: snapshot.elapsedSeconds,
            durationSeconds: snapshot.durationSeconds,
            hasLiveSession: true,
            rate: snapshot.playbackRate,
            upNext: queue,
        )
    }

    private static func handleToggleFromWidget() async {
        if await AudioSessionActor.shared.currentSnapshot() != nil {
            try? await AudioSessionActor.shared.transport(.togglePlayPause)
            let fresh = await AudioSessionActor.shared.currentSnapshot()
            await publishSession(fresh)
        } else {
            InkAmpPendingDeepLinkStore.shared.set(.continueItem(nil))
            InkAmpContinueLink.notifyPendingDeepLinkReady()
        }
    }
}
#endif
