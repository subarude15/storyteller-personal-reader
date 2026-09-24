import Foundation
import Testing

@testable import SilveranKit

@Suite("Storyteller reconnect policy")
struct StorytellerReconnectPolicyTests {

    // MARK: - Delay formula (current actor semantics)

    @Test func backoffDelayIsLinearFiveSecondsPerFailure() {
        #expect(StorytellerReconnectPolicy.backoffDelay(afterFailureCount: 0) == 0)
        #expect(StorytellerReconnectPolicy.backoffDelay(afterFailureCount: 1) == 5)
        #expect(StorytellerReconnectPolicy.backoffDelay(afterFailureCount: 2) == 10)
        #expect(StorytellerReconnectPolicy.backoffDelay(afterFailureCount: 3) == 15)
        #expect(StorytellerReconnectPolicy.backoffDelay(afterFailureCount: 11) == 55)
    }

    @Test func backoffDelayCapsAtSixtySeconds() {
        #expect(StorytellerReconnectPolicy.backoffDelay(afterFailureCount: 12) == 60)
        #expect(StorytellerReconnectPolicy.backoffDelay(afterFailureCount: 13) == 60)
        #expect(StorytellerReconnectPolicy.backoffDelay(afterFailureCount: 100) == 60)
    }

    @Test func constantsMatchPriorHardcodedValues() {
        #expect(StorytellerReconnectPolicy.delayPerFailureSeconds == 5)
        #expect(StorytellerReconnectPolicy.maxDelaySeconds == 60)
    }

    // MARK: - Eligibility

    @Test func canAttemptBlockedWhenOffline() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(
            !StorytellerReconnectPolicy.canAttempt(
                networkAvailable: false,
                cooldownUntil: nil,
                now: now,
            )
        )
        #expect(
            !StorytellerReconnectPolicy.canAttempt(
                networkAvailable: false,
                cooldownUntil: now.addingTimeInterval(-10),
                now: now,
            )
        )
    }

    @Test func canAttemptAllowedWithNoCooldownWhenOnline() {
        #expect(
            StorytellerReconnectPolicy.canAttempt(
                networkAvailable: true,
                cooldownUntil: nil,
                now: Date(timeIntervalSince1970: 1_000),
            )
        )
    }

    @Test func canAttemptRespectsCooldownWindow() {
        let now = Date(timeIntervalSince1970: 1_000)
        let until = now.addingTimeInterval(5)
        #expect(
            !StorytellerReconnectPolicy.canAttempt(
                networkAvailable: true,
                cooldownUntil: until,
                now: now,
            )
        )
        #expect(
            StorytellerReconnectPolicy.canAttempt(
                networkAvailable: true,
                cooldownUntil: until,
                now: until,
            )
        )
        #expect(
            StorytellerReconnectPolicy.canAttempt(
                networkAvailable: true,
                cooldownUntil: until,
                now: until.addingTimeInterval(0.001),
            )
        )
    }

    // MARK: - Schedule next state (post-increment semantics)

    @Test func nextBackoffStateIncrementsAndAppliesDelay() {
        let now = Date(timeIntervalSince1970: 2_000)
        let first = StorytellerReconnectPolicy.nextBackoffState(
            currentFailureCount: 0,
            now: now,
        )
        #expect(first.failureCount == 1)
        #expect(first.delay == 5)
        #expect(first.cooldownUntil == now.addingTimeInterval(5))

        let twelfth = StorytellerReconnectPolicy.nextBackoffState(
            currentFailureCount: 11,
            now: now,
        )
        #expect(twelfth.failureCount == 12)
        #expect(twelfth.delay == 60)
        #expect(twelfth.cooldownUntil == now.addingTimeInterval(60))
    }
}
