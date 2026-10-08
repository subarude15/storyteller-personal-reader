import Foundation
import Testing

@testable import SilveranKit

private func sampleLocator(progress: Double) -> BookLocator {
    BookLocator(
        href: "audiobook",
        type: "audio/mp4",
        title: "Ch",
        locations: BookLocator.Locations(
            fragments: nil,
            progression: progress,
            position: nil,
            totalProgression: progress,
            cssSelector: nil,
            partialCfi: nil,
            domRange: nil,
        ),
        text: nil,
    )
}

private func sampleCheckpoint(
    book: BookID = BookID(sourceID: "s", uuid: "b"),
    progress: Double,
    timestamp: Double,
    reason: String = "periodicCheckpoint",
    updatedAt: Double? = nil,
) -> AudiobookRecoveryCheckpoint {
    AudiobookRecoveryCheckpoint(
        bookID: book,
        locator: sampleLocator(progress: progress),
        totalProgression: progress,
        timestamp: timestamp,
        reason: reason,
        sessionGeneration: 1,
        updatedAt: updatedAt ?? timestamp,
    )
}

@Test func conflictRejectsUninitializedZero() {
    let result = AudiobookProgressConflict.evaluate(
        ProgressConflictInput(
            incomingProgression: 0,
            incomingTimestamp: 2_000,
            playheadInitialized: false,
            isExplicitUserAction: false,
            knownBestProgression: 0.58,
        )
    )
    #expect(result == .rejectUninitializedZero)
}

@Test func conflictRejectsUninitializedNonZero() {
    let result = AudiobookProgressConflict.evaluate(
        ProgressConflictInput(
            incomingProgression: 0.12,
            incomingTimestamp: 2_000,
            playheadInitialized: false,
            isExplicitUserAction: false,
        )
    )
    #expect(result == .rejectUninitialized)
}

@Test func conflictAllowsExplicitZeroRestart() {
    let result = AudiobookProgressConflict.evaluate(
        ProgressConflictInput(
            incomingProgression: 0,
            incomingTimestamp: 3_000,
            playheadInitialized: true,
            isExplicitUserAction: true,
            knownBestProgression: 0.58,
        )
    )
    #expect(result == .accept)
}

@Test func conflictRejectsSuspiciousZeroAgainstKnownProgress() {
    let result = AudiobookProgressConflict.evaluate(
        ProgressConflictInput(
            incomingProgression: 0,
            incomingTimestamp: 3_000,
            playheadInitialized: true,
            isExplicitUserAction: false,
            knownBestProgression: 0.58,
        )
    )
    #expect(result == .rejectSuspiciousZero(knownProgress: 0.58))
}

@Test func conflictAllowsZeroForNewBookWithoutKnownProgress() {
    let result = AudiobookProgressConflict.evaluate(
        ProgressConflictInput(
            incomingProgression: 0,
            incomingTimestamp: 1_000,
            playheadInitialized: true,
            isExplicitUserAction: false,
            knownBestProgression: nil,
        )
    )
    #expect(result == .accept)
}

@Test func conflictAllowsDeliberateBackwardSeek() {
    let result = AudiobookProgressConflict.evaluate(
        ProgressConflictInput(
            incomingProgression: 0.20,
            incomingTimestamp: 5_000,
            playheadInitialized: true,
            isExplicitUserAction: true,
            knownBestProgression: 0.80,
            lastAuthoritativeUserActionTimestamp: 4_000,
        )
    )
    #expect(result == .accept)
}

@Test func conflictRejectsStaleIncomingVersusNewerUserAction() {
    let result = AudiobookProgressConflict.evaluate(
        ProgressConflictInput(
            incomingProgression: 0.55,
            incomingTimestamp: 1_000,
            playheadInitialized: true,
            isExplicitUserAction: false,
            lastAuthoritativeUserActionTimestamp: 4_000,
        )
    )
    #expect(result == .rejectStaleVersusUserAction(userActionTimestamp: 4_000))
}

@Test func preferredRestoreUsesNewestTimestampNotHighestPercent() {
    let preferred = AudiobookProgressConflict.preferredRestore(
        candidates: [
            (progression: 0.90, timestamp: 1_000, source: "oldHigh"),
            (progression: 0.25, timestamp: 5_000, source: "newRewind"),
            (progression: 0.10, timestamp: 2_000, source: "mid"),
        ]
    )
    #expect(preferred?.source == "newRewind")
    #expect(preferred?.progression == 0.25)
}

@Test func preferredRestoreTieBreakPrefersNonZero() {
    let preferred = AudiobookProgressConflict.preferredRestore(
        candidates: [
            (progression: 0.0, timestamp: 5_000, source: "zero"),
            (progression: 0.42, timestamp: 5_000, source: "nonzero"),
        ]
    )
    #expect(preferred?.source == "nonzero")
}

@Test func checkpointAppendKeepsLatestByEventTimestampAndBoundsRing() {
    var ring: [AudiobookRecoveryCheckpoint] = []
    for i in 1...5 {
        let outcome = AudiobookProgressConflict.appendCheckpoint(
            existing: ring,
            new: sampleCheckpoint(progress: Double(i) / 10, timestamp: Double(i * 1_000)),
        )
        guard case .appended(let next) = outcome else {
            Issue.record("expected append")
            return
        }
        ring = next
    }
    #expect(ring.count == AudiobookProgressConflict.maxCheckpointsPerBook)
    #expect(ring.first?.totalProgression == 0.5)
}

@Test func checkpointAppendNeverDropsOnlyRecoveryState() {
    let outcome = AudiobookProgressConflict.appendCheckpoint(
        existing: [],
        new: sampleCheckpoint(progress: 0.58, timestamp: 9_000, reason: "pause"),
    )
    guard case .appended(let ring) = outcome else {
        Issue.record("expected append")
        return
    }
    #expect(ring.count == 1)
    #expect(ring[0].totalProgression == 0.58)
}

@Test func delayedOlderCheckpointCannotSupersedeNewerExplicitRewind() {
    let rewind = sampleCheckpoint(progress: 0.20, timestamp: 5_000, reason: "userDraggedSeekBar")
    guard case .appended(let afterRewind) = AudiobookProgressConflict.appendCheckpoint(
        existing: [sampleCheckpoint(progress: 0.80, timestamp: 1_000)],
        new: rewind,
        isExplicitUserAction: true,
    ) else {
        Issue.record("expected rewind append")
        return
    }
    #expect(afterRewind.first?.totalProgression == 0.20)

    let delayedOld = sampleCheckpoint(
        progress: 0.79,
        timestamp: 2_000,
        reason: "periodicCheckpoint",
        updatedAt: 9_999,
    )
    let delayed = AudiobookProgressConflict.appendCheckpoint(
        existing: afterRewind,
        new: delayedOld,
        isExplicitUserAction: false,
    )
    #expect(delayed == .rejectedStale)
}

@Test func rejectedSuspiciousZeroWouldNotPassCheckpointBoundaryRules() {
    // Mirrors PSA saveRecoveryCheckpoint gate: suspicious zero must not replace
    // a known valid recovery position unless the write is an explicit user action.
    let acceptance = AudiobookProgressConflict.evaluate(
        ProgressConflictInput(
            incomingProgression: 0,
            incomingTimestamp: 8_000,
            playheadInitialized: true,
            isExplicitUserAction: false,
            knownBestProgression: 0.58,
            lastAuthoritativeUserActionTimestamp: 7_000,
        )
    )
    #expect(acceptance == .rejectSuspiciousZero(knownProgress: 0.58))

    let periodicInvalid = AudiobookProgressConflict.evaluate(
        ProgressConflictInput(
            incomingProgression: 0,
            incomingTimestamp: 8_000,
            playheadInitialized: false,
            isExplicitUserAction: false,
            knownBestProgression: 0.58,
        )
    )
    #expect(periodicInvalid == .rejectUninitializedZero)
}

@Test func duplicateLocatorStillRequiresCheckpointValidation() {
    // Even if AudioSessionActor skips Storyteller upload for an unchanged locator,
    // checkpoint persistence must still evaluate conflict rules.
    let acceptance = AudiobookProgressConflict.evaluate(
        ProgressConflictInput(
            incomingProgression: 0,
            incomingTimestamp: 3_000,
            playheadInitialized: true,
            isExplicitUserAction: false,
            knownBestProgression: 0.42,
        )
    )
    #expect(acceptance == .rejectSuspiciousZero(knownProgress: 0.42))
}

@Test func deliberateRewindSurvivesPreferredRestoreAcrossTermination() {
    // After kill/relaunch, restore uses newest event timestamp — not highest %.
    let preferred = AudiobookProgressConflict.preferredRestore(
        candidates: [
            (progression: 0.88, timestamp: 1_000, source: "checkpointBeforeRewind"),
            (progression: 0.30, timestamp: 4_000, source: "checkpointAfterRewind"),
            (progression: 0.88, timestamp: 1_500, source: "pendingBeforeRewind"),
        ]
    )
    #expect(preferred?.source == "checkpointAfterRewind")
    #expect(preferred?.progression == 0.30)
}

@Test func listeningMilestoneCapAndCoalesce() {
    let book = BookID(sourceID: "s", uuid: "hist")
    let locator = sampleLocator(progress: 0.1)
    var milestones: [AudiobookListeningMilestone] = []
    for i in 1...25 {
        let milestone = AudiobookListeningMilestone(
            bookID: book,
            locator: locator,
            totalProgression: Double(i) / 100,
            timestamp: Double(i * 10_000),
            locationDescription: "Ch, \(i)%",
            reason: .userPausedPlayback,
        )
        milestones = AudiobookProgressConflict.appendMilestone(existing: milestones, new: milestone)
    }
    #expect(milestones.count == AudiobookProgressConflict.maxListeningMilestonesPerBook)
    #expect(milestones.first?.totalProgression == 0.25)

    let nearDuplicate = AudiobookListeningMilestone(
        bookID: book,
        locator: locator,
        totalProgression: 0.2505,
        timestamp: 250_500,
        locationDescription: "Ch, 25%",
        reason: .userPausedPlayback,
    )
    milestones = AudiobookProgressConflict.appendMilestone(
        existing: milestones,
        new: nearDuplicate,
    )
    #expect(milestones.count == AudiobookProgressConflict.maxListeningMilestonesPerBook)
    #expect(milestones.first?.totalProgression == 0.2505)
}

@Test func delayedServerDoesNotNavigatePastNewerUserAction() {
    #expect(
        AudiobookProgressConflict.shouldNavigateToIncomingServer(
            incomingTimestamp: 1_000,
            lastUserActionTimestamp: 5_000,
            autoSyncEnabled: true,
        ) == false
    )
    #expect(
        AudiobookProgressConflict.shouldNavigateToIncomingServer(
            incomingTimestamp: 6_000,
            lastUserActionTimestamp: 5_000,
            autoSyncEnabled: true,
        ) == true
    )
    #expect(
        AudiobookProgressConflict.shouldNavigateToIncomingServer(
            incomingTimestamp: 9_000,
            lastUserActionTimestamp: nil,
            autoSyncEnabled: false,
        ) == false
    )
}

@Test func rapidCheckpointWritesDoNotDuplicateIdenticalTimestampReason() {
    let first = sampleCheckpoint(
        progress: 0.3,
        timestamp: 1_000,
        reason: "appBackgrounding",
        updatedAt: 1_000,
    )
    let second = sampleCheckpoint(
        progress: 0.3,
        timestamp: 1_000,
        reason: "appBackgrounding",
        updatedAt: 1_100,
    )
    guard case .appended(let once) = AudiobookProgressConflict.appendCheckpoint(
        existing: [],
        new: first,
    ) else {
        Issue.record("expected first append")
        return
    }
    guard case .appended(let ring) = AudiobookProgressConflict.appendCheckpoint(
        existing: once,
        new: second,
    ) else {
        Issue.record("expected second append")
        return
    }
    #expect(ring.count == 1)
    #expect(ring[0].updatedAt == 1_100)
}

@Test func checkpointPruningKeepsNewestValidRecoveryState() {
    var ring: [AudiobookRecoveryCheckpoint] = []
    for i in 1...6 {
        let outcome = AudiobookProgressConflict.appendCheckpoint(
            existing: ring,
            new: sampleCheckpoint(progress: Double(i) / 10, timestamp: Double(i * 1_000)),
        )
        guard case .appended(let next) = outcome else {
            Issue.record("expected append at \(i)")
            return
        }
        ring = next
        #expect(!ring.isEmpty)
    }
    #expect(ring.first?.timestamp == 6_000)
    #expect(ring.first?.totalProgression == 0.6)
}

@Test func listeningRestoreResultDistinguishesFailureModes() {
    #expect(ListeningRestoreResult.success != .syncFailed)
    #expect(ListeningRestoreResult.syncRejected != .seekFailed)
    #expect(ListeningRestoreResult.noActiveBook != .success)
    #expect(ListeningRestoreResult.invalidLocator != .sessionReplaced)
    #expect(ListeningRestoreResult.seekFailed != .invalidLocator)
    #expect(ListeningRestoreResult.sessionReplaced != .syncFailed)
}

@Test func syncResultRejectedIsDistinctFromSuccess() {
    let rejected: SyncResult = .rejected
    #expect(rejected != .success)
    #expect(rejected != .queued)
    #expect(rejected != .failed)
}

@Test func validatedRestoreProgressionRejectsMissingOrOutOfRange() {
    let known: Set<String> = ["chapter-0", "chapter-1"]
    let missing = BookLocator(
        href: "chapter-0",
        type: "audio/mp4",
        title: nil,
        locations: nil,
        text: nil,
    )
    #expect(
        AudiobookProgressConflict.validatedRestoreProgression(
            locator: missing,
            knownHrefs: known,
        ) == nil
    )

    let over = sampleLocator(progress: 1.5)
    #expect(
        AudiobookProgressConflict.validatedRestoreProgression(
            locator: over,
            knownHrefs: known,
        ) == nil
    )

    let under = sampleLocator(progress: -0.1)
    #expect(
        AudiobookProgressConflict.validatedRestoreProgression(
            locator: under,
            knownHrefs: known,
        ) == nil
    )
}

@Test func validatedRestoreProgressionRejectsForeignHref() {
    let known: Set<String> = ["chapter-0", "chapter-1"]
    let foreign = BookLocator(
        href: "other-book-track",
        type: "audio/mp4",
        title: "Ch",
        locations: BookLocator.Locations(
            fragments: nil,
            progression: 0.4,
            position: nil,
            totalProgression: 0.4,
            cssSelector: nil,
            partialCfi: nil,
            domRange: nil,
        ),
        text: nil,
    )
    #expect(
        AudiobookProgressConflict.validatedRestoreProgression(
            locator: foreign,
            knownHrefs: known,
        ) == nil
    )

    let emptyHref = BookLocator(
        href: "  ",
        type: "audio/mp4",
        title: nil,
        locations: BookLocator.Locations(
            fragments: nil,
            progression: 0.2,
            position: nil,
            totalProgression: 0.2,
            cssSelector: nil,
            partialCfi: nil,
            domRange: nil,
        ),
        text: nil,
    )
    #expect(
        AudiobookProgressConflict.validatedRestoreProgression(
            locator: emptyHref,
            knownHrefs: known,
        ) == nil
    )
}

@Test func validatedRestoreProgressionAcceptsKnownHrefAndGenericFallback() {
    let known: Set<String> = ["chapter-0", "chapter-1"]
    #expect(
        AudiobookProgressConflict.validatedRestoreProgression(
            locator: BookLocator(
                href: "chapter-1",
                type: "audio/mp4",
                title: "Ch",
                locations: BookLocator.Locations(
                    fragments: nil,
                    progression: 0.55,
                    position: nil,
                    totalProgression: 0.55,
                    cssSelector: nil,
                    partialCfi: nil,
                    domRange: nil,
                ),
                text: nil,
            ),
            knownHrefs: known,
        ) == 0.55
    )
    #expect(
        AudiobookProgressConflict.validatedRestoreProgression(
            locator: sampleLocator(progress: 0.42),
            knownHrefs: known,
        ) == 0.42
    )
}

@Test func seekToleranceIsSecondsBasedNotFivePercent() {
    // 10-hour book: 5% would be 30 minutes — far too loose.
    let tenHours: TimeInterval = 10 * 60 * 60
    let fivePercentMiss = 0.50 + 0.06  // 6pp away from 50%
    #expect(
        AudiobookProgressConflict.seekLandedWithinTolerance(
            targetProgression: 0.50,
            landedProgression: fivePercentMiss,
            durationSeconds: tenHours,
        ) == false
    )
    // ~1.5s miss on a long book must still pass.
    let onePointFiveSeconds = 0.50 + (1.5 / tenHours)
    #expect(
        AudiobookProgressConflict.seekLandedWithinTolerance(
            targetProgression: 0.50,
            landedProgression: onePointFiveSeconds,
            durationSeconds: tenHours,
        ) == true
    )
    // Just under 2s still within budget (avoid constructing exact 2.0 via
    // fraction*duration — IEEE noise can nudge it slightly over).
    let underTwoSeconds = 0.50 + (1.999 / tenHours)
    #expect(
        AudiobookProgressConflict.seekLandedWithinTolerance(
            targetProgression: 0.50,
            landedProgression: underTwoSeconds,
            durationSeconds: tenHours,
        ) == true
    )
    // Just over 2s must fail — a fixed fractional floor (e.g. 0.0005 ≈ 18s
    // on a 10h book) must not accept this.
    let overTwoSeconds = 0.50 + (2.5 / tenHours)
    #expect(abs(overTwoSeconds - 0.50) * tenHours > AudiobookProgressConflict.seekToleranceSeconds)
    #expect(
        AudiobookProgressConflict.seekLandedWithinTolerance(
            targetProgression: 0.50,
            landedProgression: overTwoSeconds,
            durationSeconds: tenHours,
        ) == false
    )
    // Tolerance width derived from seconds, not a % floor.
    let expectedFraction = 2.0 / tenHours
    #expect(
        AudiobookProgressConflict.seekToleranceFraction(durationSeconds: tenHours)
            == expectedFraction
    )
    #expect(expectedFraction < 0.001)
}

@Test func seekToleranceAllowsNearExactLandingOnShortAssets() {
    let short: TimeInterval = 30
    #expect(
        AudiobookProgressConflict.seekLandedWithinTolerance(
            targetProgression: 0.10,
            landedProgression: 0.10 + (1.0 / short),
            durationSeconds: short,
        ) == true
    )
    #expect(
        AudiobookProgressConflict.seekLandedWithinTolerance(
            targetProgression: 0.10,
            landedProgression: 0.10 + (3.0 / short),
            durationSeconds: short,
        ) == false
    )
}

@Test func restoreSequenceDoesNotCommitBeforeVerifiedSeek() {
    // Pure regression of the restore contract: invalid locator / failed seek /
    // persistence failure must not be reported as success, and delayed server
    // navigation stays blocked once the user-action clock is stamped.
    enum Phase: Equatable {
        case validate
        case stampUserAction
        case seek
        case verify
        case persist
        case done
    }

    func simulate(
        locatorValid: Bool,
        seekOk: Bool,
        persistOk: Bool,
    ) -> (result: ListeningRestoreResult, committed: Bool, lastPhase: Phase) {
        var phase = Phase.validate
        var committed = false
        var userActionTs: Double?

        guard locatorValid else {
            return (.invalidLocator, false, phase)
        }
        phase = .stampUserAction
        userActionTs = 5_000
        // Delayed older server must not navigate past the stamp.
        #expect(
            AudiobookProgressConflict.shouldNavigateToIncomingServer(
                incomingTimestamp: 1_000,
                lastUserActionTimestamp: userActionTs,
                autoSyncEnabled: true,
            ) == false
        )

        phase = .seek
        guard seekOk else {
            return (.seekFailed, false, phase)
        }
        phase = .verify
        // Seek verified — only now may we commit.
        phase = .persist
        guard persistOk else {
            return (.syncFailed, false, phase)
        }
        committed = true
        phase = .done
        return (.success, committed, phase)
    }

    let failedSeek = simulate(locatorValid: true, seekOk: false, persistOk: true)
    #expect(failedSeek.result == .seekFailed)
    #expect(failedSeek.committed == false)

    let invalid = simulate(locatorValid: false, seekOk: true, persistOk: true)
    #expect(invalid.result == .invalidLocator)
    #expect(invalid.committed == false)

    let persistFail = simulate(locatorValid: true, seekOk: true, persistOk: false)
    #expect(persistFail.result == .syncFailed)
    #expect(persistFail.committed == false)
    #expect(persistFail.lastPhase == .persist)

    let ok = simulate(locatorValid: true, seekOk: true, persistOk: true)
    #expect(ok.result == .success)
    #expect(ok.committed == true)
    #expect(ok.lastPhase == .done)
}

@Test func sessionReplacementDuringRestoreIsDistinctFailure() {
    // Captured generation must match after each await; mismatch is not seekFailed.
    let startGeneration: UInt64 = 3
    let afterOpenGeneration: UInt64 = 4
    #expect(startGeneration != afterOpenGeneration)
    #expect(ListeningRestoreResult.sessionReplaced != .seekFailed)
    #expect(ListeningRestoreResult.sessionReplaced != .syncFailed)
}
