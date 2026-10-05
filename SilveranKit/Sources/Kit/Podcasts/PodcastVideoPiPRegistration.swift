//
//  PodcastVideoPiPRegistration.swift
//  SilveranKit
//
//  Pure active-surface registration and restore-gate policy for Picture in
//  Picture. No UIKit ownership — surfaces keep their local AVPlayerLayers.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Tracks which video surface currently supplies the PiP content source.
///
/// Registration is identity-based so a dismantling older surface cannot clear
/// a newer one that already registered during a portrait ↔ fullscreen swap.
public struct PodcastVideoPiPActiveSurface: Equatable, Sendable {
    public private(set) var surfaceID: String?

    public init(surfaceID: String? = nil) {
        self.surfaceID = surfaceID
    }

    public var hasActiveSurface: Bool {
        surfaceID != nil
    }

    public mutating func register(surfaceID: String) {
        self.surfaceID = surfaceID
    }

    /// Clears only when `surfaceID` matches the currently registered surface.
    public mutating func unregister(surfaceID: String) {
        guard self.surfaceID == surfaceID else { return }
        self.surfaceID = nil
    }
}

/// Blocks late AVKit restore callbacks after the podcast/video session ends.
public struct PodcastVideoPiPRestoreGate: Equatable, Sendable {
    public private(set) var sessionGeneration: UInt64
    public private(set) var restoreAllowed: Bool

    public init(sessionGeneration: UInt64 = 0, restoreAllowed: Bool = true) {
        self.sessionGeneration = sessionGeneration
        self.restoreAllowed = restoreAllowed
    }

    /// A surface registered for a live video session may restore UI on PiP stop.
    public mutating func beginSession() {
        sessionGeneration &+= 1
        restoreAllowed = true
    }

    /// Session closed (stop / teardown). Ignore subsequent restore requests.
    public mutating func endSession() {
        sessionGeneration &+= 1
        restoreAllowed = false
    }

    public func shouldRestoreInterface(observedGeneration: UInt64) -> Bool {
        restoreAllowed && observedGeneration == sessionGeneration
    }
}

/// Distinguishes the currently visible registered surface from the layer
/// protected as the active PiP content source. They may differ during an
/// A→B surface swap while PiP is still running on A.
public struct PodcastVideoPiPBindingState: Equatable, Sendable {
    /// Visible surface that owns the pending/live inline layer.
    public var visibleSurfaceID: String?
    /// Identity of the layer/surface feeding the active PiP controller.
    public var protectedSourceID: String?
    public var isPictureInPictureActive: Bool

    public init(
        visibleSurfaceID: String? = nil,
        protectedSourceID: String? = nil,
        isPictureInPictureActive: Bool = false
    ) {
        self.visibleSurfaceID = visibleSurfaceID
        self.protectedSourceID = protectedSourceID
        self.isPictureInPictureActive = isPictureInPictureActive
    }

    public mutating func registerVisible(surfaceID: String) {
        visibleSurfaceID = surfaceID
    }

    public mutating func unregisterVisible(surfaceID: String) {
        guard visibleSurfaceID == surfaceID else { return }
        visibleSurfaceID = nil
    }

    public mutating func protectSource(sourceID: String) {
        protectedSourceID = sourceID
        isPictureInPictureActive = true
    }

    public mutating func releaseProtectedSource() {
        protectedSourceID = nil
        isPictureInPictureActive = false
    }

    public mutating func endSession() {
        visibleSurfaceID = nil
        protectedSourceID = nil
        isPictureInPictureActive = false
    }

    public func mayClearPlayer(sourceID: String) -> Bool {
        PodcastVideoPiPLifecyclePolicy.shouldClearPlayerOnDismantle(
            isPictureInPictureActive: isPictureInPictureActive,
            isControllerContentSource: protectedSourceID == sourceID
        )
    }

    /// After PiP stops, clear the orphaned source only when that layer is not
    /// still the live visible surface's layer.
    public func shouldClearReleasedSourcePlayer(
        releasedSourceIsStillVisibleLayer: Bool
    ) -> Bool {
        !releasedSourceIsStillVisibleLayer
    }
}

/// Pure teardown / observation decisions for the PiP coordinator.
public enum PodcastVideoPiPLifecyclePolicy {
    /// While PiP is showing the dismantling surface's layer as its content
    /// source, keep `layer.player` bound so the floating window does not blank.
    /// No UIKit re-parenting — the coordinator retains that source layer instead.
    public static func shouldClearPlayerOnDismantle(
        isPictureInPictureActive: Bool,
        isControllerContentSource: Bool
    ) -> Bool {
        !(isPictureInPictureActive && isControllerContentSource)
    }

    /// Keep refreshing `isPictureInPicturePossible` until it becomes true or
    /// the controller/source identity changes. Avoids a short startup window
    /// that leaves the button stuck disabled after slow stream start.
    public static func shouldContinuePossibilityRefresh(
        isPossible: Bool,
        hasController: Bool,
        controllerMatchesObserved: Bool
    ) -> Bool {
        !isPossible && hasController && controllerMatchesObserved
    }
}
