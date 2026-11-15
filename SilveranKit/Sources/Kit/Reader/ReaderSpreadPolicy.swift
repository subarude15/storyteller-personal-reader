import Foundation

/// iPad landscape two-page spread. Platform-free so thresholds and geometry stay testable.
public enum ReaderSpreadPolicy {
    public static let settingKey = "reader.twoPagesInLandscape"
    public static let minimumWidth: Double = 1000
    public static let outerMargin: Double = 48
    public static let gutter: Double = 32
    public static let hairlineOpacity = 0.06
    /// Spine shadow on each side of the hairline; it overlaps the 32pt text gutter.
    public static let spineShadowWidth: Double = 24

    /// `width`/`height` must be the measured reader container (after the iPad audio sidebar), not the screen.
    public static func showsSpread(
        enabled: Bool,
        regularWidth: Bool,
        scrolling: Bool,
        width: Double,
        height: Double
    ) -> Bool {
        enabled && regularWidth && !scrolling && width > height && width >= minimumWidth
    }

    public static func pageWidth(containerWidth: Double) -> Double {
        (containerWidth - 2 * outerMargin - gutter) / 2
    }

    /// Rendered pages shown together. Index 0 is the blank verso that puts the cover on the recto;
    /// an odd final page has no partner (nil renders blank).
    public static func pair(containing page: Int, pageCount: Int) -> (left: Int, right: Int?) {
        let left = max(0, page) / 2 * 2
        return (left, left + 1 < pageCount ? left + 1 : nil)
    }

    public static func spineOpacity(isDark: Bool) -> Double {
        isDark ? 0.30 : 0.10
    }

    /// Sepia and light themes count as light; anything below mid perceived brightness is dark.
    public static func isDark(backgroundHex: String) -> Bool {
        let hex = backgroundHex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard hex.count >= 6, let value = UInt32(hex.prefix(6), radix: 16) else { return false }
        let r = Double((value >> 16) & 0xFF), g = Double((value >> 8) & 0xFF), b = Double(value & 0xFF)
        return (r * 299 + g * 587 + b * 114) / 1000 < 128
    }
}
