//
//  RaveBSDEndpointRouting.swift
//  SilveranKit
//
//  Prefer LAN RaveBSD when reachable; otherwise use the remote URL.
//  Reachable means /health returned RaveBSD’s plain “ok”, not any HTTP status.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum RaveBSDNetworkRoute: String, Sendable, Equatable {
    case local
    case remote

    public var settingsStatusLabel: String {
        switch self {
            case .local: "Using local"
            case .remote: "Using remote"
        }
    }
}

public struct RaveBSDEndpointSelection: Equatable, Sendable {
    public var baseURL: String
    public var route: RaveBSDNetworkRoute

    public init(baseURL: String, route: RaveBSDNetworkRoute) {
        self.baseURL = baseURL
        self.route = route
    }
}

public enum RaveBSDEndpointRouting {
    public static let probeTimeout: TimeInterval = 2

    public static func effectiveLocalURL(stored: String) -> String? {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return RaveBSDURL.normalizeBase(trimmed)?.absoluteString
    }

    public static func effectiveRemoteURL(stored: String) -> String? {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return RaveBSDURL.normalizeBase(trimmed)?.absoluteString
    }

    public static func select(
        localURL: String,
        remoteURL: String,
        localReachable: Bool,
    ) -> RaveBSDEndpointSelection? {
        let local = effectiveLocalURL(stored: localURL)
        let remote = effectiveRemoteURL(stored: remoteURL)
        if localReachable, let local {
            return RaveBSDEndpointSelection(baseURL: local, route: .local)
        }
        if let remote {
            return RaveBSDEndpointSelection(baseURL: remote, route: .remote)
        }
        if let local {
            return RaveBSDEndpointSelection(baseURL: local, route: .local)
        }
        return nil
    }

    public static func orderedBases(localURL: String, remoteURL: String) -> [RaveBSDEndpointSelection] {
        var out: [RaveBSDEndpointSelection] = []
        if let local = effectiveLocalURL(stored: localURL) {
            out.append(RaveBSDEndpointSelection(baseURL: local, route: .local))
        }
        if let remote = effectiveRemoteURL(stored: remoteURL) {
            out.append(RaveBSDEndpointSelection(baseURL: remote, route: .remote))
        }
        return out
    }

    public static func probeReachability(
        baseURL: String,
        timeout: TimeInterval = probeTimeout,
        transport: any RaveBSDTransport = LiveRaveBSDTransport(),
    ) async -> Bool {
        guard let root = RaveBSDURL.normalizeBase(baseURL) else { return false }
        var request = URLRequest(
            url: root.appendingPathComponent("health"),
            timeoutInterval: timeout,
        )
        request.httpMethod = "GET"
        request.setValue("inkamp/ravebsd-probe", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let http = try await transport.send(request)
            if RaveBSDCloudflare.isChallenge(
                status: http.status,
                contentType: http.contentType,
                data: http.data,
            ) {
                return false
            }
            if http.status == 401 || http.status == 403 {
                return false
            }
            return RaveBSDResponseParsing.isHealthOK(http.data, status: http.status)
        } catch {
            return false
        }
    }

    public static func resolveLive(
        localURL: String,
        remoteURL: String,
        transport: any RaveBSDTransport = LiveRaveBSDTransport(),
    ) async -> RaveBSDEndpointSelection? {
        let local = effectiveLocalURL(stored: localURL)
        var localOK = false
        if let local {
            localOK = await probeReachability(baseURL: local, transport: transport)
        }
        return select(localURL: localURL, remoteURL: remoteURL, localReachable: localOK)
    }
}
