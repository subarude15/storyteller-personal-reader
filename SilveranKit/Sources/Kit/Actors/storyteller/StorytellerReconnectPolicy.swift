import Foundation

/// Pure reconnect eligibility and backoff delay math formerly inlined on `StorytellerActor`.
///
/// R9 boundary: deterministic policy only. Does **not** own counters, sleeps, tasks,
/// connection state, authentication, network monitoring, or HTTP.
enum StorytellerReconnectPolicy {
    /// Seconds added per recorded failure before the cap applies.
    static let delayPerFailureSeconds: TimeInterval = 5.0
    /// Hard ceiling on cooldown duration (matches prior `min(60.0, …)`).
    static let maxDelaySeconds: TimeInterval = 60.0

    /// Cooldown length after `failureCount` failures have already been recorded
    /// (i.e. the post-increment count used by the prior actor formula).
    ///
    /// Formula (unchanged): `min(60, failureCount * 5)` — linear, not exponential.
    static func backoffDelay(afterFailureCount failureCount: Int) -> TimeInterval {
        min(maxDelaySeconds, Double(failureCount) * delayPerFailureSeconds)
    }

    /// Whether a reconnect / authenticate attempt may proceed right now.
    ///
    /// Offline always blocks. With no cooldown, always allowed. Otherwise allowed
    /// once `now` is at or past `cooldownUntil`.
    static func canAttempt(
        networkAvailable: Bool,
        cooldownUntil: Date?,
        now: Date = Date(),
    ) -> Bool {
        guard networkAvailable else { return false }
        guard let cooldownUntil else { return true }
        return cooldownUntil <= now
    }

    /// Next failure count and cooldown deadline after a failed auth/reconnect.
    /// Mirrors prior `scheduleReconnectBackoff` mutation math without side effects.
    static func nextBackoffState(
        currentFailureCount: Int,
        now: Date = Date(),
    ) -> (failureCount: Int, cooldownUntil: Date, delay: TimeInterval) {
        let failureCount = currentFailureCount + 1
        let delay = backoffDelay(afterFailureCount: failureCount)
        return (failureCount, now.addingTimeInterval(delay), delay)
    }
}
