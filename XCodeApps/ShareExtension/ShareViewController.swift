#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import SilveranKit

/// Share extension principal view controller.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private var hosting: UIViewController?
    private var torrentFileURL: URL?
    private var classification: ManualDownloadIntakeClassification = .rejected(.emptyPayload)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        Task { await loadSharedItems() }
    }

    private func loadSharedItems() async {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            presentRejected(.emptyPayload)
            return
        }

        for item in items {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                    let url = await loadURL(provider)
                {
                    let result = ManualDownloadIntake.classify(url: url)
                    if case .torrent = result, url.isFileURL {
                        torrentFileURL = url
                    } else if case .torrent = result, !url.isFileURL {
                        // Remote .torrent link from Safari — try loading as file if provider has data.
                        if let file = await loadFile(provider) {
                            torrentFileURL = file
                            classification = ManualDownloadIntake.classifyTorrentFile(url: file)
                            await MainActor.run { presentForm() }
                            return
                        }
                    }
                    switch result {
                        case .magnet:
                            classification = result
                            await MainActor.run { presentForm() }
                            return
                        case .torrent:
                            if torrentFileURL != nil {
                                classification = result
                                await MainActor.run { presentForm() }
                                return
                            }
                        case .rejected(let error):
                            // Keep looking; another attachment may be valid.
                            if error == .webpageNotMagnetOrTorrent {
                                classification = result
                            }
                    }
                }

                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                    let text = await loadText(provider)
                {
                    let result = ManualDownloadIntake.classify(text: text)
                    if case .magnet = result {
                        classification = result
                        await MainActor.run { presentForm() }
                        return
                    }
                    if case .rejected = result {
                        classification = result
                    }
                }

                if provider.hasItemConformingToTypeIdentifier("public.data"),
                    let file = await loadFile(provider)
                {
                    let result = ManualDownloadIntake.classifyTorrentFile(url: file)
                    if case .torrent = result {
                        torrentFileURL = file
                        classification = result
                        await MainActor.run { presentForm() }
                        return
                    }
                }
            }
        }

        await MainActor.run {
            if case .rejected = classification {
                presentRejected(
                    {
                        if case .rejected(let error) = classification { return error }
                        return .unsupportedItem
                    }()
                )
            } else {
                presentForm()
            }
        }
    }

    @MainActor
    private func presentForm() {
        let form = ShareFormHost(
            classification: classification,
            torrentFileURL: torrentFileURL,
            onCancel: { [weak self] in self?.cancel() },
            onSent: { [weak self] in self?.complete() },
        )
        let host = UIHostingController(rootView: form)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        hosting = host
    }

    @MainActor
    private func presentRejected(_ error: ManualDownloadIntakeError) {
        classification = .rejected(error)
        presentForm()
    }

    private func cancel() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    private func complete() {
        // Open host so it can drain the queue.
        if let url = URL(string: "punkrally://add-download") {
            var responder: UIResponder? = self
            while let current = responder {
                if let application = current as? UIApplication {
                    application.open(url, options: [:], completionHandler: nil)
                    break
                }
                responder = current.next
            }
            // Extension-safe open via openURL selector (pre-iOS 18 share pattern).
            let selector = sel_registerName("openURL:")
            var walk: UIResponder? = self
            while let current = walk {
                if current.responds(to: selector) {
                    current.perform(selector, with: url)
                    break
                }
                walk = current.next
            }
        }
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    private func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data,
                    let text = String(data: data, encoding: .utf8),
                    let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
                {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) {
                item,
                _
                in
                if let text = item as? String {
                    continuation.resume(returning: text)
                } else if let data = item as? Data,
                    let text = String(data: data, encoding: .utf8)
                {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadFile(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) {
                url,
                _
                in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("inkamp-share-\(UUID().uuidString)-\(url.lastPathComponent)")
                try? FileManager.default.removeItem(at: temp)
                do {
                    try FileManager.default.copyItem(at: url, to: temp)
                    continuation.resume(returning: temp)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

private struct ShareFormHost: View {
    var classification: ManualDownloadIntakeClassification
    var torrentFileURL: URL?
    var onCancel: () -> Void
    var onSent: () -> Void

    @State private var mediaType: NASMediaKind = .ebook
    @State private var errorMessage: String?
    @State private var isSending = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Item") {
                    Text(titleText)
                        .font(.body.weight(.semibold))
                    Text(subtitleText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if canSend {
                    Section("Media type") {
                        Picker("Type", selection: $mediaType) {
                            Text(NASMediaKind.ebook.label).tag(NASMediaKind.ebook)
                            Text(NASMediaKind.audiobook.label).tag(NASMediaKind.audiobook)
                        }
                        .pickerStyle(.segmented)
                    }

                    Section("Destination") {
                        Text("Uses your NAS Downloads \(mediaType.label) folder after Deluge finishes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    if canSend {
                        Button {
                            Task { await send() }
                        } label: {
                            if isSending {
                                ProgressView().frame(maxWidth: .infinity)
                            } else {
                                Text("Send").frame(maxWidth: .infinity)
                            }
                        }
                        .disabled(isSending)
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Close", action: onCancel)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("Add to ink+amp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }

    private var canSend: Bool {
        switch classification {
            case .magnet: true
            case .torrent: torrentFileURL != nil
            case .rejected: false
        }
    }

    private var titleText: String {
        switch classification {
            case .magnet(_, let title), .torrent(_, let title): title
            case .rejected: "Can't add this"
        }
    }

    private var subtitleText: String {
        switch classification {
            case .magnet: "Magnet link"
            case .torrent(let filename, _): filename
            case .rejected(let error): error.message
        }
    }

    private func send() async {
        errorMessage = nil
        isSending = true
        defer { isSending = false }
        do {
            switch classification {
                case .magnet(let url, let title):
                    _ = try ManualDownloadIntakeHandoff.enqueueMagnet(
                        url: url,
                        mediaType: mediaType,
                        source: .shareExtension,
                        displayTitle: title,
                    )
                case .torrent(let filename, let title):
                    guard let fileURL = torrentFileURL else {
                        errorMessage = ManualDownloadIntakeError.inaccessibleTorrent.message
                        return
                    }
                    _ = try ManualDownloadIntakeHandoff.enqueueTorrent(
                        from: fileURL,
                        mediaType: mediaType,
                        source: .shareExtension,
                        displayTitle: title,
                        preferredFilename: filename,
                    )
                case .rejected(let error):
                    errorMessage = error.message
                    return
            }
            onSent()
        } catch let error as ManualDownloadIntakeError {
            errorMessage = error.message
        } catch {
            errorMessage = ManualDownloadIntakeError.handoffUnavailable.message
        }
    }
}
#endif
