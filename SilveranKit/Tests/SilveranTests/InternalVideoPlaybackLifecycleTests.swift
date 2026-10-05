//
//  InternalVideoPlaybackLifecycleTests.swift
//  SilveranTests
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing

@testable import SilveranKit

@Suite("Internal video playback lifecycle")
struct InternalVideoPlaybackLifecycleTests {

    private func watching() -> InternalVideoPlaybackContext {
        InternalVideoPlaybackContext(
            isInternalVideo: true,
            isPlaying: true,
            isPlayerPresented: true,
            isPictureInPictureActive: false,
            isAppActive: true,
            isPictureInPicturePossible: true,
            isPictureInPictureSupported: true
        )
    }

    @Test func playingVideoKeepsScreenAwake() {
        #expect(InternalVideoPlaybackLifecycle.shouldDisableIdleTimer(watching()))
    }

    @Test func pausingVideoRestoresIdleTimer() {
        var context = watching()
        context.isPlaying = false
        #expect(!InternalVideoPlaybackLifecycle.shouldDisableIdleTimer(context))
    }

    @Test func closingPlayerRestoresIdleTimer() {
        var context = watching()
        context.isPlayerPresented = false
        #expect(!InternalVideoPlaybackLifecycle.shouldDisableIdleTimer(context))
    }

    @Test func finishedVideoRestoresIdleTimer() {
        var context = watching()
        context.isPlaying = false
        #expect(!InternalVideoPlaybackLifecycle.shouldDisableIdleTimer(context))
    }

    @Test func audioOnlyPodcastDoesNotKeepScreenAwake() {
        var context = watching()
        context.isInternalVideo = false
        #expect(!InternalVideoPlaybackLifecycle.shouldDisableIdleTimer(context))
    }

    @Test func pictureInPictureDoesNotHoldIdleTimer() {
        var context = watching()
        context.isPictureInPictureActive = true
        #expect(!InternalVideoPlaybackLifecycle.shouldDisableIdleTimer(context))
    }

    @Test func inactiveSceneReleasesIdleTimer() {
        var context = watching()
        context.isAppActive = false
        #expect(!InternalVideoPlaybackLifecycle.shouldDisableIdleTimer(context))
    }

    @Test func lastIdleTimerReleaseRestoresAutoLock() {
        var hold = IdleTimerHold()
        hold = hold.setting(true, client: IdleTimerClient.internalVideo)
        hold = hold.setting(true, client: IdleTimerClient.mediaOverlay)
        #expect(hold.disablesIdleTimer)

        hold = hold.setting(false, client: IdleTimerClient.internalVideo)
        #expect(hold.disablesIdleTimer)

        hold = hold.setting(false, client: IdleTimerClient.mediaOverlay)
        #expect(!hold.disablesIdleTimer)
        #expect(hold.clients.isEmpty)
    }

    @Test func releasingUnknownClientDoesNotClearOtherHolders() {
        let hold = IdleTimerHold(clients: [IdleTimerClient.internalVideo])
            .setting(false, client: IdleTimerClient.mediaOverlay)
        #expect(hold.disablesIdleTimer)
        #expect(hold.clients == [IdleTimerClient.internalVideo])
    }

    @Test func automaticPictureInPictureRequiresWatchingInlineVideo() {
        #expect(!InternalVideoPlaybackLifecycle.isPictureInPictureEnabled)
        #expect(!InternalVideoPlaybackLifecycle.allowsAutomaticPictureInPicture(watching()))

        var audio = watching()
        audio.isInternalVideo = false
        #expect(!InternalVideoPlaybackLifecycle.allowsAutomaticPictureInPicture(audio))

        var paused = watching()
        paused.isPlaying = false
        #expect(!InternalVideoPlaybackLifecycle.allowsAutomaticPictureInPicture(paused))

        var mini = watching()
        mini.isPlayerPresented = false
        #expect(!InternalVideoPlaybackLifecycle.allowsAutomaticPictureInPicture(mini))
    }

    @Test func pictureInPictureControlIsVideoOnlyAndFailsClosed() {
        #expect(!InternalVideoPlaybackLifecycle.isPictureInPictureEnabled)
        #expect(!InternalVideoPlaybackLifecycle.shouldShowPictureInPictureControl(watching()))
        #expect(!InternalVideoPlaybackLifecycle.canStartPictureInPicture(watching()))

        var unsupported = watching()
        unsupported.isPictureInPictureSupported = false
        unsupported.isPictureInPicturePossible = false
        #expect(!InternalVideoPlaybackLifecycle.shouldShowPictureInPictureControl(unsupported))
        #expect(!InternalVideoPlaybackLifecycle.canStartPictureInPicture(unsupported))

        var notYet = watching()
        notYet.isPictureInPicturePossible = false
        #expect(!InternalVideoPlaybackLifecycle.shouldShowPictureInPictureControl(notYet))
        #expect(!InternalVideoPlaybackLifecycle.canStartPictureInPicture(notYet))

        var audio = watching()
        audio.isInternalVideo = false
        #expect(!InternalVideoPlaybackLifecycle.shouldShowPictureInPictureControl(audio))
    }

    @Test func pictureInPictureTransitionDoesNotResetPlayback() {
        #expect(!InternalVideoPlaybackLifecycle.shouldResetPlaybackOnPictureInPictureTransition())
    }

    @Test func backgroundAndLockDoNotPauseSession() {
        #expect(!InternalVideoPlaybackLifecycle.shouldPauseOnSceneBackground())
        #expect(
            InternalVideoPlaybackLifecycle.shouldMaintainPlaybackInBackground(
                hasPodcastSession: true,
                isPlaying: true
            )
        )
        #expect(
            !InternalVideoPlaybackLifecycle.shouldMaintainPlaybackInBackground(
                hasPodcastSession: true,
                isPlaying: false
            )
        )
        #expect(
            !InternalVideoPlaybackLifecycle.shouldMaintainPlaybackInBackground(
                hasPodcastSession: false,
                isPlaying: true
            )
        )
    }

    @Test func movieAudioSessionIsVideoOnly() {
        #expect(InternalVideoPlaybackLifecycle.prefersMoviePlaybackAudioSession(isInternalVideo: true))
        #expect(!InternalVideoPlaybackLifecycle.prefersMoviePlaybackAudioSession(isInternalVideo: false))
    }
}
