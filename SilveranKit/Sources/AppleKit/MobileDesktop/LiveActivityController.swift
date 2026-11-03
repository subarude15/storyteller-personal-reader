#if os(iOS)
import ActivityKit
import Observation
import OSLog
import SilveranAppleWidgets
import SilveranKit
import UIKit

/// Mirrors the one app-wide audio session into a single Lock Screen / Dynamic Island
/// activity.
///
/// Lifecycle (ActivityKit semantics):
/// - Pause keeps the activity alive with static time so it stays resumable from its
///   buttons; it is not ended.
/// - Natural finish (paused at the item end for 5s, no auto-queued item) or a session
///   closed by the system calls `end(_:dismissalPolicy:)` with `.after(now + 15 min)`.
///   `end` stops the activity immediately; the policy only controls how long the final
///   paused state stays on the Lock Screen.
/// - User close (mini-player stop, closing a paused podcast) ends with `.immediate`.
/// - System end (8h limit) or a Lock Screen swipe drops the reference; a new activity
///   starts on the next play transition, not on the next progress tick.
@MainActor
public final class LiveActivityController {
    public static let shared = LiveActivityController()

    private static let logger = Logger(subsystem: "com.punkrally.reader", category: "LiveActivity")

    private var installed = false
    /// Syncs are dropped until leftovers from a previous process have been adopted or ended.
    private var adopted = false
    private var activity: Activity<InkAmpPlaybackAttributes>?
    private var rendered: InkAmpPlaybackActivityState?
    private var latestSnapshot: AudioSessionSnapshot?
    private var latestSnapshotAt = Date()
    private var gate = InkAmpLiveActivityGate()
    private var syncRunning = false
    private var syncPending = false
    private var thumbnail: (itemID: String, image: ObjectIdentifier, filename: String)?
    private var thumbnailRevision = 0
    private static let finishGrace: Duration = .seconds(5)
    private var finishCheck: Task<Void, Never>?
    /// Item whose finish grace period elapsed; the next sync ends its activity.
    private var finishedItemID: String?

    private init() {}

    public func install() {
        guard !installed else { return }
        installed = true

        Task {
            let current = await AudioSessionActor.shared.currentSnapshot()
            if latestSnapshot == nil { record(current) }
            await adoptExisting(hasSession: current != nil)
            adopted = true
            await AudioSessionActor.shared.addSnapshotObserver { snapshot in
                Task { @MainActor in LiveActivityController.shared.receive(snapshot) }
            }
            scheduleSync()
        }
        observeCoverAndTint()
        let center = NotificationCenter.default
        for name in [
            UserDefaults.didChangeNotification,
            UIAccessibility.darkerSystemColorsStatusDidChangeNotification,
        ] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in LiveActivityController.shared.scheduleSync() }
            }
        }
    }

    /// Call before closing `kind` on an explicit user action so its activity is removed
    /// immediately instead of lingering for 15 minutes.
    public func noteUserClosedSession(_ kind: AudioSessionKind) {
        gate.userClosed(itemID: InkAmpPlaybackActivityState.activityItemID(for: kind))
    }

    private func receive(_ snapshot: AudioSessionSnapshot?) {
        record(snapshot)
        scheduleSync()
    }

    private func record(_ snapshot: AudioSessionSnapshot?) {
        latestSnapshot = snapshot
        latestSnapshotAt = Date()
        gate.observe(isPlaying: snapshot?.isPlaying)
    }

    /// Coalesces bursts (progress ticks, defaults writes) into one pass over the latest
    /// state; passes never overlap, so an older update can't land after a newer one.
    private func scheduleSync() {
        guard adopted else { return }
        syncPending = true
        guard !syncRunning else { return }
        syncRunning = true
        Task { @MainActor in
            while syncPending {
                syncPending = false
                await sync()
            }
            syncRunning = false
        }
    }

    private func observeCoverAndTint() {
        withObservationTracking {
            _ = CoverTintModel.shared.palette
            _ = AudioSessionMonitor.shared.coverImage
        } onChange: {
            Task { @MainActor in
                LiveActivityController.shared.scheduleSync()
                LiveActivityController.shared.observeCoverAndTint()
            }
        }
    }

    private func adoptExisting(hasSession: Bool) async {
        let existing = Activity<InkAmpPlaybackAttributes>.activities
        let plan = InkAmpLiveActivityGate.adoptionPlan(
            existing: existing.map { ($0.id, $0.activityState == .active) },
            hasSession: hasSession,
        )
        for stale in existing where plan.end.contains(stale.id) {
            await Self.endActivity(id: stale.id, final: nil, dismissAt: nil)
        }
        if let kept = existing.first(where: { $0.id == plan.keep }) {
            track(kept)
            rendered = kept.content.state
        }
    }

    private func sync() async {
        guard let snapshot = latestSnapshot else {
            await endForSessionClose()
            return
        }
        guard InkAmpLiveActivitySettings.isEnabled else {
            if activity != nil || !Activity<InkAmpPlaybackAttributes>.activities.isEmpty {
                await endAll()
            }
            return
        }

        let itemID = InkAmpPlaybackActivityState.activityItemID(for: snapshot.kind)
        let coverFilename = await thumbnailFilename(for: snapshot.kind)
        // A newer snapshot for another item arrived while the thumbnail was written;
        // the pending pass renders that one.
        guard let current = latestSnapshot,
            InkAmpPlaybackActivityState.activityItemID(for: current.kind) == itemID
        else { return }

        let next = InkAmpPlaybackActivityState(
            snapshot: current,
            coverFilename: coverFilename,
            tint: tint(for: current.kind),
            now: latestSnapshotAt,
        )
        guard next.payloadByteCount <= InkAmpPlaybackActivityState.maximumPayloadBytes else {
            Self.logger.error("payload over limit bytes=\(next.payloadByteCount, privacy: .public)")
            return
        }

        if !next.isFinished || activity == nil {
            finishCheck?.cancel()
            finishCheck = nil
            finishedItemID = nil
        } else if finishedItemID == next.itemID {
            // Still finished after the grace period: no auto-queue item took over.
            finishedItemID = nil
            await endForSessionClose()
            return
        } else if finishCheck == nil {
            scheduleFinishCheck(itemID: next.itemID)
        }

        if let activity, activity.activityState == .active {
            guard rendered?.needsUpdate(to: next) ?? true else { return }
            await Self.updateActivity(id: activity.id, state: next)
            rendered = next
            return
        }

        guard gate.mayStart(isPlaying: current.isPlaying),
            ActivityAuthorizationInfo().areActivitiesEnabled
        else { return }
        do {
            let started = try Activity.request(
                attributes: InkAmpPlaybackAttributes(),
                content: ActivityContent(state: next, staleDate: nil),
                pushType: nil,
            )
            track(started)
            rendered = next
            Self.logger.notice("started kind=\(next.itemKind.rawValue, privacy: .public)")
        } catch {
            Self.logger.error("request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Natural completion keeps the session open (paused at the end), so it never shows
    /// up as a nil snapshot. Wait briefly so a podcast auto-queue can switch the item in
    /// place; if it is still finished, end with the 15 minute retention.
    private func scheduleFinishCheck(itemID: String) {
        finishCheck = Task { @MainActor in
            try? await Task.sleep(for: Self.finishGrace)
            guard !Task.isCancelled else { return }
            finishCheck = nil
            finishedItemID = itemID
            scheduleSync()
        }
    }

    private func tint(for kind: AudioSessionKind) -> CoverTintPalette? {
        guard CoverTintSettings.isEnabled, !UIAccessibility.isDarkerSystemColorsEnabled,
            CoverTintModel.shared.itemID == ContinueWidgetItemID.from(sessionKind: kind)
        else { return nil }
        return CoverTintModel.shared.palette
    }

    /// 120x120 JPEG of the monitor's cover, written once per cover image (not per tick).
    private func thumbnailFilename(for kind: AudioSessionKind) async -> String? {
        let itemID = ContinueWidgetItemID.from(sessionKind: kind)
        let monitor = AudioSessionMonitor.shared
        guard let image = monitor.coverImage,
            let monitorKind = monitor.snapshot?.kind,
            ContinueWidgetItemID.from(sessionKind: monitorKind) == itemID
        else {
            return thumbnail?.itemID == itemID ? thumbnail?.filename : nil
        }
        let identity = ObjectIdentifier(image)
        if let thumbnail, thumbnail.itemID == itemID, thumbnail.image == identity {
            return thumbnail.filename
        }

        thumbnailRevision += 1
        let filename = InkAmpPlaybackActivityStore.thumbnailFilename(itemID: itemID, revision: thumbnailRevision)
        let side = CGFloat(InkAmpPlaybackActivityStore.thumbnailPixelSide)
        let written = await Task.detached(priority: .utility) { () -> Bool in
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let jpeg = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
                .jpegData(withCompressionQuality: 0.8) { _ in
                    let size = image.size
                    let scale = max(side / max(size.width, 1), side / max(size.height, 1))
                    let drawn = CGSize(width: size.width * scale, height: size.height * scale)
                    image.draw(in: CGRect(
                        x: (side - drawn.width) / 2,
                        y: (side - drawn.height) / 2,
                        width: drawn.width,
                        height: drawn.height,
                    ))
                }
            do {
                try InkAmpPlaybackActivityStore.writeThumbnail(jpeg, filename: filename)
                return true
            } catch {
                return false
            }
        }.value
        guard written else { return nil }
        thumbnail = (itemID, identity, filename)
        return filename
    }

    private func track(_ activity: Activity<InkAmpPlaybackAttributes>) {
        self.activity = activity
        Task { @MainActor in
            for await state in activity.activityStateUpdates {
                guard state == .ended || state == .dismissed else { continue }
                let controller = LiveActivityController.shared
                guard controller.activity?.id == activity.id else { return }
                controller.activity = nil
                controller.rendered = nil
                controller.gate.activityEndedExternally(sessionActive: controller.latestSnapshot != nil)
                Self.logger.notice("ended externally state=\(String(describing: state), privacy: .public)")
                return
            }
        }
    }

    private func endForSessionClose() async {
        defer { gate.sessionEnded() }
        guard let activity else { return }
        let now = Date()
        var final = rendered
        if let state = final {
            final?.position = min(state.expectedPosition(at: now), max(state.itemEnd, state.position))
            final?.positionAt = now
            final?.isPlaying = false
        }
        let dismissAt = gate.dismissalDate(renderedItemID: rendered?.itemID, now: now)
        self.activity = nil
        rendered = nil
        await Self.endActivity(id: activity.id, final: final, dismissAt: dismissAt)
    }

    // `Activity` is not Sendable, so its nonisolated async APIs can't be called on a
    // main-actor reference; resolve it by ID off the main actor instead.
    private nonisolated static func updateActivity(id: String, state: InkAmpPlaybackActivityState) async {
        for activity in Activity<InkAmpPlaybackAttributes>.activities where activity.id == id {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    private nonisolated static func endActivity(
        id: String,
        final: InkAmpPlaybackActivityState?,
        dismissAt: Date?,
    ) async {
        let policy: ActivityUIDismissalPolicy = dismissAt.map { .after($0) } ?? .immediate
        for activity in Activity<InkAmpPlaybackAttributes>.activities where activity.id == id {
            await activity.end(final.map { ActivityContent(state: $0, staleDate: nil) }, dismissalPolicy: policy)
        }
    }

    private func endAll() async {
        activity = nil
        rendered = nil
        await InkAmpPlaybackActivityCleanup.endAllImmediately()
    }
}
#endif
