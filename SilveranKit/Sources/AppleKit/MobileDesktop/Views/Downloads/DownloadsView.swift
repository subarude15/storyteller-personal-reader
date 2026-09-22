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
    @State private var pendingMagnet = ""
    @State private var showClearFailedConfirm = false

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
                    Text("Paste a magnet or send a Manual Search result to TorBox / your NAS torrent client.")
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
            if !buckets.failed.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear Failed") {
                        showClearFailedConfirm = true
                    }
                }
            }
            if !buckets.recent.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear Completed") {
                        Task { await clearCompleted() }
                    }
                }
            }
        }
        .confirmationDialog(
            "Clear all failed attempts?",
            isPresented: $showClearFailedConfirm,
            titleVisibility: .visible,
        ) {
            Button("Clear Failed", role: .destructive) {
                Task { await clearFailed() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Removes failed download history only. Successful downloads and media files are not deleted. Providers are not contacted."
            )
        }
        .sheet(isPresented: $showManualAdd) {
            NavigationStack {
                ManualAddDownloadView(initialMagnet: pendingMagnet) {
                    pendingMagnet = ""
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
        .onReceive(NotificationCenter.default.publisher(for: .inkampOpenManualMagnet)) { note in
            if let url = note.object as? URL {
                // The root view persists every incoming magnet first so cold launches
                // cannot lose it. Clear that backup when the live notification reaches
                // Downloads, otherwise the same magnet can reopen on the next launch.
                _ = ManualDownloadMagnetDeepLinkStore.consume()
                presentMagnet(url)
            } else {
                openPendingMagnetIfNeeded()
            }
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
                    } onTransferToNAS: {
                        await transferToNAS(job)
                    } onDeleteLocal: {
                        await deleteLocal(job)
                    } onDeleteAttempt: { deleteFromTorBox in
                        await deleteAttempt(job, deleteFromTorBox: deleteFromTorBox)
                    }
                }
            }
        }
    }

    private func startPolling() async {
        openPendingMagnetIfNeeded()
        await refresh(forceBackend: true)
        while !Task.isCancelled {
            let hasActive = jobs.contains { $0.status.isActive }
            // Poll aggressively only while something is in flight.
            try? await Task.sleep(for: .seconds(hasActive ? 8 : 45))
            guard !Task.isCancelled else { return }
            if scenePhase == .active {
                await refresh(forceBackend: hasActive)
            }
        }
    }

    private func refresh(forceBackend: Bool) async {
        await reload()
        guard forceBackend, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let hasActive = jobs.contains { $0.status.isActive }
        if hasActive || forceBackend {
            _ = await ManualDownloadStatusRefresh.live().refresh()
            await reload()
        }
    }

    private func reload() async {
        jobs = await ManualDownloadJobStore.shared.allJobs()
    }

    private func clearCompleted() async {
        await ManualDownloadJobStore.shared.clearCompleted()
        await reload()
    }

    private func clearFailed() async {
        await ManualDownloadAttemptCleanup.clearFailed()
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

    private func transferToNAS(_ job: ManualDownloadJob) async {
        busyID = job.id
        defer { busyID = nil }
        _ = await TorBoxNASTransferService.live().transfer(job: job)
        await reload()
    }

    private func deleteLocal(_ job: ManualDownloadJob) async {
        busyID = job.id
        defer { busyID = nil }
        await NASAcquisitionHandler.live().deleteLocalCopy(job: job)
        await reload()
    }

    private func deleteAttempt(_ job: ManualDownloadJob, deleteFromTorBox: Bool) async {
        busyID = job.id
        defer { busyID = nil }
        // Optional TorBox cloud delete is explicit user confirmation only.
        // Attempt history cleanup never resubmits magnets or contacts Deluge/qBit.
        if deleteFromTorBox {
            await ManualDownloadStatusRefresh.live().deleteRemoteIfNeeded(job: job)
        }
        await ManualDownloadAttemptCleanup.deleteAttempt(job)
        await reload()
    }

    private func openPendingMagnetIfNeeded() {
        if let url = ManualDownloadMagnetDeepLinkStore.consume() {
            presentMagnet(url)
        }
    }

    private func presentMagnet(_ url: URL) {
        guard url.scheme?.lowercased() == "magnet", NASMagnetValidation.isValid(url) else { return }
        pendingMagnet = url.absoluteString
        showManualAdd = true
    }
}

private struct DownloadsJobRow: View {
    let job: ManualDownloadJob
    var busyID: String?
    var onRetry: () async -> Void
    var onRetryUpload: () async -> Void
    var onRetryDownload: () async -> Void
    var onRetryRouting: () async -> Void
    var onTransferToNAS: () async -> Void
    var onDeleteLocal: () async -> Void
    var onDeleteAttempt: (_ deleteFromTorBox: Bool) async -> Void

    @State private var showTorBoxDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.title.isEmpty ? "Untitled" : job.title)
                .font(.headline)
            if !job.author.isEmpty {
                Text(job.author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("\(job.backend.label) · \(statusLabel)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                if let progress = job.progress, shouldShowProgressText {
                    Text(progressText(progress))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let size = displaySize {
                    Text(size)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if let progress = job.progress, shouldShowBar {
                ProgressView(value: min(max(progress, 0), 1))
            } else if job.status == .transferring {
                ProgressView()
            } else if job.status == .uploading {
                Text("Uploading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if job.status == .routing {
                Text(DelugeManualRouting.statusLabel(for: job.mediaType, routing: true))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if job.status == .complete, !job.destination.isEmpty {
                Text("Saved to:\n\(job.destination)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if job.backend != .torbox {
                Text(job.destination)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if job.status == .ready || job.status == .transferring {
                Text(job.destination.isEmpty ? job.mediaType.label : job.destination)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(job.mediaType.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
        .confirmationDialog(
            "Remove download?",
            isPresented: $showTorBoxDeleteConfirm,
            titleVisibility: .visible,
        ) {
            Button("Remove from Downloads") {
                Task { await onDeleteAttempt(false) }
            }
            Button("Delete from TorBox too", role: .destructive) {
                Task { await onDeleteAttempt(true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Delete from TorBox removes the cloud torrent. Files already transferred to your NAS will not be deleted."
            )
        }
    }

    private var statusLabel: String {
        switch job.status {
            case .routing:
                DelugeManualRouting.statusLabel(for: job.mediaType, routing: true)
            case .submitted, .queued, .downloading, .processing, .delugeFinishing, .readyToRoute,
                .downloaded, .uploading, .ready, .transferring, .complete, .failed, .unknown:
                job.status.label
        }
    }

    private var shouldShowBar: Bool {
        switch job.status {
            case .downloading, .queued, .processing, .delugeFinishing, .transferring, .unknown:
                job.progress != nil
            case .submitted, .readyToRoute, .routing, .downloaded, .uploading, .ready, .complete,
                .failed:
                false
        }
    }

    private var shouldShowProgressText: Bool {
        switch job.status {
            case .downloading, .queued, .processing, .delugeFinishing, .transferring, .unknown:
                job.status != .submitted
            case .submitted, .readyToRoute, .routing, .downloaded, .uploading, .ready, .complete,
                .failed:
                false
        }
    }

    private var displaySize: String? {
        let bytes = job.totalSize ?? job.byteCount
        guard let bytes, bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    @ViewBuilder
    private var actions: some View {
        HStack {
            if job.canTransferToNASNow {
                Button("Transfer to NAS") { Task { await onTransferToNAS() } }
                    .disabled(busyID != nil)
            }
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
                case .retryTransfer:
                    Button("Retry Transfer") { Task { await onTransferToNAS() } }
                        .disabled(busyID != nil)
                case .none:
                    EmptyView()
            }
            if job.status == .failed || job.status == .ready || job.status == .complete {
                if job.backend == .torbox {
                    Button("Remove", role: .destructive) {
                        showTorBoxDeleteConfirm = true
                    }
                    .disabled(busyID != nil)
                } else if job.status == .failed || job.status == .ready {
                    Button("Delete Attempt", role: .destructive) {
                        Task { await onDeleteAttempt(false) }
                    }
                    .disabled(busyID != nil)
                }
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
    @State private var magnetText: String
    @State private var mediaType: NASMediaKind = .ebook
    @State private var settings = NASDownloadSettingsStore.shared.snapshot
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    init(initialMagnet: String = "", onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
        _magnetText = State(initialValue: initialMagnet)
    }

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
                if settings.torrentClient == .deluge {
                    LabeledContent("Deluge starts in") {
                        Text(settings.trimmedDelugeIncomingFolder)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
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
        switch settings.torrentClient {
            case .torbox:
                return settings.torboxEnabled
            case .deluge:
                return !settings.trimmedDelugeBaseURL.isEmpty
            case .qbittorrent:
                return !settings.trimmedQBittorrentBaseURL.isEmpty
            case .none:
                return false
        }
    }

    private var finalDestinationPreview: String {
        let folder = settings.folder(for: mediaType)
        return folder.isEmpty ? "Set destination folders in NAS Downloads settings" : folder
    }

    private var backendPreview: String {
        switch settings.torrentClient {
            case .torbox: settings.torboxEnabled ? "TorBox" : "TorBox (enable in Settings)"
            case .deluge: "Deluge"
            case .qbittorrent: "qBittorrent"
            case .none: "No torrent provider selected"
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
        guard settings.torrentClient != .none else {
            errorMessage = "Select a torrent provider in NAS Downloads settings."
            return
        }
        if settings.torrentClient == .torbox, !settings.torboxEnabled {
            errorMessage = "Enable TorBox in NAS Downloads settings."
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
