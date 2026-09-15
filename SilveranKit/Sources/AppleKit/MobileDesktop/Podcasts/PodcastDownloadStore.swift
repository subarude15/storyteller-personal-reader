#if os(iOS)
import Foundation
import Observation
import SilveranKit

/// Disk ledger + files for RSS podcast downloads (separate from LocalMediaActor / SourceCache).
@MainActor
@Observable
public final class PodcastDownloadStore {
    public static let shared = PodcastDownloadStore()

    private static let settingsKey = "punkRally.podcastDownloadSettings.v1"
    private static let ledgerFileName = "podcast_downloads.json"
    private static let rootFolderName = "PodcastDownloads"

    private var records: [PodcastDownloadRecord] = []
    private var settingsCache: PodcastDownloadSettings
    @ObservationIgnored private var downloadTasks: [String: Task<Void, Never>] = [:]
    private var pendingPins: Set<String> = []

    private init() {
        settingsCache = Self.loadSettingsFromDefaults()
        records = Self.loadLedger()
        pendingPins = Self.loadPendingPins()
    }

    // MARK: - Settings

    public var settings: PodcastDownloadSettings {
        settingsCache
    }

    public func updateSettings(_ mutate: (inout PodcastDownloadSettings) -> Void) {
        var next = settingsCache
        mutate(&next)
        settingsCache = next
        Self.saveSettingsToDefaults(next)
    }

    public func markExplainerSeen() {
        updateSettings { $0.hasSeenAutoCleanExplainer = true }
    }

    // MARK: - Records

    public func allDownloads() -> [PodcastDownloadRecord] {
        records.sorted { $0.downloadedAt > $1.downloadedAt }
    }

    public func record(for episodeID: String) -> PodcastDownloadRecord? {
        records.first { $0.episodeID == episodeID }
    }

    public func isDownloaded(_ episodeID: String) -> Bool {
        guard let record = record(for: episodeID) else { return false }
        return FileManager.default.fileExists(atPath: originalURL(for: record).path)
    }

    /// Playback URL: Clean sibling when chip == Clean and file exists; else Original.
    public func localAudioURL(for episodeID: String) -> URL? {
        guard let record = record(for: episodeID) else { return nil }
        if record.adStripState == .clean,
            let cleanName = record.cleanLocalFileName
        {
            let clean = episodeFolder(for: record.episodeID).appendingPathComponent(cleanName)
            if FileManager.default.fileExists(atPath: clean.path) {
                return clean
            }
        }
        let original = originalURL(for: record)
        guard FileManager.default.fileExists(atPath: original.path) else { return nil }
        return original
    }

    public func adStripState(for episodeID: String) -> PodcastAdStripState? {
        record(for: episodeID)?.adStripState
    }

    public func isDownloading(_ episodeID: String) -> Bool {
        downloadTasks[episodeID] != nil
    }

    public func isCleaning(_ episodeID: String) -> Bool {
        record(for: episodeID)?.adStripState == .cleaning
    }

    // MARK: - Pin / progress

    public func setPinned(_ episodeID: String, pinned: Bool) {
        if pinned {
            pendingPins.insert(episodeID)
        } else {
            pendingPins.remove(episodeID)
        }
        Self.savePendingPins(pendingPins)
        guard let index = records.firstIndex(where: { $0.episodeID == episodeID }) else { return }
        records[index].isPinned = pinned
        persistLedger()
    }

    /// Keep an episode: pin if already downloaded, otherwise download then pin.
    /// Queue / Keep always uses the Clean pending path (auto-strip intent).
    public func keepEpisode(
        episodeID: String,
        title: String,
        showTitle: String?,
        feedURL: URL?,
        remoteAudioURL: URL?,
        durationSeconds: TimeInterval?
    ) {
        pendingPins.insert(episodeID)
        Self.savePendingPins(pendingPins)
        if let index = records.firstIndex(where: { $0.episodeID == episodeID }) {
            records[index].isPinned = true
            persistLedger()
            // Already on disk: if Original only, kick stub Clean so Keep matches queue UX.
            if records[index].adStripState == .original,
                FileManager.default.fileExists(atPath: originalURL(for: records[index]).path)
            {
                Task { await runCleanPipeline(episodeID: episodeID) }
            }
            return
        }
        guard let remoteAudioURL else { return }
        enqueueDownload(
            episodeID: episodeID,
            title: title,
            showTitle: showTitle,
            feedURL: feedURL,
            remoteAudioURL: remoteAudioURL,
            durationSeconds: durationSeconds,
            intent: .clean
        )
    }

    public func updatePlayback(
        episodeID: String,
        positionSeconds: TimeInterval,
        durationSeconds: TimeInterval?,
        markFinished: Bool = false
    ) {
        guard let index = records.firstIndex(where: { $0.episodeID == episodeID }) else { return }
        records[index].positionSeconds = max(0, positionSeconds)
        if let durationSeconds, durationSeconds > 0 {
            records[index].durationSeconds = durationSeconds
        }
        records[index].lastPlayedAt = Date()
        if markFinished
            || PodcastShelfPrunePolicy.isFinished(records[index], settings: settingsCache)
        {
            records[index].isFinished = true
        }
        persistLedger()

        if markFinished, records.indices.contains(index), records[index].isFinished {
            pruneFinishedEpisodeIfNeeded(episodeID: episodeID)
        }
    }

    /// Remove a finished download after close when Auto-clean + Remove when finished.
    public func pruneFinishedEpisodeIfNeeded(episodeID: String) {
        guard settingsCache.autoCleanEnabled else { return }
        guard settingsCache.removeWhenFinished else { return }
        guard settingsCache.hasSeenAutoCleanExplainer else { return }
        guard let record = record(for: episodeID), !record.isPinned else { return }
        guard PodcastShelfPrunePolicy.isFinished(record, settings: settingsCache) else { return }
        deleteDownload(episodeID: episodeID)
        updateSettings {
            $0.lastPruneAt = Date()
            $0.lastPruneCount = 1
        }
    }

    // MARK: - Download / delete

    /// Enqueue a download. `.original` = manual Download now (no strip).
    /// `.clean` = Strip-then-download or queue/Keep (Clean pending after Original).
    public func enqueueDownload(
        episodeID: String,
        title: String,
        showTitle: String?,
        feedURL: URL?,
        remoteAudioURL: URL,
        durationSeconds: TimeInterval?,
        intent: PodcastDownloadIntent = .original
    ) {
        guard downloadTasks[episodeID] == nil else { return }
        if isDownloaded(episodeID) {
            if intent == .clean,
                let record = record(for: episodeID),
                record.adStripState != .clean
            {
                Task { await runCleanPipeline(episodeID: episodeID) }
            }
            return
        }

        downloadTasks[episodeID] = Task { [weak self] in
            defer { Task { @MainActor in self?.downloadTasks[episodeID] = nil } }
            await self?.performDownload(
                episodeID: episodeID,
                title: title,
                showTitle: showTitle,
                feedURL: feedURL,
                remoteAudioURL: remoteAudioURL,
                durationSeconds: durationSeconds,
                intent: intent
            )
        }
    }

    public func deleteDownload(episodeID: String) {
        downloadTasks[episodeID]?.cancel()
        downloadTasks[episodeID] = nil
        guard let index = records.firstIndex(where: { $0.episodeID == episodeID }) else { return }
        let record = records[index]
        let folder = episodeFolder(for: record.episodeID)
        try? FileManager.default.removeItem(at: folder)
        records.remove(at: index)
        persistLedger()
    }

    // MARK: - Prune

    public func previewPrune(now: Date = Date()) -> [PodcastPruneCandidate] {
        PodcastShelfPrunePolicy.candidates(
            from: records,
            settings: settingsCache,
            now: now
        )
    }

    /// Runs prune when auto-clean is on and the one-time explainer has been seen.
    @discardableResult
    public func runAutoPruneIfAllowed(now: Date = Date()) -> Int {
        guard settingsCache.autoCleanEnabled else { return 0 }
        guard settingsCache.hasSeenAutoCleanExplainer else { return 0 }
        return applyPrune(previewPrune(now: now), at: now)
    }

    /// Clean now / confirmation — ignores explainer gate (user explicitly asked).
    @discardableResult
    public func applyPrune(_ candidates: [PodcastPruneCandidate], at now: Date = Date()) -> Int {
        guard !candidates.isEmpty else { return 0 }
        let ids = Set(candidates.map(\.record.episodeID))
        for id in ids {
            deleteDownload(episodeID: id)
        }
        updateSettings {
            $0.lastPruneAt = now
            $0.lastPruneCount = ids.count
        }
        return ids.count
    }

    /// Overnight / foreground: at most once per 18h.
    @discardableResult
    public func runOvernightPruneIfDue(now: Date = Date()) -> Int {
        guard settingsCache.autoCleanEnabled else { return 0 }
        guard settingsCache.hasSeenAutoCleanExplainer else { return 0 }
        if let last = settingsCache.lastPruneAt,
            now.timeIntervalSince(last) < 18 * 3600
        {
            return 0
        }
        return runAutoPruneIfAllowed(now: now)
    }

    // MARK: - Private

    private func performDownload(
        episodeID: String,
        title: String,
        showTitle: String?,
        feedURL: URL?,
        remoteAudioURL: URL,
        durationSeconds: TimeInterval?,
        intent: PodcastDownloadIntent
    ) async {
        do {
            let (tempURL, response) = try await URLSession.shared.download(from: remoteAudioURL)
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: tempURL)
                return
            }
            let ext = Self.preferredExtension(for: remoteAudioURL, response: response)
            let folder = try episodeDirectory(for: episodeID)
            let fileName = "audio.\(ext)"
            let dest = folder.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tempURL, to: dest)
            let size =
                (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?
                .int64Value

            let record = PodcastDownloadRecord(
                episodeID: episodeID,
                title: title,
                showTitle: showTitle,
                feedURL: feedURL,
                remoteAudioURL: remoteAudioURL,
                localFileName: fileName,
                downloadedAt: Date(),
                durationSeconds: durationSeconds,
                isPinned: pendingPins.contains(episodeID),
                byteSize: size,
                adStripState: .original,
                cleanLocalFileName: nil
            )
            if let index = records.firstIndex(where: { $0.episodeID == episodeID }) {
                var merged = record
                merged.isPinned = records[index].isPinned || pendingPins.contains(episodeID)
                merged.positionSeconds = records[index].positionSeconds
                merged.lastPlayedAt = records[index].lastPlayedAt
                merged.isFinished = records[index].isFinished
                // Preserve an existing Clean sibling if re-downloading Original.
                merged.cleanLocalFileName = records[index].cleanLocalFileName
                merged.adStripState = records[index].adStripState == .clean ? .clean : .original
                records[index] = merged
            } else {
                records.append(record)
            }
            persistLedger()

            if intent == .clean {
                await runCleanPipeline(episodeID: episodeID)
            }
        } catch {
            debugLog("[PodcastDownloadStore] download failed for \(episodeID): \(error)")
        }
    }

    /// Stub Clean path: Cleaning… → copy Original to `audio.clean.*` → Clean.
    /// On failure/timeout: chip stays Original; Original file remains playable.
    private func runCleanPipeline(episodeID: String) async {
        guard let index = records.firstIndex(where: { $0.episodeID == episodeID }) else { return }
        let record = records[index]
        let original = originalURL(for: record)
        guard FileManager.default.fileExists(atPath: original.path) else { return }

        records[index].adStripState = .cleaning
        persistLedger()

        let ext = original.pathExtension.isEmpty ? "mp3" : original.pathExtension
        let cleanName = "audio.clean.\(ext)"
        let cleanURL = episodeFolder(for: episodeID).appendingPathComponent(cleanName)

        do {
            try await StubPodcastAdStripPipeline.shared.produceCleanCopy(
                originalURL: original,
                cleanURL: cleanURL
            )
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: cleanURL)
                if let i = records.firstIndex(where: { $0.episodeID == episodeID }) {
                    records[i].adStripState = .original
                    persistLedger()
                }
                return
            }
            guard let i = records.firstIndex(where: { $0.episodeID == episodeID }) else { return }
            // Never delete Original when Clean lands.
            records[i].cleanLocalFileName = cleanName
            records[i].adStripState = .clean
            persistLedger()
        } catch {
            debugLog("[PodcastDownloadStore] clean stub failed for \(episodeID): \(error)")
            try? FileManager.default.removeItem(at: cleanURL)
            if let i = records.firstIndex(where: { $0.episodeID == episodeID }) {
                records[i].adStripState = .original
                records[i].cleanLocalFileName = nil
                persistLedger()
            }
        }
    }

    private func originalURL(for record: PodcastDownloadRecord) -> URL {
        episodeFolder(for: record.episodeID).appendingPathComponent(record.localFileName)
    }

    private func episodeFolder(for episodeID: String) -> URL {
        rootDirectory().appendingPathComponent(Self.safeFolderName(episodeID), isDirectory: true)
    }

    private func episodeDirectory(for episodeID: String) throws -> URL {
        let dir = episodeFolder(for: episodeID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func rootDirectory() -> URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent(Self.rootFolderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func persistLedger() {
        let url = rootDirectory().appendingPathComponent(Self.ledgerFileName)
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private static func loadLedger() -> [PodcastDownloadRecord] {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = base
            .appendingPathComponent(rootFolderName, isDirectory: true)
            .appendingPathComponent(ledgerFileName)
        guard
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([PodcastDownloadRecord].self, from: data)
        else { return [] }
        return decoded
    }

    private static func loadSettingsFromDefaults() -> PodcastDownloadSettings {
        let defaults = UserDefaults.standard
        guard
            let data = defaults.data(forKey: settingsKey),
            let decoded = try? JSONDecoder().decode(PodcastDownloadSettings.self, from: data)
        else {
            return .default
        }
        return decoded
    }

    private static func saveSettingsToDefaults(_ settings: PodcastDownloadSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: settingsKey)
    }

    private static let pendingPinsKey = "punkRally.podcastPendingPins.v1"

    private static func loadPendingPins() -> Set<String> {
        let values = UserDefaults.standard.stringArray(forKey: pendingPinsKey) ?? []
        return Set(values)
    }

    private static func savePendingPins(_ pins: Set<String>) {
        UserDefaults.standard.set(Array(pins), forKey: pendingPinsKey)
    }

    private static func safeFolderName(_ episodeID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = episodeID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let name = String(mapped)
        return name.isEmpty ? UUID().uuidString : String(name.prefix(120))
    }

    private static func preferredExtension(for url: URL, response: URLResponse) -> String {
        if let mime = response.mimeType {
            switch mime {
                case "audio/mpeg", "audio/mp3": return "mp3"
                case "audio/mp4", "audio/x-m4a", "audio/aac": return "m4a"
                case "audio/ogg", "application/ogg": return "ogg"
                case "audio/wav", "audio/x-wav": return "wav"
                default: break
            }
        }
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty, ext.count <= 5 { return ext }
        return "mp3"
    }
}
#endif
