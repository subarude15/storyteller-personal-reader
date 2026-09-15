//
//  PodcastShowSearchService.swift
//  ink+amp
//
//  Find shows — Apple iTunes Search API (public, no API key):
//  https://itunes.apple.com/search?media=podcast&term=…
//  Results include artwork + feedUrl (RSS). Podcast Index is not used here
//  (requires API keys); paste-URL remains the offline / custom-feed fallback.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// One hit from Find shows search (resolved RSS feed URL required).
public struct PRPodcastSearchResult: Identifiable, Equatable, Sendable {
    public var id: String { feedURL.absoluteString }
    public let title: String
    public let author: String?
    public let coverURL: URL?
    public let feedURL: URL
    public let collectionID: Int?

    public init(
        title: String,
        author: String? = nil,
        coverURL: URL? = nil,
        feedURL: URL,
        collectionID: Int? = nil
    ) {
        self.title = title
        self.author = author
        self.coverURL = coverURL
        self.feedURL = feedURL
        self.collectionID = collectionID
    }
}

public enum PodcastShowSearchError: Error, LocalizedError, Equatable {
    case emptyQuery
    case offline
    case badResponse
    case noResults

    public var errorDescription: String? {
        switch self {
            case .emptyQuery:
                return "Type a show name to search."
            case .offline:
                return "Can't reach Apple Search. Check your connection and try again."
            case .badResponse:
                return "Search didn't return usable results. Try another name, or paste an RSS URL."
            case .noResults:
                return "No shows found. Try a different spelling, or paste an RSS URL."
        }
    }
}

/// Looks up podcast shows via the public iTunes Search API.
public struct PodcastShowSearchService: Sendable {
    public static let shared = PodcastShowSearchService()

    /// Documented endpoint — free, no auth.
    public static let apiBase = "https://itunes.apple.com/search"

    private init() {}

    public func search(term: String, limit: Int = 25) async throws -> [PRPodcastSearchResult] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PodcastShowSearchError.emptyQuery }

        var components = URLComponents(string: Self.apiBase)!
        components.queryItems = [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "entity", value: "podcast"),
            URLQueryItem(name: "term", value: trimmed),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 50)))),
        ]
        guard let url = components.url else { throw PodcastShowSearchError.badResponse }

        var request = URLRequest(url: url)
        request.setValue("ink-amp/1.0 (Podcast Find)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw PodcastShowSearchError.offline
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else {
            throw PodcastShowSearchError.badResponse
        }

        let decoded: ITunesSearchResponse
        do {
            decoded = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
        } catch {
            throw PodcastShowSearchError.badResponse
        }

        var seen = Set<String>()
        let mapped: [PRPodcastSearchResult] = decoded.results.compactMap { row in
            guard
                let feedString = row.feedUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
                !feedString.isEmpty,
                let feedURL = URL(string: feedString),
                feedURL.scheme == "http" || feedURL.scheme == "https"
            else { return nil }
            let key = feedURL.absoluteString
            guard seen.insert(key).inserted else { return nil }
            let title = (row.collectionName ?? row.trackName)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let title, !title.isEmpty else { return nil }
            let art =
                row.artworkUrl600.flatMap(URL.init(string:))
                ?? row.artworkUrl100.flatMap(URL.init(string:))
            return PRPodcastSearchResult(
                title: title,
                author: row.artistName,
                coverURL: art,
                feedURL: feedURL,
                collectionID: row.collectionId
            )
        }

        if mapped.isEmpty {
            throw PodcastShowSearchError.noResults
        }
        return mapped
    }
}

// MARK: - Wire format

private struct ITunesSearchResponse: Decodable {
    let resultCount: Int?
    let results: [ITunesPodcastResult]
}

private struct ITunesPodcastResult: Decodable {
    let collectionId: Int?
    let collectionName: String?
    let trackName: String?
    let artistName: String?
    let feedUrl: String?
    let artworkUrl100: String?
    let artworkUrl600: String?
}
