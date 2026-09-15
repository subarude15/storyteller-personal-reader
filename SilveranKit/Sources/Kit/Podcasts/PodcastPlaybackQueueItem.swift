//
//  PodcastPlaybackQueueItem.swift
//  SilveranKit
//
//  Upcoming RSS episodes for the shared podcast player (not Storyteller books).
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// One queued podcast episode (plays through `PodcastPlayerPresenter` / `AudioSessionActor`).
public struct PodcastPlaybackQueueItem: Identifiable, Codable, Equatable, Sendable {
    public var id: String { episodeID }
    public let episodeID: String
    public var title: String
    public var showTitle: String?
    public var summary: String?
    public var audioURL: URL
    public var durationSeconds: TimeInterval?
    public var coverURL: URL?
    public var feedURL: URL?
    /// `PRPodcastMediaKind` raw value (`audio` / `video`).
    public var mediaKindRaw: String

    public init(
        episodeID: String,
        title: String,
        showTitle: String? = nil,
        summary: String? = nil,
        audioURL: URL,
        durationSeconds: TimeInterval? = nil,
        coverURL: URL? = nil,
        feedURL: URL? = nil,
        mediaKindRaw: String = "audio"
    ) {
        self.episodeID = episodeID
        self.title = title
        self.showTitle = showTitle
        self.summary = summary
        self.audioURL = audioURL
        self.durationSeconds = durationSeconds
        self.coverURL = coverURL
        self.feedURL = feedURL
        self.mediaKindRaw = mediaKindRaw
    }

    public var isVideo: Bool { mediaKindRaw == "video" }

    /// Payload for the existing `punkRallyPlayPodcastEpisode` bridge.
    public func playNotificationUserInfo(fromQueueAdvance: Bool = false) -> [String: Any] {
        var info: [String: Any] = [
            "episodeID": episodeID,
            "title": title,
            "audioURL": audioURL,
            "mediaKind": mediaKindRaw,
        ]
        info["showTitle"] = showTitle
        info["summary"] = summary
        if let durationSeconds { info["durationSeconds"] = durationSeconds }
        if let coverURL { info["coverURL"] = coverURL }
        if let feedURL { info["feedURL"] = feedURL }
        if fromQueueAdvance { info["fromQueueAdvance"] = true }
        return info
    }
}

/// Pure queue edits (unit-tested without UI).
public enum PodcastPlaybackQueueEdits {
    /// Insert immediately after the current episode (front of upcoming).
    public static func playNext(
        upcoming: [PodcastPlaybackQueueItem],
        item: PodcastPlaybackQueueItem
    ) -> [PodcastPlaybackQueueItem] {
        var next = upcoming.filter { $0.episodeID != item.episodeID }
        next.insert(item, at: 0)
        return next
    }

    /// Append to the end of upcoming.
    public static func playLast(
        upcoming: [PodcastPlaybackQueueItem],
        item: PodcastPlaybackQueueItem
    ) -> [PodcastPlaybackQueueItem] {
        var next = upcoming.filter { $0.episodeID != item.episodeID }
        next.append(item)
        return next
    }
}
