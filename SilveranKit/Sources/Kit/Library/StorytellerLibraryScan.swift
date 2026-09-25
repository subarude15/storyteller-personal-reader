import Foundation

/// Storyteller library file scan via `/api/v2/books/scan`.
///
/// Upstream: `storyteller-platform/storyteller`
/// `applications/web/src/app/api/v2/books/scan/route.ts` and Settings “Scan library”
/// (`triggerScan({ force: true })` + polled `GET`).
///
/// `POST` returns 204 immediately while the scan runs in the background. Completion is
/// only knowable by polling `GET` (`running` true → false). Never treat POST success alone
/// as “scan complete.”
public enum StorytellerLibraryScan {
    public static let pathComponent = "scan"
    /// Matches Storyteller web Settings (`force: true` on manual Scan library).
    public static let defaultForce = true

    public struct State: Equatable, Sendable {
        public var running: Bool
        public var source: String?
        public var startedAt: Int64?
        public var progress: Progress?
        public var pendingSources: [String]

        public struct Progress: Equatable, Sendable {
            public var processed: Int
            public var total: Int

            public init(processed: Int, total: Int) {
                self.processed = processed
                self.total = total
            }
        }

        public init(
            running: Bool,
            source: String? = nil,
            startedAt: Int64? = nil,
            progress: Progress? = nil,
            pendingSources: [String] = [],
        ) {
            self.running = running
            self.source = source
            self.startedAt = startedAt
            self.progress = progress
            self.pendingSources = pendingSources
        }
    }

    /// How far we got after a successful POST.
    public enum Completion: Equatable, Sendable {
        /// Saw `running: true` then later `running: false`.
        case confirmedComplete
        /// POST accepted; never observed `running: true` before the poll budget ended.
        case startedUnconfirmed
        /// Still `running: true` when the poll budget ended.
        case stillRunning
    }

    public enum Failure: Error, Equatable, Sendable {
        case notConfigured
        case notConnected
        case authenticationFailed
        case permissionDenied
        case unsupported
        case rejected(statusCode: Int)
        case transport(String)
        case scanAlreadyInProgress
        case cancelled

        public var userMessage: String {
            switch self {
                case .notConfigured:
                    return "Storyteller isn't configured."
                case .notConnected:
                    return "Storyteller isn't connected."
                case .authenticationFailed:
                    return "Storyteller sign-in failed. Check your credentials."
                case .permissionDenied:
                    return "This account can't start a library scan (needs book process permission)."
                case .unsupported:
                    return "This Storyteller version doesn't expose library scan."
                case .rejected(let statusCode):
                    return "Storyteller rejected the scan (HTTP \(statusCode))."
                case .transport(let detail):
                    return "Couldn't reach Storyteller (\(detail))."
                case .scanAlreadyInProgress:
                    return "A library scan is already in progress."
                case .cancelled:
                    return "Scan cancelled."
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        case success(Completion)
        case failure(Failure)
    }

    public struct Polling: Equatable, Sendable {
        public var intervalNanoseconds: UInt64
        public var maxAttempts: Int

        public init(intervalNanoseconds: UInt64, maxAttempts: Int) {
            self.intervalNanoseconds = intervalNanoseconds
            self.maxAttempts = maxAttempts
        }

        /// ~45s at 1.5s intervals — enough to observe start→finish for small libraries
        /// without hanging Settings. Not infinite.
        public static let `default` = Polling(
            intervalNanoseconds: 1_500_000_000,
            maxAttempts: 30,
        )
    }

    /// Pure status-poll reducer used by the actor after POST acceptance.
    public static func completion(
        afterStates states: [State],
        exhaustedBudget: Bool,
    ) -> Completion {
        let sawRunning = states.contains(where: \.running)
        let lastRunning = states.last?.running ?? false
        if sawRunning && !lastRunning {
            return .confirmedComplete
        }
        if sawRunning && lastRunning && exhaustedBudget {
            return .stillRunning
        }
        return .startedUnconfirmed
    }

    public static func parseState(from data: Data) throws -> State {
        guard !data.isEmpty else {
            throw DecodeError.emptyBody
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeError.notObject
        }
        guard let running = json["running"] as? Bool else {
            throw DecodeError.missingRunning
        }
        let source = json["source"] as? String
        let startedAt: Int64?
        if let number = json["startedAt"] as? NSNumber {
            startedAt = number.int64Value
        } else {
            startedAt = nil
        }
        var progress: State.Progress?
        if let progressJSON = json["progress"] as? [String: Any],
            let processed = intValue(progressJSON["processed"]),
            let total = intValue(progressJSON["total"])
        {
            progress = State.Progress(processed: processed, total: total)
        }
        let pending: [String]
        if let raw = json["pendingSources"] as? [Any] {
            pending = raw.compactMap { $0 as? String }
        } else {
            pending = []
        }
        return State(
            running: running,
            source: source,
            startedAt: startedAt,
            progress: progress,
            pendingSources: pending,
        )
    }

    public enum DecodeError: Error, Equatable, Sendable {
        case emptyBody
        case notObject
        case missingRunning
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
            case let int as Int:
                return int
            case let number as NSNumber:
                return number.intValue
            default:
                return nil
        }
    }
}
