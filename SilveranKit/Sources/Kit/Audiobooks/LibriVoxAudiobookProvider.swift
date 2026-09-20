import Foundation

public enum AudiobookProviderError: Error, Equatable, Sendable {
    case unreachable
    case timeout
    case httpStatus(Int)
    case rateLimited
    case undecodable

    public var issue: AudiobookProviderIssue {
        switch self {
            case .unreachable: .unreachable
            case .timeout: .timeout
            case .httpStatus: .unexpectedResponse
            case .rateLimited: .rateLimited
            case .undecodable: .unexpectedResponse
        }
    }
}

public enum AudiobookProviderIssue: Equatable, Sendable {
    case unreachable
    case timeout
    case rateLimited
    case unexpectedResponse
}

/// LibriVox public-domain catalog. One title query for the selected work. No catalog crawl.
public struct LibriVoxAudiobookProvider: AudiobookCatalogProviding {
    public var kind: AudiobookProviderKind { .librivox }

    public var fetch: @Sendable (URL) async throws -> Data

    public init(
        fetch: @escaping @Sendable (URL) async throws -> Data = LibriVoxAudiobookProvider.liveFetch
    ) {
        self.fetch = fetch
    }

    public static func liveFetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("inkamp/audiobook-resolver", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            debugLog(
                "[LibriVox] provider=librivox url=\(sanitizedURL(url)) network=\(error.code.rawValue)"
            )
            switch error.code {
                case .timedOut:
                    throw AudiobookProviderError.timeout
                default:
                    throw AudiobookProviderError.unreachable
            }
        } catch {
            debugLog("[LibriVox] provider=librivox url=\(sanitizedURL(url)) network=unknown")
            throw AudiobookProviderError.unreachable
        }
        guard let http = response as? HTTPURLResponse else {
            debugLog("[LibriVox] provider=librivox url=\(sanitizedURL(url)) status=missing")
            throw AudiobookProviderError.unreachable
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
        debugLog(
            "[LibriVox] provider=librivox url=\(sanitizedURL(url)) status=\(http.statusCode) type=\(contentType)"
        )
        switch http.statusCode {
            case 200..<300:
                return data
            case 429:
                throw AudiobookProviderError.rateLimited
            default:
                throw AudiobookProviderError.httpStatus(http.statusCode)
        }
    }

    /// Anchored title+author, then anchored title, then one unanchored title query.
    /// Stops at the first non-empty page. Never sends offset or since.
    public static func queryURLs(for work: CanonicalBookWork) -> [URL] {
        let title = AudiobookText.searchTitle(work.title, subtitle: work.subtitle)
        guard title.count >= 2 else { return [] }
        let surname = work.authors.compactMap { name -> String? in
            let surname = AudiobookText.authorSurname(name)
            return surname.count >= 2 ? surname : nil
        }.first
        var urls: [URL] = []
        if let surname, let url = url(title: title, author: surname, anchored: true) {
            urls.append(url)
        }
        if let url = url(title: title, author: nil, anchored: true) {
            urls.append(url)
        }
        if let url = url(title: title, author: nil, anchored: false) {
            urls.append(url)
        }
        return urls
    }

    public func search(_ work: CanonicalBookWork) async throws -> [AudiobookProviderItem] {
        let urls = Self.queryURLs(for: work)
        guard !urls.isEmpty else { return [] }
        var lastError: AudiobookProviderError?
        for url in urls {
            do {
                let data = try await fetch(url)
                let items = try Self.decode(data)
                if !items.isEmpty {
                    return items
                }
            } catch let error as AudiobookProviderError {
                if error == .undecodable {
                    lastError = error
                    debugLog(
                        "[LibriVox] provider=librivox url=\(Self.sanitizedURL(url)) decode=failed"
                    )
                    continue
                }
                throw error
            } catch let error as URLError {
                switch error.code {
                    case .timedOut: throw AudiobookProviderError.timeout
                    default: throw AudiobookProviderError.unreachable
                }
            } catch {
                throw AudiobookProviderError.unreachable
            }
        }
        if let lastError {
            throw lastError
        }
        return []
    }

    public static func decode(_ data: Data) throws -> [AudiobookProviderItem] {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            debugLog("[LibriVox] provider=librivox decode=\(type(of: error))")
            throw AudiobookProviderError.undecodable
        }
        return envelope.books.compactMap(Self.item(from:))
    }

    static func sanitizedURL(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }

    private static func url(title: String, author: String?, anchored: Bool) -> URL? {
        var components = URLComponents(string: "https://librivox.org/api/feed/audiobooks/")
        var items = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "extended", value: "1"),
            URLQueryItem(name: "coverart", value: "1"),
            URLQueryItem(name: "limit", value: "15"),
            URLQueryItem(name: "title", value: anchored ? "^\(title)" : title),
        ]
        if let author {
            items.append(URLQueryItem(name: "author", value: author))
        }
        components?.queryItems = items
        return components?.url
    }

    private static func item(from book: Book) -> AudiobookProviderItem? {
        let id = book.id.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = book.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty, !title.isEmpty else { return nil }
        let authors = (book.authors ?? []).compactMap { author -> String? in
            let name = [author.firstName, author.lastName]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return name.isEmpty ? nil : name
        }
        let chapters = chapters(from: book.sections ?? [])
        let readers = chapters.flatMap(\.readers)
        var seen = Set<String>()
        let narrator = readers.filter { seen.insert($0).inserted }.joined(separator: ", ")
        let duration =
            timeInterval(from: book.totalTimeSeconds?.value)
            ?? chapters.compactMap(\.chapter.duration).reduce(0, +)
        return AudiobookProviderItem(
            provider: .librivox,
            providerItemID: id,
            title: title,
            authors: authors,
            narrator: narrator.isEmpty ? nil : narrator,
            language: book.language,
            duration: duration > 0 ? duration : nil,
            artworkURL: url(book.coverThumbnail) ?? url(book.coverJPEG),
            description: book.description.map(plainText).flatMap { $0.isEmpty ? nil : $0 },
            sourceURL: url(book.librivoxURL) ?? url(book.projectURL),
            chapters: chapters.map(\.chapter),
        )
    }

    private struct NamedReader {
        var chapter: ResolvedAudiobookChapter
        var readers: [String]
    }

    private static func chapters(from sections: [Section]) -> [NamedReader] {
        let sorted = sections.sorted { lhs, rhs in
            (Int(lhs.number?.value ?? "") ?? 0) < (Int(rhs.number?.value ?? "") ?? 0)
        }
        var chapters: [NamedReader] = []
        for (index, section) in sorted.enumerated() {
            guard let playback = url(section.listenURL) else { continue }
            let scheme = playback.scheme?.lowercased()
            guard scheme == "https" || scheme == "http" else { continue }
            let number = Int(section.number?.value ?? "") ?? (index + 1)
            let title = section.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = (title?.isEmpty == false) ? title! : "Chapter \(number)"
            let playtime = timeInterval(from: section.playtime?.value)
            let readers = (section.readers ?? []).compactMap { reader -> String? in
                let name = reader.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                return name?.isEmpty == false ? name : nil
            }
            chapters.append(
                NamedReader(
                    chapter: ResolvedAudiobookChapter(
                        id: section.id?.value ?? "\(number)",
                        title: label,
                        order: number,
                        playbackURL: playback,
                        duration: playtime,
                    ),
                    readers: readers,
                )
            )
        }
        return chapters
    }

    /// Call `TimeInterval(_:)` directly. Passing `TimeInterval.init` or any
    /// `(String) -> TimeInterval?` into `flatMap` selects `String.flatMap` instead.
    private static func timeInterval(from raw: String?) -> TimeInterval? {
        guard let raw else { return nil }
        return TimeInterval(raw)
    }

    private static func url(_ raw: String?) -> URL? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    static func plainText(_ html: String) -> String {
        let stripped = html.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression,
        )
        let entities = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&quot;": "\"",
            "&#39;": "'",
            "&lt;": "<",
            "&gt;": ">",
        ]
        var text = stripped
        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private struct Envelope: Decodable {
        var books: [Book]

        private enum CodingKeys: String, CodingKey {
            case books
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let books = try? container.decode([Book].self, forKey: .books) {
                self.books = books
            } else if let book = try? container.decode(Book.self, forKey: .books) {
                self.books = [book]
            } else if container.contains(.books) {
                self.books = []
            } else {
                throw AudiobookProviderError.undecodable
            }
        }
    }

    private struct Book: Decodable {
        var id: FlexString
        var title: String?
        var description: String?
        var language: String?
        var totalTimeSeconds: FlexString?
        var librivoxURL: String?
        var projectURL: String?
        var coverThumbnail: String?
        var coverJPEG: String?
        var authors: [Author]?
        var sections: [Section]?

        private enum CodingKeys: String, CodingKey {
            case id
            case title
            case description
            case language
            case totalTimeSeconds = "totaltimesecs"
            case librivoxURL = "url_librivox"
            case projectURL = "url_project"
            case coverThumbnail = "coverart_thumbnail"
            case coverJPEG = "coverart_jpg"
            case authors
            case sections
        }
    }

    private struct Author: Decodable {
        var firstName: String?
        var lastName: String?

        private enum CodingKeys: String, CodingKey {
            case firstName = "first_name"
            case lastName = "last_name"
        }
    }

    private struct Section: Decodable {
        var id: FlexString?
        var number: FlexString?
        var title: String?
        var listenURL: String?
        var playtime: FlexString?
        var readers: [Reader]?

        private enum CodingKeys: String, CodingKey {
            case id
            case number = "section_number"
            case title
            case listenURL = "listen_url"
            case playtime
            case readers
        }
    }

    private struct Reader: Decodable {
        var displayName: String?

        private enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
        }
    }

    private struct FlexString: Decodable {
        var value: String

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                value = string
                return
            }
            if let int = try? container.decode(Int.self) {
                value = String(int)
                return
            }
            if let double = try? container.decode(Double.self) {
                value = String(Int(double))
                return
            }
            value = ""
        }
    }
}
