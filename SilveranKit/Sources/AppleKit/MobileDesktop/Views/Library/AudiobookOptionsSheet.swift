#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI

/// Shown only after the user asks for audiobook options for one selected work.
struct AudiobookOptionsSheet: View {
    let work: CanonicalBookWork
    let book: BookMetadata

    @Environment(\.dismiss) private var dismiss
    @State private var results: [ResolvedAudiobook] = []
    @State private var failure: AudiobookResolutionFailure?
    @State private var searching = true
    @State private var playbackMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if searching {
                    ProgressView("Searching audiobook providers")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let failure, results.isEmpty {
                    status(failure.message)
                } else if results.isEmpty {
                    status("No audiobook found for this book.")
                } else {
                    List(results) { result in
                        row(result)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Audiobook Options")
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
            await load()
        }
        .alert(
            "Audiobook",
            isPresented: Binding(
                get: { playbackMessage != nil },
                set: { if !$0 { playbackMessage = nil } },
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(playbackMessage ?? AudiobookResolutionFailure.playbackSourceUnavailable.message)
        }
    }

    private func status(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Audiobook Options", systemImage: "headphones")
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ result: ResolvedAudiobook) -> some View {
        Button {
            play(result)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                artwork(result.artworkURL)
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.provider.displayName)
                        .font(.subheadline.weight(.semibold))
                    if let narrator = result.narrator, !narrator.isEmpty {
                        Text("Narrated by \(narrator)")
                            .font(.subheadline)
                    }
                    Text(detailLine(result))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(result.match.confidence.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(result.match.confidence == .weak ? .orange : .secondary)
                    if result.match.confidence == .weak {
                        Text(result.match.reasons.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(playTitle(result))
                        .font(.caption.weight(.semibold))
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(result))
    }

    private func artwork(_ url: URL?) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    Image(systemName: "headphones")
                        .foregroundStyle(.secondary)
            }
        }
        .frame(width: 54, height: 54)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func detailLine(_ result: ResolvedAudiobook) -> String {
        var parts: [String] = []
        if let duration = result.duration, duration > 0 {
            parts.append(Self.durationText(duration))
        }
        if let language = result.language, !language.isEmpty {
            parts.append(language)
        }
        if result.chapterCount > 0 {
            let noun = result.chapterCount == 1 ? "chapter" : "chapters"
            parts.append("\(result.chapterCount) \(noun)")
        }
        return parts.isEmpty ? result.title : parts.joined(separator: " · ")
    }

    private func playTitle(_ result: ResolvedAudiobook) -> String {
        #if os(iOS)
        guard let resume = resume(for: result) else { return "Play" }
        return resume.completed ? "Play again" : "Resume"
        #else
        return "Open on iPhone to play"
        #endif
    }

    private func accessibilityLabel(_ result: ResolvedAudiobook) -> String {
        var parts = [result.provider.displayName, result.title]
        if let narrator = result.narrator { parts.append(narrator) }
        parts.append(result.match.confidence.label)
        return parts.joined(separator: ", ")
    }

    private func load() async {
        searching = true
        let outcome = await AudiobookResolution.lookup(work: work)
        results = outcome.results
        failure = outcome.failure
        searching = false
    }

    private func resume(for result: ResolvedAudiobook) -> AudiobookResumeState? {
        AudiobookResumeStore.shared.state(
            workID: work.workID,
            provider: result.provider,
            providerItemID: result.providerItemID,
        )
    }

    private func play(_ result: ResolvedAudiobook) {
        #if os(iOS)
        guard let metadata = result.playbackMetadata() else {
            playbackMessage = AudiobookResolutionFailure.playbackSourceUnavailable.message
            return
        }
        let saved = resume(for: result)
        let startAt: TimeInterval?
        if let saved, !saved.completed {
            startAt = result.globalTime(chapterIndex: saved.chapterIndex, position: saved.chapterPosition)
        } else {
            startAt = nil
        }
        let playback = ResolvedAudiobookPlayback(
            workID: work.workID,
            provider: result.provider,
            providerItemID: result.providerItemID,
            artworkURL: result.artworkURL,
        )
        Task {
            await ResolvedAudiobookLaunch.shared.arm(
                ResolvedAudiobookLaunch.Context(
                    book: book,
                    metadata: metadata,
                    playback: playback,
                    startAt: startAt,
                )
            )
            PlayerPresenter.shared.present(
                PlayerBookData(
                    metadata: book,
                    localMediaPath: nil,
                    category: .audio,
                    resolvedAudiobookID: result.id,
                )
            )
            dismiss()
        }
        #else
        playbackMessage = "Open this book on iPhone to play the audiobook."
        #endif
    }

    private static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours) hr \(minutes) min"
        }
        return "\(max(minutes, 1)) min"
    }
}
#endif
