#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI

public struct DownloadsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var jobs: [ManualDownloadJob] = []
    @State private var busyID: String?
    @State private var isRefreshing = false

    private var buckets: ManualDownloadBuckets {
        ManualDownloadBuckets.partition(jobs)
    }

    public init() {}

    public var body: some View {
        List {
            if jobs.isEmpty {
                Section {
                    Text("No manual downloads yet")
                        .foregroundStyle(.secondary)
                    Text("Send a Manual Search result to the NAS to see it here.")
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
            if !buckets.recent.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear Completed") {
                        Task { await clearCompleted() }
                    }
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
                Text(job.status.label)
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

    private var shouldShowBar: Bool {
        switch job.status {
            case .downloading, .queued, .unknown: job.progress != nil
            case .submitted, .downloaded, .uploading, .complete, .failed: false
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack {
            if job.canRetryUploadNow {
                Button("Retry Upload") { Task { await onRetryUpload() } }
                    .disabled(busyID != nil)
                Button("Delete Local Copy", role: .destructive) { Task { await onDeleteLocal() } }
                    .disabled(busyID != nil)
            } else if job.canRetryDownloadNow {
                Button("Retry Download") { Task { await onRetryDownload() } }
                    .disabled(busyID != nil)
            } else if job.canRetryTorrentNow {
                Button("Retry") { Task { await onRetry() } }
                    .disabled(busyID != nil)
            }
        }
        .font(.subheadline)
    }

    private func progressText(_ progress: Double) -> String {
        "\(Int((min(max(progress, 0), 1) * 100).rounded()))%"
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
