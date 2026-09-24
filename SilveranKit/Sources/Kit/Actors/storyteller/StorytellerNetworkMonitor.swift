import Foundation

#if canImport(Network)
import Network

/// Owns `NWPathMonitor` lifecycle and maps path updates to availability booleans.
///
/// R8 boundary: network observation only. Does **not** own connection state,
/// reconnect/retry policy, authentication, LAN/public routing, or HTTP transport.
final class StorytellerNetworkMonitor {
    private var monitor: NWPathMonitor?
    /// Same serial queue role as the prior inline `StorytellerActor` monitor.
    private let queue = DispatchQueue(label: "StorytellerActor.NetworkMonitor")

    /// Whether an underlying `NWPathMonitor` is currently started.
    var isRunning: Bool { monitor != nil }

    /// Maps Apple path status to the availability flag `StorytellerActor` already consumes.
    /// Characterization: only `.satisfied` counts as available.
    static func isPathAvailable(_ status: NWPath.Status) -> Bool {
        status == .satisfied
    }

    /// Starts path observation. Idempotent while already running (matches prior actor guard).
    /// After `stop()`, call `start` again to create a fresh `NWPathMonitor`.
    func start(onAvailabilityChange: @escaping @Sendable (Bool) -> Void) {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { path in
            onAvailabilityChange(Self.isPathAvailable(path.status))
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }
}
#endif
