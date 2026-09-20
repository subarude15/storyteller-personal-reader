#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI

private struct RequestLibraryPresentationIndexKey: EnvironmentKey {
    static let defaultValue = RequestLibraryPresentationIndex()
}

extension EnvironmentValues {
    var requestLibraryPresentationIndex: RequestLibraryPresentationIndex {
        get { self[RequestLibraryPresentationIndexKey.self] }
        set { self[RequestLibraryPresentationIndexKey.self] = newValue }
    }
}

/// Compact Requests filter next to the existing library sort/filter controls.
struct RequestLibraryFilterChip: View {
    @Binding var filter: RequestLibraryFilter
    let summary: RequestLibraryChipSummary

    var body: some View {
        Menu {
            ForEach(RequestLibraryFilter.allCases, id: \.self) { option in
                Button {
                    filter = option
                } label: {
                    if option == filter {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: summary.showsAttention ? "exclamationmark.triangle" : "tray.full")
                    .font(.caption2.weight(.semibold))
                Text(filter == .all ? "Requests" : filter.label)
                    .font(.caption.weight(.semibold))
                if summary.showsCount {
                    Text("\(summary.activeCount)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            summary.showsAttention ? Color.orange.opacity(0.2) : Color.accentColor.opacity(0.15),
                            in: Capsule(),
                        )
                }
            }
            .foregroundStyle(summary.showsAttention ? Color.orange : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.thinMaterial, in: Capsule())
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = ["Requests"]
        if summary.showsCount {
            parts.append("\(summary.activeCount)")
        }
        if summary.showsAttention {
            parts.append("\(summary.attentionCount) need attention")
        }
        if filter != .all {
            parts.append("filter \(filter.label)")
        }
        return parts.joined(separator: ", ")
    }
}

/// Small cover badge. Separate control so the book-card tap still opens the book.
struct RequestLibraryStatusBadge: View {
    let state: RequestLibraryBadgeState

    var body: some View {
        Label(state.label, systemImage: state.systemImage)
            .font(.system(size: 9, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .accessibilityLabel(state.accessibilityLabel)
    }

    private var foreground: Color {
        switch state.kind {
            case .needsAttention: .orange
            case .inProgress: .primary
            case .ready: .green
        }
    }

    private var background: Color {
        switch state.kind {
            case .needsAttention: Color.orange.opacity(0.18)
            case .inProgress: Color.primary.opacity(0.08)
            case .ready: Color.green.opacity(0.18)
        }
    }
}

struct RequestLibraryStatusBadgeLink: View {
    let book: BookMetadata
    @Environment(\.requestLibraryPresentationIndex) private var index

    var body: some View {
        if let state = index.badge(for: book) {
            let destination = RequestActivityLibraryNavigation.badge(book: book, index: index)
            NavigationLink {
                RequestActivityView(initialRequestID: destination.requestID)
            } label: {
                RequestLibraryStatusBadge(state: state)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 6)
            .accessibilityHint("Opens request activity")
        }
    }
}

struct RequestLibraryPendingSection: View {
    let rows: [RequestLibraryPendingRow]

    var body: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Requested but not yet in library")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(rows) { row in
                    NavigationLink {
                        RequestActivityView(
                            initialRequestID: RequestActivityLibraryNavigation.pendingRow(row).requestID
                        )
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(row.author.isEmpty ? row.formatsLabel : "\(row.author) · \(row.formatsLabel)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            RequestLibraryStatusBadge(state: row.badge)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
#endif
