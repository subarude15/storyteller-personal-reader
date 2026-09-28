import Foundation

/// Visual page-turn appearance for paginated ebook reading.
/// Navigation semantics (which page is shown) stay with the Foliate paginator;
/// this value only selects transition appearance.
public enum PageTurnStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case slide
    case curl
    case instant

    public var id: String { rawValue }

    public var label: String {
        switch self {
            case .slide: return "Slide"
            case .curl: return "Curl"
            case .instant: return "Instant"
        }
    }

    /// Decode unknown / missing values as `.slide` so existing installs keep
    /// current reader behavior.
    public static func resolved(from raw: String?) -> PageTurnStyle {
        guard let raw, let value = PageTurnStyle(rawValue: raw) else {
            return .slide
        }
        return value
    }
}
