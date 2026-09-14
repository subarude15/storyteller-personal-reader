//
//  RSSPodcastParser.swift
//  punk+rally
//
//  Ported from Enve Book Player (AGPL-3.0-only):
//  https://github.com/opisaac9001/Enve-Book-Player
//  Original: ios/enve/Networking/Providers/RSSPodcastParser.swift
//  Modifications: XMLParser-based; emits PRPodcastShow/PRPodcastEpisode; no provider coupling.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Minimal RSS 2.0 + iTunes podcast feed parser.
/// Parses channels/items, iTunes extensions for artwork and duration, and common enclosures.
public final class RSSPodcastParser: NSObject, XMLParserDelegate {

    private struct Enclosure {
        let url: URL?
        let type: String?
        let length: Int?
    }

    private struct PendingEpisode {
        var title: String = ""
        var summary: String = ""
        var link: String = ""
        var guid: String = ""
        var pubDateString: String = ""
        var durationString: String = ""
        var episodeInt: Int?
        var enclosure: Enclosure?
        var itunesImageURL: URL?
    }

    private var pendingEpisode: PendingEpisode?
    private var episodes: [PRPodcastEpisode] = []
    private var currentElement: String?
    private var currentText = ""
    private var showTitle = ""
    private var showDescription = ""
    private var showAuthor = ""
    private var showImageURL: URL?
    private var showCategories: [String] = []
    private var inChannel = false
    private var inItem = false

    public init(showTitle: String = "") {
        self.showTitle = showTitle
        super.init()
    }

    /// Parses RSS `Data` into a `PRPodcastShow`.
    public func parse(_ data: Data, feedURL: URL? = nil) -> PRPodcastShow? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        let ok = parser.parse()
        guard ok || !episodes.isEmpty else { return nil }

        return PRPodcastShow(
            title: showTitle.isEmpty ? "Untitled Podcast" : showTitle,
            author: showAuthor.isEmpty ? nil : showAuthor,
            description: showDescription.isEmpty ? nil : showDescription,
            coverURL: showImageURL,
            feedURL: feedURL,
            categories: showCategories,
            episodes: episodes,
            lastUpdated: episodes.compactMap(\.publishedAt).max()
        )
    }

    // MARK: - XMLParserDelegate

    public func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        currentText = ""

        switch elementName {
        case "channel":
            inChannel = true
        case "item":
            inItem = true
            pendingEpisode = PendingEpisode()
        case "enclosure":
            if pendingEpisode != nil {
                pendingEpisode?.enclosure = Enclosure(
                    url: attributeDict["url"].flatMap(URL.init(string:)),
                    type: attributeDict["type"],
                    length: attributeDict["length"].flatMap(Int.init)
                )
            }
        case "itunes:image":
            if let href = attributeDict["href"], pendingEpisode == nil {
                showImageURL = URL(string: href)
            } else if let href = attributeDict["href"], pendingEpisode != nil {
                pendingEpisode?.itunesImageURL = URL(string: href)
            }
        case "image":
            // <image><url>...</url></image> — handled via text accumulation below.
            break
        default:
            break
        }
    }

    public func parser(
        _ parser: XMLParser,
        foundCharacters string: String
    ) {
        currentText += string
    }

    public func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "title":
            if inItem, pendingEpisode != nil {
                pendingEpisode?.title = text
            } else if inChannel {
                showTitle = text
            }
        case "description":
            if inItem, pendingEpisode != nil {
                pendingEpisode?.summary = text
            } else if inChannel {
                showDescription = text
            }
        case "link":
            if inItem, pendingEpisode != nil {
                pendingEpisode?.link = text
            }
        case "guid":
            if inItem, pendingEpisode != nil {
                pendingEpisode?.guid = text.isEmpty ? pendingEpisode?.link ?? "" : text
            }
        case "pubDate":
            if inItem, pendingEpisode != nil {
                pendingEpisode?.pubDateString = text
            }
        case "itunes:duration":
            if inItem, pendingEpisode != nil {
                pendingEpisode?.durationString = text
            }
        case "itunes:author":
            if inChannel {
                showAuthor = text
            }
        case "itunes:category":
            if inChannel, !text.isEmpty {
                showCategories.append(text)
            }
        case "itunes:episode":
            if inItem, pendingEpisode != nil {
                pendingEpisode?.episodeInt = Int(text)
            }
        case "url":
            if inChannel {
                showImageURL = URL(string: text)
            }
        case "item":
            finalizeEpisode()
            inItem = false
        case "channel":
            inChannel = false
        default:
            break
        }

        currentElement = nil
        currentText = ""
    }

    // MARK: - Private

    private func finalizeEpisode() {
        guard var ep = pendingEpisode else { return }
        defer { pendingEpisode = nil }

        // Standardize episode ID: GUID first, fall back to link, then title slug.
        let fallbackID = ep.guid.isEmpty ? ep.link : ep.guid
        let episodeID = fallbackID.isEmpty
            ? "ep-\(episodes.count)-\(ep.title)"
            : fallbackID

        let duration = Self.parseDuration(ep.durationString)

        let publishedAt = Self.parseDate(ep.pubDateString)

        let cover = ep.itunesImageURL ?? showImageURL

        episodes.append(
            PRPodcastEpisode(
                id: episodeID,
                title: ep.title.isEmpty ? "Untitled Episode" : ep.title,
                summary: ep.summary.isEmpty ? nil : ep.summary,
                audioURL: ep.enclosure?.url,
                durationSeconds: duration,
                publishedAt: publishedAt,
                episodeNumber: ep.episodeInt,
                showTitle: showTitle,
                coverURL: cover
            )
        )
    }

    static func parseDuration(_ raw: String) -> TimeInterval? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // "HH:MM:SS", "MM:SS", or bare seconds
        let parts = trimmed.split(separator: ":")
        if parts.count == 3, let h = Int(parts[0]), let m = Int(parts[1]), let s = Int(parts[2]) {
            return TimeInterval(h * 3600 + m * 60 + s)
        }
        if parts.count == 2, let m = Int(parts[0]), let s = Int(parts[1]) {
            return TimeInterval(m * 60 + s)
        }
        if parts.count == 1, let seconds = Int(parts[0]) {
            return TimeInterval(seconds)
        }
        return nil
    }

    static func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)

        // RFC 822 / RFC 1123 variants used by most feeds.
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd",
        ]
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }
}