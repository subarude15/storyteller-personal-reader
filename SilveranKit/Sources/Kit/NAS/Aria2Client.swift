//
//  Aria2Client.swift
//  SilveranKit
//
//  Minimal aria2 JSON-RPC client. The NAS fetches the file; the phone
//  only submits the URI and destination directory.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct Aria2HTTP: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public protocol Aria2Transport: Sendable {
    func send(url: URL, body: Data, timeout: TimeInterval) async throws -> Aria2HTTP
}

public struct LiveAria2Transport: Aria2Transport {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(url: URL, body: Data, timeout: TimeInterval) async throws -> Aria2HTTP {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        return Aria2HTTP(status: http?.statusCode ?? 0, body: data)
    }
}

public enum Aria2Connection: Equatable, Sendable {
    case ok
    case cannotReachServer
    case authenticationFailed
    case timeout
    case invalidResponse
    case invalidURL

    public var message: String {
        switch self {
            case .ok: "Connected"
            case .cannotReachServer: "Cannot reach server"
            case .authenticationFailed: "Authentication failed"
            case .timeout: "Timed out"
            case .invalidResponse: "Invalid server response"
            case .invalidURL: "Invalid URL"
        }
    }
}

public enum Aria2ClientError: Error, Equatable, Sendable {
    case invalidURL
    case cannotReachServer
    case authenticationFailed
    case timeout
    case invalidResponse
    case rpcError

    public var connection: Aria2Connection {
        switch self {
            case .invalidURL: .invalidURL
            case .cannotReachServer: .cannotReachServer
            case .authenticationFailed: .authenticationFailed
            case .timeout: .timeout
            case .invalidResponse, .rpcError: .invalidResponse
        }
    }

    public var handoff: NASHandoffError {
        switch self {
            case .invalidURL: .invalidURL(.aria2)
            case .cannotReachServer: .unreachable(.aria2)
            case .authenticationFailed: .authenticationFailed(.aria2)
            case .timeout: .timeout(.aria2)
            case .invalidResponse, .rpcError: .rpcError(.aria2)
        }
    }
}

public struct Aria2AddResult: Equatable, Sendable {
    public var gid: String?

    public init(gid: String? = nil) {
        self.gid = gid
    }
}

public struct Aria2Client: Sendable {
    public var transport: any Aria2Transport
    public var timeout: TimeInterval

    public init(
        transport: any Aria2Transport = LiveAria2Transport(),
        timeout: TimeInterval = 12,
    ) {
        self.transport = transport
        self.timeout = timeout
    }

    public func testConnection(rpcURL: String, secret: String) async -> Aria2Connection {
        do {
            _ = try await rpc(
                rpcURL: rpcURL,
                secret: secret,
                method: "aria2.getVersion",
                params: [],
                id: 1,
            )
            return .ok
        } catch let error as Aria2ClientError {
            return error.connection
        } catch let error as URLError {
            switch error.code {
                case .timedOut: return .timeout
                default: return .cannotReachServer
            }
        } catch {
            return .invalidResponse
        }
    }

    public func addURI(
        rpcURL: String,
        secret: String,
        uri: String,
        directory: String,
        filename: String? = nil,
    ) async throws -> Aria2AddResult {
        var options: [String: String] = ["dir": directory]
        if let filename, let safe = Self.outputFilename(filename) {
            options["out"] = safe
        }
        let result = try await rpc(
            rpcURL: rpcURL,
            secret: secret,
            method: "aria2.addUri",
            params: [[uri], options] as [Any],
            id: 2,
        )
        return Aria2AddResult(gid: result as? String)
    }

    public static func outputFilename(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "Magnet link" { return nil }
        if trimmed.contains("/") || trimmed.contains("\\") { return nil }
        if trimmed.contains("..") { return nil }
        if trimmed.contains("\0") { return nil }
        return trimmed
    }

    public static func tokenParameter(secret: String) -> String? {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "token:\(trimmed)"
    }

    public static func rpcURL(from raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        while text.hasSuffix("/") { text.removeLast() }
        guard var components = URLComponents(string: text),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty
        else { return nil }
        components.scheme = scheme
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        var path = components.path
        if path.hasSuffix("/jsonrpc") {
            // already correct
        } else if path.isEmpty || path == "/" {
            path = "/jsonrpc"
        } else if path.hasSuffix("/jsonrpc/") {
            path = String(path.dropLast())
        } else {
            path = path.hasSuffix("/") ? path + "jsonrpc" : path + "/jsonrpc"
        }
        components.path = path
        return components.url
    }

    public static func encodeRequest(
        method: String,
        secret: String,
        params: [Any],
        id: Int,
    ) throws -> Data {
        var rpcParams = params
        if let token = tokenParameter(secret: secret) {
            rpcParams.insert(token, at: 0)
        }
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": rpcParams,
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func rpc(
        rpcURL: String,
        secret: String,
        method: String,
        params: [Any],
        id: Int,
    ) async throws -> Any? {
        guard let endpoint = Self.rpcURL(from: rpcURL) else {
            throw Aria2ClientError.invalidURL
        }
        let body = try Self.encodeRequest(method: method, secret: secret, params: params, id: id)
        let http: Aria2HTTP
        do {
            http = try await transport.send(url: endpoint, body: body, timeout: timeout)
        } catch let error as URLError {
            switch error.code {
                case .timedOut: throw Aria2ClientError.timeout
                default: throw Aria2ClientError.cannotReachServer
            }
        }
        guard http.status != 0 else { throw Aria2ClientError.cannotReachServer }
        guard http.status != 401, http.status != 403 else {
            throw Aria2ClientError.authenticationFailed
        }
        guard http.status >= 200, http.status < 500 else {
            throw Aria2ClientError.cannotReachServer
        }
        guard let json = try? JSONSerialization.jsonObject(with: http.body) as? [String: Any]
        else {
            throw Aria2ClientError.invalidResponse
        }
        if let error = json["error"] as? [String: Any] {
            let code = error["code"] as? Int
            let message = (error["message"] as? String ?? "").lowercased()
            if code == 1 || message.contains("unauthorized") || message.contains("token") {
                throw Aria2ClientError.authenticationFailed
            }
            throw Aria2ClientError.rpcError
        }
        return json["result"]
    }
}
