//
//  PodcastAdStripPipeline.swift
//  SilveranAppleKit
//
//  Ad-strip hooks for Clean downloads. This IPA ships a STUB only:
//  StubPodcastAdStripPipeline copies Original → Clean sibling for UI smoke
//  (no ML / NAS strip). Real PrincessDonut worker is Later.
//
//  SPDX-License-Identifier: AGPL-3.0-only

#if os(iOS)
import Foundation
import SilveranKit

/// Produces a Clean sibling from an on-disk Original podcast file.
public protocol PodcastAdStripPipeline: Sendable {
    /// Write Clean audio at `cleanURL` from `originalURL`. Must not delete Original.
    func produceCleanCopy(originalURL: URL, cleanURL: URL) async throws
}

/// Stub: byte-copy Original → Clean after a short delay (UI smoke only).
public struct StubPodcastAdStripPipeline: PodcastAdStripPipeline {
    public static let shared = StubPodcastAdStripPipeline()

    /// Artificial delay so the Cleaning… chip is visible in smoke tests.
    public var delaySeconds: TimeInterval

    public init(delaySeconds: TimeInterval = 1.2) {
        self.delaySeconds = delaySeconds
    }

    public func produceCleanCopy(originalURL: URL, cleanURL: URL) async throws {
        if delaySeconds > 0 {
            try await Task.sleep(for: .seconds(delaySeconds))
        }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: cleanURL.path) {
            try FileManager.default.removeItem(at: cleanURL)
        }
        try FileManager.default.copyItem(at: originalURL, to: cleanURL)
    }
}
#endif
