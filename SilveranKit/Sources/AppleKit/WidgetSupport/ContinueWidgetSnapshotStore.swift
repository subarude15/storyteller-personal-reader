import Foundation
import SilveranKit

#if canImport(WidgetKit) && (os(iOS) || os(macOS))
import WidgetKit
#endif

public enum ContinueWidgetKindTag: String, Codable, Sendable {
    case ebook
    case audiobook
    case readaloud
    case podcast
}

/// Home-screen Continue card payload shared via App Group (not Keychain).
public struct ContinueWidgetSnapshot: Codable, Sendable, Hashable {
    public var generatedAt: Date
    public var title: String?
    public var subtitle: String?
    public var coverFilename: String?
    public var isPlaying: Bool
    public var kind: ContinueWidgetKindTag?
    /// Absolute deep link into ink+amp (`punkrally://continue`).
    public var deepLink: String?

    public init(
        generatedAt: Date = Date(),
        title: String? = nil,
        subtitle: String? = nil,
        coverFilename: String? = nil,
        isPlaying: Bool = false,
        kind: ContinueWidgetKindTag? = nil,
        deepLink: String? = nil,
    ) {
        self.generatedAt = generatedAt
        self.title = title
        self.subtitle = subtitle
        self.coverFilename = coverFilename
        self.isPlaying = isPlaying
        self.kind = kind
        self.deepLink = deepLink
    }

    public static let empty = ContinueWidgetSnapshot()

    public var hasItem: Bool {
        title != nil
    }
}

public enum ContinueWidgetSnapshotStore {
    private static let snapshotFilename = "continue-now.json"
    private static let coversDirectoryName = "ContinueCovers"

    public static func loadSnapshot(bundle: Bundle = .main) -> ContinueWidgetSnapshot {
        guard let container = SilveranWidgetSnapshotStore.sharedContainerURL(bundle: bundle)
        else {
            return .empty
        }
        let url = snapshotURL(in: container)
        guard let data = try? Data(contentsOf: url) else {
            return .empty
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ContinueWidgetSnapshot.self, from: data)) ?? .empty
    }

    public static func coverURL(for filename: String, bundle: Bundle = .main) -> URL? {
        guard let container = SilveranWidgetSnapshotStore.sharedContainerURL(bundle: bundle)
        else { return nil }
        return coversDirectory(in: container).appendingPathComponent(filename, isDirectory: false)
    }

    /// Publish the Continue / Now Playing tile. Pass `coverData` when available;
    /// nil keeps the previous cover file when title matches.
    public static func publish(
        title: String?,
        subtitle: String?,
        isPlaying: Bool,
        kind: ContinueWidgetKindTag?,
        coverData: Data?,
        deepLink: String = InkAmpContinueLink.continueURL.absoluteString,
    ) {
        guard let container = SilveranWidgetSnapshotStore.sharedContainerURL() else {
            debugLog("[ContinueWidgetSnapshotStore] App group container unavailable")
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: container,
                withIntermediateDirectories: true,
            )
            let covers = coversDirectory(in: container)
            try FileManager.default.createDirectory(
                at: covers,
                withIntermediateDirectories: true,
            )

            var coverFilename: String?
            if let coverData, !coverData.isEmpty {
                let name = "continue_cover.dat"
                let url = covers.appendingPathComponent(name, isDirectory: false)
                try coverData.write(to: url, options: [.atomic])
                coverFilename = name
            } else if let existing = loadSnapshot().coverFilename,
                title != nil
            {
                // Keep last cover while the same session refreshes without image bytes.
                coverFilename = existing
            }

            let snapshot = ContinueWidgetSnapshot(
                generatedAt: Date(),
                title: title,
                subtitle: subtitle,
                coverFilename: coverFilename,
                isPlaying: isPlaying,
                kind: kind,
                deepLink: title == nil ? nil : deepLink,
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: snapshotURL(in: container), options: [.atomic])
            reloadTimelines()
        } catch {
            debugLog("[ContinueWidgetSnapshotStore] Failed to publish: \(error)")
        }
    }

    public static func reloadTimelines() {
        #if canImport(WidgetKit) && (os(iOS) || os(macOS))
        WidgetCenter.shared.reloadTimelines(ofKind: SilveranWidgetConstants.continueWidgetKind)
        #endif
    }

    private static func snapshotURL(in container: URL) -> URL {
        container.appendingPathComponent(snapshotFilename, isDirectory: false)
    }

    private static func coversDirectory(in container: URL) -> URL {
        container.appendingPathComponent(coversDirectoryName, isDirectory: true)
    }
}

/// Deep links for the Continue widget (`punkrally` scheme — already registered).
public enum InkAmpContinueLink {
    public static let continueURL = URL(string: "punkrally://continue")!
    public static let toggleURL = URL(string: "punkrally://continue?action=toggle")!

    public static func isContinueURL(_ url: URL) -> Bool {
        guard url.scheme == "punkrally" else { return false }
        let host = url.host() ?? url.host
        return host == "continue"
    }

    public static func wantsToggle(_ url: URL) -> Bool {
        guard isContinueURL(url) else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        return items?.contains(where: { $0.name == "action" && $0.value == "toggle" }) == true
    }
}
