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
    /// Handoff only — never treated as an in-app video enclosure.
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

    /// External YouTube handoff when there is no RSS video enclosure to play in-app.
    public var watchOnYouTubeURL: URL? {
        guard videoURL == nil else { return nil }
        return youtubeURL
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

    public init(feedURL: URL, addedAt: Date = Date(), lastRefreshedAt: Date? = nil) {
        self.feedURL = feedURL
        self.addedAt = addedAt
        self.lastRefreshedAt = lastRefreshedAt
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