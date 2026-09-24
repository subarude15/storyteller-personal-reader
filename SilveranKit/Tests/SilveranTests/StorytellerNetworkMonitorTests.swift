import Foundation
import Testing

@testable import SilveranKit

#if canImport(Network)
import Network

@Suite("Storyteller network monitor")
struct StorytellerNetworkMonitorTests {

    // MARK: - Path → availability mapping (current actor semantics)

    @Test func pathAvailableOnlyWhenSatisfied() {
        #expect(StorytellerNetworkMonitor.isPathAvailable(.satisfied))
        #expect(!StorytellerNetworkMonitor.isPathAvailable(.unsatisfied))
        #expect(!StorytellerNetworkMonitor.isPathAvailable(.requiresConnection))
    }

    // MARK: - Start / stop lifecycle

    @Test func startIsIdempotentWhileRunning() {
        let monitor = StorytellerNetworkMonitor()
        #expect(!monitor.isRunning)

        monitor.start { _ in }
        #expect(monitor.isRunning)

        // Second start must not replace the running monitor (prior actor guard).
        monitor.start { _ in }
        #expect(monitor.isRunning)

        monitor.stop()
        #expect(!monitor.isRunning)
    }

    @Test func stopClearsAndAllowsRestart() {
        let monitor = StorytellerNetworkMonitor()
        monitor.start { _ in }
        #expect(monitor.isRunning)

        monitor.stop()
        #expect(!monitor.isRunning)

        // After cancel, a fresh NWPathMonitor is required — start creates one.
        monitor.start { _ in }
        #expect(monitor.isRunning)
        monitor.stop()
        #expect(!monitor.isRunning)
    }

    @Test func stopWhenNotStartedIsNoOp() {
        let monitor = StorytellerNetworkMonitor()
        monitor.stop()
        #expect(!monitor.isRunning)
    }
}
#endif
