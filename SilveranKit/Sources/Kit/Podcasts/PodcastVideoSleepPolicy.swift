//
//  PodcastVideoSleepPolicy.swift
//  SilveranKit
//
//  When the expanded internal video player should keep the screen awake.
//  Portrait, landscape, and fullscreen share one session — presentation mode
//  is not an input. Audio-only, audiobooks, and external YouTube never are.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public extension Notification.Name {
    /// Podcast/video playhead is actually advancing (open or resume).
    /// Pause does not post this. Finish is `punkRallyPodcastDidFinish`.
    static let punkRallyPodcastPlaybackBecameActive = Notification.Name(
        "punkRallyPodcastPlaybackBecameActive"
    )
}

/// Reasons that may disable the idle timer. Releasing one must not clear another.
public struct DisplaySleepHolds: Equatable, Sendable {
    public var narration = false
    public var videoPlayback = false

    public init(narration: Bool = false, videoPlayback: Bool = false) {
        self.narration = narration
        self.videoPlayback = videoPlayback
    }

    public var disablesIdleTimer: Bool { narration || videoPlayback }

    public mutating func setNarration(_ enabled: Bool) {
        narration = enabled
    }

    public mutating func setVideoPlayback(_ enabled: Bool) {
        videoPlayback = enabled
    }
}

/// Inputs for internal-video screen wake. Pause inside the player may keep
/// the hold; end, dismiss, session teardown, and background must drop it.
public struct VideoPlaybackSleepState: Equatable, Sendable {
    public var isInternalVideo: Bool
    public var isPlayerExpanded: Bool
    public var playbackReachedEnd: Bool
    public var hasLivePodcastSession: Bool
    public var appIsActive: Bool

    public init(
        isInternalVideo: Bool = false,
        isPlayerExpanded: Bool = false,
        playbackReachedEnd: Bool = false,
        hasLivePodcastSession: Bool = false,
        appIsActive: Bool = true
    ) {
        self.isInternalVideo = isInternalVideo
        self.isPlayerExpanded = isPlayerExpanded
        self.playbackReachedEnd = playbackReachedEnd
        self.hasLivePodcastSession = hasLivePodcastSession
        self.appIsActive = appIsActive
    }

    public var preventsSleep: Bool {
        VideoPlaybackSleepLogic.preventsSleep(self)
    }
}

public enum VideoPlaybackSleepEvent: Equatable, Sendable {
    case playerVisibility(isInternalVideo: Bool, isPlayerExpanded: Bool)
    case playbackDidFinish
    case playbackBecameActive
    /// `false` for no session, audiobook, readaloud, or any non-podcast snapshot.
    case sessionSnapshot(isPodcast: Bool)
    case appBackgrounded
    case appBecameActive
}

public enum VideoPlaybackSleepLogic {
    /// Awake only while an expanded internal video session is live, in the
    /// foreground, and has not reached the end. A temporary pause keeps the
    /// hold. Fullscreen does not change the result.
    public static func preventsSleep(_ state: VideoPlaybackSleepState) -> Bool {
        state.appIsActive
            && state.isInternalVideo
            && state.isPlayerExpanded
            && state.hasLivePodcastSession
            && !state.playbackReachedEnd
    }

    public static func reduce(
        state: VideoPlaybackSleepState,
        event: VideoPlaybackSleepEvent
    ) -> VideoPlaybackSleepState {
        var next = state
        switch event {
            case .playerVisibility(let isInternalVideo, let isPlayerExpanded):
                next.isInternalVideo = isInternalVideo
                next.isPlayerExpanded = isPlayerExpanded

            case .playbackDidFinish:
                next.playbackReachedEnd = true

            case .playbackBecameActive:
                next.playbackReachedEnd = false

            case .sessionSnapshot(let isPodcast):
                next.hasLivePodcastSession = isPodcast
                // The finished session is gone (dismissed, stopped, or replaced
                // by audio). Don't let that end-flag block the next video.
                if !isPodcast {
                    next.playbackReachedEnd = false
                }

            case .appBackgrounded:
                next.appIsActive = false

            case .appBecameActive:
                next.appIsActive = true
        }
        return next
    }
}
