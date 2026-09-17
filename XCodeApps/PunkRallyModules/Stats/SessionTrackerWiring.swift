//
//  SessionTrackerWiring.swift
//  ink+amp
//
//  Bridges AppleKit player/reader notifications into SessionTracker.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranAppleKit

/// Installs once from the host shell; forwards stats lifecycle notifications.
@MainActor
enum SessionTrackerWiring {
    private static var installed = false
    private static var observers: [NSObjectProtocol] = []

    static func install() {
        guard !installed else { return }
        installed = true

        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: .punkRallyStatsSessionStart,
                object: nil,
                queue: .main
            ) { note in
                Task { @MainActor in
                    guard
                        let kindRaw = note.userInfo?["kind"] as? String,
                        let kind = PRMediaSession.Kind(rawValue: kindRaw),
                        let mediaID = note.userInfo?["mediaID"] as? String,
                        let title = note.userInfo?["mediaTitle"] as? String
                    else { return }
                    SessionTracker.shared.startSession(
                        kind: kind,
                        mediaID: mediaID,
                        mediaTitle: title
                    )
                }
            }
        )
        observers.append(
            center.addObserver(
                forName: .punkRallyStatsSessionEnd,
                object: nil,
                queue: .main
            ) { note in
                Task { @MainActor in
                    let mediaID = note.userInfo?["mediaID"] as? String
                    let progress = note.userInfo?["progress"] as? Double
                    SessionTracker.shared.endSession(mediaID: mediaID, progress: progress)
                }
            }
        )
        observers.append(
            center.addObserver(
                forName: .punkRallyStatsMediaFinished,
                object: nil,
                queue: .main
            ) { note in
                Task { @MainActor in
                    guard
                        let mediaID = note.userInfo?["mediaID"] as? String,
                        let title = note.userInfo?["mediaTitle"] as? String
                    else { return }
                    SessionTracker.shared.recordFinished(mediaID: mediaID, mediaTitle: title)
                }
            }
        )
        observers.append(
            center.addObserver(
                forName: Notification.Name("punkRallyPodcastDidFinish"),
                object: nil,
                queue: .main
            ) { note in
                Task { @MainActor in
                    let episodeID = note.userInfo?["episodeID"] as? String
                    let mediaID = episodeID.map { "podcast/\($0)" }
                    if let mediaID {
                        SessionTracker.shared.recordFinished(
                            mediaID: mediaID,
                            mediaTitle: SessionTracker.shared.activeMediaTitle(for: mediaID)
                                ?? "Podcast"
                        )
                    }
                    SessionTracker.shared.endSession(mediaID: mediaID, progress: 1)
                }
            }
        )
    }
}
