#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

public struct DownloadsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var jobs: [ManualDownloadJob] = []
    @State private var busyID: String?
    @State private var isRefreshing = false
    @State private var showManualAdd = false

    private var buckets: ManualDownloadBuckets {
        ManualDownloadBuckets.partition(jobs)
    }

    public init() {}

    public var body: some View {
        List {
            Section {
                Button {
                    showManualAdd = true
                } label: {
                    Label("Add Download", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("downloads-add-manual")
            }

            if jobs.isEmpty {
                Section {
                    Text("No manual downloads yet")
                        .foregroundStyle(.secondary)
                    Text("Paste a magnet or send a Manual Search result to the NAS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                jobSection("Active", buckets.active)
                jobSection("Failed", buckets.failed)
                jobSection("Recent", buckets.recent)
            }
        }
        .navigationTitle("Downloads")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await refresh(forceBackend: true) }
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showManualAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add Download")
            }
            if !buckets.recent.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear Completed") {
                        Task { await clearCompleted() }
                    }
                }
            }
        }
        .sheet(isPresented: $showManualAdd) {
            NavigationStack {
                ManualAddDownloadView {
                    showManualAdd = false
                    Task { await refresh(forceBackend: true) }
                }
            }
        }
        .task { await startPolling() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await refresh(forceBackend: true) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .inkampManualDownloadJobsDidChange)) { _ in
            Task { await reload() }
        }
    }

    @ViewBuilder
    private func jobSection(_ title: String, _ items: [ManualDownloadJob]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { job in
                    DownloadsJobRow(job: job, busyID: busyID) {
                        await retry(job)
                    } onRetryUpload: {
                        await retryUpload(job)
                    } onRetryDownload: {
                        await retryDownload(job)
                    } onRetryRouting: {
                        await retryRouting(job)
                    } onDeleteLocal: {
                        await deleteLocal(job)
                    }
                }
            }
        }
    }

    private func startPolling() async {
        await refresh(forceBackend: true)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            await refresh(forceBackend: true)
        }
    }

    private func refresh(forceBackend: Bool) async {
        await reload()
        guard forceBackend, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        _ = await ManualDownloadStatusRefresh.live().refresh()
        await reload()
    }

    private func reload() async {
        jobs = await ManualDownloadJobStore.shared.allJobs()
    }

    private func clearCompleted() async {
        await ManualDownloadJobStore.shared.clearCompleted()
        await reload()
    }

    private func retry(_ job: ManualDownloadJob) async {
        busyID = job.id
        defer { busyID = nil }
        _ = await NASAcquisitionHandler.live().retryDownload(job: job)
        await reload()
    }

    private func retryUpload(_ job: ManualDownloadJob) async {
        busyID = job.id
        defer { busyID = nil }
        _ = await NASAcquisitionHandler.live().retryUpload(job: job)
        await reload()
    }

    private func retryDownload(_ job: ManualDownloadJob) async {
        await retry(job)
    }

    private func retryRouting(_ job: ManualDownloadJob) async {
        busyID = job.id
        defer { busyID = nil }
        _ = await ManualDownloadStatusRefresh.live().retryRouting(job: job)
        await reload()
    }

    private func deleteLocal(_ job: ManualDownloadJob) async {
        busyID = job.id
        defer { busyID = nil }
        await NASAcquisitionHandler.live().deleteLocalCopy(job: job)
        await reload()
    }
}

private struct DownloadsJobRow: View {
    let job: ManualDownloadJob
    var busyID: String?
    var onRetry: () async -> Void
    var onRetryUpload: () async -> Void
    var onRetryDownload: () async -> Void
    var onRetryRouting: () async -> Void
    var onDeleteLocal: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.title.isEmpty ? "Untitled" : job.title)
                .font(.headline)
            if !job.author.isEmpty {
                Text(job.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("\(job.mediaType.label) • \(job.backend.label)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Text(statusLabel)
                    .font(.subheadline.weight(.medium))
                if let progress = job.progress, job.status.isActive, job.status != .submitted {
                    Text(progressText(progress))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if let progress = job.progress, shouldShowBar {
                ProgressView(value: min(max(progress, 0), 1))
            } else if job.status == .uploading {
                Text("Uploading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if job.status == .routing {
                Text(DelugeManualRouting.statusLabel(for: job.mediaType, routing: true))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(job.destination)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(job.submittedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if let error = job.lastError, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            actions
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("downloads-job-\(job.id)")
    }

    private var statusLabel: String {
        switch job.status {
            case .routing:
                DelugeManualRouting.statusLabel(for: job.mediaType, routing: true)
            case .submitted, .queued, .downloading, .delugeFinishing, .readyToRoute,
                .downloaded, .uploading, .complete, .failed, .unknown:
                job.status.label
        }
    }

    private var shouldShowBar: Bool {
        switch job.status {
            case .downloading, .queued, .delugeFinishing, .unknown: job.progress != nil
            case .submitted, .readyToRoute, .routing, .downloaded, .uploading, .complete, .failed:
                false
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack {
            switch job.retryAction {
                case .retryUpload:
                    Button("Retry Upload") { Task { await onRetryUpload() } }
                        .disabled(busyID != nil)
                    Button("Delete Local Copy", role: .destructive) { Task { await onDeleteLocal() } }
                        .disabled(busyID != nil)
                case .retryDownload:
                    Button("Retry Download") { Task { await onRetryDownload() } }
                        .disabled(busyID != nil)
                case .retryTorrent:
                    Button("Retry") { Task { await onRetry() } }
                        .disabled(busyID != nil)
                case .retryRouting:
                    Button("Retry Move") { Task { await onRetryRouting() } }
                        .disabled(busyID != nil)
                case .none:
                    EmptyView()
            }
        }
        .font(.subheadline)
    }

    private func progressText(_ progress: Double) -> String {
        "\(Int((min(max(progress, 0), 1) * 100).rounded()))%"
    }
}

/// Paste a magnet and pick eBook / Audiobook for Deluge staging + final routing.
struct ManualAddDownloadView: View {
    var onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var magnetText = ""
    @State private var mediaType: NASMediaKind = .ebook
    @State private var settings = NASDownloadSettingsStore.shared.snapshot
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("Magnet URL", text: $magnetText, axis: .vertical)
                    .lineLimit(3...6)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                Button("Paste Magnet") {
                    pasteMagnetFromClipboard()
                }
            } header: {
                Text("Magnet")
            } footer: {
                Text("Clipboard is only read when you tap Paste Magnet.")
            }

            Section("Media type") {
                Picker("Type", selection: $mediaType) {
                    Text(NASMediaKind.ebook.label).tag(NASMediaKind.ebook)
                    Text(NASMediaKind.audiobook.label).tag(NASMediaKind.audiobook)
                }
                .pickerStyle(.segmented)
            }

            Section("Destination") {
                LabeledContent("Final folder") {
                    Text(finalDestinationPreview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Backend") {
                    Text(backendPreview)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Deluge starts in") {
                    Text(settings.trimmedDelugeIncomingFolder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Submit")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(isSubmitting || !canSubmit)
                .buttonStyle(.borderedProminent)
            }
        }
        .navigationTitle("Add Download")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                    onFinished()
                }
            }
        }
        .onAppear {
            settings = NASDownloadSettingsStore.shared.snapshot
        }
    }

    private var canSubmit: Bool {
        let trimmed = magnetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), NASMagnetValidation.isValid(url) else { return false }
        return settings.torrentClient == .deluge && !settings.trimmedDelugeBaseURL.isEmpty
    }

    private var finalDestinationPreview: String {
        let folder = settings.folder(for: mediaType)
        return folder.isEmpty ? "Set destination folders in NAS Downloads settings" : folder
    }

    private var backendPreview: String {
        switch settings.torrentClient {
            case .deluge: "Deluge"
            case .qbittorrent: "qBittorrent (select Deluge for this workflow)"
            case .none: "No torrent client selected"
        }
    }

    private func pasteMagnetFromClipboard() {
        #if canImport(UIKit)
        if let text = UIPasteboard.general.string {
            magnetText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #elseif canImport(AppKit)
        if let text = NSPasteboard.general.string(forType: .string) {
            magnetText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
    }

    private func submit() async {
        errorMessage = nil
        let trimmed = magnetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), NASMagnetValidation.isValid(url) else {
            errorMessage = NASHandoffError.malformedMagnet.message
            return
        }
        guard settings.torrentClient == .deluge else {
            errorMessage = "Select Deluge as the torrent client in NAS Downloads settings."
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }
        let candidate = ManualAcquisitionCandidate(
            sourceURL: url,
            detectedType: .magnet,
            sourceHost: url.host,
            bookMetadata: ManualSearchBookContext(
                title: magnetDisplayTitle(url),
                authors: [],
                requestedMediaType: mediaType == .audiobook ? .audiobook : .ebook,
            ),
        )
        let result = await NASAcquisitionHandler.live().handle(candidate)
        switch result {
            case .submitted, .completed, .placeholder:
                dismiss()
                onFinished()
            case .failed(let message):
                errorMessage = message
        }
    }

    private func magnetDisplayTitle(_ url: URL) -> String {
        let raw = url.absoluteString
        for pair in raw.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].lowercased() == "dn" else { continue }
            let decoded = parts[1].removingPercentEncoding ?? parts[1]
            let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let hash = TorrentHash.fromMagnet(raw) {
            return "Magnet \(hash.prefix(8))"
        }
        return "Magnet download"
    }
}

struct DownloadsAttentionBadge: View {
    @State private var count = 0

    var body: some View {
        Group {
            if count > 0 {
                Text(count > 9 ? "9+" : "\(count)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.red))
                    .accessibilityLabel("\(count) downloads need attention")
            }
        }
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .inkampManualDownloadJobsDidChange)) { _ in
            Task { await reload() }
        }
    }

    private func reload() async {
        let jobs = await ManualDownloadJobStore.shared.allJobs()
        count = ManualDownloadBuckets.partition(jobs).attentionCount
    }
}

public struct DownloadsToolbarButton: View {
    @State private var badge = 0

    public init() {}

    public var body: some View {
        Button {
            NotificationCenter.default.post(name: .inkampShowManualDownloads, object: nil)
        } label: {
            Label("Downloads", systemImage: "arrow.down.circle")
        }
        .accessibilityLabel(badge > 0 ? "Downloads, \(badge)" : "Downloads")
        .overlay(alignment: .topTrailing) {
            if badge > 0 {
                Text(badge > 9 ? "9+" : "\(badge)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.red))
                    .foregroundStyle(.white)
                    .offset(x: 8, y: -8)
                    .accessibilityHidden(true)
            }
        }
        .task { await reloadBadge() }
        .onReceive(NotificationCenter.default.publisher(for: .inkampManualDownloadJobsDidChange)) { _ in
            Task { await reloadBadge() }
        }
    }

    private func reloadBadge() async {
        let jobs = await ManualDownloadJobStore.shared.allJobs()
        badge = ManualDownloadBuckets.partition(jobs).attentionCount
    }
}

typealias ManualDownloadsView = DownloadsView
#endif
