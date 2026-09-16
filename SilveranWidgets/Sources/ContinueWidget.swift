import SilveranAppleWidgets
import SwiftUI
import WidgetKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ContinueEntry: TimelineEntry {
    let date: Date
    let snapshot: ContinueWidgetSnapshot
}

struct ContinueTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContinueEntry {
        ContinueEntry(
            date: Date(),
            snapshot: ContinueWidgetSnapshot(
                title: "Continue",
                subtitle: "ink+amp",
                isPlaying: false,
                kind: .audiobook,
                deepLink: InkAmpContinueLink.continueURL.absoluteString,
            ),
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (ContinueEntry) -> Void) {
        SilveranWidgetSnapshotStore.logAppGroupAvailability(source: "timeline")
        completion(ContinueEntry(date: Date(), snapshot: Self.honestSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContinueEntry>) -> Void) {
        SilveranWidgetSnapshotStore.logAppGroupAvailability(source: "timeline")
        let snapshot = Self.honestSnapshot()
        let entry = ContinueEntry(date: Date(), snapshot: snapshot)
        // Refresh often enough that play/pause state stays honest while playing.
        let next = Date().addingTimeInterval(entry.snapshot.isPlaying ? 60 : 15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    /// Always deep-linkable; never rely on App Group for a non-blank tile.
    private static func honestSnapshot() -> ContinueWidgetSnapshot {
        var snapshot = ContinueWidgetSnapshotStore.loadSnapshot()
        if snapshot.deepLink == nil || snapshot.deepLink?.isEmpty == true {
            snapshot.deepLink = InkAmpContinueLink.continueURL.absoluteString
        }
        return snapshot
    }
}

struct ContinueWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: SilveranWidgetConstants.continueWidgetKind,
            provider: ContinueTimelineProvider(),
        ) { entry in
            ContinueWidgetView(entry: entry)
        }
        .configurationDisplayName("Continue")
        .description("Opens ink+amp Continue. Live cover/title need App Groups.")
        .supportedFamilies(Self.supportedFamilies)
        .contentMarginsDisabled()
    }

    private static var supportedFamilies: [WidgetFamily] {
        var families: [WidgetFamily] = [.systemSmall, .systemMedium]
        #if !os(macOS)
        // Optional Lock Screen tile — lean on system Now Playing first; this is a bonus.
        families += [.accessoryRectangular, .accessoryCircular]
        #endif
        return families
    }
}

private struct ContinueWidgetView: View {
    let entry: ContinueEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
                #if !os(macOS)
                    case .accessoryRectangular:
                        accessoryRectangular
                    case .accessoryCircular:
                        accessoryCircular
                #endif
                case .systemSmall:
                    smallBody
                default:
                    mediumBody
            }
        }
        .containerBackground(for: .widget) {
            ContinuePalette.background
        }
        .widgetURL(URL(string: entry.snapshot.deepLink ?? InkAmpContinueLink.continueURL.absoluteString))
    }

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                cover(size: 52)
                Spacer(minLength: 0)
                if entry.snapshot.hasItem {
                    playPauseButton
                }
            }
            titleBlock(lineLimit: 2)
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private var mediumBody: some View {
        HStack(spacing: 14) {
            cover(size: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text("Continue")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ContinuePalette.accent)
                titleBlock(lineLimit: 2)
                Spacer(minLength: 0)
                HStack {
                    if let kind = entry.snapshot.kind {
                        Text(kindLabel(kind))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(ContinuePalette.secondary)
                    }
                    Spacer(minLength: 0)
                    if entry.snapshot.hasItem {
                        playPauseButton
                    }
                }
            }
        }
        .padding(14)
    }

    #if !os(macOS)
    private var accessoryRectangular: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(displaySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if entry.snapshot.hasItem {
                playPauseButton
            }
        }
    }

    private var accessoryCircular: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: entry.snapshot.hasItem
                ? (entry.snapshot.isPlaying ? "pause.fill" : "play.fill")
                : "book.fill")
                .font(.title3.weight(.semibold))
        }
    }
    #endif

    /// Deep-link toggle only — no AppIntents / AudioPlaybackIntent (AltStore).
    private var playPauseButton: some View {
        Link(destination: InkAmpContinueLink.toggleURL) {
            playPauseLabel
        }
        .accessibilityLabel(entry.snapshot.isPlaying ? "Pause" : "Play")
    }

    private var playPauseLabel: some View {
        Image(systemName: entry.snapshot.isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(ContinuePalette.primary)
            .frame(width: 36, height: 36)
            .background(ContinuePalette.accent.opacity(0.18), in: Circle())
    }

    private func titleBlock(lineLimit: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(displayTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ContinuePalette.primary)
                .lineLimit(lineLimit)
            Text(displaySubtitle)
                .font(.caption)
                .foregroundStyle(ContinuePalette.secondary)
                .lineLimit(1)
        }
    }

    /// Never-blank: live App Group title, else extension-local last title, else invite.
    /// Free AltStore often has no App Group — still show “Open ink+amp”, never an empty tile.
    private var displayTitle: String {
        if let title = entry.snapshot.title, !title.isEmpty {
            return title
        }
        if let fallback = ContinueWidgetSnapshotStore.lastTitleFallback() {
            return fallback
        }
        return "Open ink+amp"
    }

    private var displaySubtitle: String {
        if entry.snapshot.hasItem {
            return entry.snapshot.subtitle ?? "ink+amp"
        }
        if entry.snapshot.title == nil, ContinueWidgetSnapshotStore.lastTitleFallback() != nil {
            return "Open ink+amp"
        }
        return "Tap to continue"
    }

    private func cover(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(ContinuePalette.coverFallback)
            if let image = coverImage {
                image
                    .resizable()
                    .widgetAccentedRenderingMode(.fullColor)
                    .scaledToFill()
            } else {
                Image(systemName: coverSymbol)
                    .font(.system(size: size * 0.32, weight: .semibold))
                    .foregroundStyle(ContinuePalette.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var coverImage: Image? {
        guard let filename = entry.snapshot.coverFilename,
            let url = ContinueWidgetSnapshotStore.coverURL(for: filename)
        else { return nil }
        #if canImport(UIKit)
        guard let ui = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: ui)
        #elseif canImport(AppKit)
        guard let data = try? Data(contentsOf: url),
            let ns = NSImage(data: data)
        else { return nil }
        return Image(nsImage: ns)
        #else
        return nil
        #endif
    }

    private var coverSymbol: String {
        switch entry.snapshot.kind {
            case .podcast: return "mic.fill"
            case .audiobook, .readaloud: return "headphones"
            case .ebook, .none: return "book.closed.fill"
        }
    }

    private func kindLabel(_ kind: ContinueWidgetKindTag) -> String {
        switch kind {
            case .ebook: return "READ"
            case .audiobook: return "LISTEN"
            case .readaloud: return "SYNC"
            case .podcast: return "POD"
        }
    }
}

private enum ContinuePalette {
    static let accent = Color(red: 0.91, green: 0.365, blue: 0.016) // #E85D04
    // Explicit ink colors — Color.primary can wash out on some WidgetKit surfaces.
    static let primary = Color(red: 0.102, green: 0.094, blue: 0.078) // #1A1814
    static let secondary = Color(red: 0.420, green: 0.396, blue: 0.376) // #6B6560
    static let coverFallback = Color(white: 0.2) // same dark charcoal as book placeholders
    static let background = LinearGradient(
        colors: [
            Color(red: 0.97, green: 0.96, blue: 0.95),
            Color(red: 0.93, green: 0.91, blue: 0.88),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing,
    )
}
