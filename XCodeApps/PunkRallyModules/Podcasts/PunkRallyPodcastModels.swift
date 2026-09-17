//
//  PunkRallyPodcastModels.swift
//  ink+amp
//
//  Ported from Enve Book Player (AGPL-3.0-only):
//  https://github.com/opisaac9001/Enve-Book-Player
//  Original: ios/enve/Screens/Podcasts/PodcastsModel.swift
//  Modifications: RSS-only (no Audiobookshelf provider), ink+amp tokens.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit

/// A podcast show sourced from an RSS feed. Covers only Storyteller-free RSS podcasts
/// (podcasts are NOT Storyteller OPDS in the ink+amp model).
public struct PRPodcastShow: Identifiable, Equatable, Sendable {
    public var id: String { feedURL?.absoluteString ?? uuid }
    public let uuid: String
    public let title: String
    public let author: String?
    public let description: String?
    public let coverURL: URL?
    public let feedURL: URL?
    public let categories: [String]
    public let episodes: [PRPodcastEpisode]
    public let lastUpdated: Date?
    public let addedAt: Date

    public init(
        uuid: String = UUID().uuidString,
        title: String,
        author: String? = nil,
        description: String? = nil,
        coverURL: URL? = nil,
        feedURL: URL? = nil,
        categories: [String] = [],
        episodes: [PRPodcastEpisode] = [],
        lastUpdated: Date? = nil,
        addedAt: Date = Date()
    ) {
        self.uuid = uuid
        self.title = title
        self.author = author
        self.description = description
        self.coverURL = coverURL
        self.feedURL = feedURL
        self.categories = categories
        self.episodes = episodes
        self.lastUpdated = lastUpdated
        self.addedAt = addedAt
    }
}

public struct PRPodcastEpisode: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let summary: String?
    public let audioURL: URL?
    public let videoURL: URL?
    /// YouTube watch URL from link / show notes / iTunes text when present.
    /// Play in ink+amp resolves a stream via Settings URL; Watch on YouTube hands off.
    public let youtubeURL: URL?
    public let durationSeconds: TimeInterval?
    public let publishedAt: Date?
    public let episodeNumber: Int?
    public let showTitle: String?
    public let coverURL: URL?

    public init(
        id: String,
        title: String,
        summary: String? = nil,
        audioURL: URL? = nil,
        videoURL: URL? = nil,
        youtubeURL: URL? = nil,
        durationSeconds: TimeInterval? = nil,
        publishedAt: Date? = nil,
        episodeNumber: Int? = nil,
        showTitle: String? = nil,
        coverURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.audioURL = audioURL
        self.videoURL = videoURL
        self.youtubeURL = youtubeURL
        self.durationSeconds = durationSeconds
        self.publishedAt = publishedAt
        self.episodeNumber = episodeNumber
        self.showTitle = showTitle
        self.coverURL = coverURL
    }

    /// True when the feed published both an audio and a video enclosure.
    public var hasAudioAndVideo: Bool {
        audioURL != nil && videoURL != nil
    }

    /// YouTube affordances when there is no RSS video enclosure (hybrid RSS video
    /// already plays in-app — keep YouTube for audio-only / notes-only episodes).
    /// Prefers a user-confirmed Match on YouTube URL, else feed extract with a
    /// real video id — channel / @handle URLs must not show Play / Watch chips.
    public var watchOnYouTubeURL: URL? {
        guard videoURL == nil else { return nil }
        if let matched = PodcastMatchedYouTubeStore.shared.watchURL(for: id) {
            return matched
        }
        guard let youtubeURL else { return nil }
        guard PodcastYouTubeURL.videoID(from: youtubeURL) != nil else { return nil }
        return youtubeURL
    }

    /// True when there is no confirmed watch URL yet (feed or Match) and no RSS
    /// video enclosure — show explicit Match on YouTube instead of fake Play chips.
    public var needsYouTubeMatch: Bool {
        videoURL == nil && watchOnYouTubeURL == nil
    }

    public var isFileRecentlyAdded: Bool {
        guard let publishedAt else { return false }
        return Date().timeIntervalSince(publishedAt) < 7 * 24 * 3600
    }
}

/// Preferred enclosure when an episode offers both audio and video.
public enum PRPodcastMediaKind: String, Codable, Sendable, CaseIterable {
    case audio
    case video

    public var displayName: String {
        switch self {
            case .audio: return "Audio"
            case .video: return "Video"
        }
    }
}

/// A lightweight persisted subscription record (kept in UserDefaults in v1;
/// SwiftData migration comes when Silveran's own persistence is integrated).
public struct PRPodcastSubscription: Identifiable, Codable, Equatable {
    public var id: String { feedURL.absoluteString }
    public let feedURL: URL
    public let addedAt: Date
    public var lastRefreshedAt: Date?
    /// Optional show title for sync / UI before the next RSS refresh.
    public var title: String?
    public var updatedAt: Date
    /// Unsubscribe tombstone for cross-device sync (hidden from subscribed list).
    public var unsubscribed: Bool

    public init(
        feedURL: URL,
        addedAt: Date = Date(),
        lastRefreshedAt: Date? = nil,
        title: String? = nil,
        updatedAt: Date? = nil,
        unsubscribed: Bool = false
    ) {
        self.feedURL = feedURL
        self.addedAt = addedAt
        self.lastRefreshedAt = lastRefreshedAt
        self.title = title
        self.updatedAt = updatedAt ?? addedAt
        self.unsubscribed = unsubscribed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        feedURL = try container.decode(URL.self, forKey: .feedURL)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        lastRefreshedAt = try container.decodeIfPresent(Date.self, forKey: .lastRefreshedAt)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? addedAt
        unsubscribed = try container.decodeIfPresent(Bool.self, forKey: .unsubscribed) ?? false
    }
}

/// Categories an RSS podcast can belong to (Storyteller books use ebook/audiobook/readaloud only).
public enum PRPodcastCategory: String, CaseIterable, Sendable {
    case news
    case education
    case comedy
    case arts
    case technology
    case music
    case other

    public var displayName: String {
        rawValue.capitalized
    }
}