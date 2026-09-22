//
//  ManualDownloadAttemptCleanup.swift
//  SilveranKit
//
//  Destructive local cleanup for Downloads attempt history. Never submits to
//  Deluge / TorBox / qBittorrent and never posts retry notifications.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Strictly local deletion of download-attempt history (+ orphaned intake queue).
public enum ManualDownloadAttemptCleanup {
    /// Remove one attempt record and any matching pending Share/Shortcuts intake
    /// so lifecycle processing cannot recreate it.
    public static func deleteAttempt(
        _ job: ManualDownloadJob,
        jobs: any ManualDownloadJobStoring = ManualDownloadJobStore.shared,
        bundle: Bundle = .main,
        intakeRoot: URL? = nil,
    ) async {
        let identity = job.attemptIdentityKey
        await jobs.delete(id: job.id)
        ManualDownloadIntakeHandoff.abandonPending(
            matchingFingerprint: identity,
            bundle: bundle,
            root: intakeRoot,
        )
    }

    /// Remove all failed attempt records and matching orphaned intake payloads.
    /// Does not delete successful downloads or contact any provider.
    public static func clearFailed(
        jobs: any ManualDownloadJobStoring = ManualDownloadJobStore.shared,
        bundle: Bundle = .main,
        intakeRoot: URL? = nil,
    ) async {
        let failed = await jobs.allJobs().filter { $0.status == .failed }
        let fingerprints = Set(failed.map(\.attemptIdentityKey))
        await jobs.clearFailed()
        for fingerprint in fingerprints {
            ManualDownloadIntakeHandoff.abandonPending(
                matchingFingerprint: fingerprint,
                bundle: bundle,
                root: intakeRoot,
            )
        }
    }
}
