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
    @State private var displayContext: AudiobookListeningHistoryDisplayContext?
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
                            case .invalidLocator:
                                restoreErrorMessage =
                                    "That saved position is not valid for the open audiobook."
                            case .sessionReplaced:
                                restoreErrorMessage =
                                    "The audiobook session changed during restore. Try again."
                            case .seekFailed:
                                restoreErrorMessage =
                                    "Could not seek to that position. Progress was not changed."
                            case .syncRejected:
                                restoreErrorMessage =
                                    "Reached the position, but it conflicted with newer listening progress."
                            case .syncFailed:
                                restoreErrorMessage =
                                    "Reached the position, but saving progress failed. Try again."
                        }
                    }
                }
            } message: {
                if let milestone = pendingResume {
                    Text(resumeConfirmationMessage(for: milestone))
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
        let dayTime = AudiobookListeningHistoryFormatting.relativeDayTime(
            epochMillis: milestone.timestamp
        )
        let exactTime = AudiobookListeningHistoryFormatting.formatPositionTimestamp(
            AudiobookListeningHistoryFormatting.exactPositionSeconds(
                locator: milestone.locator,
                totalProgression: milestone.totalProgression,
                context: displayContext,
            )
        )
        let fallbackLocation = AudiobookListeningHistoryFormatting.fallbackLocationLabel(
            milestone.locationDescription
        )

        VStack(alignment: .leading, spacing: 6) {
            Text(dayTime)
                .font(.subheadline.weight(.semibold))
            if let exactTime {
                Text(exactTime)
                    .font(.body.monospacedDigit().weight(.medium))
                    .accessibilityLabel("Position \(exactTime)")
            } else if !fallbackLocation.isEmpty {
                Text(fallbackLocation)
                    .font(.body)
            }
            Text(formatReason(milestone.reason))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(milestone.percentLabel)
                .font(.caption.monospacedDigit())
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

    private func resumeConfirmationMessage(for milestone: AudiobookListeningMilestone) -> String {
        let dayTime = AudiobookListeningHistoryFormatting.relativeDayTime(
            epochMillis: milestone.timestamp
        )
        if let exact = AudiobookListeningHistoryFormatting.formatPositionTimestamp(
            AudiobookListeningHistoryFormatting.exactPositionSeconds(
                locator: milestone.locator,
                totalProgression: milestone.totalProgression,
                context: displayContext,
            )
        ) {
            return "Jump to \(exact) (\(milestone.percentLabel)) from \(dayTime)?"
        }
        let location = AudiobookListeningHistoryFormatting.fallbackLocationLabel(
            milestone.locationDescription
        )
        if location.isEmpty {
            return "Jump to \(milestone.percentLabel) from \(dayTime)?"
        }
        return "Jump to \(location) (\(milestone.percentLabel)) from \(dayTime)?"
    }

    private func refresh() async {
        isLoading = true
        displayContext = await AudioSessionActor.shared.listeningHistoryDisplayContext()
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
