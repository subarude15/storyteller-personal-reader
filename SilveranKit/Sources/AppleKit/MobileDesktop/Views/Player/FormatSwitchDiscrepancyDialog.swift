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
                Button("Continue from here (\(prompt.mappedPercentLabel))") {
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
                    "\(prompt.bookTitle): this format’s saved place differs from where you are. Exact alignment wasn’t available, so choose which position to keep."
                )
            }
        }
    }
}
#endif
