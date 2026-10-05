//
//  PodcastVideoPiPRegistrationTests.swift
//  SilveranTests
//
//  Pure lifecycle/state policy for PiP surface registration and restore.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing

@testable import SilveranKit

@Suite("Podcast video PiP registration")
struct PodcastVideoPiPRegistrationTests {

    @Test func onlyCurrentSurfaceCanUnregisterItself() {
        var active = PodcastVideoPiPActiveSurface()
        active.register(surfaceID: "portrait")
        #expect(active.surfaceID == "portrait")

        active.unregister(surfaceID: "portrait")
        #expect(active.surfaceID == nil)
        #expect(!active.hasActiveSurface)
    }

    @Test func staleUnregisterDoesNotClearNewerRegistration() {
        var active = PodcastVideoPiPActiveSurface()
        active.register(surfaceID: "portrait")
        active.register(surfaceID: "fullscreen")
        #expect(active.surfaceID == "fullscreen")

        // Portrait dismantles after fullscreen already registered.
        active.unregister(surfaceID: "portrait")
        #expect(active.surfaceID == "fullscreen")
        #expect(active.hasActiveSurface)
    }

    @Test func closedSessionBlocksLateRestore() {
        var gate = PodcastVideoPiPRestoreGate()
        gate.beginSession()
        let liveGeneration = gate.sessionGeneration
        #expect(gate.shouldRestoreInterface(observedGeneration: liveGeneration))

        gate.endSession()
        #expect(!gate.shouldRestoreInterface(observedGeneration: liveGeneration))
        #expect(!gate.shouldRestoreInterface(observedGeneration: gate.sessionGeneration))
    }

    @Test func newSessionAfterCloseAllowsRestoreAgain() {
        var gate = PodcastVideoPiPRestoreGate()
        gate.beginSession()
        let first = gate.sessionGeneration
        gate.endSession()
        #expect(!gate.shouldRestoreInterface(observedGeneration: first))

        gate.beginSession()
        let second = gate.sessionGeneration
        #expect(second != first)
        #expect(gate.shouldRestoreInterface(observedGeneration: second))
        #expect(!gate.shouldRestoreInterface(observedGeneration: first))
    }

    @Test func pictureInPictureTransitionDoesNotResetPlayback() {
        #expect(!InternalVideoPlaybackLifecycle.shouldResetPlaybackOnPictureInPictureTransition())
    }

    @Test func teardownWhilePiPActiveKeepsControllerSourcePlayerBound() {
        #expect(
            !PodcastVideoPiPLifecyclePolicy.shouldClearPlayerOnDismantle(
                isPictureInPictureActive: true,
                isControllerContentSource: true
            )
        )
        // Non-source surfaces (or inactive PiP) may clear normally.
        #expect(
            PodcastVideoPiPLifecyclePolicy.shouldClearPlayerOnDismantle(
                isPictureInPictureActive: true,
                isControllerContentSource: false
            )
        )
        #expect(
            PodcastVideoPiPLifecyclePolicy.shouldClearPlayerOnDismantle(
                isPictureInPictureActive: false,
                isControllerContentSource: true
            )
        )
    }

    @Test func possibilityRefreshContinuesUntilPossibleOrControllerChanges() {
        #expect(
            PodcastVideoPiPLifecyclePolicy.shouldContinuePossibilityRefresh(
                isPossible: false,
                hasController: true,
                controllerMatchesObserved: true
            )
        )
        #expect(
            !PodcastVideoPiPLifecyclePolicy.shouldContinuePossibilityRefresh(
                isPossible: true,
                hasController: true,
                controllerMatchesObserved: true
            )
        )
        #expect(
            !PodcastVideoPiPLifecyclePolicy.shouldContinuePossibilityRefresh(
                isPossible: false,
                hasController: false,
                controllerMatchesObserved: true
            )
        )
        #expect(
            !PodcastVideoPiPLifecyclePolicy.shouldContinuePossibilityRefresh(
                isPossible: false,
                hasController: true,
                controllerMatchesObserved: false
            )
        )
    }
}
