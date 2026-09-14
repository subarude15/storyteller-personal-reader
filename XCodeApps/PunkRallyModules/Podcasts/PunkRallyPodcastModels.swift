//
//  PunkRallyPodcastModels.swift
//  punk+rally
//
//  Ported from Enve Book Player (AGPL-3.0-only):
//  https://github.com/opisaac9001/Enve-Book-Player
//  Original: ios/enve/Screens/Podcasts/PodcastsModel.swift
//  Modifications: RSS-only (no Audiobookshelf provider), punk+rally tokens.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// A podcast show sourced from an RSS feed. Covers only Storyteller-free RSS podcasts
/// (podcasts are NOT Storyteller OPDS in the punk+rally model).
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
        self.durationSeconds = durationSeconds
        self.publishedAt = publishedAt
        self.episodeNumber = episodeNumber
        self.showTitle = showTitle
        self.coverURL = coverURL
    }

    public var isFileRecentlyAdded: Bool {
        guard let publishedAt else { return false }
        return Date().timeIntervalSince(publishedAt) < 7 * 24 * 3600
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