#if os(iOS) || os(macOS)
import SwiftUI

/// Shared Now Playing metrics for Phase 2 playback chrome.
public enum InkAmpPlayerMetrics {
    /// Filled play/pause target — comfortably larger than 44pt.
    public static let playButtonSize: CGFloat = 64
    public static let skipButtonSize: CGFloat = 52
    public static let chapterButtonSize: CGFloat = 44
    /// Cover art width as a fraction of available player width (portrait).
    public static let coverWidthFraction: CGFloat = 0.55
    public static let coverCornerRadius: CGFloat = 18
    public static let optionCornerRadius: CGFloat = InkAmpMetrics.controlRadius
}

/// Filled circular play/pause — strongest transport control.
public struct InkAmpPlayerPlayPauseButton: View {
    @Environment(\.colorScheme) private var colorScheme
    private var theme: InkAmpAppTheme { .resolve(for: colorScheme) }

    private let isPlaying: Bool
    private let isLoading: Bool
    private let action: () -> Void

    public init(
        isPlaying: Bool,
        isLoading: Bool = false,
        action: @escaping () -> Void,
    ) {
        self.isPlaying = isPlaying
        self.isLoading = isLoading
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(theme.accent)
                    .frame(
                        width: InkAmpPlayerMetrics.playButtonSize,
                        height: InkAmpPlayerMetrics.playButtonSize,
                    )
                if isLoading {
                    ProgressView()
                        .tint(iconColor)
                } else {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(iconColor)
                        .offset(x: isPlaying ? 0 : 2)
                }
            }
            .frame(
                width: InkAmpPlayerMetrics.playButtonSize,
                height: InkAmpPlayerMetrics.playButtonSize,
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .accessibilityLabel(isLoading ? "Loading" : (isPlaying ? "Pause" : "Play"))
    }

    private var iconColor: Color {
        theme.isDark ? theme.background : Color.white
    }
}

/// Secondary circular skip / chapter control.
public struct InkAmpPlayerSkipButton: View {
    @Environment(\.colorScheme) private var colorScheme
    private var theme: InkAmpAppTheme { .resolve(for: colorScheme) }

    private let systemImage: String
    private let size: CGFloat
    private let help: String
    private let action: () -> Void

    public init(
        systemImage: String,
        size: CGFloat = InkAmpPlayerMetrics.skipButtonSize,
        help: String,
        action: @escaping () -> Void,
    ) {
        self.systemImage = systemImage
        self.size = size
        self.help = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(size >= InkAmpPlayerMetrics.skipButtonSize ? .title2 : .title3)
                .foregroundStyle(theme.primaryText)
                .frame(width: size, height: size)
                .contentShape(Circle())
                .background(
                    Circle()
                        .strokeBorder(theme.border, lineWidth: 1)
                        .background(Circle().fill(theme.surfaceElevated))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
        .help(help)
    }
}

/// Compact option chip (speed / sleep / chapters) used under transport.
public struct InkAmpPlaybackOptionButton<Label: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private var theme: InkAmpAppTheme { .resolve(for: colorScheme) }

    private let selected: Bool
    private let action: () -> Void
    private let label: Label

    public init(
        selected: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label,
    ) {
        self.selected = selected
        self.action = action
        self.label = label()
    }

    public var body: some View {
        Button(action: action) {
            label
                .font(.callout.weight(.semibold))
                .foregroundStyle(selected ? theme.accent : theme.primaryText)
                .frame(width: 38, height: 38)
                .background(
                    RoundedRectangle(
                        cornerRadius: InkAmpPlayerMetrics.optionCornerRadius,
                        style: .continuous,
                    )
                    .fill(
                        selected
                            ? theme.accent.opacity(0.16)
                            : theme.surface
                    )
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: InkAmpPlayerMetrics.optionCornerRadius,
                        style: .continuous,
                    )
                    .strokeBorder(
                        selected ? theme.accent.opacity(0.35) : theme.border,
                        lineWidth: 1,
                    )
                )
        }
        .buttonStyle(.plain)
    }
}

/// Cover / artwork frame for portrait Now Playing.
public struct InkAmpPlayerArtwork<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private var theme: InkAmpAppTheme { .resolve(for: colorScheme) }

    private let maxWidthFraction: CGFloat
    private let content: Content

    public init(
        maxWidthFraction: CGFloat = InkAmpPlayerMetrics.coverWidthFraction,
        @ViewBuilder content: () -> Content,
    ) {
        self.maxWidthFraction = maxWidthFraction
        self.content = content()
    }

    public var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width * maxWidthFraction, proxy.size.height)
            content
                .frame(width: side, height: side)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: InkAmpPlayerMetrics.coverCornerRadius,
                        style: .continuous,
                    )
                )
                .shadow(
                    color: colorScheme == .dark ? .clear : .black.opacity(0.08),
                    radius: 10,
                    y: 3,
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Title + subtitle stack for Now Playing metadata.
public struct InkAmpPlayerMetadata: View {
    @Environment(\.colorScheme) private var colorScheme
    private var theme: InkAmpAppTheme { .resolve(for: colorScheme) }

    private let title: String
    private let subtitle: String?
    private let context: String?
    private let chip: String?

    public init(
        title: String,
        subtitle: String? = nil,
        context: String? = nil,
        chip: String? = nil,
    ) {
        self.title = title
        self.subtitle = subtitle
        self.context = context
        self.chip = chip
    }

    public var body: some View {
        VStack(spacing: 8) {
            if let chip {
                InkAmpChip(chip, selected: false)
            }
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(theme.primaryText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }
            if let context {
                Text(context)
                    .font(.footnote)
                    .foregroundStyle(theme.tertiaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
    }
}
#endif
