//
//  QBittorrentClientTests.swift
//  SilveranTests
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit
import Testing

@Suite("qBittorrent client")
struct QBittorrentClientTests {
    @Test func loginSuccessThenAddsMagnetWithSavePath() async throws {
        let transport = QBittorrentScript()
        transport.handler = { url, _, body, cookie in
            if url.path.hasSuffix("/auth/login") {
                let form = String(data: body ?? Data(), encoding: .utf8) ?? ""
                #expect(form.contains("username=admin"))
                #expect(form.contains("password=secret"))
                return QBittorrentHTTP(
                    status: 200,
                    body: Data("Ok.".utf8),
                    setCookie: "SID=abc123; Path=/",
                )
            }
            #expect(url.path.hasSuffix("/torrents/add"))
            #expect(cookie?.contains("SID=abc123") == true)
            let form = String(data: body ?? Data(), encoding: .utf8) ?? ""
            #expect(form.contains("urls=magnet%3A%3Fxt%3Durn%3Abtih%3Aabc"))
            #expect(form.contains("savepath=%2Fmedia%2Faudiobooks"))
            #expect(form.contains("paused=false"))
            return QBittorrentHTTP(status: 200, body: Data("Ok.".utf8))
        }
        let client = QBittorrentClient(transport: transport)
        #expect(
            await client.testConnection(
                baseURL: "http://qb.example:8080",
                username: "admin",
                password: "secret",
            ) == .ok
        )
        let result = try await client.addMagnet(
            baseURL: "http://qb.example:8080",
            username: "admin",
            password: "secret",
            uri: "magnet:?xt=urn:btih:abc",
            savePath: "/media/audiobooks",
            start: true,
        )
        #expect(result.jobID == nil)
    }

    @Test func torrentURLIsSubmittedWithoutDownloadingBytes() async throws {
        let transport = QBittorrentScript()
        transport.handler = { url, _, body, _ in
            if url.path.hasSuffix("/auth/login") {
                return QBittorrentHTTP(
                    status: 200,
                    body: Data("Ok.".utf8),
                    setCookie: "SID=x",
                )
            }
            let form = String(data: body ?? Data(), encoding: .utf8) ?? ""
            #expect(form.contains("https%3A%2F%2Ffiles.example%2Fhobbit.torrent"))
            #expect(form.contains("savepath=%2Fmedia%2Fbooks"))
            return QBittorrentHTTP(status: 200, body: Data("Ok.".utf8))
        }
        let client = QBittorrentClient(transport: transport)
        _ = try await client.addTorrentURL(
            baseURL: "http://qb.example:8080",
            username: "admin",
            password: "secret",
            url: "https://files.example/hobbit.torrent",
            savePath: "/media/books",
            start: true,
        )
    }

    @Test func badPasswordMapsToAuthenticationFailed() async {
        let transport = QBittorrentScript()
        transport.handler = { _, _, _, _ in
            QBittorrentHTTP(status: 200, body: Data("Fails.".utf8))
        }
        let client = QBittorrentClient(transport: transport)
        #expect(
            await client.testConnection(
                baseURL: "http://qb.example:8080",
                username: "admin",
                password: "nope",
            ) == .authenticationFailed
        )
    }

    @Test func connectionFailureMapsCleanly() async {
        let transport = QBittorrentScript()
        transport.throwError = URLError(.cannotConnectToHost)
        let client = QBittorrentClient(transport: transport)
        #expect(
            await client.testConnection(
                baseURL: "http://qb.example:8080",
                username: "admin",
                password: "x",
            ) == .cannotReachServer
        )
    }

    @Test func invalidURLRejected() async {
        let client = QBittorrentClient(transport: QBittorrentScript())
        #expect(
            await client.testConnection(baseURL: "not-a-url", username: "a", password: "b")
                == .invalidURL
        )
    }

    @Test func rejectedAddSurfacesHandoffError() async {
        let transport = QBittorrentScript()
        transport.handler = { url, _, _, _ in
            if url.path.hasSuffix("/auth/login") {
                return QBittorrentHTTP(status: 200, body: Data("Ok.".utf8), setCookie: "SID=x")
            }
            return QBittorrentHTTP(status: 200, body: Data("Fails.".utf8))
        }
        let client = QBittorrentClient(transport: transport)
        do {
            _ = try await client.addMagnet(
                baseURL: "http://qb.example:8080",
                username: "admin",
                password: "secret",
                uri: "magnet:?xt=urn:btih:abc",
                savePath: "/media/audiobooks",
                start: true,
            )
            Issue.record("add should fail")
        } catch let error as QBittorrentClientError {
            #expect(error == .rejected)
            #expect(error.handoff == .rejected(.qbittorrent))
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

private final class QBittorrentScript: QBittorrentTransport, @unchecked Sendable {
    var throwError: URLError?
    var handler: ((URL, String, Data?, String?) -> QBittorrentHTTP)?

    func send(
        url: URL,
        method: String,
        body: Data?,
        contentType _: String?,
        cookie: String?,
        timeout _: TimeInterval,
    ) async throws -> QBittorrentHTTP {
        if let throwError { throw throwError }
        return handler?(url, method, body, cookie)
            ?? QBittorrentHTTP(status: 200, body: Data("Ok.".utf8), setCookie: "SID=x")
    }
}
