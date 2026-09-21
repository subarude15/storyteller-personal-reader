//
//  Aria2ClientTests.swift
//  SilveranTests
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit
import Testing

@Suite("aria2 client")
struct Aria2ClientTests {
    @Test func addUriIncludesDirAndOptionalFilename() async throws {
        let transport = Aria2Script()
        transport.handler = { body in
            guard let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
                throw Aria2ClientError.invalidResponse
            }
            #expect(json["method"] as? String == "aria2.addUri")
            guard let params = json["params"] as? [Any] else {
                throw Aria2ClientError.invalidResponse
            }
            #expect(params[0] as? String == "token:s3cret")
            #expect(params[1] as? [String] == ["https://files.example/hobbit.epub"])
            let options = params[2] as? [String: String]
            #expect(options?["dir"] == "/media/books")
            #expect(options?["out"] == "The Hobbit.epub")
            return Aria2HTTP(
                status: 200,
                body: Data(#"{"jsonrpc":"2.0","id":2,"result":"2089b05ecca3d829"}"#.utf8),
            )
        }
        let client = Aria2Client(transport: transport)
        let result = try await client.addURI(
            rpcURL: "http://aria.example:6800",
            secret: "s3cret",
            uri: "https://files.example/hobbit.epub",
            directory: "/media/books",
            filename: "The Hobbit.epub",
        )
        #expect(result.gid == "2089b05ecca3d829")
    }

    @Test func tokenFormattingOmitsEmptySecret() throws {
        let withToken = try Aria2Client.encodeRequest(
            method: "aria2.addUri",
            secret: "s3cret",
            params: [["https://x"], ["dir": "/media"]],
            id: 1,
        )
        let json = try #require(JSONSerialization.jsonObject(with: withToken) as? [String: Any])
        let params = try #require(json["params"] as? [Any])
        #expect(params[0] as? String == "token:s3cret")

        let without = try Aria2Client.encodeRequest(
            method: "aria2.getVersion",
            secret: "  ",
            params: [],
            id: 1,
        )
        let empty = try #require(JSONSerialization.jsonObject(with: without) as? [String: Any])
        let emptyParams = try #require(empty["params"] as? [Any])
        #expect(emptyParams.isEmpty)
        #expect(Aria2Client.tokenParameter(secret: "") == nil)
        #expect(Aria2Client.tokenParameter(secret: "abc") == "token:abc")
    }

    @Test func filenameIsOmittedWhenUnsafeOrUnknown() {
        #expect(Aria2Client.outputFilename("The Hobbit.epub") == "The Hobbit.epub")
        #expect(Aria2Client.outputFilename("Magnet link") == nil)
        #expect(Aria2Client.outputFilename("../escape.epub") == nil)
        #expect(Aria2Client.outputFilename("a/b.epub") == nil)
        #expect(Aria2Client.outputFilename("") == nil)
    }

    @Test func rpcErrorMapsToHandoffError() async {
        let transport = Aria2Script()
        transport.handler = { _ in
            Aria2HTTP(
                status: 200,
                body: Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":1,"message":"Unauthorized"}}"#.utf8),
            )
        }
        let client = Aria2Client(transport: transport)
        #expect(
            await client.testConnection(rpcURL: "http://aria.example:6800", secret: "bad")
                == .authenticationFailed
        )
    }

    @Test func connectionFailureMapsCleanly() async {
        let transport = Aria2Script()
        transport.throwError = URLError(.timedOut)
        let client = Aria2Client(transport: transport)
        #expect(
            await client.testConnection(rpcURL: "http://aria.example:6800", secret: "x")
                == .timeout
        )
    }

    @Test func invalidRPCURLRejected() async {
        let client = Aria2Client(transport: Aria2Script())
        #expect(await client.testConnection(rpcURL: "notaurl", secret: "") == .invalidURL)
    }
}

private final class Aria2Script: Aria2Transport, @unchecked Sendable {
    var throwError: URLError?
    var handler: ((Data) throws -> Aria2HTTP)?

    func send(url _: URL, body: Data, timeout _: TimeInterval) async throws -> Aria2HTTP {
        if let throwError { throw throwError }
        return try handler?(body)
            ?? Aria2HTTP(status: 200, body: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
    }
}
