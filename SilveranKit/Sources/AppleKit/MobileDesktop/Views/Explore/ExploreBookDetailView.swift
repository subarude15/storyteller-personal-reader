#if os(iOS)
import SilveranKit
import SwiftUI

/// Detail surface for an Explore catalog title: Read now + Add to Library.
public struct ExploreBookDetailView: View {
    let book: ExploreBook

    @Environment(MediaViewModel.self) private var mediaViewModel: MediaViewModel?
    @Environment(\.dismiss) private var dismiss

    @State private var isDownloading = false
    @State private var downloadProgress: Double?
    @State private var isImporting = false
    @State private var importProgress: Double?
    @State private var importProgressLabel: String?
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var importedRecord: ExploreImportRecord?

    public init(book: ExploreBook) {
        self.book = book
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 16) {
                    ExploreRemoteCover(url: book.coverURL)
                        .frame(width: 140, height: 210)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        Text(book.title)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(book.authorDisplay)
                            .font(.body)
                            .foregroundStyle(.secondary)
                        Text(book.sourceName)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        if let rights = book.rights, !rights.isEmpty {
                            Text(rights)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Rights information not provided by \(book.sourceName).")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }

                if let summary = book.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.body)
                        .foregroundStyle(.primary.opacity(0.9))
                }

                VStack(spacing: 12) {
                    if let importedRecord {
                        Button {
                            openImported(importedRecord.storytellerBookID)
                        } label: {
                            Label("Open in Library", systemImage: "books.vertical")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            Task { await readNow() }
                        } label: {
                            if isDownloading {
                                HStack {
                                    ProgressView(value: downloadProgress)
                                    Text("Downloading…")
                                }
                                .frame(maxWidth: .infinity)
                            } else {
                                Label("Read now", systemImage: "book")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isDownloading || isImporting || book.epubURL == nil)

                        Button {
                            Task { await addToLibrary() }
                        } label: {
                            if isImporting {
                                HStack {
                                    ProgressView(value: importProgress)
                                    Text(importProgressLabel ?? "Uploading…")
                                }
                                .frame(maxWidth: .infinity)
                            } else {
                                Label("Add to Library", systemImage: "square.and.arrow.down")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isDownloading || isImporting || book.epubURL == nil)
                    }
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote)
                        .foregroundStyle(statusIsError ? Color.red : Color.secondary)
                }
            }
            .padding(20)
        }
        .navigationTitle("Book")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            importedRecord = ExploreImportStore.shared.record(for: book)
        }
    }

    // MARK: - Actions

    private func readNow() async {
        guard let epubURL = book.epubURL else {
            statusIsError = true
            statusMessage = ExploreCatalogError.noAcquisitionLink.localizedDescription
            return
        }
        isDownloading = true
        downloadProgress = 0
        statusMessage = nil
        defer {
            isDownloading = false
            downloadProgress = nil
        }
        do {
            let fileURL = try await ExploreBookCache.shared.downloadEPUB(
                sourceID: book.sourceID,
                itemID: book.itemID,
                from: epubURL,
                progress: { value in
                    Task { @MainActor in
                        downloadProgress = value
                    }
                }
            )
            let metadata = ExploreBookIdentity.makeEphemeralMetadata(for: book)
            let bookData = PlayerBookData(
                metadata: metadata,
                localMediaPath: fileURL,
                category: .ebook
            )
            PlayerPresenter.shared.present(bookData)
        } catch {
            statusIsError = true
            statusMessage = (error as? ExploreCatalogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }

    private func addToLibrary() async {
        if let existing = ExploreImportStore.shared.record(for: book) {
            importedRecord = existing
            statusIsError = false
            statusMessage = "Already in your library."
            return
        }
        guard let epubURL = book.epubURL else {
            statusIsError = true
            statusMessage = ExploreCatalogError.noAcquisitionLink.localizedDescription
            return
        }

        isImporting = true
        importProgress = 0.05
        importProgressLabel = "Preparing…"
        statusMessage = nil
        defer {
            isImporting = false
            importProgress = nil
            importProgressLabel = nil
        }

        do {
            let fileURL = try await ExploreBookCache.shared.downloadEPUB(
                sourceID: book.sourceID,
                itemID: book.itemID,
                from: epubURL,
                progress: { value in
                    Task { @MainActor in
                        importProgress = 0.05 + 0.2 * value
                        importProgressLabel = "Downloading…"
                    }
                }
            )

            let sourceID = try await resolveUploadSourceID()
            importProgressLabel = "Reading ebook…"
            importProgress = 0.28
            let data = try Data(contentsOf: fileURL)
            let filename = safeEPUBFilename(for: book, fallbackURL: epubURL)
            let asset = StorytellerUploadAsset(
                format: .ebook,
                filename: filename,
                data: data,
                contentType: "application/epub+zip",
                relativePath: nil
            )

            importProgressLabel = "Uploading…"
            importProgress = 0.32
            let uploadBookUUID = UUID().uuidString
            let bookID = BookID(sourceID: sourceID, uuid: uploadBookUUID)
            let success = await BookServiceActor.shared.uploadBookAssets(
                bookID: bookID,
                ebook: asset,
                audiobooks: [],
                readaloud: nil,
                onProgress: { fraction in
                    Task { @MainActor in
                        let scaled = 0.32 + 0.68 * min(max(fraction, 0), 1)
                        if scaled > (importProgress ?? 0) {
                            importProgress = scaled
                        }
                    }
                }
            )

            await BookServiceActor.shared.fetchLibraryInformation()

            guard success else {
                statusIsError = true
                statusMessage =
                    "Couldn't upload to Storyteller. Check Wi‑Fi / LAN and try again."
                return
            }

            let record = ExploreImportRecord(
                exploreID: book.id,
                storytellerBookID: bookID,
                title: book.title
            )
            ExploreImportStore.shared.save(record)
            importedRecord = record
            statusIsError = false
            statusMessage = "Added to Library."
            importProgress = 1
        } catch {
            statusIsError = true
            statusMessage = (error as? ExploreCatalogError)?.localizedDescription
                ?? error.localizedDescription
        }
    }

    private func resolveUploadSourceID() async throws -> BookSourceID {
        let sources = await BookServiceActor.shared.bookSources
            .filter { $0.capabilities.canUploadBooks }
            .sorted { lhs, rhs in
                if lhs.kind == .storyteller && rhs.kind != .storyteller { return true }
                if lhs.kind != .storyteller && rhs.kind == .storyteller { return false }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        if let preferred = sources.first(where: { $0.kind == .storyteller }) {
            return preferred.id
        }
        if let first = sources.first {
            return first.id
        }
        throw ExploreCatalogError.importFailed(
            "Add a Storyteller source in Settings before importing."
        )
    }

    private func safeEPUBFilename(for book: ExploreBook, fallbackURL: URL) -> String {
        let raw = book.title.isEmpty ? fallbackURL.deletingPathExtension().lastPathComponent : book.title
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "book" : String(cleaned.prefix(80))
        return base.lowercased().hasSuffix(".epub") ? base : "\(base).epub"
    }

    private func openImported(_ bookID: BookID) {
        if let item = mediaViewModel?.library.bookMetaData.first(where: { $0.id == bookID }) {
            mediaViewModel?.pendingOpenBookID = item.id
            statusIsError = false
            statusMessage = "Find “\(item.title)” in Library."
        } else {
            statusIsError = false
            statusMessage = "Imported — refresh Library if it isn’t visible yet."
        }
    }
}
#endif
