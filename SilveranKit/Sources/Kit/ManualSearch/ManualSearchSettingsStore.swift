//
//  ManualSearchSettingsStore.swift
//  SilveranKit
//
//  Live Manual Search preferences. Persistence goes through the PR #66
//  settings journal — not a second sync system.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

@MainActor
public final class ManualSearchSettingsStore {
    public static let shared = ManualSearchSettingsStore()

    public private(set) var snapshot: ManualSearchSettingsSnapshot

    public init(journal: SettingsSyncJournal = .live()) {
        if let document = journal.load() {
            snapshot = SettingsSyncApply.manualSearch(document: document)
        } else {
            snapshot = ManualSearchSettingsSnapshot()
        }
    }

    public var enabledProviders: [ManualSearchProvider] {
        snapshot.enabledProviders
    }

    public var openInAppBrowser: Bool {
        snapshot.openInAppBrowser
    }

    public func applySynced(_ snapshot: ManualSearchSettingsSnapshot) {
        guard snapshot != self.snapshot else { return }
        self.snapshot = snapshot
        NotificationCenter.default.post(name: .inkampManualSearchSettingsDidChange, object: nil)
    }

    public func replace(_ snapshot: ManualSearchSettingsSnapshot, at date: Date = Date()) {
        let normalized = ManualSearchSettingsSnapshot(
            providers: ManualSearchCatalog.reindex(snapshot.providers),
            openInAppBrowser: snapshot.openInAppBrowser,
        )
        self.snapshot = normalized
        SettingsSyncCoordinator.shared.noteLocalManualSearchChange(
            providers: normalized.providers,
            openInAppBrowser: normalized.openInAppBrowser,
            at: date,
        )
        NotificationCenter.default.post(name: .inkampManualSearchSettingsDidChange, object: nil)
    }

    public func setEnabled(id: String, enabled: Bool) {
        var providers = snapshot.providers
        guard let index = providers.firstIndex(where: { $0.id == id }) else { return }
        providers[index].enabled = enabled
        replace(ManualSearchSettingsSnapshot(providers: providers, openInAppBrowser: snapshot.openInAppBrowser))
    }

    public func move(from offsets: IndexSet, to destination: Int) {
        var providers = snapshot.providers.sorted { $0.sortOrder < $1.sortOrder }
        // Foundation-only: SwiftUI's `move(fromOffsets:toOffset:)` is unavailable
        // when SilveranKit is built under `swift test` without importing SwiftUI.
        providers.rearrange(fromOffsets: offsets, toOffset: destination)
        replace(ManualSearchSettingsSnapshot(providers: providers, openInAppBrowser: snapshot.openInAppBrowser))
    }

    public func addCustom(
        name: String,
        searchURLTemplate: String,
        supportedMediaTypes: [ManualSearchMediaType] = ManualSearchMediaType.allCases,
        symbolName: String = "globe",
    ) -> ManualSearchTemplateError? {
        let provider = ManualSearchProvider(
            id: "custom-\(UUID().uuidString.lowercased())",
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            searchURLTemplate: searchURLTemplate.trimmingCharacters(in: .whitespacesAndNewlines),
            supportedMediaTypes: supportedMediaTypes.isEmpty ? ManualSearchMediaType.allCases : supportedMediaTypes,
            symbolName: ManualSearchSymbolName.normalize(symbolName),
            sortOrder: snapshot.providers.count,
            isBuiltIn: false,
        )
        if let error = ManualSearchProviderValidation.validateForSave(provider) {
            return error
        }
        var providers = snapshot.providers
        providers.append(provider)
        replace(ManualSearchSettingsSnapshot(providers: providers, openInAppBrowser: snapshot.openInAppBrowser))
        return nil
    }

    public func update(_ provider: ManualSearchProvider) -> ManualSearchTemplateError? {
        if let error = ManualSearchProviderValidation.validateForSave(provider) {
            return error
        }
        var providers = snapshot.providers
        guard let index = providers.firstIndex(where: { $0.id == provider.id }) else { return .malformedTemplate }
        var updated = provider
        updated.symbolName = ManualSearchSymbolName.normalize(provider.symbolName)
        if providers[index].isBuiltIn {
            updated.isBuiltIn = true
            updated.id = providers[index].id
        } else {
            updated.isBuiltIn = false
        }
        providers[index] = updated
        replace(ManualSearchSettingsSnapshot(providers: providers, openInAppBrowser: snapshot.openInAppBrowser))
        return nil
    }

    public func deleteCustom(id: String) {
        let remaining = snapshot.providers.filter { provider in
            if provider.id == id { return provider.isBuiltIn }
            return true
        }
        guard remaining.count != snapshot.providers.count else { return }
        replace(ManualSearchSettingsSnapshot(providers: remaining, openInAppBrowser: snapshot.openInAppBrowser))
    }

    public func resetBuiltIn(id: String) {
        guard let catalog = ManualSearchCatalog.builtIn(id: id),
            let index = snapshot.providers.firstIndex(where: { $0.id == id && $0.isBuiltIn })
        else { return }
        var providers = snapshot.providers
        var restored = catalog
        restored.sortOrder = providers[index].sortOrder
        providers[index] = restored
        replace(ManualSearchSettingsSnapshot(providers: providers, openInAppBrowser: snapshot.openInAppBrowser))
    }

    public func setOpenInAppBrowser(_ enabled: Bool) {
        guard snapshot.openInAppBrowser != enabled else { return }
        replace(ManualSearchSettingsSnapshot(providers: snapshot.providers, openInAppBrowser: enabled))
    }
}

extension Array {
    /// Foundation-only stand-in for SwiftUI's `move(fromOffsets:toOffset:)`.
    /// Preserves relative order of moved elements; `destination` is an insertion
    /// index in the pre-move array (`0...count`).
    mutating func rearrange(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard !offsets.isEmpty else { return }
        let sorted = offsets.sorted()
        let moved = sorted.map { self[$0] }
        for index in sorted.reversed() {
            remove(at: index)
        }
        insert(contentsOf: moved, at: destination - sorted.filter { $0 < destination }.count)
    }
}
