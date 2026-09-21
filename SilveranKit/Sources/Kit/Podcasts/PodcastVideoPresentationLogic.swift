//
//  PodcastVideoPresentationLogic.swift
//  SilveranKit
//
//  Pure decisions for internal podcast video portrait ↔ landscape fullscreen.
//  Presentation-only: never owns or replaces the shared AVPlayer session.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Portrait Now Playing vs immersive landscape video chrome.
public enum PodcastVideoPresentationMode: String, Equatable, Sendable {
    case portrait
    case landscapeFullscreen
}

/// Why immersive video mode was entered (drives portrait-exit policy).
public enum PodcastVideoFullscreenEntryReason: String, Equatable, Sendable {
    /// Device/interface rotated to landscape while the expanded video player was visible.
    case automaticRotation
    /// User tapped the fullscreen control (may stay until manual close).
    case manual
}

/// Coarse interface orientation used for presentation (not raw UIDevice).
public enum PodcastVideoInterfaceOrientation: String, Equatable, Sendable {
    case portrait
    case landscape
    /// faceUp / faceDown / unknown — ignore for transitions.
    case ignored
}

/// Inputs that gate auto fullscreen (video-only, expanded player, phone).
public struct PodcastVideoPresentationContext: Equatable, Sendable {
    public var isInternalVideo: Bool
    public var isPlayerExpanded: Bool
    /// iPhone auto-rotates into fullscreen; iPad uses manual/responsive only.
    public var isPhone: Bool

    public init(isInternalVideo: Bool, isPlayerExpanded: Bool, isPhone: Bool) {
        self.isInternalVideo = isInternalVideo
        self.isPlayerExpanded = isPlayerExpanded
        self.isPhone = isPhone
    }
}

public struct PodcastVideoPresentationState: Equatable, Sendable {
    public var mode: PodcastVideoPresentationMode
    public var entryReason: PodcastVideoFullscreenEntryReason?

    public init(
        mode: PodcastVideoPresentationMode = .portrait,
        entryReason: PodcastVideoFullscreenEntryReason? = nil
    ) {
        self.mode = mode
        self.entryReason = entryReason
    }

    public static let portrait = PodcastVideoPresentationState()
}

public enum PodcastVideoPresentationEvent: Equatable, Sendable {
    case interfaceOrientationChanged(PodcastVideoInterfaceOrientation)
    case manualEnterFullscreen
    case manualExitFullscreen
    case mediaBecameNonVideo
    case playerCollapsed
}

/// Testable enter/exit rules for landscape video fullscreen.
///
/// Invariant: entering/exiting fullscreen must never replace the shared
/// `AudioSessionActor` / `AVPlayer` session — views only re-host the surface.
public enum PodcastVideoPresentationLogic {
    public static func shouldEnterFullscreen(
        mediaIsInternalVideo: Bool,
        playerExpanded: Bool,
        interfaceOrientation: PodcastVideoInterfaceOrientation,
        isPhone: Bool
    ) -> Bool {
        guard mediaIsInternalVideo, playerExpanded, isPhone else { return false }
        return interfaceOrientation == .landscape
    }

    public static func shouldExitFullscreen(
        current: PodcastVideoPresentationState,
        mediaIsInternalVideo: Bool,
        playerExpanded: Bool,
        interfaceOrientation: PodcastVideoInterfaceOrientation
    ) -> Bool {
        guard current.mode == .landscapeFullscreen else { return false }
        if !mediaIsInternalVideo || !playerExpanded { return true }
        // Auto-entered fullscreen exits when the interface returns to portrait.
        // Manual fullscreen stays until the user closes it (or media/player changes).
        if current.entryReason == .automaticRotation, interfaceOrientation == .portrait {
            return true
        }
        return false
    }

    public static func reduce(
        state: PodcastVideoPresentationState,
        event: PodcastVideoPresentationEvent,
        context: PodcastVideoPresentationContext
    ) -> PodcastVideoPresentationState {
        switch event {
            case .interfaceOrientationChanged(let orientation):
                guard orientation != .ignored else { return state }

                if shouldExitFullscreen(
                    current: state,
                    mediaIsInternalVideo: context.isInternalVideo,
                    playerExpanded: context.isPlayerExpanded,
                    interfaceOrientation: orientation
                ) {
                    return .portrait
                }

                if state.mode == .portrait,
                    shouldEnterFullscreen(
                        mediaIsInternalVideo: context.isInternalVideo,
                        playerExpanded: context.isPlayerExpanded,
                        interfaceOrientation: orientation,
                        isPhone: context.isPhone
                    )
                {
                    return PodcastVideoPresentationState(
                        mode: .landscapeFullscreen,
                        entryReason: .automaticRotation
                    )
                }
                return state

            case .manualEnterFullscreen:
                guard context.isInternalVideo, context.isPlayerExpanded else { return state }
                return PodcastVideoPresentationState(
                    mode: .landscapeFullscreen,
                    entryReason: .manual
                )

            case .manualExitFullscreen:
                return .portrait

            case .mediaBecameNonVideo, .playerCollapsed:
                return .portrait
        }
    }
}
