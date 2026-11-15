#if os(iOS) || os(macOS)
import Foundation

#if os(iOS)
import UIKit
#endif

/// Tactile feedback helper for Apple Books–style reader scrubbing, chapter transitions,
/// jump-back navigation, and page bookmarking.
@MainActor
enum ReaderHaptics {
    #if os(iOS)
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let lightImpactGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let rigidImpactGenerator = UIImpactFeedbackGenerator(style: .rigid)
    private static let softImpactGenerator = UIImpactFeedbackGenerator(style: .soft)
    #endif

    static func prepareForScrub() {
        #if os(iOS)
        selectionGenerator.prepare()
        #endif
    }

    static func selectionTick() {
        #if os(iOS)
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
        #endif
    }

    static func chapterBoundaryCrossed() {
        #if os(iOS)
        softImpactGenerator.impactOccurred(intensity: 0.65)
        #endif
    }

    static func jumpNavigation() {
        #if os(iOS)
        lightImpactGenerator.impactOccurred(intensity: 0.78)
        #endif
    }

    static func bookmarkToggled(added: Bool) {
        #if os(iOS)
        if added {
            rigidImpactGenerator.impactOccurred(intensity: 0.85)
        } else {
            lightImpactGenerator.impactOccurred(intensity: 0.55)
        }
        #endif
    }
}
#endif
