#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI

/// Previous Positions / Listening History for Storyteller audiobooks.
/// Shows meaningful listening milestones (not every 5–10s recovery checkpoint).
public struct AudiobookListeningHistoryView: View {
    let bookID: BookID
    let bookTitle: String
    var onResumed: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var milestones: [AudiobookListeningMilestone] = []
    @State private var isLoading = true
    @State private var pendingResume: AudiobookListeningMilestone?
    @State private var showResumeConfirmation = false
    @State private var restoreErrorMessage: String?

    public init(
        bookID: BookID,
        bookTitle: String,
        onResumed: (() -> Void)? = nil,
    ) {
        self.bookID = bookID
        self.bookTitle = bookTitle
        self.onResumed = onResumed
    }

    public var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if milestones.isEmpty {
                    ContentUnavailableView(
                        "No Previous Positions",
                        systemImage: "clock.arrow.circlepath",
                        description: Text(
                            "Pause, seek, or leave the player to save listening positions here."
                        ),
                    )
                } else {
                    List {
                        ForEach(milestones, id: \.timestamp) { milestone in
                            milestoneRow(milestone)
                        }
                    }
                    #if os(iOS)
                    .listStyle(.insetGrouped)
                    #endif
                }
            }
            .navigationTitle("Previous Positions")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if !milestones.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Clear", role: .destructive) {
                            Task {
                                await ProgressSyncActor.shared.clearListeningHistory(for: bookID)
                                milestones = []
                            }
                        }
                    }
                }
            }
            .task { await refresh() }
            .alert("Resume Here?", isPresented: $showResumeConfirmation) {
                Button("Cancel", role: .cancel) { pendingResume = nil }
                Button("Resume Here") {
                    guard let milestone = pendingResume else { return }
                    Task {
                        let result = await AudioSessionActor.shared.restoreListeningPosition(
                            locator: milestone.locator,
                            locationDescription: milestone.locationDescription,
                        )
                        pendingResume = nil
                        switch result {
                            case .success:
                                onResumed?()
                                dismiss()
                            case .noActiveBook:
                                restoreErrorMessage =
                                    "No audiobook is open. Open the book, then try Resume Here again."
                            case .syncRejected:
                                restoreErrorMessage =
                                    "Could not restore that position (conflict with newer listening progress)."
                            case .syncFailed:
                                restoreErrorMessage =
                                    "Could not save the restored position. Check your connection and try again."
                            case .seekFailed:
                                restoreErrorMessage =
                                    "Saved progress, but seeking to that position failed. Try again."
                        }
                    }
                }
            } message: {
                if let milestone = pendingResume {
                    Text(
                        "Jump to \(milestone.locationDescription) (\(milestone.percentLabel)) from \(milestone.humanTimestamp)?"
                    )
                }
            }
            .alert(
                "Restore Failed",
                isPresented: Binding(
                    get: { restoreErrorMessage != nil },
                    set: { if !$0 { restoreErrorMessage = nil } },
                ),
            ) {
                Button("OK", role: .cancel) { restoreErrorMessage = nil }
            } message: {
                Text(restoreErrorMessage ?? "")
            }
        }
        .inkAmpAppThemed()
    }

    @ViewBuilder
    private func milestoneRow(_ milestone: AudiobookListeningMilestone) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(milestone.humanTimestamp)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(milestone.percentLabel)
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(milestone.locationDescription)
                .font(.body)
            Text(formatReason(milestone.reason))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                pendingResume = milestone
                showResumeConfirmation = true
            } label: {
                Label("Resume Here", systemImage: "arrow.counterclockwise")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private func refresh() async {
        isLoading = true
        milestones = await ProgressSyncActor.shared.getListeningHistory(for: bookID)
        isLoading = false
    }

    private func formatReason(_ reason: SyncReason) -> String {
        switch reason {
            case .userPausedPlayback: return "Paused"
            case .userDraggedSeekBar: return "Seek"
            case .userSkippedForward: return "Skipped forward"
            case .userSkippedBackward: return "Skipped back"
            case .userSelectedChapter: return "Chapter change"
            case .userClosedBook: return "Closed"
            case .userRestoredFromHistory: return "Restored from history"
            case .userConfirmedRestart: return "Restarted"
            case .appBackgrounding: return "Backgrounded"
            case .appTerminating: return "App closed"
            default: return reason.rawValue
        }
    }
}

#endif
