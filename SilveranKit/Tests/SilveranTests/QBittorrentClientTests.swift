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
        transport.handler = { url, _, body, _, cookie in
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
        transport.handler = { url, _, body, _, _ in
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

    @Test func torrentFileIsSubmittedAsMultipart() async throws {
        let torrentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inkamp-qb-test-\(UUID().uuidString).torrent")
        let payload = Data("d8:announce13:http://a.come")
        try payload.write(to: torrentURL)
        defer { try? FileManager.default.removeItem(at: torrentURL) }

        let transport = QBittorrentScript()
        transport.handler = { url, _, body, contentType, _ in
            if url.path.hasSuffix("/auth/login") {
                return QBittorrentHTTP(status: 200, body: Data("Ok.".utf8), setCookie: "SID=x")
            }
            #expect(url.path.hasSuffix("/torrents/add"))
            #expect(contentType?.contains("multipart/form-data") == true)
            let text = String(data: body ?? Data(), encoding: .utf8) ?? ""
            #expect(text.contains("name=\"torrents\""))
            #expect(text.contains("filename=\"book.torrent\""))
            #expect(text.contains("name=\"savepath\""))
            #expect(text.contains("/media/audiobooks"))
            #expect(text.contains("name=\"paused\""))
            #expect(text.contains("false"))
            #expect(text.contains("d8:announce13:http://a.come"))
            return QBittorrentHTTP(status: 200, body: Data("Ok.".utf8))
        }
        let client = QBittorrentClient(transport: transport)
        _ = try await client.addTorrentFile(
            baseURL: "http://qb.example:8080",
            username: "admin",
            password: "secret",
            fileURL: torrentURL,
            filename: "book.torrent",
            savePath: "/media/audiobooks",
            start: true,
        )
    }

    @Test func badPasswordMapsToAuthenticationFailed() async {
        let transport = QBittorrentScript()
        transport.handler = { _, _, _, _, _ in
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

    @Test func torrentInfoReturnsProgressAndState() async throws {
        let transport = QBittorrentScript()
        transport.handler = { url, method, _, _, _ in
            if url.path.hasSuffix("/auth/login") {
                return QBittorrentHTTP(status: 200, body: Data("Ok.".utf8), setCookie: "SID=x")
            }
            #expect(url.path.hasSuffix("/torrents/info"))
            #expect(method == "GET")
            #expect(url.query?.contains("hashes=") == true)
            return QBittorrentHTTP(
                status: 200,
                body: Data(
                    #"""
                    [{"hash":"ABC","state":"downloading","progress":0.63,"dlspeed":1200,"size":100,"completed":63}]
                    """#.utf8
                ),
            )
        }
        let client = QBittorrentClient(transport: transport)
        let snapshots = try await client.torrentStatuses(
            baseURL: "http://qb.example:8080",
            username: "admin",
            password: "secret",
            hashes: ["ABC"],
        )
        #expect(snapshots["abc"]?.state == "downloading")
        #expect(snapshots["abc"]?.progress == 0.63)
        #expect(snapshots["abc"]?.liveStatus.status == .downloading)
    }

    @Test func rejectedAddSurfacesHandoffError() async {
        let transport = QBittorrentScript()
        transport.handler = { url, _, _, _, _ in
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

    @Test func ordinaryMagnetAddStaysFormURLEncoded() async throws {
        let transport = QBittorrentScript()
        transport.handler = { url, _, body, contentType, _ in
            if url.path.hasSuffix("/auth/login") {
                return QBittorrentHTTP(status: 200, body: Data("Ok.".utf8), setCookie: "SID=x")
            }
            #expect(url.path.hasSuffix("/torrents/add"))
            #expect(contentType == "application/x-www-form-urlencoded")
            #expect(!(contentType?.contains("multipart/form-data") ?? false))
            let form = String(data: body ?? Data(), encoding: .utf8) ?? ""
            #expect(form.contains("urls="))
            #expect(form.contains("savepath="))
            return QBittorrentHTTP(status: 200, body: Data("Ok.".utf8))
        }
        let client = QBittorrentClient(transport: transport)
        _ = try await client.addMagnet(
            baseURL: "http://qb.example:8080",
            username: "admin",
            password: "secret",
            uri: "magnet:?xt=urn:btih:abc",
            savePath: "/media/audiobooks",
            start: true,
        )
    }

    @Test func multipartURLAddQueriesDefaultSavePath() async throws {
        var sawDefault = false
        let transport = QBittorrentScript()
        transport.handler = { url, method, body, contentType, cookie in
            if url.path.hasSuffix("/auth/login") {
                return QBittorrentHTTP(status: 200, body: Data("Ok.".utf8), setCookie: "SID=bridge")
            }
            if url.path.hasSuffix("/app/defaultSavePath") {
                #expect(method == "GET")
                #expect(cookie?.contains("SID=bridge") == true)
                sawDefault = true
                return QBittorrentHTTP(status: 200, body: Data("/data/completed".utf8))
            }
            #expect(url.path.hasSuffix("/torrents/add"))
            #expect(contentType?.contains("multipart/form-data") == true)
            #expect(contentType?.contains("application/x-www-form-urlencoded") != true)
            let text = String(data: body ?? Data(), encoding: .utf8) ?? ""
            #expect(text.contains("name=\"urls\""))
            #expect(text.contains("magnet:?xt=urn:btih:abc"))
            #expect(text.contains("name=\"savepath\""))
            #expect(text.contains("/data/completed"))
            #expect(!text.contains("/volume1/data/torrents/completed"))
            #expect(text.contains("name=\"paused\""))
            #expect(text.contains("false"))
            return QBittorrentHTTP(status: 200, body: Data("Ok.".utf8))
        }
        let client = QBittorrentClient(transport: transport)
        _ = try await client.addURLsMultipart(
            baseURL: "http://torboxarr.example:8085",
            username: "admin",
            password: "secret",
            urls: "magnet:?xt=urn:btih:abc",
            start: true,
            savePathFallback: "/data/completed",
        )
        #expect(sawDefault)
    }

    @Test func multipartURLAddUsesFallbackWhenDefaultSavePathFails() async throws {
        let transport = QBittorrentScript()
        transport.handler = { url, _, body, contentType, _ in
            if url.path.hasSuffix("/auth/login") {
                return QBittorrentHTTP(status: 200, body: Data("Ok.".utf8), setCookie: "SID=x")
            }
            if url.path.hasSuffix("/app/defaultSavePath") {
                return QBittorrentHTTP(status: 500, body: Data("nope".utf8))
            }
            #expect(contentType?.contains("multipart/form-data") == true)
            let text = String(data: body ?? Data(), encoding: .utf8) ?? ""
            #expect(text.contains("/data/completed"))
            #expect(!text.contains("/volume1/data/torrents/completed"))
            return QBittorrentHTTP(status: 200, body: Data("Ok.".utf8))
        }
        let client = QBittorrentClient(transport: transport)
        _ = try await client.addURLsMultipart(
            baseURL: "http://torboxarr.example:8085",
            username: "admin",
            password: "secret",
            urls: "magnet:?xt=urn:btih:abc",
            start: true,
            savePathFallback: TorBoxarrConnectionSettings.apiDefaultSavePath,
        )
    }
}

private final class QBittorrentScript: QBittorrentTransport, @unchecked Sendable {
    var throwError: URLError?
    var handler: ((URL, String, Data?, String?, String?) -> QBittorrentHTTP)?

    func send(
        url: URL,
        method: String,
        body: Data?,
        contentType: String?,
        cookie: String?,
        timeout _: TimeInterval,
    ) async throws -> QBittorrentHTTP {
        if let throwError { throw throwError }
        return handler?(url, method, body, contentType, cookie)
            ?? QBittorrentHTTP(status: 200, body: Data("Ok.".utf8), setCookie: "SID=x")
    }
}
