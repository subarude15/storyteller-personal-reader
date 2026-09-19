#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

public struct UploadNewBookData: Codable, Hashable {
    public var sourceID: BookSourceID?

    public init(sourceID: BookSourceID? = nil) {
        self.sourceID = sourceID
    }
}

public struct UploadNewBookView: View {
    private let initialSourceID: BookSourceID?
    @Environment(MediaViewModel.self) private var mediaViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedEbookURL: URL?
    @State private var selectedAudiobookURLs: [URL] = []
    @State private var selectedReadaloudURL: URL?
    @State private var fileSummaries: [URL: String] = [:]
    @State private var bookSources: [BookSourceRecord] = []
    @State private var selectedSourceID: BookSourceID?
    @State private var destinationHint: String?
    @State private var uploadState: StorytellerBookUploadState = .idle
    @State private var folderStatus: String?
    @State private var uploadTask: Task<Void, Never>?
    @State private var uploadGeneration = 0
    @State private var confirmCancel = false
    @State private var confirmDismiss = false
    @State private var coordinator = StorytellerBookUploadCoordinator()

    #if os(iOS)
    @State private var activeImporter: ImporterTarget?
    @State private var pendingImporterTarget: ImporterTarget?

    private enum ImporterTarget: Identifiable {
        case ebook
        case audiobook
        case readaloud

        var id: Self { self }
    }
    #endif

    public init(initialSourceID: BookSourceID? = nil) {
        self.initialSourceID = initialSourceID
    }

    public var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Destination") {
                    if bookSources.isEmpty {
                        Text(destinationHint ?? "Add a Storyteller source in Settings first.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Upload To", selection: selectedSourceBinding) {
                            ForEach(bookSources) { source in
                                Label(source.name, systemImage: iconName(for: source.kind))
                                    .tag(source.id)
                            }
                        }
                        .disabled(selectionLocked)
                        .accessibilityHint("Where the files are uploaded")
                    }
                    if selectedSource?.kind == .storyteller {
                        Text("Uses the active Storyteller URL (LAN when on home Wi‑Fi).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    singleFileRow(
                        label: "Ebook",
                        url: selectedEbookURL,
                        role: .ebook,
                        onClear: { selectedEbookURL = nil },
                        onSelect: selectEbook,
                    )
                    audioFileRow()
                    singleFileRow(
                        label: "Readaloud (optional)",
                        url: selectedReadaloudURL,
                        role: .readaloud,
                        onClear: { selectedReadaloudURL = nil },
                        onSelect: selectReadaloud,
                    )
                } header: {
                    Text("Files")
                } footer: {
                    Text(footerText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if folderStatus != nil || uploadState != .idle {
                    Section("Status") {
                        statusBlock
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDismissesKeyboard(.interactively)

            Divider()

            bottomBar
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
        .navigationTitle(navigationTitleText)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(operationInFlight)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { requestDismiss() }
                    .accessibilityHint(
                        operationInFlight
                            ? "Asks before cancelling the upload and closing"
                            : "Closes this screen"
                    )
            }
            #endif
        }
        .interactiveDismissDisabled(operationInFlight)
        .confirmationDialog(
            "Cancel this upload?",
            isPresented: $confirmCancel,
            titleVisibility: .visible,
        ) {
            Button("Cancel Upload", role: .destructive) {
                uploadTask?.cancel()
            }
            Button("Keep Uploading", role: .cancel) {}
        } message: {
            Text(
                "Files Storyteller already accepted stay on the server. Cancelling does not delete a partial book, and the upload does not keep going in the background."
            )
        }
        .confirmationDialog(
            "Upload still running",
            isPresented: $confirmDismiss,
            titleVisibility: .visible,
        ) {
            Button("Cancel Upload and Close", role: .destructive) {
                uploadTask?.cancel()
                dismiss()
            }
            Button("Keep Uploading", role: .cancel) {}
        } message: {
            Text(
                "Closing stops this upload. Files Storyteller already accepted stay on the server. Nothing is rolled back."
            )
        }
        .task {
            await loadSources()
        }
        .onDisappear {
            if operationInFlight {
                uploadTask?.cancel()
            }
        }
        #if os(iOS)
        .fileImporter(
            isPresented: importerPresentedBinding,
            allowedContentTypes: importerContentTypes,
            allowsMultipleSelection: activeImporter == .audiobook,
        ) { result in
            handleImporterResult(result)
        }
        #endif
    }

    private var navigationTitleText: String {
        selectedSource?.kind == .localFolder ? "Add Book" : "Upload to Storyteller"
    }

    private var footerText: String {
        if selectedSource?.kind == .localFolder {
            return "Pick an EPUB and/or audiobook. The original files are not changed or deleted."
        }
        return
            "Pick an EPUB and/or audiobook (several audio files are fine). Upload sends them to Storyteller. The original files are not changed or deleted. Read & Listen is ready only after Storyteller reports ALIGNED."
    }

    @ViewBuilder
    private var statusBlock: some View {
        if let folderStatus {
            Label(folderStatus, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel(folderStatus)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label(uploadState.statusTitle, systemImage: statusSymbol)
                    .foregroundStyle(statusColor)
                    .accessibilityLabel(uploadState.statusTitle)
                Text(uploadState.statusDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if operationInFlight, let fraction = uploadState.fraction {
                    ProgressView(value: fraction)
                        .accessibilityLabel("Uploading")
                        .accessibilityValue("\(Int(fraction * 100)) percent")
                } else if operationInFlight {
                    ProgressView()
                        .accessibilityLabel(uploadState.statusTitle)
                }
                openBookLink
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var openBookLink: some View {
        if let bookID = uploadState.confirmedBookID,
            let book = mediaViewModel.library.bookMetaData.first(where: { $0.id == bookID })
        {
            #if os(iOS)
            NavigationLink {
                iOSBookDetailView(item: book, mediaKind: book.ebook == nil ? .audiobook : .ebook)
            } label: {
                Text("Open Book")
            }
            .accessibilityHint("Shows this Storyteller book")
            #else
            Button("Open Book") {
                mediaViewModel.pendingInfoBookID = book.id
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Shows this Storyteller book")
            #endif
        }
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if showsAnother {
                    Button("Upload Another") {
                        Task { await resetForNewBook() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(operationInFlight)
                }
                Spacer(minLength: 0)
                if operationInFlight {
                    Button("Cancel") { confirmCancel = true }
                        .buttonStyle(.bordered)
                        .accessibilityHint("Stops this upload. Files already accepted stay on Storyteller.")
                }
            }
            HStack {
                #if os(macOS)
                Button("Close") { requestDismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                #endif
                Spacer(minLength: 0)
                Button(primaryActionTitle) {
                    startUpload()
                }
                .buttonStyle(.borderedProminent)
                .disabled(primaryDisabled)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint(primaryActionTitle)
            }
        }
        .padding()
    }

    private var selectedSourceBinding: Binding<BookSourceID> {
        Binding(
            get: { selectedSourceID ?? bookSources.first?.id ?? "" },
            set: { selectedSourceID = $0 },
        )
    }

    private var operationInFlight: Bool { uploadTask != nil }

    private var selectionLocked: Bool {
        if operationInFlight { return true }
        switch uploadState {
            case .idle, .blocked:
                return folderStatus != nil
            case .preparing, .uploading, .uploadComplete, .processing, .bookVisible, .readaloudQueued,
                .readaloudProcessing, .readaloudReady, .stillProcessing, .partial, .failed, .cancelled:
                return true
        }
    }

    private var showsAnother: Bool {
        folderStatus != nil || uploadState != .idle
    }

    private var hasAnyFileSelected: Bool {
        selectedEbookURL != nil || !selectedAudiobookURLs.isEmpty || selectedReadaloudURL != nil
    }

    private var selectedSource: BookSourceRecord? {
        bookSources.first { $0.id == selectedSourceID }
    }

    private var primaryActionTitle: String {
        if selectedSource?.kind == .localFolder {
            return uploadState == .idle && folderStatus == nil ? "Add" : "Retry"
        }
        switch uploadState {
            case .idle:
                return "Upload"
            case .partial:
                return "Continue upload"
            case .stillProcessing:
                return "Check again"
            case .preparing, .uploading, .uploadComplete, .processing:
                return "Upload"
            case .bookVisible, .readaloudQueued, .readaloudProcessing, .readaloudReady:
                return "Upload"
            case .failed, .cancelled, .blocked:
                return "Continue upload"
        }
    }

    private var primaryDisabled: Bool {
        if operationInFlight || selectedSourceID == nil || !hasAnyFileSelected { return true }
        switch uploadState {
            case .bookVisible, .readaloudQueued, .readaloudProcessing, .readaloudReady:
                return true
            case .idle, .preparing, .uploading, .uploadComplete, .processing, .stillProcessing, .partial,
                .failed, .cancelled, .blocked:
                return folderStatus != nil
        }
    }

    private var statusSymbol: String {
        switch uploadState {
            case .bookVisible, .readaloudReady:
                return "checkmark.circle.fill"
            case .failed, .blocked:
                return "exclamationmark.triangle.fill"
            case .cancelled, .partial, .stillProcessing:
                return "exclamationmark.circle.fill"
            case .idle, .preparing, .uploading, .uploadComplete, .processing, .readaloudQueued,
                .readaloudProcessing:
                return "arrow.up.circle"
        }
    }

    private var statusColor: Color {
        switch uploadState {
            case .bookVisible, .readaloudReady:
                return .green
            case .failed, .blocked:
                return .red
            case .cancelled, .partial, .stillProcessing, .readaloudQueued, .readaloudProcessing:
                return .orange
            case .idle, .preparing, .uploading, .uploadComplete, .processing:
                return .primary
        }
    }

    @ViewBuilder
    private func singleFileRow(
        label: String,
        url: URL?,
        role: StorytellerUploadFileRole,
        onClear: @escaping () -> Void,
        onSelect: @escaping () -> Void,
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.headline)
            if let url {
                Text(fileSummaries[url] ?? url.lastPathComponent)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("None selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Select…", action: onSelect)
                    .buttonStyle(.bordered)
                    .disabled(selectionLocked)
                    .accessibilityLabel("Select \(label)")
                if url != nil {
                    Button("Clear", action: onClear)
                        .buttonStyle(.bordered)
                        .disabled(selectionLocked)
                        .accessibilityLabel("Clear \(label)")
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func audioFileRow() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Audiobook")
                .font(.headline)
            if selectedAudiobookURLs.isEmpty {
                Text("None selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(selectedAudiobookURLs, id: \.self) { url in
                    Text(fileSummaries[url] ?? url.lastPathComponent)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button("Select…", action: selectAudiobook)
                    .buttonStyle(.bordered)
                    .disabled(selectionLocked)
                    .accessibilityLabel("Select audiobook")
                if !selectedAudiobookURLs.isEmpty {
                    Button("Clear") { selectedAudiobookURLs = [] }
                        .buttonStyle(.bordered)
                        .disabled(selectionLocked)
                        .accessibilityLabel("Clear audiobook")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func iconName(for kind: BookSourceKind) -> String {
        switch kind {
            case .storyteller:
                return "server.rack"
            case .localFolder:
                return "folder"
        }
    }

    private func requestDismiss() {
        if operationInFlight {
            confirmDismiss = true
        } else {
            dismiss()
        }
    }

    private func resetForNewBook() async {
        selectedEbookURL = nil
        selectedAudiobookURLs = []
        selectedReadaloudURL = nil
        fileSummaries = [:]
        folderStatus = nil
        uploadState = .idle
        await coordinator.resetForNewBook()
    }

    private func loadSources() async {
        let sources = await BookServiceActor.shared.bookSources
        let permitted = await BookServiceActor.shared.uploadPermittedSourceIDs()
        var listed: [BookSourceRecord] = []
        var hidStoryteller = false
        for source in sources where source.capabilities.canUploadBooks {
            let access: StorytellerBookCreateAccess
            if source.kind == .storyteller {
                access = await BookServiceActor.shared.storytellerBookCreateAccess(sourceID: source.id)
            } else {
                access = .allowed
            }
            if StorytellerUploadDestinations.isListed(
                source,
                uploadPermittedSourceIDs: permitted,
                storytellerAccess: access,
            ) {
                listed.append(source)
            } else if source.kind == .storyteller {
                hidStoryteller = true
            }
        }
        listed.sort { lhs, rhs in
            if lhs.kind == .storyteller && rhs.kind != .storyteller { return true }
            if lhs.kind != .storyteller && rhs.kind == .storyteller { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        let hint =
            hidStoryteller && listed.isEmpty
            ? "Reconnect to Storyteller, or ask for permission to create books. Your selected files stay here."
            : nil
        bookSources = listed
        destinationHint = hint
        if let selectedSourceID, listed.contains(where: { $0.id == selectedSourceID }) {
            self.selectedSourceID = selectedSourceID
        } else if let initialSourceID, listed.contains(where: { $0.id == initialSourceID }) {
            selectedSourceID = initialSourceID
        } else {
            selectedSourceID = listed.first?.id
        }
    }

    private func startUpload() {
        guard uploadTask == nil else { return }
        uploadTask = Task { @MainActor in
            await performUpload()
            uploadTask = nil
        }
    }

    private func performUpload() async {
        guard hasAnyFileSelected, let sourceID = selectedSourceID, let source = selectedSource else { return }
        folderStatus = nil
        uploadGeneration += 1
        let generation = uploadGeneration
        let files = collectedFiles()
        if let issue = StorytellerUploadFileValidation.issues(in: files) {
            uploadState = .blocked(message: issue)
            return
        }
        if source.kind != .storyteller {
            await uploadToFolder(sourceID: sourceID, files: files)
            return
        }
        let state = await coordinator.upload(
            sourceID: sourceID,
            isStoryteller: true,
            files: files,
            transport: LiveStorytellerBookUploadTransport(),
            fileSystem: SystemStorytellerUploadFileSystem(),
            onState: { next in
                Task { @MainActor in
                    guard uploadGeneration == generation else { return }
                    uploadState = next
                }
            },
        )
        uploadGeneration += 1
        uploadState = state
        if state.confirmedBookID != nil {
            await mediaViewModel.refreshMetadata(source: "storyteller-upload")
        }
    }

    private func collectedFiles() -> [StorytellerUploadRequestFile] {
        var files: [StorytellerUploadRequestFile] = []
        if let url = selectedEbookURL {
            files.append(requestFile(url, role: .ebook))
        }
        for url in selectedAudiobookURLs {
            files.append(requestFile(url, role: .audiobook))
        }
        if let url = selectedReadaloudURL {
            files.append(requestFile(url, role: .readaloud))
        }
        return files
    }

    /// Inspection already rejected bad files. This rebuilds the same request for the coordinator.
    private func requestFile(_ url: URL, role: StorytellerUploadFileRole) -> StorytellerUploadRequestFile {
        if case .file(let file) = StorytellerUploadFileStaging.inspect(role: role, url: url) {
            return file
        }
        let format: StorytellerBookFormat =
            switch role {
                case .ebook: .ebook
                case .audiobook: .audiobook
                case .readaloud: .readaloud
            }
        return StorytellerUploadRequestFile(
            format: format,
            filename: url.lastPathComponent,
            byteCount: 0,
            contentType: StorytellerUploadFileValidation.contentType(for: role, filename: url.lastPathComponent),
            typeIdentifier: nil,
            fileURL: url,
        )
    }

    private func uploadToFolder(sourceID: BookSourceID, files: [StorytellerUploadRequestFile]) async {
        let fileSystem = SystemStorytellerUploadFileSystem()
        var staged: [(StorytellerUploadRequestFile, URL)] = []
        defer {
            for item in staged {
                fileSystem.removeStaged(item.1)
            }
        }
        uploadState = .preparing
        do {
            for file in files {
                try Task.checkCancellation()
                staged.append((file, try fileSystem.stage(file.fileURL)))
            }
        } catch is CancellationError {
            uploadState = .cancelled(partialOnServer: false)
            return
        } catch {
            uploadState = .failed(message: "Couldn’t prepare the files for this folder.", bookID: nil)
            return
        }
        if Task.isCancelled {
            uploadState = .cancelled(partialOnServer: false)
            return
        }
        uploadState = .uploading(fraction: 0)
        let assets = staged.map { file, url in
            StorytellerUploadAsset(
                format: file.format,
                filename: file.filename,
                fileURL: url,
                byteCount: file.byteCount,
                contentType: file.contentType,
                deleteFileWhenFinished: false,
            )
        }
        let success = await BookServiceActor.shared.uploadBookAssets(
            bookID: BookID(sourceID: sourceID, uuid: UUID().uuidString),
            ebook: assets.first { $0.format == .ebook },
            audiobooks: assets.filter { $0.format == .audiobook },
            readaloud: assets.first { $0.format == .readaloud },
        )
        if Task.isCancelled && !success {
            uploadState = .cancelled(partialOnServer: false)
            return
        }
        guard success else {
            uploadState = .failed(message: "Couldn’t add these files to the folder.", bookID: nil)
            return
        }
        uploadState = .idle
        folderStatus = "Added to this folder."
        await BookServiceActor.shared.fetchLibraryInformation()
    }

    private func remember(_ url: URL, role: StorytellerUploadFileRole) {
        switch StorytellerUploadFileStaging.inspect(role: role, url: url) {
            case .file(let file):
                let size = ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file)
                fileSummaries[url] = "\(file.filename) · \(size)"
            case .rejected(let message):
                fileSummaries[url] = message
        }
    }

    #if os(macOS)
    private func selectEbook() {
        guard let url = chooseFiles(types: [.epub], multiple: false, message: "Select an EPUB ebook file").first
        else { return }
        selectedEbookURL = url
        remember(url, role: .ebook)
    }

    private func selectAudiobook() {
        let urls = chooseFiles(
            types: [.mpeg4Audio, .mp3, .audio],
            multiple: true,
            message: "Select one or more audiobook files",
        )
        guard !urls.isEmpty else { return }
        selectedAudiobookURLs = urls
        for url in urls { remember(url, role: .audiobook) }
    }

    private func selectReadaloud() {
        guard
            let url = chooseFiles(
                types: [.epub],
                multiple: false,
                message: "Select a readaloud EPUB file (with media overlays)",
            ).first
        else { return }
        selectedReadaloudURL = url
        remember(url, role: .readaloud)
    }

    private func chooseFiles(types: [UTType], multiple: Bool, message: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = false
        panel.message = message
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }
    #else
    private func selectEbook() {
        pendingImporterTarget = .ebook
        activeImporter = .ebook
    }

    private func selectAudiobook() {
        pendingImporterTarget = .audiobook
        activeImporter = .audiobook
    }

    private func selectReadaloud() {
        pendingImporterTarget = .readaloud
        activeImporter = .readaloud
    }

    private var importerPresentedBinding: Binding<Bool> {
        Binding(
            get: { activeImporter != nil },
            set: { if !$0 { activeImporter = nil } },
        )
    }

    private var importerContentTypes: [UTType] {
        switch activeImporter {
            case .audiobook:
                return [.mpeg4Audio, .mp3, .audio]
            case .ebook, .readaloud, nil:
                return [.epub]
        }
    }

    private func handleImporterResult(_ result: Result<[URL], Error>) {
        defer {
            activeImporter = nil
            pendingImporterTarget = nil
        }
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        switch pendingImporterTarget {
            case .ebook:
                if let url = urls.first {
                    selectedEbookURL = url
                    remember(url, role: .ebook)
                }
            case .audiobook:
                selectedAudiobookURLs = urls
                for url in urls { remember(url, role: .audiobook) }
            case .readaloud:
                if let url = urls.first {
                    selectedReadaloudURL = url
                    remember(url, role: .readaloud)
                }
            case nil:
                break
        }
    }
    #endif
}

#endif
