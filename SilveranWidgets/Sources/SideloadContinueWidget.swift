import SilveranAppleWidgets
import SwiftUI
import WidgetKit

/// Crash-proof Sideload Continue tile for free AltStore.
///
/// Own file, zero AppIntents / AudioPlaybackIntent. WidgetKit snapshots that
/// hit unsigned AppIntent metadata silently kill the extension → blank tile
/// that still taps through. Keep this path StaticConfiguration + solid colors.
@main
struct SilveranReaderWidgets: WidgetBundle {
    var body: some Widget {
        SideloadContinueWidget()
    }
}

struct SideloadContinueWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: SilveranWidgetConstants.sideloadContinueWidgetKind,
            provider: SideloadContinueTimelineProvider(),
        ) { _ in
            SideloadContinueWidgetView()
        }
        .configurationDisplayName("ink+amp Continue")
        .description("Opens Continue in ink+amp.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct SideloadContinueEntry: TimelineEntry {
    let date: Date
}

/// Single static entry — no App Group / UserDefaults reads on this path.
private struct SideloadContinueTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> SideloadContinueEntry {
        SideloadContinueEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (SideloadContinueEntry) -> Void) {
        completion(SideloadContinueEntry(date: Date()))
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<SideloadContinueEntry>) -> Void,
    ) {
        completion(
            Timeline(
                entries: [SideloadContinueEntry(date: Date())],
                policy: .never,
            )
        )
    }
}

private struct SideloadContinueWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if family == .systemSmall {
                smallBody
            } else {
                mediumBody
            }
        }
        .containerBackground(for: .widget) {
            SideloadContinuePalette.cream
        }
        .widgetURL(InkAmpContinueLink.continueURL)
    }

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            cover(size: 52)
            titleBlock
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private var mediumBody: some View {
        HStack(spacing: 14) {
            cover(size: 72)
            VStack(alignment: .leading, spacing: 4) {
                titleBlock
                Spacer(minLength: 0)
            }
        }
        .padding(14)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Open ink+amp")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SideloadContinuePalette.ink)
                .lineLimit(2)
            Text("Tap to continue")
                .font(.caption)
                .foregroundStyle(SideloadContinuePalette.secondary)
                .lineLimit(1)
        }
    }

    private func cover(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(SideloadContinuePalette.charcoal)
            Image(systemName: "book.closed.fill")
                .font(.system(size: size * 0.32, weight: .semibold))
                .foregroundStyle(SideloadContinuePalette.secondary)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private enum SideloadContinuePalette {
    // Hardcoded RGB — Color.primary can wash out on WidgetKit surfaces.
    static let cream = Color(red: 0.97, green: 0.96, blue: 0.95)
    static let charcoal = Color(white: 0.2)
    static let ink = Color(red: 0.102, green: 0.094, blue: 0.078) // #1A1814
    static let secondary = Color(red: 0.420, green: 0.396, blue: 0.376) // #6B6560
}
