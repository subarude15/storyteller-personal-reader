import SwiftUI
import SilveranAppleKit
import SilveranKit

/// Isolated simulator host. Does not use the release entry point, credentials,
/// network library, audio engine or signing/deployment route.
@main
struct GeometryHarnessApp: App {
    init() { InkAmpGeometryFixture.seedStats() }

    var body: some Scene {
        WindowGroup {
            PunkRallyTabView()
                .dynamicTypeSize(
                    ProcessInfo.processInfo.environment["INKAMP_GEOMETRY_DYNAMIC_TYPE"] == "accessibility"
                        ? .accessibility3 : .large
                )
                .preferredColorScheme(.dark)
        }
    }
}

/// DATA/clock injection only: no substitute cards, spacers or fake geometry.
/// The authenticated VM, artwork loads and release entry point remain unrepresented.
enum InkAmpGeometryFixture {
    static var profile: String {
        ProcessInfo.processInfo.environment["INKAMP_GEOMETRY_HOME_PROFILE"] ?? "bedtime"
    }
    static var restoreAfterLayout: Bool {
        ProcessInfo.processInfo.environment["INKAMP_GEOMETRY_RESTORE_AFTER_LAYOUT"] == "1"
    }
    static var minutesUntilBedtime: Int? { profile == "no-bedtime" ? nil : 310 }

    private static let touched = Date(timeIntervalSince1970: 1_700_000_000)
    private static let titles = [
        "Adam Nevill - The Reddening: A Gripping Folk-Horror",
        "The Acolyte", "Them", "All the Fiends of Hell",
        "Another long queue title that wraps across two production card lines",
    ]
    private static let books: [BookMetadata] = titles.enumerated().map { index, title in
        let locator = BookLocator(
            href: "fixture.xhtml", type: "application/xhtml+xml", title: nil,
            locations: .init(fragments: nil, progression: nil, position: nil,
                totalProgression: index == 0 ? 0.25 : 0.98,
                cssSelector: nil, partialCfi: nil, domRange: nil), text: nil)
        let position = BookReadingPosition(uuid: nil, locator: locator,
            timestamp: touched.addingTimeInterval(-Double(index) * 60).timeIntervalSince1970 * 1000,
            createdAt: nil, updatedAt: nil)
        let aligned = BookReadaloud(uuid: nil, filepath: "fixture.epub", missing: 0,
            status: "ALIGNED", currentStage: nil, stageProgress: nil,
            queuePosition: nil, restartPending: nil, createdAt: nil, updatedAt: nil)
        let author = BookCreator(uuid: nil, id: nil, name: "Adam Nevill",
            fileAs: nil, role: nil, createdAt: nil, updatedAt: nil)
        return BookMetadata(
            bookID: BookID(sourceID: "geometry-fixture", uuid: "book-\(index)"),
            title: title, subtitle: nil, description: nil, language: "en",
            createdAt: nil, updatedAt: nil, publicationDate: nil,
            authors: [author], narrators: nil, creators: nil, series: nil,
            tags: nil, collections: nil, ebook: nil, audiobook: nil,
            readaloud: aligned, status: nil, position: position, rating: nil,
            duration: index == 0 ? 54960 : 7200)
    }

    static var queue: (continueItem: HomeMixedItem?, upNext: [HomeMixedItem]) {
        let podcast = PodcastRecentEntry(
            episodeID: "geometry-podcast", title: "Big Tech lost big in the 2026 election",
            showTitle: "The Vergecast", coverURL: nil,
            audioURL: URL(fileURLWithPath: "/geometry-fixture-not-played.m4a"),
            durationSeconds: 7200, lastTouched: touched.addingTimeInterval(-90), progress: 0.2)
        return HomeMixedQueue.build(books: books, progress: [:],
            preferredCategory: { _ in .synced }, podcastRecents: [podcast],
            podcastDownloads: [], upNextLimit: 40)
    }

    static func seedStats() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let durations: [TimeInterval] = [3 * 3600 + 4 * 60, 58 * 60, 58 * 60]
        let sessions = durations.enumerated().map { day, duration in
            guard let date = calendar.date(byAdding: .day, value: -day, to: today) else {
                preconditionFailure("Cannot construct fixture history date")
            }
            let start = date.addingTimeInterval(3600)
            return PRMediaSession(kind: .listening, mediaID: "geometry-history-\(day)",
                mediaTitle: "Local fixture history", startedAt: start,
                endedAt: start.addingTimeInterval(duration), durationSeconds: duration,
                medium: "readaloud")
        }
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(sessions),
                forKey: "punkRally.stats.sessions.v1")
        } catch {
            preconditionFailure("Cannot encode fixture history: \(error)")
        }
    }
}
