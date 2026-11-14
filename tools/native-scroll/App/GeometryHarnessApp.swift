import SwiftUI

/// Isolated simulator host. Does not use the release entry point, credentials,
/// network library, audio engine or signing/deployment route.
@main
struct GeometryHarnessApp: App {
    var body: some Scene {
        WindowGroup {
            PunkRallyTabView()
                .dynamicTypeSize(
                    ProcessInfo.processInfo.environment["INKAMP_GEOMETRY_DYNAMIC_TYPE"] == "accessibility"
                        ? .accessibility3 : .large
                )
        }
    }
}

/// Synthetic local CONTENT, not a replacement container/inset implementation.
/// All real Home boundary modifiers and the real stats button stay in place.
/// Fixed fixture dimensions describe overflowing data; they reserve NO player space.
enum InkAmpGeometryFixture {
    static var content: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Good morning").font(.largeTitle.bold())
            Text("Finish tonight").font(.headline)
                .frame(maxWidth: .infinity, minHeight: 160)
                .background(.quaternary)
            Text("Continue · local fixture").font(.title2)
                .frame(maxWidth: .infinity, minHeight: 220)
                .background(.quaternary)
            VStack(alignment: .leading, spacing: 12) {
                Text("Up Next").font(.title2.bold())
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(1...5, id: \.self) { number in
                            VStack(alignment: .leading, spacing: 6) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.quaternary)
                                    .frame(width: 104, height: 144)
                                Text("Fixture \(number)").font(.headline)
                                Text("1h 36m left").font(.caption)
                            }
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("geometry.upnext")
        }
    }
}
