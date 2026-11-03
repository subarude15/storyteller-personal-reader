import Foundation

/// Curated reader font families and one-tap typography/layout presets.
public enum ReaderTypographyPolicy {
    public struct BuiltInFontOption: Identifiable, Equatable, Sendable {
        public let id: String
        public let label: String
        public let sampleFontName: String?
        public let isSerif: Bool

        public init(
            id: String,
            label: String,
            sampleFontName: String? = nil,
            isSerif: Bool = true
        ) {
            self.id = id
            self.label = label
            self.sampleFontName = sampleFontName
            self.isSerif = isSerif
        }
    }

    public static let builtInFontOptions: [BuiltInFontOption] = [
        BuiltInFontOption(
            id: "System Default",
            label: "System Default",
            sampleFontName: nil,
            isSerif: true
        ),
        BuiltInFontOption(
            id: "Charter",
            label: "Charter",
            sampleFontName: "Charter-Roman",
            isSerif: true
        ),
        BuiltInFontOption(
            id: "Georgia",
            label: "Georgia",
            sampleFontName: "Georgia",
            isSerif: true
        ),
        BuiltInFontOption(
            id: "Palatino",
            label: "Palatino",
            sampleFontName: "Palatino-Roman",
            isSerif: true
        ),
        BuiltInFontOption(
            id: "Baskerville",
            label: "Baskerville",
            sampleFontName: "Baskerville",
            isSerif: true
        ),
        BuiltInFontOption(
            id: "Iowan Old Style",
            label: "Iowan Old Style",
            sampleFontName: "IowanOldStyle-Roman",
            isSerif: true
        ),
        BuiltInFontOption(
            id: "Avenir Next",
            label: "Avenir Next",
            sampleFontName: "AvenirNext-Regular",
            isSerif: false
        ),
        BuiltInFontOption(
            id: "serif",
            label: "Classic Serif",
            sampleFontName: "TimesNewRomanPSMT",
            isSerif: true
        ),
        BuiltInFontOption(
            id: "sans-serif",
            label: "Clean Sans",
            sampleFontName: nil,
            isSerif: false
        ),
        BuiltInFontOption(
            id: "monospace",
            label: "Monospace",
            sampleFontName: "Menlo-Regular",
            isSerif: false
        ),
    ]

    public static func isBuiltInFont(_ fontFamily: String) -> Bool {
        builtInFontOptions.contains { $0.id == fontFamily }
    }

    /// Formats a font family identifier into a valid CSS `font-family` value.
    public static func cssFontFamily(for fontFamily: String) -> String {
        let trimmed = fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "System Default" else {
            return "serif"
        }
        let genericKeywords: Set<String> = ["serif", "sans-serif", "monospace", "ui-serif", "ui-sans-serif", "system-ui"]
        if genericKeywords.contains(trimmed.lowercased()) {
            return trimmed
        }
        if trimmed.contains(",") || trimmed.contains("\"") || trimmed.contains("'") {
            return trimmed
        }
        if trimmed.contains(" ") {
            return "\"\(trimmed)\", serif"
        }
        return trimmed
    }

    public struct LayoutPreset: Identifiable, Equatable, Sendable {
        public let id: String
        public let title: String
        public let subtitle: String
        public let systemImage: String
        public let lineSpacing: Double
        public let marginLeftRight: Double
        public let marginTopBottom: Double
        public let wordSpacing: Double
        public let letterSpacing: Double

        public init(
            id: String,
            title: String,
            subtitle: String,
            systemImage: String,
            lineSpacing: Double,
            marginLeftRight: Double,
            marginTopBottom: Double,
            wordSpacing: Double = 0.0,
            letterSpacing: Double = 0.0
        ) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.systemImage = systemImage
            self.lineSpacing = lineSpacing
            self.marginLeftRight = marginLeftRight
            self.marginTopBottom = marginTopBottom
            self.wordSpacing = wordSpacing
            self.letterSpacing = letterSpacing
        }
    }

    public static let layoutPresets: [LayoutPreset] = [
        LayoutPreset(
            id: "compact",
            title: "Compact",
            subtitle: "More words per page",
            systemImage: "arrow.down.right.and.arrow.up.left",
            lineSpacing: 1.2,
            marginLeftRight: 4,
            marginTopBottom: 4,
            wordSpacing: 0.0,
            letterSpacing: 0.0
        ),
        LayoutPreset(
            id: "balanced",
            title: "Balanced",
            subtitle: "Default book proportions",
            systemImage: "book.pages",
            lineSpacing: 1.4,
            marginLeftRight: 6,
            marginTopBottom: 8,
            wordSpacing: 0.0,
            letterSpacing: 0.0
        ),
        LayoutPreset(
            id: "relaxed",
            title: "Relaxed",
            subtitle: "Generous line & page breathing room",
            systemImage: "text.line.first.and.arrowtriangle.forward",
            lineSpacing: 1.6,
            marginLeftRight: 10,
            marginTopBottom: 10,
            wordSpacing: 0.1,
            letterSpacing: 0.01
        ),
        LayoutPreset(
            id: "editorial",
            title: "Editorial",
            subtitle: "Wide margins & airy leading",
            systemImage: "doc.richtext",
            lineSpacing: 1.8,
            marginLeftRight: 14,
            marginTopBottom: 12,
            wordSpacing: 0.1,
            letterSpacing: 0.02
        ),
    ]

    /// Returns the preset whose spacing and margin parameters match the given values within tolerance.
    public static func activePreset(
        lineSpacing: Double,
        marginLeftRight: Double,
        marginTopBottom: Double,
        wordSpacing: Double,
        letterSpacing: Double
    ) -> LayoutPreset? {
        layoutPresets.first { preset in
            abs(preset.lineSpacing - lineSpacing) < 0.05
                && abs(preset.marginLeftRight - marginLeftRight) < 0.5
                && abs(preset.marginTopBottom - marginTopBottom) < 0.5
                && abs(preset.wordSpacing - wordSpacing) < 0.05
                && abs(preset.letterSpacing - letterSpacing) < 0.005
        }
    }
}
