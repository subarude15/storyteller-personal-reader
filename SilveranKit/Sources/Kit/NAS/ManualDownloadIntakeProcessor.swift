//
//  ManualDownloadIntakeProcessor.swift
//  SilveranKit
//
//  Host-side drain of Share / Shortcuts intake into ManualAcquisitionHandling.
//  Deluge routing stays in NASAcquisitionHandler (PR71).
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum ManualDownloadIntakeProcessor {
    /// Consume pending App Group (or test-root) payloads once per payload UUID.
    ///
    /// - Consumed payload IDs are permanent one-time queue consumption.
    /// - Fingerprint dedupe only collapses duplicate/stale copies in the *current*
    ///   pending queue (one submit per fingerprint per drain).
    /// - A later explicit `enqueueMagnet` / `enqueueTorrent` of the same content
    ///   creates a new payload UUID and remains eligible — fingerprints are never
    ///   permanently blacklisted.
    /// - Failed handoffs still consume the queue; Retry lives on the Downloads job.
    @discardableResult
    public static func processPending(
        handler: any ManualAcquisitionHandling,
        bundle: Bundle = .main,
        root: URL? = nil,
    ) async -> Int {
        ManualDownloadIntakeHandoff.clearPendingSignal()
        let pending = ManualDownloadIntakeHandoff.listPending(bundle: bundle, root: root)
        var processed = 0
        // In-drain fingerprint set: suppress duplicate queued copies / stale replays
        // of the same logical pending item without blocking future explicit shares.
        var seenFingerprints = Set<String>()
        for payload in pending {
            if ManualDownloadIntakeHandoff.isProcessed(payload.id, bundle: bundle, root: root) {
                ManualDownloadIntakeHandoff.markProcessed(payload, bundle: bundle, root: root)
                if payload.kind == .torrentFile {
                    ManualDownloadIntakeHandoff.removeStagedTorrent(payload, bundle: bundle, root: root)
                }
                continue
            }

            if seenFingerprints.contains(payload.fingerprint) {
                // Duplicate pending copy of the same content — consume without submit.
                ManualDownloadIntakeHandoff.markProcessed(payload, bundle: bundle, root: root)
                if payload.kind == .torrentFile {
                    ManualDownloadIntakeHandoff.removeStagedTorrent(payload, bundle: bundle, root: root)
                }
                continue
            }
            seenFingerprints.insert(payload.fingerprint)

            let candidateResult: Result<ManualAcquisitionCandidate, ManualDownloadIntakeError>
            switch payload.kind {
                case .magnet:
                    candidateResult = payload.makeCandidate()
                case .torrentFile:
                    do {
                        let local = try ManualDownloadIntakeHandoff.importTorrentIntoAppStaging(
                            payload,
                            bundle: bundle,
                            root: root,
                        )
                        candidateResult = payload.makeCandidate(localTorrentFileURL: local)
                    } catch {
                        candidateResult = .failure(.inaccessibleTorrent)
                    }
            }

            switch candidateResult {
                case .failure:
                    // Leave payload for a later retry only when the torrent file is still there.
                    continue
                case .success(let candidate):
                    let result = await handler.handle(candidate)
                    // Consume the intake queue for both success and failure. Leaving a
                    // failed payload queued re-submits on every foreground and duplicates
                    // Downloads history. User Retry goes through the failed job record.
                    ManualDownloadIntakeHandoff.markProcessed(payload, bundle: bundle, root: root)
                    if payload.kind == .torrentFile {
                        ManualDownloadIntakeHandoff.removeStagedTorrent(
                            payload,
                            bundle: bundle,
                            root: root,
                        )
                    }
                    if intakeHandoffSucceeded(result) {
                        processed += 1
                    }
            }
        }
        if processed > 0 {
            NotificationCenter.default.post(name: .inkampShowManualDownloads, object: nil)
        }
        return processed
    }

    /// Intake drain only consumes the queue when NAS handoff actually accepted the item.
    private static func intakeHandoffSucceeded(_ result: ManualAcquisitionHandoffResult) -> Bool {
        switch result {
            case .submitted, .completed:
                true
            case .placeholder, .failed:
                false
            default:
                // ManualAcquisitionHandoffResult is closed; satisfy exhaustive-switch rule.
                false
        }
    }
}
