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
                    NotificationCenter.default.post(name: .punkRallyOpenContinue, object: nil)
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

    /// Refresh from Home Continue when nothing is on the shared session.
    public static func publishHomeContinue(
        title: String?,
        subtitle: String?,
        kind: ContinueWidgetKindTag?,
        coverData: Data?,
    ) {
        Task { @MainActor in
            let session = await AudioSessionActor.shared.currentSnapshot()
            if session != nil {
                // Live session wins over Home queue.
                return
            }
            ContinueWidgetSnapshotStore.publish(
                title: title,
                subtitle: subtitle,
                isPlaying: false,
                kind: kind,
                coverData: coverData,
            )
        }
    }

    public static func consumePendingWidgetCommands() {
        if ContinueWidgetBridge.consumePendingToggle() {
            Task { await handleToggleFromWidget() }
        }
        if ContinueWidgetBridge.consumePendingOpen() {
            NotificationCenter.default.post(name: .punkRallyOpenContinue, object: nil)
        }
    }

    private static func schedulePublishFromSession(_ snapshot: AudioSessionSnapshot?) {
        publishTask?.cancel()
        publishTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await publishSession(snapshot)
        }
    }

    private static func publishSession(_ snapshot: AudioSessionSnapshot?) async {
        guard let snapshot else {
            // Session ended — keep title/cover, clear playing so the tile isn't stuck.
            let last = ContinueWidgetSnapshotStore.loadSnapshot()
            guard last.isPlaying else { return }
            ContinueWidgetSnapshotStore.publish(
                title: last.title,
                subtitle: last.subtitle,
                isPlaying: false,
                kind: last.kind,
                coverData: nil,
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

        ContinueWidgetSnapshotStore.publish(
            title: snapshot.title,
            subtitle: snapshot.author ?? snapshot.chapterLabel,
            isPlaying: snapshot.isPlaying,
            kind: kind,
            coverData: coverData,
        )
    }

    private static func handleToggleFromWidget() async {
        if await AudioSessionActor.shared.currentSnapshot() != nil {
            try? await AudioSessionActor.shared.transport(.togglePlayPause)
            let fresh = await AudioSessionActor.shared.currentSnapshot()
            await publishSession(fresh)
        } else {
            NotificationCenter.default.post(name: .punkRallyOpenContinue, object: nil)
        }
    }
}
#endif
