#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI

struct LazyLibrarianMatchReviewSheet: View {
    let candidates: [LazyLibrarianCandidate]
    var onSelect: (LazyLibrarianCandidate) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pending: LazyLibrarianCandidate?

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(candidates.enumerated()), id: \.offset) { _, candidate in
                    Button {
                        pending = candidate
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidate.title.isEmpty ? "Untitled" : candidate.title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            if !candidate.author.isEmpty {
                                Text(candidate.author)
                                    .foregroundStyle(.secondary)
                            }
                            let meta = metaLine(candidate)
                            if !meta.isEmpty {
                                Text(meta)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Review matches")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .confirmationDialog(
                "Queue this match?",
                isPresented: Binding(
                    get: { pending != nil },
                    set: { if !$0 { pending = nil } },
                ),
                titleVisibility: .visible,
                presenting: pending,
            ) { candidate in
                Button("Use this match") {
                    pending = nil
                    onSelect(candidate)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: { candidate in
                Text(confirmLine(candidate))
            }
        }
    }

    private func metaLine(_ candidate: LazyLibrarianCandidate) -> String {
        var parts: [String] = []
        if let year = candidate.year, !year.isEmpty {
            parts.append(year)
        }
        if let isbn = candidate.isbn, !isbn.isEmpty {
            parts.append("ISBN \(isbn)")
        } else if let work = candidate.openLibraryWorkID, !work.isEmpty {
            parts.append(work)
        }
        return parts.joined(separator: " · ")
    }

    private func confirmLine(_ candidate: LazyLibrarianCandidate) -> String {
        if candidate.author.isEmpty { return candidate.title }
        return "\(candidate.title) — \(candidate.author)"
    }
}

struct LazyLibrarianMatchActionButtons: View {
    let item: RequestActivityItem
    var isBusy: Bool
    var resolving: Bool
    var onReview: () -> Void
    var onUseBest: () -> Void

    var body: some View {
        if LazyLibrarianMatcher.canReview(item) {
            Button {
                onReview()
            } label: {
                Label("Review matches", systemImage: "list.bullet")
            }
            .disabled(isBusy)
            if LazyLibrarianMatcher.canUseBest(item) {
                Button {
                    onUseBest()
                } label: {
                    if resolving {
                        Label("Resolving…", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("Use best match", systemImage: "checkmark.circle")
                    }
                }
                .disabled(isBusy)
            }
        }
    }
}
#endif
