#if os(iOS) || os(macOS)
import SwiftUI

struct BookFormatLinkSheet: View {
    let item: BookMetadata

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            BookFormatLinkRoot(item: item)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
    }
}

struct BookFormatLinkRoot: View {
    let item: BookMetadata

    @Environment(MediaViewModel.self) private var mediaViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var startAlignment = false
    @State private var isSubmitting = false
    @State private var submittingMerge = false
    @State private var errorMessage: String?
    @State private var showUnlinkConfirm = false
    @State private var resultAlignment: ReadaloudAlignment?
    @State private var mergeStatus: StorytellerBookMergeStatus?

    private var currentItem: BookMetadata {
        mediaViewModel.library.bookMetaData.first { $0.id == item.id } ?? item
    }

    private var members: [BookMetadata] {
        mediaViewModel.formatGroupMembers(for: currentItem)
    }

    private var activeLink: BookFormatLink? {
        mediaViewModel.formatLinks.first { !$0.removed && $0.members.contains(currentItem.id) }
    }

    private var isLinked: Bool {
        activeLink != nil
    }

    private var candidates: [BookFormatCandidate] {
        BookFormatMatcher.candidates(
            for: currentItem,
            in: mediaViewModel.library.bookMetaData,
            links: mediaViewModel.formatLinks,
            query: query,
        )
    }

    var body: some View {
        Group {
            if let mergeStatus {
                mergeResultView(mergeStatus)
            } else if let resultAlignment {
                resultView(resultAlignment)
            } else if isLinked {
                manageView
            } else {
                picker
            }
        }
        .navigationTitle("Book formats")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var picker: some View {
        List {
            Section {
                Text(
                    "Choose the other format of this book. Likely matches are listed first. Nothing is linked until you confirm."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    "Choose the other format of this book. Likely matches are listed first. Nothing is linked until you confirm."
                )
            }
            if candidates.isEmpty {
                ContentUnavailableView(
                    "No matching formats",
                    systemImage: "books.vertical",
                    description: Text(
                        "Look for an e-book, audiobook, or Readaloud of this title that isn't already linked. Podcasts are not listed."
                    ),
                )
            } else {
                Section("Library") {
                    ForEach(candidates) { candidate in
                        NavigationLink {
                            BookFormatLinkConfirmationView(
                                current: currentItem,
                                other: candidate.book,
                                startAlignment: $startAlignment,
                                isSubmitting: $isSubmitting,
                                submittingMerge: $submittingMerge,
                                errorMessage: $errorMessage,
                                canMerge: canMerge(candidate.book),
                                onConfirm: { confirm(candidate.book) },
                                onMerge: { merge(candidate.book) },
                            )
                        } label: {
                            BookFormatCandidateRow(candidate: candidate)
                        }
                        .disabled(isSubmitting)
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Title, author, or series")
    }

    private var manageView: some View {
        let alignment = BookFormatAlignment.assess(members)
        return List {
            Section("Linked formats") {
                ForEach(members) { member in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(member.title)
                            .font(.headline)
                        Text(BookFormatTexts.authorLine(for: member))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(BookFormatTexts.badges(for: member).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(BookFormatTexts.editionSummary(for: member))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let activeLink, activeLink.members.count > members.count {
                    Text("One linked record is no longer in the library. You can still unlink. Nothing was deleted.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Readaloud") {
                Text(alignment.message)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                if alignment.canRetry {
                    Button("Retry Readaloud") {
                        retry()
                    }
                    .disabled(isSubmitting)
                }
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.primary)
                        .accessibilityLabel(errorMessage)
                }
            }
            Section {
                Button("Unlink formats", role: .destructive) {
                    showUnlinkConfirm = true
                }
                .disabled(isSubmitting)
            } footer: {
                Text("Unlinking separates the library cards. Neither book or its files are deleted.")
            }
        }
        .confirmationDialog(
            "Unlink these formats?",
            isPresented: $showUnlinkConfirm,
            titleVisibility: .visible,
        ) {
            Button("Unlink formats", role: .destructive) {
                Task { await unlink() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The books stay in your library. Only the association is removed.")
        }
    }

    private func resultView(_ alignment: ReadaloudAlignment) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Formats linked")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(alignment.message)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Text("Reading and listening progress were left on their own records.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func canMerge(_ other: BookMetadata) -> Bool {
        StorytellerBookMergeEligibility.isEligible(currentItem, other)
            && mediaViewModel.uploadPermittedSourceIDs.contains(currentItem.sourceID)
    }

    private func mergeResultView(_ status: StorytellerBookMergeStatus) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(status.headline)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(status.detail)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            if let warning = status.migrationWarning {
                Text(warning)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func confirm(_ other: BookMetadata) {
        guard !isSubmitting else { return }
        isSubmitting = true
        submittingMerge = false
        errorMessage = nil
        Task {
            let outcome = await mediaViewModel.linkBookFormat(
                other,
                to: currentItem,
                startAlignment: startAlignment,
            )
            isSubmitting = false
            switch outcome {
                case .linked(_, let alignment):
                    resultAlignment = alignment
                    errorMessage = nil
                case .failed(let failure):
                    errorMessage = failure.message(action: .link)
                case .unlinked, .alignment, .merged:
                    errorMessage = BookFormatLinkFailure.serverRejected.message(action: .link)
            }
        }
    }

    private func merge(_ other: BookMetadata) {
        guard !isSubmitting else { return }
        isSubmitting = true
        submittingMerge = true
        errorMessage = nil
        Task {
            let outcome = await mediaViewModel.mergeBookFormats(other, into: currentItem)
            isSubmitting = false
            submittingMerge = false
            switch outcome {
                case .merged(_, let status):
                    mergeStatus = status
                    errorMessage = nil
                case .failed(let failure):
                    errorMessage = failure.message(action: .merge)
                case .linked, .unlinked, .alignment:
                    errorMessage = BookFormatLinkFailure.serverRejected.message(action: .merge)
            }
        }
    }

    private func unlink() {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            let outcome = await mediaViewModel.unlinkBookFormats(currentItem)
            isSubmitting = false
            switch outcome {
                case .unlinked:
                    errorMessage = nil
                    dismiss()
                case .failed(let failure):
                    errorMessage = failure.message(action: .unlink)
                case .linked, .alignment, .merged:
                    errorMessage = BookFormatLinkFailure.serverRejected.message(action: .unlink)
            }
        }
    }

    private func retry() {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            let outcome = await mediaViewModel.retryFormatReadaloud(for: currentItem)
            isSubmitting = false
            switch outcome {
                case .alignment(let alignment):
                    resultAlignment = alignment
                case .failed(let failure):
                    errorMessage = failure.message(action: .retry)
                case .linked, .unlinked, .merged:
                    errorMessage = BookFormatLinkFailure.serverRejected.message(action: .retry)
            }
        }
    }
}

private struct BookFormatCandidateRow: View {
    let candidate: BookFormatCandidate

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BookDetailCoverArtwork(item: candidate.book, height: 72, cornerRadius: 6)
                .frame(width: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(candidate.book.title)
                    .font(.headline)
                Text(BookFormatTexts.authorLine(for: candidate.book))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(candidate.editionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(candidate.badges, id: \.self) { badge in
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Shows a confirmation screen. Does not link yet.")
    }

    private var accessibilityLabel: String {
        let badges = candidate.badges.joined(separator: ", ")
        return
            "\(candidate.book.title), \(BookFormatTexts.authorLine(for: candidate.book)), \(badges), \(candidate.editionSummary)"
    }
}

private struct BookFormatLinkConfirmationView: View {
    let current: BookMetadata
    let other: BookMetadata
    @Binding var startAlignment: Bool
    @Binding var isSubmitting: Bool
    @Binding var submittingMerge: Bool
    @Binding var errorMessage: String?
    let canMerge: Bool
    let onConfirm: () -> Void
    let onMerge: () -> Void

    @State private var showMergeConfirm = false

    private var confirmation: BookFormatLinkConfirmation {
        BookFormatAlignment.confirmation(current: current, other: other)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(confirmation.title)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(confirmation.body)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                if confirmation.alignment.canStart {
                    Toggle("Start Readaloud alignment", isOn: $startAlignment)
                        .disabled(isSubmitting)
                        .accessibilityHint(
                            "Asks Storyteller to queue alignment. The book is not marked ready until Storyteller says so."
                        )
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.body)
                        .accessibilityLabel(errorMessage)
                }
                Button(isSubmitting && !submittingMerge ? "Linking…" : "Link formats") {
                    onConfirm()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting)
                .accessibilityHint("Saves the association on Storyteller. Does not delete either book.")
                if canMerge {
                    Button {
                        showMergeConfirm = true
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                submittingMerge
                                    ? "Starting Read & Listen…"
                                    : StorytellerBookMergeTexts.mergeTitle
                            )
                            if !submittingMerge {
                                Text(StorytellerBookMergeTexts.mergeSubtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSubmitting)
                    .accessibilityHint(
                        "Shows a warning. Storyteller will combine both records if you confirm."
                    )
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Confirm link")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .confirmationDialog(
            StorytellerBookMergeTexts.destructiveTitle,
            isPresented: $showMergeConfirm,
            titleVisibility: .visible,
        ) {
            Button(StorytellerBookMergeTexts.confirmAction, role: .destructive) {
                onMerge()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(StorytellerBookMergeTexts.destructiveBody)
        }
    }
}
#endif
