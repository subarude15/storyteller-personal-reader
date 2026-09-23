import Foundation

/// Canonical ink+amp brand hex values shared by Home Screen widgets and app chrome.
///
/// Keep widget tiles and `InkAmpAppTheme` pointed at these constants so the six
/// approved brand colors cannot drift between targets.
public enum InkAmpBrandPalette: Sendable {
    public static let aqua = "#95D9C0"
    public static let blanc = "#FFFFFF"
    public static let carmin = "#D41F26"
    public static let tangerine = "#F58F20"
    public static let leafGreen = "#467434"
    public static let seaGrey = "#363636"
}
