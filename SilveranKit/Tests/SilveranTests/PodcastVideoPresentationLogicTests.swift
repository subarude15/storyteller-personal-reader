//
//  PodcastVideoPresentationLogicTests.swift
//  SilveranTests
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing

@testable import SilveranKit

@Suite("Podcast video presentation")
struct PodcastVideoPresentationLogicTests {

    private func phoneVideoExpanded() -> PodcastVideoPresentationContext {
        PodcastVideoPresentationContext(
            isInternalVideo: true,
            isPlayerExpanded: true,
            isPhone: true
        )
    }

    @Test func videoExpandedLandscapeEntersFullscreen() {
        let next = PodcastVideoPresentationLogic.reduce(
            state: .portrait,
            event: .interfaceOrientationChanged(.landscape),
            context: phoneVideoExpanded()
        )
        #expect(next.mode == .landscapeFullscreen)
        #expect(next.entryReason == .automaticRotation)
    }

    @Test func audioExpandedLandscapeDoesNotEnterFullscreen() {
        let context = PodcastVideoPresentationContext(
            isInternalVideo: false,
            isPlayerExpanded: true,
            isPhone: true
        )
        let next = PodcastVideoPresentationLogic.reduce(
            state: .portrait,
            event: .interfaceOrientationChanged(.landscape),
            context: context
        )
        #expect(next.mode == .portrait)
        #expect(next.entryReason == nil)
    }

    @Test func miniPlayerLandscapeDoesNotEnterFullscreen() {
        let context = PodcastVideoPresentationContext(
            isInternalVideo: true,
            isPlayerExpanded: false,
            isPhone: true
        )
        let next = PodcastVideoPresentationLogic.reduce(
            state: .portrait,
            event: .interfaceOrientationChanged(.landscape),
            context: context
        )
        #expect(next.mode == .portrait)
    }

    @Test func autoEnteredFullscreenExitsOnPortrait() {
        let entered = PodcastVideoPresentationState(
            mode: .landscapeFullscreen,
            entryReason: .automaticRotation
        )
        let next = PodcastVideoPresentationLogic.reduce(
            state: entered,
            event: .interfaceOrientationChanged(.portrait),
            context: phoneVideoExpanded()
        )
        #expect(next.mode == .portrait)
        #expect(next.entryReason == nil)
    }

    @Test func manualFullscreenRemainsOnPortraitRotation() {
        let entered = PodcastVideoPresentationState(
            mode: .landscapeFullscreen,
            entryReason: .manual
        )
        let next = PodcastVideoPresentationLogic.reduce(
            state: entered,
            event: .interfaceOrientationChanged(.portrait),
            context: phoneVideoExpanded()
        )
        #expect(next.mode == .landscapeFullscreen)
        #expect(next.entryReason == .manual)
    }

    @Test func manualExitLeavesFullscreen() {
        let entered = PodcastVideoPresentationState(
            mode: .landscapeFullscreen,
            entryReason: .manual
        )
        let next = PodcastVideoPresentationLogic.reduce(
            state: entered,
            event: .manualExitFullscreen,
            context: phoneVideoExpanded()
        )
        #expect(next == .portrait)
    }

    @Test func videoToAudioQueueExitsFullscreen() {
        let entered = PodcastVideoPresentationState(
            mode: .landscapeFullscreen,
            entryReason: .automaticRotation
        )
        let next = PodcastVideoPresentationLogic.reduce(
            state: entered,
            event: .mediaBecameNonVideo,
            context: PodcastVideoPresentationContext(
                isInternalVideo: false,
                isPlayerExpanded: true,
                isPhone: true
            )
        )
        #expect(next.mode == .portrait)
    }

    @Test func iPadDoesNotAutoEnterOnLandscape() {
        let context = PodcastVideoPresentationContext(
            isInternalVideo: true,
            isPlayerExpanded: true,
            isPhone: false
        )
        let next = PodcastVideoPresentationLogic.reduce(
            state: .portrait,
            event: .interfaceOrientationChanged(.landscape),
            context: context
        )
        #expect(next.mode == .portrait)
    }

    @Test func iPadManualFullscreenStillWorks() {
        let context = PodcastVideoPresentationContext(
            isInternalVideo: true,
            isPlayerExpanded: true,
            isPhone: false
        )
        let next = PodcastVideoPresentationLogic.reduce(
            state: .portrait,
            event: .manualEnterFullscreen,
            context: context
        )
        #expect(next.mode == .landscapeFullscreen)
        #expect(next.entryReason == .manual)
    }

    @Test func ignoredOrientationDoesNotChangeState() {
        let entered = PodcastVideoPresentationState(
            mode: .landscapeFullscreen,
            entryReason: .automaticRotation
        )
        let next = PodcastVideoPresentationLogic.reduce(
            state: entered,
            event: .interfaceOrientationChanged(.ignored),
            context: phoneVideoExpanded()
        )
        #expect(next == entered)
    }

    @Test func shouldEnterFullscreenHelpers() {
        #expect(
            PodcastVideoPresentationLogic.shouldEnterFullscreen(
                mediaIsInternalVideo: true,
                playerExpanded: true,
                interfaceOrientation: .landscape,
                isPhone: true
            )
        )
        #expect(
            !PodcastVideoPresentationLogic.shouldEnterFullscreen(
                mediaIsInternalVideo: true,
                playerExpanded: false,
                interfaceOrientation: .landscape,
                isPhone: true
            )
        )
        #expect(
            !PodcastVideoPresentationLogic.shouldEnterFullscreen(
                mediaIsInternalVideo: false,
                playerExpanded: true,
                interfaceOrientation: .landscape,
                isPhone: true
            )
        )
    }

    @Test func playerCollapsedExitsFullscreen() {
        let entered = PodcastVideoPresentationState(
            mode: .landscapeFullscreen,
            entryReason: .manual
        )
        let next = PodcastVideoPresentationLogic.reduce(
            state: entered,
            event: .playerCollapsed,
            context: phoneVideoExpanded()
        )
        #expect(next.mode == .portrait)
    }
}
