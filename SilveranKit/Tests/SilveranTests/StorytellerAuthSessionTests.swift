import Foundation
import Testing

@testable import SilveranKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Characterization of Storyteller auth request / token / Authorization helpers (R11).
///
/// Locks CURRENT semantics — including Bearer normalization quirks.
/// Do not "fix" progress's hardcoded `Bearer \(raw)` here; that path is separate.
@Suite("Storyteller auth session")
struct StorytellerAuthSessionTests {

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    // MARK: - D Authorization header formatting

    @Test func authorizationHeaderNormalizesBearerCaseInsensitively() {
        let upper = AccessToken(accessToken: "tok", tokenType: "Bearer", expiresIn: nil)
        let lower = AccessToken(accessToken: "tok", tokenType: "bearer", expiresIn: nil)
        let mixed = AccessToken(accessToken: "tok", tokenType: "BeArEr", expiresIn: nil)

        #expect(StorytellerAuthSession.authorizationHeaderValue(for: upper) == "Bearer tok")
        #expect(StorytellerAuthSession.authorizationHeaderValue(for: lower) == "Bearer tok")
        #expect(StorytellerAuthSession.authorizationHeaderValue(for: mixed) == "Bearer tok")
    }

    @Test func authorizationHeaderPreservesNonBearerTokenTypeAsPrefix() {
        // Current behavior: non-bearer types are concatenated as-is (no forced Bearer).
        let basic = AccessToken(accessToken: "secret", tokenType: "Basic", expiresIn: nil)
        #expect(StorytellerAuthSession.authorizationHeaderValue(for: basic) == "Basic secret")

        // Already-prefixed-looking tokenType is NOT re-normalized — quirk preserved.
        let weird = AccessToken(accessToken: "x", tokenType: "Token", expiresIn: nil)
        #expect(StorytellerAuthSession.authorizationHeaderValue(for: weird) == "Token x")
    }

    // MARK: - A Token request construction

    @Test func makeTokenRequestUsesFormPostHeadersBodyAndTimeout() throws {
        let apiBase = URL(string: "https://storyteller.test/api/v2")!
        let request = StorytellerAuthSession.makeTokenRequest(
            apiBaseURL: apiBase,
            username: "reader",
            password: "s3cret",
        )

        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://storyteller.test/api/v2/token")
        #expect(
            request.value(forHTTPHeaderField: "Content-Type")
                == "application/x-www-form-urlencoded; charset=utf-8"
        )
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.timeoutInterval == 10)

        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        // formURLEncodedBody sorts keys: password, then usernameOrEmail
        #expect(body.contains("usernameOrEmail=reader"))
        #expect(body.contains("password=s3cret"))
        #expect(!body.contains("Authorization"))
    }

    // MARK: - B Token response interpret / decode

    @Test func interpretTokenSuccessDecodesAccessToken() throws {
        let data = Data(
            #"{"access_token":"abc","token_type":"Bearer","expires_in":3600}"#.utf8
        )
        let http = try makeHTTPResponse(status: 200, data: data)

        let result = StorytellerAuthSession.interpretTokenResponse(http, decoder: decoder)
        guard case .success(let token) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(token.accessToken == "abc")
        #expect(token.tokenType == "Bearer")
        #expect(token.expiresIn == 3600)
    }

    @Test func interpretToken401IsUnauthorized() throws {
        let http = try makeHTTPResponse(status: 401, data: Data(#"{"error":"no"}"#.utf8))
        let result = StorytellerAuthSession.interpretTokenResponse(http, decoder: decoder)
        guard case .unauthorized = result else {
            Issue.record("expected unauthorized, got \(String(describing: result))")
            return
        }
    }

    @Test func interpretToken403IsUnauthorizedMatchingHTTPUtils() throws {
        // HTTPUtils maps both 401 and 403 → HTTPRequestError.unauthorized
        let http = try makeHTTPResponse(status: 403, data: Data())
        let result = StorytellerAuthSession.interpretTokenResponse(http, decoder: decoder)
        guard case .unauthorized = result else {
            Issue.record("expected unauthorized, got \(String(describing: result))")
            return
        }
    }

    @Test func interpretToken500IsFailure() throws {
        let http = try makeHTTPResponse(status: 500, data: Data("boom".utf8))
        let result = StorytellerAuthSession.interpretTokenResponse(http, decoder: decoder)
        guard case .failure = result else {
            Issue.record("expected failure, got \(String(describing: result))")
            return
        }
    }

    @Test func interpretToken200WithMalformedBodyIsFailure() throws {
        let http = try makeHTTPResponse(status: 200, data: Data("not-json".utf8))
        let result = StorytellerAuthSession.interpretTokenResponse(http, decoder: decoder)
        guard case .failure = result else {
            Issue.record("expected failure, got \(String(describing: result))")
            return
        }
    }

    @Test func interpretTokenMissingCredentialsPathIsCallerOwned() {
        // ensureAuthentication returns nil when username/password/apiBaseURL missing —
        // AuthSession does not invent a "not configured" HTTP result; callers gate first.
        // This test documents that makeTokenRequest requires those values (compile-time /
        // call-site), matching prior authenticate() guard.
        let apiBase = URL(string: "https://storyteller.test/api/v2")!
        let request = StorytellerAuthSession.makeTokenRequest(
            apiBaseURL: apiBase,
            username: "u",
            password: "p",
        )
        #expect(request.url != nil)
    }

    // MARK: - Helpers

    private func makeHTTPResponse(status: Int, data: Data) throws -> HTTPResponse {
        let url = URL(string: "https://storyteller.test/api/v2/token")!
        let response = try #require(
            HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"],
            )
        )
        return HTTPResponse(data: data, response: response)
    }
}

// Memberwise bridge for tests — AccessToken has no public memberwise in models.
extension AccessToken {
    fileprivate init(accessToken: String, tokenType: String, expiresIn: Int64?) {
        // Decode via JSON to avoid adding production inits for tests only.
        let expires: Any = expiresIn.map { $0 as Any } ?? NSNull()
        let obj: [String: Any] = [
            "access_token": accessToken,
            "token_type": tokenType,
            "expires_in": expires,
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self = try! decoder.decode(AccessToken.self, from: data)
    }
}
