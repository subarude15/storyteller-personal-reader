//
//  ManualAcquisitionHandling.swift
//  SilveranKit
//
//  Handoff boundary for PR 68. The browser produces a candidate and
//  calls this protocol. It does not know about qBittorrent, Deluge,
//  aria2, or NAS paths.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum ManualAcquisitionHandoffResult: Equatable, Sendable {
    /// This PR's only outcome. The next PR replaces the placeholder handler.
    case placeholder(message: String)

    public var message: String {
        switch self {
            case .placeholder(let message): message
        }
    }
}

/// Implementations live outside the browser. PR 68 swaps the placeholder.
public protocol ManualAcquisitionHandling: Sendable {
    func handle(_ candidate: ManualAcquisitionCandidate) async -> ManualAcquisitionHandoffResult
}

public struct PlaceholderManualAcquisitionHandler: ManualAcquisitionHandling {
    public static let message = "NAS handoff will be added in the next update."

    public init() {}

    public func handle(_ candidate: ManualAcquisitionCandidate) async -> ManualAcquisitionHandoffResult {
        _ = candidate
        return .placeholder(message: Self.message)
    }
}

/// Thin router so UI code never imports a future downloader client.
public struct ManualAcquisitionRouter: Sendable {
    public var handler: any ManualAcquisitionHandling

    public init(handler: any ManualAcquisitionHandling = PlaceholderManualAcquisitionHandler()) {
        self.handler = handler
    }

    public func submit(_ candidate: ManualAcquisitionCandidate) async -> ManualAcquisitionHandoffResult {
        await handler.handle(candidate)
    }
}

/// Test double. Records candidates; never talks to a NAS.
public final class RecordingManualAcquisitionHandler: ManualAcquisitionHandling, @unchecked Sendable {
    public private(set) var received: [ManualAcquisitionCandidate] = []

    public init() {}

    public func handle(_ candidate: ManualAcquisitionCandidate) async -> ManualAcquisitionHandoffResult {
        received.append(candidate)
        return .placeholder(message: PlaceholderManualAcquisitionHandler.message)
    }
}
