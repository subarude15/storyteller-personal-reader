import SwiftUI
import WidgetKit

/// Crash-proof Sideload Continue tile for free AltStore.
///
/// Lean paint path: SwiftUI + WidgetKit only — no SilveranAppleWidgets,
/// no AppIntents, no App Group / timeline I/O. Kind bump drops dead v2 snapshots.
@main
struct SilveranReaderWidgets: WidgetBundle {
    var body: some Widget {
        SideloadContinueWidget()
    }
}

struct SideloadContinueWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "inkamp.continue.v3",
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
    var body: some View {
        ZStack {
            Color(white: 0.18)
            VStack(spacing: 8) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color(white: 0.95))
                Text("Open ink+amp")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text("Tap to continue")
                    .font(.caption)
                    .foregroundStyle(Color(white: 0.9))
                    .lineLimit(1)
            }
            .multilineTextAlignment(.center)
            .padding(12)
        }
        // Visible fill is the ZStack charcoal — clear containerBackground for iOS 17+.
        .containerBackground(for: .widget) {
            Color.clear
        }
        .widgetURL(URL(string: "punkrally://continue")!)
    }
}
