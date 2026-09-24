import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Lowest-level Storyteller HTTP execution (R10).
///
/// Owns **one** execute-once send against an injected `URLSession`. Callers build
/// the `URLRequest` (URL, method, headers, body, timeouts).
///
/// Boundary — this type does **not**:
/// - interpret HTTP status codes (200/204/404/500 all return as responses)
/// - construct Authorization or refresh tokens
/// - build endpoint URLs
/// - retry / back off
/// - mutate connection state
/// - own TUS / upload sessions / download delegates
///
/// `Sendable` via immutable `URLSession` reference only — no `@unchecked Sendable`.
struct StorytellerHTTPTransport: Sendable {
    enum TransportError: Error, Equatable, Sendable {
        case nonHTTPResponse
    }

    /// Same session instance the actor already owns (config, protocols, cookies, timeouts).
    let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    /// Sends `request` exactly once via `session.data(for:)`.
    ///
    /// - Returns: `HTTPResponse` for any HTTP status code; headers and body untouched.
    /// - Throws: underlying session errors (e.g. `URLError`), or `TransportError.nonHTTPResponse`
    ///   when the URL loading system returns a non-`HTTPURLResponse`.
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TransportError.nonHTTPResponse
        }
        return HTTPResponse(data: data, response: httpResponse)
    }
}
