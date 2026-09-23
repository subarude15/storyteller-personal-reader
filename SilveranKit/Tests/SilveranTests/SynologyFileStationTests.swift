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

    @Test func listFilenamesPaginatesPastFirstDSMPage() async throws {
        let transport = SynologyScript()
        var listOffsets: [Int] = []

        transport.handler = { request, _ in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let api = items.first { $0.name == "api" }?.value
            let method = items.first { $0.name == "method" }?.value

            if request.url?.path.contains("auth.cgi") == true {
                return SynologyHTTP(
                    status: 200,
                    body: Data(#"{"success":true,"data":{"sid":"sid"}}"#.utf8),
                )
            }

            if api == "SYNO.FileStation.List", method == "list" {
                let offset = Int(items.first { $0.name == "offset" }?.value ?? "0") ?? 0
                let limit = Int(items.first { $0.name == "limit" }?.value ?? "0") ?? 0
                listOffsets.append(offset)
                #expect(limit == 200)

                if offset == 0 {
                    let files = (0..<200).map { #"{"name":"Book #($0)"}"# }.joined(separator: ",")
                    return SynologyHTTP(
                        status: 200,
                        body: Data(#"{"success":true,"data":{"total":201,"files":[#(files)]}}"#.utf8),
                    )
                }

                return SynologyHTTP(
                    status: 200,
                    body: Data(
                        #"{"success":true,"data":{"total":201,"files":[{"name":"The Eye of the Bedlam Bride"}]}}"#.utf8
                    ),
                )
            }

            return SynologyHTTP(status: 200, body: Data(#"{"success":true}"#.utf8))
        }

        let client = SynologyFileStationClient(transport: transport)
        let names = try await client.listFilenames(
            baseURL: "http://nas.example:5000",
            username: "josh",
            password: "secret",
            volumeDirectory: "/volume1/data/media/books/audiobooks",
        )

        #expect(names.count == 201)
        #expect(names.contains("The Eye of the Bedlam Bride"))
        #expect(listOffsets == [0, 200])
    }

    @Test func startMoveItemReturnsTaskIDWithoutStatusPolling() async throws {
        let transport = SynologyScript()
        var statusCalls = 0
        var startCalls = 0
        transport.handler = { request, _ in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let api = items.first { $0.name == "api" }?.value
            let method = items.first { $0.name == "method" }?.value
            if request.url?.path.contains("auth.cgi") == true {
                return SynologyHTTP(
                    status: 200,
                    body: Data(#"{"success":true,"data":{"sid":"sid"}}"#.utf8),
                )
            }
            if api == "SYNO.FileStation.CopyMove", method == "start" {
                startCalls += 1
                return SynologyHTTP(
                    status: 200,
                    body: Data(#"{"success":true,"data":{"taskid":"move-42"}}"#.utf8),
                )
            }
            if api == "SYNO.FileStation.CopyMove", method == "status" {
                statusCalls += 1
                return SynologyHTTP(
                    status: 200,
                    body: Data(#"{"success":true,"data":{"finished":false}}"#.utf8),
                )
            }
            return SynologyHTTP(status: 200, body: Data(#"{"success":true}"#.utf8))
        }
        let client = SynologyFileStationClient(transport: transport)
        let taskID = try await client.startMoveItem(
            baseURL: "http://nas.example:5000",
            username: "josh",
            password: "secret",
            sourceVolumePath: "/volume1/data/torrents/completed/Book",
            destinationVolumeDirectory: "/volume1/data/media/books/books",
        )
        #expect(taskID == "move-42")
        #expect(startCalls == 1)
        #expect(statusCalls == 0)
    }

    @Test func moveTaskStatusTreatsDSMErrorsArrayAsFailed() async throws {
        let transport = SynologyScript()
        transport.handler = { request, _ in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let api = items.first { $0.name == "api" }?.value
            let method = items.first { $0.name == "method" }?.value
            if request.url?.path.contains("auth.cgi") == true {
                return SynologyHTTP(
                    status: 200,
                    body: Data(#"{"success":true,"data":{"sid":"sid"}}"#.utf8),
                )
            }
            if api == "SYNO.FileStation.CopyMove", method == "status" {
                return SynologyHTTP(
                    status: 200,
                    body: Data(#"{"success":true,"data":{"finished":true,"errors":[{"code":408}]}}"#.utf8),
                )
            }
            return SynologyHTTP(status: 200, body: Data(#"{"success":true}"#.utf8))
        }

        let client = SynologyFileStationClient(transport: transport)
        let status = try await client.moveTaskStatus(
            baseURL: "http://nas.example:5000",
            username: "josh",
            password: "secret",
            taskID: "bad-move",
        )
        #expect(status == .failed)
    }

    @Test func moveItemPollsStatusWithDelayNotImmediateBurst() async throws {
        let transport = SynologyScript()
        var statusCalls = 0
        var timestamps: [Date] = []
        transport.handler = { request, _ in
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let api = items.first { $0.name == "api" }?.value
            let method = items.first { $0.name == "method" }?.value
            if request.url?.path.contains("auth.cgi") == true {
                return SynologyHTTP(
                    status: 200,
                    body: Data(#"{"success":true,"data":{"sid":"sid"}}"#.utf8),
                )
            }
            if api == "SYNO.FileStation.CopyMove", method == "start" {
                return SynologyHTTP(
                    status: 200,
                    body: Data(#"{"success":true,"data":{"taskid":"move-slow"}}"#.utf8),
                )
            }
            if api == "SYNO.FileStation.CopyMove", method == "status" {
                statusCalls += 1
                timestamps.append(Date())
                let finished = statusCalls >= 2
                return SynologyHTTP(
                    status: 200,
                    body: Data("{\"success\":true,\"data\":{\"finished\":\(finished)}}".utf8),
                )
            }
            return SynologyHTTP(status: 200, body: Data(#"{"success":true}"#.utf8))
        }
        let client = SynologyFileStationClient(transport: transport)
        try await client.moveItem(
            baseURL: "http://nas.example:5000",
            username: "josh",
            password: "secret",
            sourceVolumePath: "/volume1/data/torrents/completed/Book",
            destinationVolumeDirectory: "/volume1/data/media/books/audiobooks",
        )
        #expect(statusCalls == 2)
        #expect(timestamps.count == 2)
        // Real delay between polls — not eight immediate back-to-back requests.
        #expect(timestamps[1].timeIntervalSince(timestamps[0]) >= 0.2)
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
