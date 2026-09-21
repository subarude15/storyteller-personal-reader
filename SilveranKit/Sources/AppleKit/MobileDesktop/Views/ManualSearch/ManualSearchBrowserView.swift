#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI
import WebKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Focused WKWebView for one provider search. Produces acquisition candidates
/// and hands them to `ManualAcquisitionRouter` — never to a NAS client.
struct ManualSearchBrowserView: View {
    let session: ManualSearchBrowserSession
    var router: ManualAcquisitionRouter = ManualAcquisitionRouter()

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var controller: ManualSearchBrowserController
    @State private var candidate: ManualAcquisitionCandidate?
    @State private var handoffTitle = "Send to NAS"
    @State private var handoffMessage: String?

    init(session: ManualSearchBrowserSession, router: ManualAcquisitionRouter = ManualAcquisitionRouter()) {
        self.session = session
        self.router = router
        _controller = StateObject(
            wrappedValue: ManualSearchBrowserController(
                startURL: session.url,
                book: session.book,
                providerID: session.provider.id,
            )
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if controller.isLoading {
                    ProgressView(value: controller.progress)
                        .progressViewStyle(.linear)
                }
                ManualSearchWebView(controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(controller.pageTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        controller.goBack()
                    } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .disabled(!controller.canGoBack)
                    .accessibilityLabel("Back")

                    Button {
                        controller.goForward()
                    } label: {
                        Image(systemName: "chevron.forward")
                    }
                    .disabled(!controller.canGoForward)
                    .accessibilityLabel("Forward")

                    Button {
                        if controller.isLoading {
                            controller.stop()
                        } else {
                            controller.reload()
                        }
                    } label: {
                        Image(systemName: controller.isLoading ? "xmark" : "arrow.clockwise")
                    }
                    .accessibilityLabel(controller.isLoading ? "Stop" : "Reload")

                    Button {
                        if let url = controller.currentURL {
                            openURL(url)
                        }
                    } label: {
                        Image(systemName: "safari")
                    }
                    .disabled(controller.currentURL == nil)
                    .accessibilityLabel("Open in Safari")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let host = controller.displayHost {
                    Text(host)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(.bar)
                }
            }
        }
        .onReceive(controller.candidatePublisher) { found in
            candidate = found
        }
        .sheet(item: $candidate) { found in
            ManualAcquisitionConfirmSheet(
                candidate: found,
                router: router,
                onFinished: { title, message in
                    candidate = nil
                    handoffTitle = title
                    handoffMessage = message
                },
                onContinue: {
                    candidate = nil
                },
                onOpenExternally: {
                    openURL(found.sourceURL)
                    candidate = nil
                },
                onCancel: {
                    candidate = nil
                },
            )
        }
        .alert(handoffTitle, isPresented: Binding(
            get: { handoffMessage != nil },
            set: { if !$0 { handoffMessage = nil } },
        )) {
            Button("OK", role: .cancel) { handoffMessage = nil }
        } message: {
            Text(handoffMessage ?? "")
        }
    }
}

struct ManualAcquisitionConfirmSheet: View {
    let candidate: ManualAcquisitionCandidate
    var router: ManualAcquisitionRouter
    let onFinished: (String, String) -> Void
    let onContinue: () -> Void
    let onOpenExternally: () -> Void
    let onCancel: () -> Void

    @State private var settings = NASDownloadSettingsSnapshot()
    @State private var overrideKind: NASMediaKind?
    @State private var sending = false
    @State private var sendError: String?

    private var preview: NASHandoffPreview {
        NASHandoffPreview.make(
            candidate: candidateForSubmit,
            override: overrideKind,
            settings: settings,
        )
    }

    private var candidateForSubmit: ManualAcquisitionCandidate {
        var copy = candidate
        if let overrideKind {
            copy.bookMetadata.requestedMediaType = overrideKind == .audiobook ? .audiobook : .ebook
        }
        return copy
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(candidate.bookMetadata.title)
                        .font(.headline)
                    if !candidate.bookMetadata.authorDisplay.isEmpty {
                        Text(candidate.bookMetadata.authorDisplay)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    LabeledContent("Type", value: preview.mediaKind?.label ?? "Unknown")
                    LabeledContent("Download via", value: preview.backendLabel)
                    LabeledContent("Destination", value: preview.destination.isEmpty ? "—" : preview.destination)
                    LabeledContent("Source", value: candidate.displayHost)
                    LabeledContent("File", value: candidate.displayFilename)
                }
                if preview.needsMediaTypeChoice {
                    Section {
                        Picker("Save as", selection: Binding(
                            get: { overrideKind },
                            set: { overrideKind = $0 },
                        )) {
                            Text("Choose…").tag(Optional<NASMediaKind>.none)
                            Text(NASMediaKind.ebook.label).tag(Optional(NASMediaKind.ebook))
                            Text(NASMediaKind.audiobook.label).tag(Optional(NASMediaKind.audiobook))
                        }
                    } footer: {
                        Text("This file type is ambiguous. Choose eBook or Audiobook.")
                    }
                }
                if let sendError {
                    Section {
                        Text(sendError)
                            .foregroundStyle(.red)
                    }
                } else if let blocking = preview.blockingMessage {
                    Section {
                        Text(blocking)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button {
                        Task { await send() }
                    } label: {
                        if sending {
                            ProgressView()
                        } else {
                            Text(sendError == nil ? "Send to NAS" : "Retry")
                        }
                    }
                    .disabled(sending || !preview.canSubmit)
                    .accessibilityIdentifier("manual-search-send-to-nas")
                    Button("Continue in Browser", action: onContinue)
                    Button("Open Externally", action: onOpenExternally)
                    Button("Cancel", role: .cancel, action: onCancel)
                }
            }
            .navigationTitle("Send to NAS")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task { await loadSettings() }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private func loadSettings() async {
        var snapshot = NASDownloadSettingsStore.shared.snapshot
        let configURL = await SettingsActor.shared.config.delugeBaseURL
        if snapshot.trimmedDelugeBaseURL.isEmpty {
            snapshot.delugeBaseURL = configURL
        }
        settings = snapshot
    }

    private func send() async {
        sending = true
        sendError = nil
        defer { sending = false }
        let result = await router.submit(candidateForSubmit)
        switch result {
            case .submitted(let message):
                onFinished("Sent to NAS", message)
            case .failed(let message):
                sendError = message
            case .placeholder(let message):
                onFinished("Send to NAS", message)
        }
    }
}

extension ManualAcquisitionCandidate: Identifiable {
    public var id: String {
        "\(sourceURL.absoluteString)|\(detectedType.rawValue)|\(filename ?? "")"
    }
}

@MainActor
final class ManualSearchBrowserController: NSObject, ObservableObject {
    let startURL: URL
    let book: ManualSearchBookContext
    let providerID: String

    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var pageTitle = "Search"
    @Published var currentURL: URL?
    @Published var displayHost: String?

    let candidatePublisher = ManualSearchCandidatePipe()

    weak var webView: WKWebView? {
        didSet { bindWebView() }
    }

    private var observations: [NSKeyValueObservation] = []

    init(startURL: URL, book: ManualSearchBookContext, providerID: String) {
        self.startURL = startURL
        self.book = book
        self.providerID = providerID
        super.init()
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func stop() { webView?.stopLoading() }

    fileprivate func handleCandidate(_ candidate: ManualAcquisitionCandidate) {
        candidatePublisher.send(candidate)
    }

    private func bindWebView() {
        observations.removeAll()
        guard let webView else { return }
        observations = [
            webView.observe(\.canGoBack, options: .new) { [weak self] view, _ in
                Task { @MainActor in self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: .new) { [weak self] view, _ in
                Task { @MainActor in self?.canGoForward = view.canGoForward }
            },
            webView.observe(\.isLoading, options: .new) { [weak self] view, _ in
                Task { @MainActor in self?.isLoading = view.isLoading }
            },
            webView.observe(\.estimatedProgress, options: .new) { [weak self] view, _ in
                Task { @MainActor in self?.progress = view.estimatedProgress }
            },
            webView.observe(\.title, options: .new) { [weak self] view, _ in
                Task { @MainActor in
                    let title = view.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    self?.pageTitle = title.isEmpty ? "Search" : title
                }
            },
            webView.observe(\.url, options: .new) { [weak self] view, _ in
                Task { @MainActor in
                    self?.currentURL = view.url
                    self?.displayHost = view.url.flatMap { ManualAcquisitionDetection.host(of: $0) }
                }
            },
        ]
        currentURL = webView.url
        displayHost = webView.url.flatMap { ManualAcquisitionDetection.host(of: $0) }
    }
}

/// Avoid Combine just to hop a candidate onto the view.
final class ManualSearchCandidatePipe: ObservableObject {
    private var handler: ((ManualAcquisitionCandidate) -> Void)?

    func send(_ candidate: ManualAcquisitionCandidate) {
        handler?(candidate)
    }

    func subscribe(_ handler: @escaping (ManualAcquisitionCandidate) -> Void) -> ManualSearchCandidatePipe {
        self.handler = handler
        return self
    }
}

private struct ManualSearchCandidatePipeViewModifier: ViewModifier {
    let pipe: ManualSearchCandidatePipe
    let handler: (ManualAcquisitionCandidate) -> Void

    func body(content: Content) -> some View {
        content.onAppear {
            _ = pipe.subscribe(handler)
        }
    }
}

extension View {
    fileprivate func onReceive(
        _ pipe: ManualSearchCandidatePipe,
        perform handler: @escaping (ManualAcquisitionCandidate) -> Void,
    ) -> some View {
        modifier(ManualSearchCandidatePipeViewModifier(pipe: pipe, handler: handler))
    }
}

private struct ManualSearchWebView: View {
    @ObservedObject var controller: ManualSearchBrowserController

    var body: some View {
        ManualSearchWebViewRepresentable(controller: controller)
    }
}

#if os(macOS)
private typealias ManualSearchPlatformViewRepresentable = NSViewRepresentable
#else
private typealias ManualSearchPlatformViewRepresentable = UIViewRepresentable
#endif

private struct ManualSearchWebViewRepresentable: ManualSearchPlatformViewRepresentable {
    let controller: ManualSearchBrowserController

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView {
        makeWebView(context: context)
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
    #else
    func makeUIView(context: Context) -> WKWebView {
        makeWebView(context: context)
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
    #endif

    func makeCoordinator() -> ManualSearchBrowserCoordinator {
        ManualSearchBrowserCoordinator(controller: controller)
    }

    private func makeWebView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        #if os(iOS)
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        #endif
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        controller.webView = webView
        webView.load(URLRequest(url: controller.startURL))
        return webView
    }
}

@MainActor
final class ManualSearchBrowserCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let controller: ManualSearchBrowserController

    init(controller: ManualSearchBrowserController) {
        self.controller = controller
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        (policy(for: navigationAction), preferences)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
    ) async -> WKNavigationResponsePolicy {
        let response = navigationResponse.response
        guard let url = response.url ?? webView.url else {
            return .allow
        }

        if let candidate = ManualAcquisitionDetection.candidate(
            url: url,
            response: response,
            suggestedFilename: response.suggestedFilename,
            bookMetadata: controller.book,
            providerID: controller.providerID,
        ) {
            controller.handleCandidate(candidate)
            return .download
        }

        return .allow
    }

    private func policy(for navigationAction: WKNavigationAction) -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }

        if let candidate = ManualAcquisitionDetection.actionStageCandidate(
            url: url,
            bookMetadata: controller.book,
            providerID: controller.providerID,
        ) {
            controller.handleCandidate(candidate)
            return .cancel
        }

        if ManualAcquisitionDetection.isIgnoredScheme(url) {
            return .cancel
        }

        return .allow
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload,
    ) {
        download.delegate = self
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload,
    ) {
        download.delegate = self
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures,
    ) -> WKWebView? {
        if let url = navigationAction.request.url, ManualAcquisitionDetection.isNavigableWebURL(url) {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
    ) async -> URL? {
        if let url = response.url ?? download.originalRequest?.url,
            let candidate = ManualAcquisitionDetection.candidate(
                url: url,
                response: response,
                suggestedFilename: suggestedFilename,
                bookMetadata: controller.book,
                providerID: controller.providerID,
            )
        {
            controller.handleCandidate(candidate)
        }
        _ = await download.cancel()
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("inkamp-unused-\(UUID().uuidString)")
    }

    func downloadDidFinish(_ download: WKDownload) {}

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {}
}
#endif
