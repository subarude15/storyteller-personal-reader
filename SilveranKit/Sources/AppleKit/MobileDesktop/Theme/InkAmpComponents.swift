#if os(iOS) || os(macOS)
import SwiftUI

/// Flat editorial card surface for Phase 1 library / Home chrome.
public struct InkAmpCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private var theme: InkAmpAppTheme { .resolve(for: colorScheme) }

    private let elevated: Bool
    private let feature: Bool
    private let content: Content

    public init(
        elevated: Bool = true,
        feature: Bool = false,
        @ViewBuilder content: () -> Content,
    ) {
        self.elevated = elevated
        self.feature = feature
        self.content = content()
    }

    private var radius: CGFloat {
        feature ? InkAmpMetrics.featureCardRadius : InkAmpMetrics.cardRadius
    }

    public var body: some View {
        content
            .padding(InkAmpMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(theme.border.opacity(colorScheme == .dark ? 0.9 : 0.7), lineWidth: 1)
            )
            .shadow(
                color: colorScheme == .dark
                    ? .clear
                    : .black.opacity(elevated ? 0.06 : 0),
                radius: elevated ? 8 : 0,
                y: elevated ? 2 : 0,
            )
    }

    private var fill: Color {
        elevated ? theme.surfaceElevated : theme.surface
    }
}

/// Semibold section label + optional trailing action.
public struct InkAmpSectionHeader: View {
    @Environment(\.colorScheme) private var colorScheme
    private var theme: InkAmpAppTheme { .resolve(for: colorScheme) }

    private let title: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(
        _ title: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
    ) {
        self.title = title
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.primaryText)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(theme.accent)
                    .frame(minHeight: InkAmpMetrics.minHitTarget)
            }
        }
    }
}

/// Compact capsule chip for filters / status.
public struct InkAmpChip: View {
    @Environment(\.colorScheme) private var colorScheme
    private var theme: InkAmpAppTheme { .resolve(for: colorScheme) }

    private let title: String
    private let selected: Bool
    private let action: (() -> Void)?

    public init(_ title: String, selected: Bool = false, action: (() -> Void)? = nil) {
        self.title = title
        self.selected = selected
        self.action = action
    }

    public var body: some View {
        let label = Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(selected ? theme.surfaceElevated : theme.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(selected ? theme.accent : theme.surface)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(selected ? Color.clear : theme.border, lineWidth: 1)
            )

        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
                .frame(minHeight: InkAmpMetrics.minHitTarget)
        } else {
            label
        }
    }
}

/// Themed progress bar — Carmin (light) / Tangerine (dark).
public struct InkAmpProgressBar: View {
    @Environment(\.colorScheme) private var colorScheme
    private var theme: InkAmpAppTheme { .resolve(for: colorScheme) }

    private let progress: Double
    private let height: CGFloat

    public init(progress: Double, height: CGFloat = 4) {
        self.progress = progress
        self.height = height
    }

    /// Fill width for the accent capsule. Zero progress must not paint a residual dot.
    public static func fillWidth(progress: Double, totalWidth: CGFloat) -> CGFloat {
        let clamped = min(max(progress, 0), 1)
        guard clamped > 0 else { return 0 }
        return totalWidth * clamped
    }

    public var body: some View {
        GeometryReader { proxy in
            let fill = Self.fillWidth(progress: progress, totalWidth: proxy.size.width)
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(theme.progress.opacity(0.18))
                if fill > 0 {
                    Capsule(style: .continuous)
                        .fill(theme.progress)
                        .frame(width: fill)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Filled primary CTA using theme accent.
public struct InkAmpPrimaryButton: View {
    @Environment(\.colorScheme) private var colorScheme
    private var theme: InkAmpAppTheme { .resolve(for: colorScheme) }

    private let title: String
    private let action: () -> Void

    public init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(theme.isDark ? theme.background : Color.white)
                .frame(maxWidth: .infinity)
                .frame(minHeight: InkAmpMetrics.minHitTarget)
                .padding(.horizontal, 16)
                .background(
                    RoundedRectangle(cornerRadius: InkAmpMetrics.controlRadius, style: .continuous)
                        .fill(theme.accent)
                )
        }
        .buttonStyle(.plain)
    }
}

/// Applies themed surface fill + continuous clip + optional border / light shadow.
public struct InkAmpSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    private var theme: InkAmpAppTheme { .resolve(for: colorScheme) }

    private let elevated: Bool
    private let radius: CGFloat
    private let bordered: Bool

    public init(
        elevated: Bool = true,
        radius: CGFloat = InkAmpMetrics.cardRadius,
        bordered: Bool = true,
    ) {
        self.elevated = elevated
        self.radius = radius
        self.bordered = bordered
    }

    public func body(content: Content) -> some View {
        content
            .background(
                (elevated ? theme.surfaceElevated : theme.surface),
                in: RoundedRectangle(cornerRadius: radius, style: .continuous),
            )
            .overlay {
                if bordered {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(
                            theme.border.opacity(colorScheme == .dark ? 0.95 : 0.75),
                            lineWidth: 1,
                        )
                }
            }
            .shadow(
                color: colorScheme == .dark ? .clear : .black.opacity(elevated ? 0.08 : 0),
                radius: elevated ? 10 : 0,
                y: elevated ? 3 : 0,
            )
    }
}

extension View {
    public func inkAmpSurface(
        elevated: Bool = true,
        radius: CGFloat = InkAmpMetrics.cardRadius,
        bordered: Bool = true,
    ) -> some View {
        modifier(InkAmpSurfaceModifier(elevated: elevated, radius: radius, bordered: bordered))
    }
}
#endif
