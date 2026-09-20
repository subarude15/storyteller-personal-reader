#if os(iOS) || os(macOS)
import SwiftUI
import SilveranKit

@MainActor
final class ServicesHealthViewModel: ObservableObject {
    @Published private(set) var results: [ServiceHealthResult] = []
    @Published private(set) var isRunning = false
    @Published private(set) var lastRunAt: Date?

    private let diagnostics: ServiceHealthDiagnostics
    private var runTask: Task<Void, Never>?

    init(diagnostics: ServiceHealthDiagnostics = ServiceHealthDiagnostics()) {
        self.diagnostics = diagnostics
        let cached = diagnostics.cache.load()
        if !cached.isEmpty {
            results = cached
        } else {
            results = ServiceHealthID.allCases.map {
                ServiceHealthResult.checking($0)
            }
        }
    }

    var summary: ServiceHealthSummary {
        ServiceHealthSummary(results: results)
    }

    var attentionItems: [ServiceHealthAttentionItem] {
        ServiceHealthAttention.items(from: results)
    }

    func onAppear() {
        if diagnostics.cache.shouldAutoRefresh() {
            runDiagnostics(force: true)
        } else if results.isEmpty {
            results = diagnostics.cache.load()
        }
    }

    func runDiagnostics(force: Bool = true) {
        runTask?.cancel()
        isRunning = true
        runTask = Task { [weak self] in
            guard let self else { return }
            let finished = await self.diagnostics.runAll(force: force) { [weak self] result in
                await MainActor.run {
                    self?.upsert(result)
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.results = finished
                self.isRunning = false
                self.lastRunAt = Date()
            }
        }
    }

    private func upsert(_ result: ServiceHealthResult) {
        if let index = results.firstIndex(where: { $0.serviceID == result.serviceID }) {
            results[index] = result
        } else {
            results.append(result)
        }
        let order = ServiceHealthID.allCases
        results.sort {
            (order.firstIndex(of: $0.serviceID) ?? 0) < (order.firstIndex(of: $1.serviceID) ?? 0)
        }
    }
}

public struct ServicesHealthView: View {
    @StateObject private var model = ServicesHealthViewModel()

    public init() {}

    public var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Services & Health")
                        .font(.title2.weight(.semibold))
                    HStack(spacing: 16) {
                        summaryChip(title: "Healthy", value: model.summary.healthy, tint: .green)
                        summaryChip(title: "Warnings", value: model.summary.warnings, tint: .orange)
                        summaryChip(
                            title: "Unavailable",
                            value: model.summary.unavailable,
                            tint: .red,
                        )
                    }
                    Button {
                        model.runDiagnostics(force: true)
                    } label: {
                        Label(
                            model.isRunning ? "Running…" : "Run diagnostics",
                            systemImage: "stethoscope",
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isRunning)
                }
                .padding(.vertical, 4)
            }

            if !model.attentionItems.isEmpty {
                Section("Needs Attention") {
                    ForEach(model.attentionItems) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.serviceName)
                                .font(.headline)
                            Text(item.problem)
                                .font(.subheadline)
                            Text(item.suggestedAction)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section("Services") {
                ForEach(model.results) { result in
                    NavigationLink {
                        ServiceHealthDetailView(result: result)
                    } label: {
                        serviceRow(result)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .modifier(SoftScrollEdgeModifier())
        .navigationTitle("Services & Health")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { model.onAppear() }
    }

    private func summaryChip(title: String, value: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func serviceRow(_ result: ServiceHealthResult) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: result.status.systemImage)
                .foregroundStyle(statusColor(result.status))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.displayName)
                Text(result.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let checked = result.lastChecked {
                    Text("Checked \(ServiceHealthURLSanitizer.relativeAge(from: checked))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if showsIndexerDetail(result), let detail = result.detail, detail != result.summary {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func statusColor(_ status: ServiceHealthStatus) -> Color {
        switch status {
            case .healthy: .green
            case .warning: .orange
            case .unavailable: .red
            case .disabled, .localOnly: .secondary
            case .checking: .blue
        }
    }

    private func showsIndexerDetail(_ result: ServiceHealthResult) -> Bool {
        switch result.serviceID {
            case .prowlarr, .jackett:
                result.status == .warning || result.status == .unavailable
            case .lazyLibrarian, .shelfarr, .librivox, .storyteller, .bookSearchLAN:
                false
        }
    }
}

public struct ServiceHealthDetailView: View {
    public var result: ServiceHealthResult

    public init(result: ServiceHealthResult) {
        self.result = result
    }

    public var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Service", value: result.displayName)
                LabeledContent("Status", value: result.status.label)
                LabeledContent("Message", value: result.summary)
                if let detail = result.detail, detail != result.summary {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Timing") {
                LabeledContent("Last checked", value: dateLabel(result.lastChecked))
                LabeledContent("Last success", value: dateLabel(result.lastSuccess))
            }

            Section("Connection") {
                LabeledContent("Host", value: result.sanitizedHost ?? "—")
                if let error = result.lastError {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last error")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(error)
                    }
                }
                if let technical = result.technicalDetail {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Technical detail")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(technical)
                            .font(.footnote.monospaced())
                    }
                }
            }

            if !result.metadata.isEmpty {
                Section("Metadata") {
                    ForEach(result.metadata.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: result.metadata[key] ?? "")
                    }
                }
            }

            if result.serviceID == .prowlarr || result.serviceID == .jackett {
                Section {
                    Text("LazyLibrarian may use these indexers to search for books.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Indexers") {
                    if result.indexers.isEmpty {
                        Text("No indexers configured")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(result.indexers) { row in
                            ServiceIndexerListRow(row: row)
                        }
                    }
                }
            }

            if let action = result.suggestedAction {
                Section("Suggested action") {
                    Text(action)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(result.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func dateLabel(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "\(formatter.string(from: date)) · \(ServiceHealthURLSanitizer.relativeAge(from: date))"
    }
}

private struct ServiceIndexerListRow: View {
    var row: ServiceIndexerRow
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.name)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(row.health.label)
                    .font(.subheadline)
                    .foregroundStyle(tint)
            }
            if let detail = row.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard (row.detail?.count ?? 0) > 80 else { return }
            expanded.toggle()
        }
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch row.health {
            case .healthy: .green
            case .failing: .orange
            case .disabled, .unknown: .secondary
        }
    }
}
#endif
