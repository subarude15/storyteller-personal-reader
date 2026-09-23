#if os(iOS) || os(macOS)
import SwiftUI

extension Color {
    /// Parses `#RRGGBB` / `RRGGBB`. Shared by app chrome and settings editors.
    init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard cleaned.count == 6 else { return nil }

        var value: UInt64 = 0
        guard Scanner(string: cleaned).scanHexInt64(&value) else { return nil }

        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0

        self = Color(red: r, green: g, blue: b)
    }
}
#endif
