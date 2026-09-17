//
//  PodcastAppleCharts.swift
//  SilveranKit
//
//  Free Apple iTunes / RSS podcast charts (no API key). Same public stack as
//  Find search — not Podcast Index. Classic RSS JSON + lookup for feedUrl.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// One show from Top Charts / genre charts (RSS feed URL resolved via lookup).
public struct PodcastChartHit: Identifiable, Equatable, Sendable {
    public var id: Int { collectionID }
    public let collectionID: Int
    public let title: String
    public let author: String?
    public let coverURL: URL?
    public let feedURL: URL

    public init(
        collectionID: Int,
        title: String,
        author: String? = nil,
        coverURL: URL? = nil,
        feedURL: URL
    ) {
        self.collectionID = collectionID
        self.title = title
        self.author = author
        self.coverURL = coverURL
        self.feedURL = feedURL
    }
}

/// Genre chip — `id == nil` means overall Top Charts.
public struct PodcastBrowseGenre: Identifiable, Hashable, Sendable {
    public var id: Int { genreID ?? 0 }
    public let genreID: Int?
    public let name: String

    public init(genreID: Int?, name: String) {
        self.genreID = genreID
        self.name = name
    }

    public static let topCharts = PodcastBrowseGenre(genreID: nil, name: "Top Charts")

    /// Apple Podcasts primary genres (store id 26 subgenres). Stable, no keys.
    public static let all: [PodcastBrowseGenre] = [
        .topCharts,
        PodcastBrowseGenre(genreID: 1303, name: "Comedy"),
        PodcastBrowseGenre(genreID: 1489, name: "News"),
        PodcastBrowseGenre(genreID: 1488, name: "True Crime"),
        PodcastBrowseGenre(genreID: 1324, name: "Society & Culture"),
        PodcastBrowseGenre(genreID: 1310, name: "Music"),
        PodcastBrowseGenre(genreID: 1301, name: "Arts"),
        PodcastBrowseGenre(genreID: 1321, name: "Business"),
        PodcastBrowseGenre(genreID: 1304, name: "Education"),
        PodcastBrowseGenre(genreID: 1512, name: "Health & Fitness"),
        PodcastBrowseGenre(genreID: 1487, name: "History"),
        PodcastBrowseGenre(genreID: 1502, name: "Leisure"),
        PodcastBrowseGenre(genreID: 1314, name: "Religion"),
        PodcastBrowseGenre(genreID: 1533, name: "Science"),
        PodcastBrowseGenre(genreID: 1545, name: "Sports"),
        PodcastBrowseGenre(genreID: 1309, name: "TV & Film"),
        PodcastBrowseGenre(genreID: 1318, name: "Technology"),
        PodcastBrowseGenre(genreID: 1483, name: "Fiction"),
        PodcastBrowseGenre(genreID: 1305, name: "Kids & Family"),
    ]
}

public enum PodcastAppleChartsError: Error, LocalizedError, Equatable {
    case offline
    case badResponse
    case empty

    public var errorDescription: String? {
        switch self {
            case .offline:
                return "Can't reach Apple Charts. Check your connection and try again."
            case .badResponse:
                return "Charts didn't return usable shows. Try again, or search by name."
            case .empty:
                return "No chart shows right now. Try another genre, or search by name."
        }
    }
}

/// Builds URLs and parses Apple chart payloads (pure; network lives in the service).
public enum PodcastAppleCharts {
    /// Classic iTunes RSS top podcasts JSON (genre optional).
    public static func chartURL(storefront: String, limit: Int, genreID: Int?) -> URL {
        let cc = storefront.lowercased()
        let capped = max(1, min(limit, 50))
        var path = "https://itunes.apple.com/\(cc)/rss/toppodcasts/limit=\(capped)"
        if let genreID {
            path += "/genre=\(genreID)"
        }
        path += "/json"
        return URL(string: path)!
    }

    public static func lookupURL(collectionIDs: [Int]) -> URL? {
        let ids = collectionIDs.filter { $0 > 0 }
        guard !ids.isEmpty else { return nil }
        let joined = ids.map(String.init).joined(separator: ",")
        return URL(string: "https://itunes.apple.com/lookup?id=\(joined)&entity=podcast")
    }

    /// Prefer larger artwork from mzstatic thumb URLs.
    public static func upscaleArtwork(_ url: URL?) -> URL? {
        guard let url else { return nil }
        let s = url.absoluteString
            .replacingOccurrences(of: "/55x55bb.png", with: "/600x600bb.jpg")
            .replacingOccurrences(of: "/60x60bb.png", with: "/600x600bb.jpg")
            .replacingOccurrences(of: "/100x100bb.png", with: "/600x600bb.jpg")
            .replacingOccurrences(of: "/170x170bb.png", with: "/600x600bb.jpg")
        return URL(string: s) ?? url
    }

    /// Parse classic RSS chart JSON into ordered collection stubs (no feed yet).
    public static func parseClassicChart(_ data: Data) throws -> [ChartStub] {
        let decoded: ClassicChartFeed
        do {
            decoded = try JSONDecoder().decode(ClassicChartFeed.self, from: data)
        } catch {
            throw PodcastAppleChartsError.badResponse
        }
        var seen = Set<Int>()
        let stubs: [ChartStub] = decoded.feed.entry.compactMap { entry in
            guard let idString = entry.id.attributes?.imId ?? entry.id.attributes?.im_id,
                let collectionID = Int(idString), collectionID > 0,
                seen.insert(collectionID).inserted
            else { return nil }
            let title = entry.imName?.label?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let title, !title.isEmpty else { return nil }
            let art =
                entry.imImage?
                .compactMap { $0.label.flatMap(URL.init(string:)) }
                .last
            return ChartStub(
                collectionID: collectionID,
                title: title,
                author: entry.imArtist?.label,
                coverURL: upscaleArtwork(art)
            )
        }
        if stubs.isEmpty { throw PodcastAppleChartsError.empty }
        return stubs
    }

    /// Merge chart order with iTunes lookup rows that carry `feedUrl`.
    public static func mergeLookup(
        stubs: [ChartStub],
        lookupData: Data
    ) throws -> [PodcastChartHit] {
        let decoded: LookupResponse
        do {
            decoded = try JSONDecoder().decode(LookupResponse.self, from: lookupData)
        } catch {
            throw PodcastAppleChartsError.badResponse
        }
        var byID: [Int: LookupPodcast] = [:]
        for row in decoded.results {
            guard let cid = row.collectionId ?? row.trackId else { continue }
            byID[cid] = row
        }
        let hits: [PodcastChartHit] = stubs.compactMap { stub in
            guard let row = byID[stub.collectionID],
                let feedString = row.feedUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
                !feedString.isEmpty,
                let feedURL = URL(string: feedString),
                feedURL.scheme == "http" || feedURL.scheme == "https"
            else { return nil }
            let art =
                row.artworkUrl600.flatMap(URL.init(string:))
                ?? row.artworkUrl100.flatMap(URL.init(string:))
                ?? stub.coverURL
            return PodcastChartHit(
                collectionID: stub.collectionID,
                title: (row.collectionName ?? row.trackName ?? stub.title)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                author: row.artistName ?? stub.author,
                coverURL: upscaleArtwork(art) ?? art,
                feedURL: feedURL
            )
        }
        if hits.isEmpty { throw PodcastAppleChartsError.empty }
        return hits
    }

    public struct ChartStub: Equatable, Sendable {
        public let collectionID: Int
        public let title: String
        public let author: String?
        public let coverURL: URL?

        public init(collectionID: Int, title: String, author: String?, coverURL: URL?) {
            self.collectionID = collectionID
            self.title = title
            self.author = author
            self.coverURL = coverURL
        }
    }
}

// MARK: - Wire format (classic RSS JSON)

private struct ClassicChartFeed: Decodable {
    let feed: ClassicFeedBody
}

private struct ClassicFeedBody: Decodable {
    let entry: [ClassicEntry]
}

private struct ClassicEntry: Decodable {
    let id: ClassicID
    let imName: ClassicLabel?
    let imArtist: ClassicLabel?
    let imImage: [ClassicImage]?

    enum CodingKeys: String, CodingKey {
        case id
        case imName = "im:name"
        case imArtist = "im:artist"
        case imImage = "im:image"
    }
}

private struct ClassicID: Decodable {
    let attributes: ClassicIDAttributes?
}

private struct ClassicIDAttributes: Decodable {
    let imId: String?
    let im_id: String?

    enum CodingKeys: String, CodingKey {
        case imId = "im:id"
        case im_id
    }
}

private struct ClassicLabel: Decodable {
    let label: String?
}

private struct ClassicImage: Decodable {
    let label: String?
}

private struct LookupResponse: Decodable {
    let results: [LookupPodcast]
}

private struct LookupPodcast: Decodable {
    let collectionId: Int?
    let trackId: Int?
    let collectionName: String?
    let trackName: String?
    let artistName: String?
    let feedUrl: String?
    let artworkUrl100: String?
    let artworkUrl600: String?
}
