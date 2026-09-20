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
    @State private var downloadStates: [String: ResolvedAudiobookDownloadSnapshot] = [:]
    @State private var removeTarget: ResolvedAudiobook?

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
        .task {
            let stream = await ResolvedAudiobookDownloads.shared.updates(for: work.workID)
            for await next in stream {
                downloadStates = next
            }
        }
        .confirmationDialog(
            "Remove this download?",
            isPresented: Binding(
                get: { removeTarget != nil },
                set: { if !$0 { removeTarget = nil } },
            ),
            titleVisibility: .visible,
        ) {
            Button("Remove Download", role: .destructive) {
                guard let removeTarget else { return }
                let target = removeTarget
                self.removeTarget = nil
                Task {
                    try? await ResolvedAudiobookDownloads.shared.remove(
                        workID: work.workID,
                        audiobook: target,
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The book stays in your library. You can stream it again later.")
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
        let snapshot = state(for: result)
        return VStack(alignment: .leading, spacing: 8) {
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
                }
                Spacer(minLength: 0)
            }
            actions(result, snapshot: snapshot)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func actions(
        _ result: ResolvedAudiobook,
        snapshot: ResolvedAudiobookDownloadSnapshot,
    ) -> some View {
        switch snapshot.phase {
            case .preparing, .downloading:
                VStack(alignment: .leading, spacing: 6) {
                    Text(progressLabel(snapshot))
                        .font(.caption.weight(.semibold))
                    if let fraction = snapshot.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                    Button("Cancel", role: .cancel) {
                        Task {
                            await ResolvedAudiobookDownloads.shared.cancel(
                                workID: work.workID,
                                audiobook: result,
                            )
                        }
                    }
                    .buttonStyle(.borderless)
                }
            case .downloaded:
                HStack(spacing: 12) {
                    Button(playTitle(result, downloaded: true)) { play(result) }
                        .buttonStyle(.borderless)
                    Button("Remove Download", role: .destructive) {
                        removeTarget = result
                    }
                    .buttonStyle(.borderless)
                }
            case .failed, .partial:
                VStack(alignment: .leading, spacing: 4) {
                    if let message = snapshot.message, snapshot.phase == .failed {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Button(playTitle(result, downloaded: false)) { play(result) }
                            .buttonStyle(.borderless)
                        Button("Retry Download") { startDownload(result) }
                            .buttonStyle(.borderless)
                    }
                }
            case .notDownloaded:
                downloadActions(result, downloadTitle: "Download", playDownloaded: false)
            @unknown default:
                downloadActions(result, downloadTitle: "Download", playDownloaded: false)
        }
    }

    private func downloadActions(
        _ result: ResolvedAudiobook,
        downloadTitle: String,
        playDownloaded: Bool,
    ) -> some View {
        HStack(spacing: 12) {
            Button(playTitle(result, downloaded: playDownloaded)) { play(result) }
                .buttonStyle(.borderless)
            Button(downloadTitle) { startDownload(result) }
                .buttonStyle(.borderless)
        }
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

    private func playTitle(_ result: ResolvedAudiobook, downloaded: Bool) -> String {
        #if os(iOS)
        if let resume = resume(for: result), !resume.completed {
            return "Resume"
        }
        if downloaded { return "Play Offline" }
        return resume(for: result)?.completed == true ? "Play again" : "Play"
        #else
        return "Open on iPhone to play"
        #endif
    }

    private func progressLabel(_ snapshot: ResolvedAudiobookDownloadSnapshot) -> String {
        if snapshot.phase == .preparing, snapshot.totalChapters == 0 {
            return "Preparing"
        }
        if let fraction = snapshot.fraction, fraction > 0 {
            return "Downloading \(Int((fraction * 100).rounded()))%"
        }
        if snapshot.totalChapters > 0 {
            return "Downloading \(snapshot.completedChapters) of \(snapshot.totalChapters)"
        }
        return "Downloading"
    }

    private func state(for result: ResolvedAudiobook) -> ResolvedAudiobookDownloadSnapshot {
        let key = ResolvedAudiobookIdentity.key(
            workID: work.workID,
            provider: result.provider,
            providerItemID: result.providerItemID,
        )
        return downloadStates[key] ?? ResolvedAudiobookDownloadSnapshot(phase: .notDownloaded)
    }

    private func load() async {
        searching = true
        let local = await ResolvedAudiobookDownloads.shared.offlineResults(workID: work.workID)
        let outcome = await AudiobookResolution.lookup(work: work)
        var merged = outcome.results
        let seen = Set(merged.map(\.id))
        for audiobook in local where !seen.contains(audiobook.id) {
            merged.insert(audiobook, at: 0)
        }
        results = merged
        failure = merged.isEmpty ? outcome.failure : nil
        searching = false
    }

    private func startDownload(_ result: ResolvedAudiobook) {
        Task {
            await ResolvedAudiobookDownloads.shared.start(workID: work.workID, audiobook: result)
        }
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
        Task {
            let local = await ResolvedAudiobookDownloads.shared.playback(
                workID: work.workID,
                audiobook: result,
            )
            guard let metadata = local?.metadata ?? result.playbackMetadata() else {
                playbackMessage = AudiobookResolutionFailure.playbackSourceUnavailable.message
                return
            }
            let saved = resume(for: result)
            let startAt: TimeInterval?
            if let saved, !saved.completed {
                startAt = result.globalTime(
                    chapterIndex: saved.chapterIndex,
                    position: saved.chapterPosition,
                )
            } else {
                startAt = nil
            }
            let playback = ResolvedAudiobookPlayback(
                workID: work.workID,
                provider: result.provider,
                providerItemID: result.providerItemID,
                artworkURL: local?.artworkURL ?? result.artworkURL,
            )
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
