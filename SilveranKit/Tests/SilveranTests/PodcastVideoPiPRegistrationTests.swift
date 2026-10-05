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

    @Test func activePiPSourceSurvivesItsSurfaceUnregister() {
        var binding = PodcastVideoPiPBindingState()
        binding.registerVisible(surfaceID: "A")
        binding.protectSource(sourceID: "layer-A")

        binding.unregisterVisible(surfaceID: "A")
        #expect(binding.visibleSurfaceID == nil)
        #expect(binding.protectedSourceID == "layer-A")
        #expect(binding.isPictureInPictureActive)
        #expect(!binding.mayClearPlayer(sourceID: "layer-A"))
    }

    @Test func staleNonSourceLayerMayBeReleasedNormally() {
        var binding = PodcastVideoPiPBindingState()
        binding.registerVisible(surfaceID: "B")
        binding.protectSource(sourceID: "layer-A")

        #expect(binding.mayClearPlayer(sourceID: "layer-B"))
        #expect(
            PodcastVideoPiPLifecyclePolicy.shouldClearPlayerOnDismantle(
                isPictureInPictureActive: true,
                isControllerContentSource: false
            )
        )
    }

    @Test func newVisibleSurfaceCanRegisterWhilePiPRemainsBoundToPreviousSource() {
        var binding = PodcastVideoPiPBindingState()
        binding.registerVisible(surfaceID: "A")
        binding.protectSource(sourceID: "layer-A")

        // B appears (fullscreen / orientation) while PiP still samples A.
        binding.registerVisible(surfaceID: "B")
        #expect(binding.visibleSurfaceID == "B")
        #expect(binding.protectedSourceID == "layer-A")
        #expect(!binding.mayClearPlayer(sourceID: "layer-A"))
        #expect(binding.mayClearPlayer(sourceID: "layer-B"))

        // A dismantles — visible stays B; protected source stays A.
        binding.unregisterVisible(surfaceID: "A")
        #expect(binding.visibleSurfaceID == "B")
        #expect(binding.protectedSourceID == "layer-A")
        #expect(!binding.mayClearPlayer(sourceID: "layer-A"))
    }

    @Test func pipStopReleasesOldProtectedSourceAndAllowsNewVisibleControllerSource() {
        var binding = PodcastVideoPiPBindingState()
        binding.registerVisible(surfaceID: "B")
        binding.protectSource(sourceID: "layer-A")

        // A is orphaned; B is the live visible layer — clear A's player.
        #expect(
            binding.shouldClearReleasedSourcePlayer(releasedSourceIsStillVisibleLayer: false)
        )
        // If the protected layer were still the visible one, keep its player.
        #expect(
            !binding.shouldClearReleasedSourcePlayer(releasedSourceIsStillVisibleLayer: true)
        )

        binding.releaseProtectedSource()
        #expect(binding.protectedSourceID == nil)
        #expect(!binding.isPictureInPictureActive)
        #expect(binding.visibleSurfaceID == "B")
        // After release, clearing "layer-A" is no longer blocked by protection.
        #expect(binding.mayClearPlayer(sourceID: "layer-A"))
    }

    @Test func sessionCloseReleasesRegisteredAndProtectedSourceState() {
        var binding = PodcastVideoPiPBindingState()
        binding.registerVisible(surfaceID: "B")
        binding.protectSource(sourceID: "layer-A")

        binding.endSession()
        #expect(binding.visibleSurfaceID == nil)
        #expect(binding.protectedSourceID == nil)
        #expect(!binding.isPictureInPictureActive)
        #expect(binding.mayClearPlayer(sourceID: "layer-A"))
    }

    @Test func lateRestoreRemainsBlockedAfterSessionClose() {
        var gate = PodcastVideoPiPRestoreGate()
        var binding = PodcastVideoPiPBindingState()
        gate.beginSession()
        binding.registerVisible(surfaceID: "A")
        binding.protectSource(sourceID: "layer-A")
        let liveGeneration = gate.sessionGeneration

        gate.endSession()
        binding.endSession()
        #expect(!gate.shouldRestoreInterface(observedGeneration: liveGeneration))
        #expect(binding.protectedSourceID == nil)
        #expect(binding.visibleSurfaceID == nil)
    }

    @Test func teardownWhilePiPActiveKeepsControllerSourcePlayerBound() {
        #expect(
            !PodcastVideoPiPLifecyclePolicy.shouldClearPlayerOnDismantle(
                isPictureInPictureActive: true,
                isControllerContentSource: true
            )
        )
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
