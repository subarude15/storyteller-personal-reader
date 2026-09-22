//
//  ManualDownloadIntakeHandoff.swift
//  SilveranKit
//
//  App Group queue + Darwin wake for Share Extension / Shortcuts → host app.
//  Reuses the same App Group resolution as the Continue widget.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

#if canImport(UIKit)
import UIKit
#endif

/// Cross-process handoff for manual download intake.
public enum ManualDownloadIntakeHandoff {
    public static let darwinName = "com.punkrally.reader.manualDownloadIntake"
    public static let pendingDefaultsKey = "manualDownload.intake.pendingSignal"
    private static let queueFolderName = "ManualDownloadIntake"
    private static let processedFolderName = "Processed"
    private static let torrentsFolderName = "Torrents"
    private static let processedLimit = 64

    private static var suite: UserDefaults? {
        UserDefaults(suiteName: AppGroupContainer.appGroupIdentifier())
    }

    public static func intakeRoot(bundle: Bundle = .main, root: URL? = nil) -> URL? {
        if let root { return root }
        guard let container = AppGroupContainer.sharedContainerURL(bundle: bundle)
        else { return nil }
        return container.appendingPathComponent(queueFolderName, isDirectory: true)
    }

    public static func ensureDirectories(bundle: Bundle = .main, root: URL? = nil) throws -> URL {
        guard let resolved = intakeRoot(bundle: bundle, root: root) else {
            throw ManualDownloadIntakeError.handoffUnavailable
        }
        let fm = FileManager.default
        try fm.createDirectory(at: resolved, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: resolved.appendingPathComponent(torrentsFolderName, isDirectory: true),
            withIntermediateDirectories: true,
        )
        try fm.createDirectory(
            at: resolved.appendingPathComponent(processedFolderName, isDirectory: true),
            withIntermediateDirectories: true,
        )
        return resolved
    }

    /// Stage a torrent into the shared container and enqueue the payload.
    public static func enqueueTorrent(
        from sourceURL: URL,
        mediaType: NASMediaKind,
        source: ManualDownloadIntakeSource,
        displayTitle: String? = nil,
        preferredFilename: String? = nil,
        bundle: Bundle = .main,
        root: URL? = nil,
    ) throws -> ManualDownloadIntakePayload {
        let intake = try ensureDirectories(bundle: bundle, root: root)
        #if canImport(Darwin)
        let access = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if access { sourceURL.stopAccessingSecurityScopedResource() }
        }
        #endif
        let data: Data
        do {
            data = try Data(contentsOf: sourceURL)
        } catch {
            throw ManualDownloadIntakeError.inaccessibleTorrent
        }
        guard !data.isEmpty else { throw ManualDownloadIntakeError.inaccessibleTorrent }

        let id = UUID().uuidString
        var filename = ManualDownloadStaging.safeFilename(
            preferredFilename ?? sourceURL.lastPathComponent,
            fallback: "download.torrent",
        )
        if !filename.lowercased().hasSuffix(".torrent") {
            filename += ".torrent"
        }
        let relative = "\(torrentsFolderName)/\(id)-\(filename)"
        let dest = intake.appendingPathComponent(relative, isDirectory: false)
        try data.write(to: dest, options: [.atomic])
        let title = displayTitle ?? ManualDownloadIntake.displayTitle(fromFilename: filename)
        let payload = ManualDownloadIntakePayload.torrent(
            mediaType: mediaType,
            source: source,
            displayTitle: title,
            relativePath: relative,
            filename: filename,
            byteCount: Int64(data.count),
        )
        // Replace generated id with the one used for the staged filename.
        var stored = payload
        stored.id = id
        try write(payload: stored, root: intake)
        signalPending()
        return stored
    }

    public static func enqueueMagnet(
        url: URL,
        mediaType: NASMediaKind,
        source: ManualDownloadIntakeSource,
        displayTitle: String? = nil,
        bundle: Bundle = .main,
        root: URL? = nil,
    ) throws -> ManualDownloadIntakePayload {
        guard NASMagnetValidation.isValid(url) else {
            throw ManualDownloadIntakeError.malformedMagnet
        }
        let intake = try ensureDirectories(bundle: bundle, root: root)
        let payload = ManualDownloadIntakePayload.magnet(
            url: url,
            mediaType: mediaType,
            source: source,
            displayTitle: displayTitle,
        )
        try write(payload: payload, root: intake)
        signalPending()
        return payload
    }

    public static func signalPending() {
        suite?.set(true, forKey: pendingDefaultsKey)
        suite?.synchronize()
        #if canImport(Darwin)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(darwinName as CFString),
            nil,
            nil,
            true,
        )
        #endif
    }

    public static func hasPendingSignal() -> Bool {
        suite?.bool(forKey: pendingDefaultsKey) == true
    }

    public static func clearPendingSignal() {
        suite?.set(false, forKey: pendingDefaultsKey)
    }

    public static func listPending(bundle: Bundle = .main, root: URL? = nil) -> [ManualDownloadIntakePayload] {
        guard let intake = try? ensureDirectories(bundle: bundle, root: root) else { return [] }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: intake,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles],
        ) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var payloads: [ManualDownloadIntakePayload] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                let payload = try? decoder.decode(ManualDownloadIntakePayload.self, from: data)
            else { continue }
            payloads.append(payload)
        }
        return payloads.sorted { $0.createdAt < $1.createdAt }
    }

    public static func isProcessed(
        _ id: String,
        bundle: Bundle = .main,
        root: URL? = nil,
    ) -> Bool {
        guard let intake = try? ensureDirectories(bundle: bundle, root: root) else { return false }
        let marker = intake.appendingPathComponent(processedFolderName, isDirectory: true)
            .appendingPathComponent("\(id).done", isDirectory: false)
        return FileManager.default.fileExists(atPath: marker.path)
    }

    public static func isFingerprintProcessed(
        _ fingerprint: String,
        bundle: Bundle = .main,
        root: URL? = nil,
    ) -> Bool {
        guard let intake = try? ensureDirectories(bundle: bundle, root: root) else { return false }
        let marker = intake.appendingPathComponent(processedFolderName, isDirectory: true)
            .appendingPathComponent("fp-\(fingerprintHash(fingerprint)).done", isDirectory: false)
        return FileManager.default.fileExists(atPath: marker.path)
    }

    public static func markProcessed(
        _ payload: ManualDownloadIntakePayload,
        bundle: Bundle = .main,
        root: URL? = nil,
    ) {
        guard let intake = try? ensureDirectories(bundle: bundle, root: root) else { return }
        let processed = intake.appendingPathComponent(processedFolderName, isDirectory: true)
        let idMarker = processed.appendingPathComponent("\(payload.id).done", isDirectory: false)
        let fpMarker = processed.appendingPathComponent(
            "fp-\(fingerprintHash(payload.fingerprint)).done",
            isDirectory: false,
        )
        let data = Data()
        try? data.write(to: idMarker, options: [.atomic])
        try? data.write(to: fpMarker, options: [.atomic])
        // Remove the JSON handoff record. Keep torrent bytes until the host copies them.
        let json = intake.appendingPathComponent("\(payload.id).json", isDirectory: false)
        try? FileManager.default.removeItem(at: json)
        trimProcessed(in: processed)
    }

    /// Drop pending intake JSON + staged torrent for a fingerprint without writing a
    /// permanent processed marker. Used by Delete Attempt / Clear Failed so the same
    /// magnet can be shared again later, but cannot auto-recreate a deleted attempt.
    public static func abandonPending(
        matchingFingerprint fingerprint: String,
        bundle: Bundle = .main,
        root: URL? = nil,
    ) {
        let trimmed = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let intake = intakeRoot(bundle: bundle, root: root) else { return }
        for payload in listPending(bundle: bundle, root: root) where payload.fingerprint == trimmed {
            let json = intake.appendingPathComponent("\(payload.id).json", isDirectory: false)
            try? FileManager.default.removeItem(at: json)
            removeStagedTorrent(payload, bundle: bundle, root: root)
        }
    }

    public static func removeStagedTorrent(
        _ payload: ManualDownloadIntakePayload,
        bundle: Bundle = .main,
        root: URL? = nil,
    ) {
        guard let intake = intakeRoot(bundle: bundle, root: root),
            let relative = payload.stagedTorrentRelativePath
        else { return }
        let url = intake.appendingPathComponent(relative, isDirectory: false)
        try? FileManager.default.removeItem(at: url)
    }

    public static func stagedTorrentURL(
        _ payload: ManualDownloadIntakePayload,
        bundle: Bundle = .main,
        root: URL? = nil,
    ) -> URL? {
        guard let intake = intakeRoot(bundle: bundle, root: root),
            let relative = payload.stagedTorrentRelativePath
        else { return nil }
        let url = intake.appendingPathComponent(relative, isDirectory: false)
        return ManualDownloadStaging.exists(url) ? url : nil
    }

    /// Copy App Group torrent into app staging so NASAcquisitionHandler owns it.
    public static func importTorrentIntoAppStaging(
        _ payload: ManualDownloadIntakePayload,
        bundle: Bundle = .main,
        root: URL? = nil,
    ) throws -> URL {
        guard let source = stagedTorrentURL(payload, bundle: bundle, root: root) else {
            throw ManualDownloadIntakeError.inaccessibleTorrent
        }
        let dest = try ManualDownloadStaging.prepareTorrent(
            suggestedFilename: payload.stagedTorrentFilename ?? source.lastPathComponent,
            jobID: payload.id,
        )
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }

    public static func installAppObserver(onPending: @escaping @Sendable () -> Void) {
        #if canImport(Darwin)
        let callback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            let box = Unmanaged<ObserverBox>.fromOpaque(observer).takeUnretainedValue()
            box.onPending()
        }
        let box = ObserverBox(onPending: onPending)
        let retained = Unmanaged.passRetained(box)
        // ponytail: retained for process lifetime.
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            retained.toOpaque(),
            callback,
            darwinName as CFString,
            nil,
            .deliverImmediately,
        )
        #else
        _ = onPending
        #endif
    }

    private static func write(payload: ManualDownloadIntakePayload, root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let url = root.appendingPathComponent("\(payload.id).json", isDirectory: false)
        try data.write(to: url, options: [.atomic])
    }

    private static func fingerprintHash(_ fingerprint: String) -> String {
        let digest = fingerprint.data(using: .utf8) ?? Data()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(40))
    }

    private static func trimProcessed(in folder: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles],
        ) else { return }
        guard files.count > processedLimit else { return }
        let sorted = files.sorted { a, b in
            let da =
                (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            let db =
                (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            return da < db
        }
        for url in sorted.prefix(files.count - processedLimit) {
            try? fm.removeItem(at: url)
        }
    }

    #if canImport(Darwin)
    private final class ObserverBox: @unchecked Sendable {
        let onPending: @Sendable () -> Void
        init(onPending: @escaping @Sendable () -> Void) {
            self.onPending = onPending
        }
    }
    #endif
}
