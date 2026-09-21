//
//  DelugeManualRouting.swift
//  SilveranKit
//
//  Decide when a manual Deluge job is safe to move_storage into the library.
//  Never race Deluge’s own incoming → completed relocation.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Action for one Deluge manual-download reconciliation pass.
public enum DelugeManualRoutingDecision: Equatable, Sendable {
    /// Still downloading or otherwise not finished.
    case observe(ManualDownloadJobStatus)
    /// Finished but Deluge has not finished relocating to the completed folder.
    case waitForDelugeCompleted(ManualDownloadJobStatus)
    /// Safe to call `core.move_storage` toward the job’s final destination.
    case requestMove
    /// Deluge already reports the torrent under the final library path.
    case alreadyAtDestination
    /// Torrent missing from Deluge.
    case torrentMissing
}

public enum DelugeManualRouting {
    /// Normalize Deluge / settings paths for equality and containment checks.
    public static func normalizedPath(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return NASPathSafety.normalizeBase(raw)
    }

    public static func path(_ path: String?, isUnder root: String) -> Bool {
        guard let path = normalizedPath(path), let root = normalizedPath(root) else { return false }
        if path == root { return true }
        return path.hasPrefix(root + "/")
    }

    public static func isFullyComplete(_ snapshot: DelugeTorrentSnapshot) -> Bool {
        if snapshot.isFinished { return true }
        if snapshot.progress >= 0.999 { return true }
        let state = snapshot.state.lowercased()
        return state.contains("seeding") && snapshot.progress >= 0.999
    }

    public static func isDelugeMoving(_ snapshot: DelugeTorrentSnapshot) -> Bool {
        snapshot.state.lowercased().contains("moving")
    }

    /// Pure reconciliation of a tracked Deluge torrent against staging + final paths.
    public static func evaluate(
        snapshot: DelugeTorrentSnapshot?,
        finalDestination: String,
        incomingFolder: String,
        completedFolder: String,
    ) -> DelugeManualRoutingDecision {
        guard let snapshot else { return .torrentMissing }

        if path(snapshot.savePath, isUnder: finalDestination) {
            return .alreadyAtDestination
        }

        let complete = isFullyComplete(snapshot)
        let inIncoming = path(snapshot.savePath, isUnder: incomingFolder)
        let inCompleted = path(snapshot.savePath, isUnder: completedFolder)
        let moving = isDelugeMoving(snapshot)

        if !complete {
            if moving || (inIncoming && snapshot.progress > 0) {
                return .observe(snapshot.progress > 0 ? .downloading : .queued)
            }
            let state = snapshot.state.lowercased()
            if state.contains("queued") { return .observe(.queued) }
            if state.contains("error") { return .observe(.unknown) }
            return .observe(.downloading)
        }

        // Complete but still in incoming (or actively relocating) — do not race Deluge.
        if moving || inIncoming {
            return .waitForDelugeCompleted(.delugeFinishing)
        }

        if inCompleted {
            return .requestMove
        }

        // Finished somewhere unexpected — keep observing as finishing until path is known.
        return .waitForDelugeCompleted(.delugeFinishing)
    }

    public static func statusLabel(for media: NASMediaKind, routing: Bool) -> String {
        if routing {
            switch media {
                case .ebook: return "Moving to eBook"
                case .audiobook: return "Moving to Audiobook"
            }
        }
        return ManualDownloadJobStatus.routing.label
    }
}
