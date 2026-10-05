//
//  InternalVideoPlaybackLifecycle.swift
//  SilveranKit
//
//  Decisions for internal podcast video (RSS video and resolved YouTube)
//  that must stay on the shared AudioSessionActor / AVPlayer session.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Reference-counted idle-timer clients. The screen stays awake while any
/// client holds, and the last release restores the system timer so one
/// feature cannot leave `isIdleTimerDisabled` stuck on.
public struct IdleTimerHold: Equatable, Sendable {
    public private(set) var clients: Set<String>

    public init(clients: Set<String> = []) {
        self.clients = clients
    }

    public var disablesIdleTimer: Bool {
        !clients.isEmpty
    }

    public func setting(_ enabled: Bool, client: String) -> IdleTimerHold {
        var next = clients
        if enabled {
            next.insert(client)
        } else {
            next.remove(client)
        }
        return IdleTimerHold(clients: next)
    }
}

public enum IdleTimerClient {
    public static let mediaOverlay = "media-overlay"
    public static let internalVideo = "internal-video"
}

/// Inputs for wake-lock and Picture in Picture policy. Playback itself stays
/// on the shared session; this struct never owns a player.
public struct InternalVideoPlaybackContext: Equatable, Sendable {
    public var isInternalVideo: Bool
    public var isPlaying: Bool
    /// Expanded Now Playing card is on screen (not the mini player alone).
    public var isPlayerPresented: Bool
    public var isPictureInPictureActive: Bool
    public var isAppActive: Bool
    public var isPictureInPicturePossible: Bool
    public var isPictureInPictureSupported: Bool

    public init(
        isInternalVideo: Bool,
        isPlaying: Bool,
        isPlayerPresented: Bool,
        isPictureInPictureActive: Bool,
        isAppActive: Bool,
        isPictureInPicturePossible: Bool = false,
        isPictureInPictureSupported: Bool = false
    ) {
        self.isInternalVideo = isInternalVideo
        self.isPlaying = isPlaying
        self.isPlayerPresented = isPlayerPresented
        self.isPictureInPictureActive = isPictureInPictureActive
        self.isAppActive = isAppActive
        self.isPictureInPicturePossible = isPictureInPicturePossible
        self.isPictureInPictureSupported = isPictureInPictureSupported
    }
}

public enum InternalVideoPlaybackLifecycle {
    /// Manual Picture in Picture for internal video (registration model — no
    /// UIKit layer re-parenting between SwiftUI surfaces).
    public static let isPictureInPictureEnabled = true

    /// Auto-start from inline stays off. Manual PiP is the supported path;
    /// enabling automatic start adds lifecycle edge cases around surface
    /// registration during portrait ↔ fullscreen swaps.
    public static let isAutomaticPictureInPictureEnabled = false

    /// Disable the idle timer only while internal video is actively playing
    /// in the foreground player. Audio-only, pause, close, finish, PiP, and
    /// a non-active scene all restore normal auto-lock.
    public static func shouldDisableIdleTimer(_ context: InternalVideoPlaybackContext) -> Bool {
        context.isInternalVideo
            && context.isPlaying
            && context.isPlayerPresented
            && !context.isPictureInPictureActive
            && context.isAppActive
    }

    /// System automatic PiP only when the user is actually watching inline video.
    /// Audio-only, paused, and mini-player-only sessions must not start PiP.
    /// Currently gated off via `isAutomaticPictureInPictureEnabled`.
    public static func allowsAutomaticPictureInPicture(
        _ context: InternalVideoPlaybackContext
    ) -> Bool {
        isPictureInPictureEnabled
            && isAutomaticPictureInPictureEnabled
            && context.isInternalVideo
            && context.isPlaying
            && context.isPlayerPresented
    }

    /// Offer the control for internal video on devices that support PiP.
    /// Unavailable states stay disabled rather than starting a second player.
    public static func shouldShowPictureInPictureControl(
        _ context: InternalVideoPlaybackContext
    ) -> Bool {
        isPictureInPictureEnabled
            && context.isInternalVideo
            && context.isPictureInPictureSupported
    }

    public static func canStartPictureInPicture(_ context: InternalVideoPlaybackContext) -> Bool {
        shouldShowPictureInPictureControl(context) && context.isPictureInPicturePossible
    }

    /// Entering or leaving PiP re-hosts the same AVPlayer. Never seek or reload.
    public static func shouldResetPlaybackOnPictureInPictureTransition() -> Bool {
        false
    }

    /// Locking the phone or backgrounding the app must not pause or tear down
    /// a live podcast session (video audio continues; audio-only already did).
    public static func shouldPauseOnSceneBackground() -> Bool {
        false
    }

    /// Re-assert background audio only for a podcast session that is already playing.
    public static func shouldMaintainPlaybackInBackground(
        hasPodcastSession: Bool,
        isPlaying: Bool
    ) -> Bool {
        hasPodcastSession && isPlaying
    }

    /// Video needs the movie playback audio-session mode (PiP and lock-screen
    /// audio). Audio-only podcasts stay on the spoken session.
    public static func prefersMoviePlaybackAudioSession(isInternalVideo: Bool) -> Bool {
        isInternalVideo
    }
}
