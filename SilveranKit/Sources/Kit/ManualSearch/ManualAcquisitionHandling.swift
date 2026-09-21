//
//  ManualAcquisitionHandling.swift
//  SilveranKit
//
//  Handoff boundary. The browser produces a candidate and calls this
//  protocol. It does not know about qBittorrent, Deluge, aria2, or NAS
//  paths.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum ManualAcquisitionHandoffResult: Equatable, Sendable {
    /// Kept so older tests and fallback wiring still compile.
    case placeholder(message: String)
    /// Job accepted by the NAS backend. Not a completed download.
    case submitted(message: String)
    case failed(message: String)

    public var message: String {
        switch self {
            case .placeholder(let message), .submitted(let message), .failed(let message):
                message
        }
    }

    public var isSubmitted: Bool {
        switch self {
            case .submitted: true
            case .placeholder, .failed: false
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
