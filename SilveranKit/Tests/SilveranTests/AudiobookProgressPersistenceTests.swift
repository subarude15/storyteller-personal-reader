import Foundation
import Testing

@testable import SilveranKit

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

@Test func checkpointAppendKeepsLatestAndBoundsRing() {
    let book = BookID(sourceID: "s", uuid: "b")
    let locator = BookLocator(
        href: "audiobook",
        type: "audio/mp4",
        title: "Ch",
        locations: BookLocator.Locations(
            fragments: nil,
            progression: 0.1,
            position: nil,
            totalProgression: 0.1,
            cssSelector: nil,
            partialCfi: nil,
            domRange: nil,
        ),
        text: nil,
    )
    var ring: [AudiobookRecoveryCheckpoint] = []
    for i in 1...5 {
        let checkpoint = AudiobookRecoveryCheckpoint(
            bookID: book,
            locator: locator,
            totalProgression: Double(i) / 10,
            timestamp: Double(i * 1_000),
            reason: "periodicCheckpoint",
            sessionGeneration: 1,
            updatedAt: Double(i * 1_000),
        )
        ring = AudiobookProgressConflict.appendCheckpoint(existing: ring, new: checkpoint)
    }
    #expect(ring.count == AudiobookProgressConflict.maxCheckpointsPerBook)
    #expect(ring.first?.totalProgression == 0.5)
    #expect(ring.contains(where: { $0.totalProgression == 0.5 }))
}

@Test func checkpointAppendNeverDropsOnlyRecoveryState() {
    let book = BookID(sourceID: "s", uuid: "only")
    let locator = BookLocator(
        href: "audiobook",
        type: "audio/mp4",
        title: nil,
        locations: BookLocator.Locations(
            fragments: nil,
            progression: 0.58,
            position: nil,
            totalProgression: 0.58,
            cssSelector: nil,
            partialCfi: nil,
            domRange: nil,
        ),
        text: nil,
    )
    let only = AudiobookRecoveryCheckpoint(
        bookID: book,
        locator: locator,
        totalProgression: 0.58,
        timestamp: 9_000,
        reason: "pause",
        sessionGeneration: 2,
    )
    let ring = AudiobookProgressConflict.appendCheckpoint(existing: [], new: only)
    #expect(ring.count == 1)
    #expect(ring[0].totalProgression == 0.58)
}

@Test func listeningMilestoneCapAndCoalesce() {
    let book = BookID(sourceID: "s", uuid: "hist")
    let locator = BookLocator(
        href: "audiobook",
        type: "audio/mp4",
        title: "Ch",
        locations: nil,
        text: nil,
    )
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
    let book = BookID(sourceID: "s", uuid: "rapid")
    let locator = BookLocator(
        href: "audiobook",
        type: "audio/mp4",
        title: nil,
        locations: BookLocator.Locations(
            fragments: nil,
            progression: 0.3,
            position: nil,
            totalProgression: 0.3,
            cssSelector: nil,
            partialCfi: nil,
            domRange: nil,
        ),
        text: nil,
    )
    let first = AudiobookRecoveryCheckpoint(
        bookID: book,
        locator: locator,
        totalProgression: 0.3,
        timestamp: 1_000,
        reason: "appBackgrounding",
        sessionGeneration: 1,
        updatedAt: 1_000,
    )
    let second = AudiobookRecoveryCheckpoint(
        bookID: book,
        locator: locator,
        totalProgression: 0.3,
        timestamp: 1_000,
        reason: "appBackgrounding",
        sessionGeneration: 1,
        updatedAt: 1_100,
    )
    var ring = AudiobookProgressConflict.appendCheckpoint(existing: [], new: first)
    ring = AudiobookProgressConflict.appendCheckpoint(existing: ring, new: second)
    #expect(ring.count == 1)
    #expect(ring[0].updatedAt == 1_100)
}
