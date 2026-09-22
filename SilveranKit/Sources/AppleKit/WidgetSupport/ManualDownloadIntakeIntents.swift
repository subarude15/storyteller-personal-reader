#if os(iOS)
import AppIntents
import Foundation
import SilveranKit
import UniformTypeIdentifiers

/// Shortcuts action: enqueue a magnet or .torrent for PR71 routing.
/// Does not inspect the clipboard — only explicit parameters.
public struct AddDownloadToInkAmpIntent: AppIntent {
    public static let title: LocalizedStringResource = "Add Download to ink+amp"
    public static let description = IntentDescription(
        "Send a magnet link or .torrent file to ink+amp for Deluge download and library routing."
    )
    public static let openAppWhenRun: Bool = true

    @Parameter(title: "URL or magnet")
    public var url: URL?

    @Parameter(title: "Magnet or link text")
    public var text: String?

    @Parameter(title: "Torrent file")
    public var torrentFile: IntentFile?

    @Parameter(title: "Media type")
    public var mediaType: ManualDownloadIntakeMediaTypeAppEnum

    public init() {
        self.mediaType = .ebook
    }

    public init(
        url: URL?,
        text: String?,
        torrentFile: IntentFile?,
        mediaType: ManualDownloadIntakeMediaTypeAppEnum,
    ) {
        self.url = url
        self.text = text
        self.torrentFile = torrentFile
        self.mediaType = mediaType
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let kind = mediaType.nasMediaKind

        if let torrentFile {
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("inkamp-intent-\(UUID().uuidString).torrent")
            try torrentFile.data.write(to: temp)
            defer { try? FileManager.default.removeItem(at: temp) }
            switch ManualDownloadIntake.classifyTorrentFile(url: temp) {
                case .torrent(let filename, let title):
                    let payload = try ManualDownloadIntakeHandoff.enqueueTorrent(
                        from: temp,
                        mediaType: kind,
                        source: .appIntent,
                        displayTitle: title,
                        preferredFilename: filename,
                    )
                    return .result(value: "Queued \(payload.displayTitle)")
                case .magnet:
                    throw ManualDownloadIntakeIntentError.message(
                        ManualDownloadIntakeError.unsupportedFile.message
                    )
                case .rejected(let error):
                    throw ManualDownloadIntakeIntentError.message(error.message)
            }
        }

        let classified: ManualDownloadIntakeClassification
        if let url {
            classified = ManualDownloadIntake.classify(url: url)
        } else if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            classified = ManualDownloadIntake.classify(text: text)
        } else {
            throw ManualDownloadIntakeIntentError.message(
                ManualDownloadIntakeError.emptyPayload.message
            )
        }

        switch classified {
            case .magnet(let magnetURL, let title):
                let payload = try ManualDownloadIntakeHandoff.enqueueMagnet(
                    url: magnetURL,
                    mediaType: kind,
                    source: .appIntent,
                    displayTitle: title,
                )
                return .result(value: "Queued \(payload.displayTitle)")
            case .torrent:
                throw ManualDownloadIntakeIntentError.message(
                    "Share the .torrent file itself, or open it in ink+amp Downloads."
                )
            case .rejected(let error):
                throw ManualDownloadIntakeIntentError.message(error.message)
        }
    }
}

public enum ManualDownloadIntakeMediaTypeAppEnum: String, AppEnum {
    case ebook
    case audiobook

    public static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Media type")
    public static var caseDisplayRepresentations: [ManualDownloadIntakeMediaTypeAppEnum: DisplayRepresentation] = [
        .ebook: "eBook",
        .audiobook: "Audiobook",
    ]

    public var nasMediaKind: NASMediaKind {
        switch self {
            case .ebook: .ebook
            case .audiobook: .audiobook
        }
    }
}

public struct ManualDownloadIntakeIntentError: Error, CustomLocalizedStringResourceConvertible {
    public var message: String

    public static func message(_ message: String) -> ManualDownloadIntakeIntentError {
        ManualDownloadIntakeIntentError(message: message)
    }

    public var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: message)
    }
}
#endif
