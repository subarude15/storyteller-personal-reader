#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI

struct BookRequestSheet: View {
    let work: CanonicalBookWork
    let owned: Set<BookRequestFormat>

    @Environment(\.dismiss) private var dismiss
    @State private var sending = false
    @State private var submission: BookRequestSubmission?
    @State private var providerName: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(work.title)
                        .font(.headline)
                    if let author = work.authors.first, !author.isEmpty {
                        Text(author)
                            .foregroundStyle(.secondary)
                    }
                    if let providerName {
                        Text("Using \(providerName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    formatRow(.ebook)
                    formatRow(.audiobook)
                    Button("Both") { send(missing(from: [.ebook, .audiobook])) }
                        .disabled(sending || missing(from: [.ebook, .audiobook]).isEmpty)
                } header: {
                    Text("Request")
                } footer: {
                    Text(
                        "Request accepted means the server will search. It does not mean the book is downloaded."
                    )
                }
                if sending {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Sending request")
                        }
                    }
                }
                if let submission {
                    Section {
                        if let message = submission.message {
                            Text(message)
                        }
                        ForEach(submission.outcomes, id: \.format) { outcome in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(outcome.format.label)
                                    .font(.subheadline.weight(.semibold))
                                Text(label(outcome.phase))
                                    .font(.subheadline)
                                Text(outcome.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Request")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            let settings = await SettingsActor.shared.config
            let keySaved = await AuthenticationActor.shared.hasLazyLibrarianAPIKey()
            let lazyReady =
                settings.lazyLibrarianEnabled
                && !settings.lazyLibrarianBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && keySaved
            let shelfReady =
                !settings.shelfarrBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !settings.shelfarrAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let chosen = BookRequestRouting.choose(
                preference: .preference(from: settings.bookRequestProvider),
                lazyLibrarianReady: lazyReady,
                shelfarrReady: shelfReady,
            )
            providerName = chosen?.displayName
        }
    }

    private func formatRow(_ format: BookRequestFormat) -> some View {
        HStack {
            Text(format.label)
            Spacer()
            if owned.contains(format) {
                Text("Already in library")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Button("Request") { send([format]) }
                    .disabled(sending)
            }
        }
    }

    private func missing(from formats: [BookRequestFormat]) -> [BookRequestFormat] {
        formats.filter { !owned.contains($0) }
    }

    private func send(_ formats: [BookRequestFormat]) {
        guard !formats.isEmpty else { return }
        sending = true
        submission = nil
        Task {
            let result = await BookRequests.submit(work: work, formats: formats)
            submission = result
            providerName = result.provider?.displayName ?? providerName
            sending = false
        }
    }

    private func label(_ phase: BookRequestPhase) -> String {
        switch phase {
            case .requested: "Requested"
            case .searching: "Searching"
            case .alreadyRequested: "Already requested"
            case .alreadyAvailable: "Already available"
            case .failed: "Failed"
            @unknown default: "Failed"
        }
    }
}
#endif
