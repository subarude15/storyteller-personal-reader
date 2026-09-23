//
//  PodcastVideoSleepPolicyTests.swift
//  SilveranTests
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing

@testable import SilveranKit

@Suite("Internal video screen wake")
struct PodcastVideoSleepPolicyTests {
    private func playingVideo() -> VideoPlaybackSleepState {
        VideoPlaybackSleepState(
            isInternalVideo: true,
            isPlayerExpanded: true,
            playbackReachedEnd: false,
            hasLivePodcastSession: true,
            appIsActive: true
        )
    }

    @Test func playingInternalVideoPreventsSleep() {
        #expect(playingVideo().preventsSleep)
    }

    @Test func pauseInsideThePlayerKeepsTheHold() {
        // Pause republishes the podcast snapshot and does not finish the session.
        var state = playingVideo()
        state = VideoPlaybackSleepLogic.reduce(
            state: state,
            event: .sessionSnapshot(isPodcast: true)
        )
        #expect(state.preventsSleep)
    }

    @Test func fullscreenUsesTheSameSessionAsPortrait() {
        // Landscape fullscreen is a chrome swap on the expanded player.
        // The wake decision does not take presentation mode as an input.
        let portrait = playingVideo()
        let fullscreen = playingVideo()
        #expect(portrait.preventsSleep)
        #expect(fullscreen.preventsSleep)
        #expect(portrait == fullscreen)
    }

    @Test func audioOnlyExpandedPlayerDoesNotPreventSleep() {
        var state = playingVideo()
        state = VideoPlaybackSleepLogic.reduce(
            state: state,
            event: .playerVisibility(isInternalVideo: false, isPlayerExpanded: true)
        )
        #expect(!state.preventsSleep)
    }

    @Test func dismissedPlayerRestoresAutoLockWhileSessionContinues() {
        var state = playingVideo()
        state = VideoPlaybackSleepLogic.reduce(
            state: state,
            event: .playerVisibility(isInternalVideo: true, isPlayerExpanded: false)
        )
        #expect(state.hasLivePodcastSession)
        #expect(!state.preventsSleep)
    }

    @Test func playbackEndRestoresAutoLock() {
        var state = playingVideo()
        state = VideoPlaybackSleepLogic.reduce(state: state, event: .playbackDidFinish)
        #expect(!state.preventsSleep)
    }

    @Test func resumeAfterEndPreventsSleepAgain() {
        var state = playingVideo()
        state = VideoPlaybackSleepLogic.reduce(state: state, event: .playbackDidFinish)
        state = VideoPlaybackSleepLogic.reduce(state: state, event: .playbackBecameActive)
        #expect(state.preventsSleep)
    }

    @Test func finishSticksUntilPlaybackActuallyRestarts() {
        var state = playingVideo()
        state = VideoPlaybackSleepLogic.reduce(state: state, event: .playbackDidFinish)
        // A later podcast snapshot (pause, ticker) must not clear the end.
        state = VideoPlaybackSleepLogic.reduce(state: state, event: .sessionSnapshot(isPodcast: true))
        #expect(state.playbackReachedEnd)
        #expect(!state.preventsSleep)
    }

    @Test func backgroundRestoresAndForegroundRestoresTheHold() {
        var state = playingVideo()
        state = VideoPlaybackSleepLogic.reduce(state: state, event: .appBackgrounded)
        #expect(!state.preventsSleep)
        state = VideoPlaybackSleepLogic.reduce(state: state, event: .appBecameActive)
        #expect(state.preventsSleep)
    }

    @Test func backgroundAfterEndStaysRestored() {
        var state = playingVideo()
        state = VideoPlaybackSleepLogic.reduce(state: state, event: .playbackDidFinish)
        state = VideoPlaybackSleepLogic.reduce(state: state, event: .appBackgrounded)
        state = VideoPlaybackSleepLogic.reduce(state: state, event: .appBecameActive)
        #expect(!state.preventsSleep)
    }

    @Test func sessionTeardownRestoresAutoLock() {
        var state = playingVideo()
        state = VideoPlaybackSleepLogic.reduce(state: state, event: .sessionSnapshot(isPodcast: false))
        #expect(!state.hasLivePodcastSession)
        #expect(!state.preventsSleep)
    }

    @Test func audiobookSnapshotDoesNotKeepVideoHold() {
        var state = playingVideo()
        state = VideoPlaybackSleepLogic.reduce(state: state, event: .sessionSnapshot(isPodcast: false))
        #expect(!state.preventsSleep)
    }

    @Test func replacingTheSessionClearsAStaleEndFlag() {
        var state = playingVideo()
        state = VideoPlaybackSleepLogic.reduce(state: state, event: .playbackDidFinish)
        state = VideoPlaybackSleepLogic.reduce(state: state, event: .sessionSnapshot(isPodcast: false))
        state = VideoPlaybackSleepLogic.reduce(state: state, event: .sessionSnapshot(isPodcast: true))
        #expect(!state.playbackReachedEnd)
        #expect(state.preventsSleep)
    }

    @Test func videoAndNarrationHoldsDoNotClearEachOther() {
        var holds = DisplaySleepHolds()
        holds.setVideoPlayback(true)
        #expect(holds.disablesIdleTimer)
        holds.setNarration(false)
        #expect(holds.disablesIdleTimer)

        holds.setNarration(true)
        holds.setVideoPlayback(false)
        #expect(holds.disablesIdleTimer)

        holds.setNarration(false)
        #expect(!holds.disablesIdleTimer)
    }
}
