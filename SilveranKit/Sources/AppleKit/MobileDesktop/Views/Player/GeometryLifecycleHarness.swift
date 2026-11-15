#if os(iOS) && DEBUG
import CoreFoundation
import SilveranKit
import SwiftUI
import UIKit

/// Debug-only DATA/I-O seams, gated to the unsigned geometry bundle. The real
/// iOSRootView, presenter binding, fullScreenCover, monitor subscription, live
/// docked-bar policy/transition and Home inset are not replaced by this driver.
@MainActor
public enum InkAmpGeometryLifecycle {
    public static var isEnabled: Bool {
        Bundle.main.bundleIdentifier == "com.punkrally.reader.geometry"
            && ["cover", "async", "launch"].contains(flow)
    }
    public static var flow: String {
        ProcessInfo.processInfo.environment["INKAMP_GEOMETRY_LIFECYCLE"] ?? ""
    }
    static var bookData: PlayerBookData?
    static var rootRestored = false
    static var publicationRequests = 0
    static var publicationHome: [String: Any] = [:]
    static var coverAppearances = 0
    static var coverDisappearances = 0
    private static var installed = false

    public static func configure(book: PlayerBookData) {
        precondition(isEnabled)
        bookData = book
        guard !installed else { return }
        installed = true
        // Darwin notifications cross the UI-test runner/app process boundary.
        // Publication does not touch NavigationStack's toolbar or scroll offset.
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in
                Task { @MainActor in
                    guard InkAmpGeometryLifecycle.isEnabled,
                        InkAmpGeometryLifecycle.flow == "async",
                        InkAmpGeometryLifecycle.publicationRequests == 0 else { return }
                    await InkAmpGeometryLifecycle.publishSession()
                }
            },
            "com.punkrally.geometry.publish-session" as CFString, nil, .deliverImmediately)
    }

    static func prepareStartup() async {
        guard isEnabled else { return }
        if flow == "cover" || flow == "launch" { await publishSession() }
    }

    static func publishSession() async {
        guard isEnabled, let data = bookData else { return }
        publicationHome = nativeHomeMetrics()
        publicationRequests += 1
        let snapshot = AudioSessionSnapshot(
            kind: .audiobook(data.metadata.id), title: data.metadata.title,
            author: "Adam Nevill",
            isPlaying: ProcessInfo.processInfo.environment["INKAMP_GEOMETRY_PLAYER"] == "playing",
            chapterLabel: "Chapter 04", bookProgress: 0.25, playbackRate: 1,
            elapsedSeconds: 13740, durationSeconds: 54960, chapterRemainingSeconds: 24 * 60)
        // Real actor observer -> AudioSessionMonitor.apply -> liveContent path.
        // Only the audio engine's data source is injected, no monitor/UI toggle.
        await AudioSessionActor.shared.publishGeometryLifecycleSnapshot(snapshot)
    }

    static func state() -> [String: Any] {
        let snapshot = AudioSessionMonitor.shared.snapshot
        let card = PlayerPresenter.shared.card != nil
        let podcast = PodcastPlayerPresenter.shared.episode != nil
        return [
            "flow": flow, "rootRestored": rootRestored,
            "publicationRequests": publicationRequests,
            "publicationHome": publicationHome,
            "presenterHasCard": card, "monitorHasSnapshot": snapshot != nil,
            "monitorIsPlaying": snapshot?.isPlaying ?? false,
            "policyDocked": MiniPlayerPolicy.isDockedBarVisible(
                hasSession: snapshot != nil, isCardPresented: card, isPodcastEpisodePresented: podcast),
            "renderPath": "liveContent",
            "fixtureSwapEnabled": ProcessInfo.processInfo.environment["INKAMP_GEOMETRY_FIXTURE"] == "1",
            "coverAppearances": coverAppearances, "coverDisappearances": coverDisappearances,
            "nativeHome": nativeHomeMetrics(),
        ]
    }

    /// Read the EXISTING UIKit-backed Home probe, including when it remains in
    /// the native hierarchy behind a fullScreenCover. No inset/offset writes.
    private static func nativeHomeMetrics() -> [String: Any] {
        func find(_ view: UIView) -> UIView? {
            if view.accessibilityIdentifier == "geometry.metrics.home" { return view }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                if let view = find(window), let value = view.accessibilityValue,
                    let data = value.data(using: .utf8),
                    let metrics = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return metrics
                }
            }
        }
        return ["found": false]
    }
}

/// Accessibility-only observation; not a tappable control or layout reservation.
struct GeometryLifecycleStateProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> StateView { StateView() }
    func updateUIView(_ uiView: StateView, context: Context) {}
    final class StateView: UIView {
        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = true
            accessibilityIdentifier = "geometry.lifecycle.state"
            accessibilityLabel = "Read only production lifecycle state"
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
        override var accessibilityValue: String? {
            get {
                guard let data = try? JSONSerialization.data(
                    withJSONObject: InkAmpGeometryLifecycle.state(), options: .sortedKeys)
                else { return "{}" }
                return String(decoding: data, as: UTF8.self)
            }
            set {}
        }
    }
}

/// Replaces ONLY the audio/file-dependent contents inside the production shell's
/// fullScreenCover. Presentation, real Presenter.dismissCard and live session
/// retention are exercised; the real audio player's internal teardown is not.
public struct GeometryLifecycleLocalPlayer: View {
    public init() {}
    public var body: some View {
        VStack(spacing: 20) {
            Text("Local lifecycle player").font(.headline)
            Text(InkAmpGeometryLifecycle.bookData?.metadata.title ?? "Local book")
            Text("Local content seam; real full-screen cover and presenter.")
                .font(.caption)
            Button("Minimize local player") { PlayerPresenter.shared.dismissCard() }
                .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("geometry.lifecycle.cover")
        .background(GeometryLifecycleStateProbe())
        .onAppear { InkAmpGeometryLifecycle.coverAppearances += 1 }
        .onDisappear { InkAmpGeometryLifecycle.coverDisappearances += 1 }
    }
}

/// Adds an identifier only in the isolated lifecycle run; preserves live chrome.
struct GeometryLifecyclePlayerMarker: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if InkAmpGeometryLifecycle.isEnabled {
            content.accessibilityElement(children: .contain)
                .accessibilityIdentifier("geometry.player")
        } else { content }
    }
}
#endif
