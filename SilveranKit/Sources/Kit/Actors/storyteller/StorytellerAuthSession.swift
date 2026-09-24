import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Storyteller authentication request / token / Authorization helpers (R11).
///
/// Extracts A–D only: token request construction, token response interpret/decode,
/// and Authorization header formatting. Does **not** own credentials persistence,
/// connection state, retry/backoff, LAN routing, logout, or HTTP transport.
///
/// Owned/called from `StorytellerActor` (value-type helpers — not a new actor).
enum StorytellerAuthSession {
    /// Outcome of a `/token` HTTP exchange after transport returns an `HTTPResponse`.
    /// Mirrors prior `httpPost` + decode catch mapping used by `authenticate()`.
    enum TokenExchangeResult {
        case success(AccessToken)
        case unauthorized
        case failure
    }

    /// Current `authorizationHeaderValue(for:)` semantics.
    /// - `tokenType` matching `"bearer"` (any case) → `"Bearer \(accessToken)"`
    /// - otherwise → `"\(tokenType) \(accessToken)"` with no further normalization
    static func authorizationHeaderValue(for token: AccessToken) -> String {
        if token.tokenType.compare("bearer", options: .caseInsensitive) == .orderedSame {
            return "Bearer \(token.accessToken)"
        }
        return "\(token.tokenType) \(token.accessToken)"
    }

    /// Builds the `/token` form POST exactly as `authenticate()` did via `httpPost`.
    static func makeTokenRequest(
        apiBaseURL: URL,
        username: String,
        password: String,
        timeout: TimeInterval = 10,
    ) -> URLRequest {
        let tokenURL = apiBaseURL.appendingPathComponent("token")
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type",
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formURLEncodedBody([
            "usernameOrEmail": username,
            "password": password,
        ])
        return request
    }

    /// Maps a transport `HTTPResponse` to token success / unauthorized / failure.
    /// Preserves prior `HTTPUtils` status throwing: 401 and 403 → unauthorized;
    /// other non-2xx → failure; 2xx with decode error → failure.
    static func interpretTokenResponse(
        _ response: HTTPResponse,
        decoder: JSONDecoder,
    ) -> TokenExchangeResult {
        let status = response.statusCode
        if (200..<300).contains(status) {
            do {
                let token = try decoder.decode(AccessToken.self, from: response.data)
                return .success(token)
            } catch {
                return .failure
            }
        }
        switch status {
            case 401, 403:
                return .unauthorized
            default:
                return .failure
        }
    }
}
