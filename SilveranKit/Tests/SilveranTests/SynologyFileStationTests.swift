//
//  SynologyFileStationTests.swift
//  SilveranTests
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit
import Testing

@Suite("Synology File Station")
struct SynologyFileStationTests {
    @Test func loginAndUploadUseShareRelativePath() async throws {
        let transport = SynologyScript()
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("inkamp-synology-test.epub")
        try Data("ebook".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }

        var uploadedPath: String?
        transport.handler = { request, fileURL in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/webapi/auth.cgi"), request.httpMethod == "POST" {
                #expect(!url.contains("super-secret"))
                return SynologyHTTP(
                    status: 200,
                    body: Data(#"{"success":true,"data":{"sid":"abc-sid"}}"#.utf8),
                )
            }
            if fileURL != nil {
                let text = String(data: (try? Data(contentsOf: fileURL!)) ?? Data(), encoding: .utf8) ?? ""
                #expect(text.contains("path"))
                #expect(text.contains("/media/books/books"))
                #expect(!text.contains("/volume1"))
                uploadedPath = "/media/books/books"
                return SynologyHTTP(status: 200, body: Data(#"{"success":true}"#.utf8))
            }
            if url.contains("getinfo") {
                #expect(url.contains("/media/books/books"))
                return SynologyHTTP(
                    status: 200,
                    body: Data(
                        #"""
                        {"success":true,"data":{"files":[{"additional":{"size":5}}]}}
                        """#.utf8
                    ),
                )
            }
            return SynologyHTTP(status: 200, body: Data(#"{"success":true}"#.utf8))
        }

        let client = SynologyFileStationClient(transport: transport)
        let result = try await client.upload(
            baseURL: "http://nas.example:5000",
            username: "josh",
            password: "super-secret",
            localFile: local,
            destination: NASUploadDestination(
                volumePath: "/volume1/media/books/books",
                filename: "The Hobbit.epub",
            ),
        )
        #expect(result.verified)
        #expect(result.byteCount == 5)
        #expect(uploadedPath == "/media/books/books")
        #expect(
            await client.testConnection(
                baseURL: "http://nas.example:5000",
                username: "josh",
                password: "super-secret",
            ) == .ok
        )
    }

    @Test func badPasswordMapsToAuthenticationFailed() async {
        let transport = SynologyScript()
        transport.handler = { _, _ in
            SynologyHTTP(
                status: 200,
                body: Data(#"{"success":false,"error":{"code":400}}"#.utf8),
            )
        }
        let client = SynologyFileStationClient(transport: transport)
        #expect(
            await client.testConnection(
                baseURL: "http://nas.example:5000",
                username: "josh",
                password: "nope",
            ) == .authenticationFailed
        )
    }

    @Test func connectionFailureMapsCleanly() async {
        let transport = SynologyScript()
        transport.throwError = URLError(.cannotConnectToHost)
        let client = SynologyFileStationClient(transport: transport)
        #expect(
            await client.testConnection(
                baseURL: "http://nas.example:5000",
                username: "josh",
                password: "x",
            ) == .cannotReachServer
        )
    }
}

private final class SynologyScript: SynologyTransport, @unchecked Sendable {
    var throwError: URLError?
    var handler: ((URLRequest, URL?) -> SynologyHTTP)?

    func send(_ request: URLRequest) async throws -> SynologyHTTP {
        if let throwError { throw throwError }
        return handler?(request, nil)
            ?? SynologyHTTP(status: 200, body: Data(#"{"success":true,"data":{"sid":"x"}}"#.utf8))
    }

    func upload(request: URLRequest, fileURL: URL) async throws -> SynologyHTTP {
        if let throwError { throw throwError }
        return handler?(request, fileURL)
            ?? SynologyHTTP(status: 200, body: Data(#"{"success":true}"#.utf8))
    }
}
