#if os(iOS) || os(macOS)
import SwiftUI

extension EnvironmentValues {
    /// Set by the iOS reader so controls that present their own sheets keep
    /// immersive chrome mounted (unmounting the presenter would dismiss the sheet).
    @Entry var readerChromeSheetReporter: ((UUID, Bool) -> Void)? = nil
}

private struct ReaderChromeSheetReporting: ViewModifier {
    let isPresented: Bool
    @Environment(\.readerChromeSheetReporter) private var report
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, shown in report?(token, shown) }
            .onDisappear { if isPresented { report?(token, false) } }
    }
}

extension View {
    func reportsReaderChromeSheet(_ isPresented: Bool) -> some View {
        modifier(ReaderChromeSheetReporting(isPresented: isPresented))
    }
}
#endif
