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
}

@Test func syncResultRejectedIsDistinctFromSuccess() {
    let rejected: SyncResult = .rejected
    #expect(rejected != .success)
    #expect(rejected != .queued)
    #expect(rejected != .failed)
}
