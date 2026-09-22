//
//  AppGroupContainer.swift
//  SilveranKit
//
//  Shared App Group resolution for widgets, Share Extension, and host app.
//  Same candidate order as the Continue widget (AltStore → Info → fallback).
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Resolves the shared container used by widgets and Share Extension intake.
public enum AppGroupContainer {
    public static let appGroupInfoKey = "SILVERAN_WIDGET_APP_GROUP"
    /// AltStore Classic writes resigned App Group identifiers here.
    public static let altStoreAppGroupsInfoKey = "ALTAppGroups"
    public static let fallbackAppGroupIdentifier = "group.com.punkrally.reader"

    /// Candidate App Group identifiers, most-trusted first.
    public static func appGroupCandidates(bundle: Bundle = .main) -> [String] {
        let altStoreGroups = bundle.object(forInfoDictionaryKey: altStoreAppGroupsInfoKey) as? [String]
        let configured = bundle.object(forInfoDictionaryKey: appGroupInfoKey) as? String
        return groupCandidates(
            altStoreGroups: altStoreGroups,
            configured: configured,
            fallback: fallbackAppGroupIdentifier,
        )
    }

    /// Pure helper (unit-tested): filters junk and de-duplicates while preserving order.
    public static func groupCandidates(
        altStoreGroups: [String]?,
        configured: String?,
        fallback: String,
    ) -> [String] {
        var candidates: [String] = []
        for group in altStoreGroups ?? [] where isUsableGroupIdentifier(group) {
            candidates.append(group)
        }
        if let configured, isUsableGroupIdentifier(configured) {
            candidates.append(configured)
        }
        if isUsableGroupIdentifier(fallback) {
            candidates.append(fallback)
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    public static func appGroupIdentifier(bundle: Bundle = .main) -> String {
        let candidates = appGroupCandidates(bundle: bundle)
        if let resolved = candidates.first(where: { containerExists(for: $0) }) {
            return resolved
        }
        return candidates.first ?? fallbackAppGroupIdentifier
    }

    public static func sharedContainerURL(bundle: Bundle = .main) -> URL? {
        for candidate in appGroupCandidates(bundle: bundle) {
            if let url = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: candidate
            ) {
                return url
            }
        }
        return nil
    }

    private static func isUsableGroupIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.contains("$(")
    }

    private static func containerExists(for identifier: String) -> Bool {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        ) != nil
    }
}
