#if os(iOS)
import SilveranKit
import SwiftUI

extension View {
    /// Choice UI when an imprecise format switch disagrees with a newer destination saved place.
    public func formatSwitchDiscrepancyDialog() -> some View {
        let discrepancy = FormatSwitchPromptState.shared.discrepancy
        return self.confirmationDialog(
            discrepancy.map { "Open \($0.destinationLabel) where?" } ?? "Open where?",
            isPresented: Binding(
                get: { FormatSwitchPromptState.shared.discrepancy != nil },
                set: { if !$0 { FormatSwitchPromptState.shared.cancel() } }
            ),
            titleVisibility: .visible,
        ) {
            if let prompt = discrepancy {
                Button("Approximate location (\(prompt.mappedPercentLabel))") {
                    FormatSwitchPromptState.shared.chooseMapped()
                }
                Button("Use saved \(prompt.destinationLabel) place (\(prompt.destinationPercentLabel))") {
                    FormatSwitchPromptState.shared.chooseDestinationSaved()
                }
                Button("Cancel", role: .cancel) {
                    FormatSwitchPromptState.shared.cancel()
                }
            }
        } message: {
            if let prompt = discrepancy {
                Text(
                    "\(prompt.bookTitle): exact sync wasn’t available (\(prompt.mappingQualityLabel)). Choose the approximate mapped place or this format’s saved location."
                )
            }
        }
    }
}
#endif
