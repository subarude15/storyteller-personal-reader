//
//  InkAmpPrimaryNavigationTests.swift
//  SilveranTests
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SilveranKit
import Testing

@Suite("ink+amp primary navigation")
struct InkAmpPrimaryNavigationTests {
    @Test func bottomShellHasExactlyFivePrimaryDestinations() {
        #expect(InkAmpPrimaryTab.allCases.count == 5)
        #expect(InkAmpPrimaryNavigation.tabBarDestinations.count == 5)
        #expect(InkAmpPrimaryTab.primaryCount == 5)
    }

    @Test func moreReplacesStatsAsFifthTab() {
        #expect(InkAmpPrimaryTab.allCases.map(\.title) == [
            "Home", "Library", "Shelf", "Podcasts", "More",
        ])
        #expect(InkAmpPrimaryTab.allCases.last == .more)
        #expect(!InkAmpPrimaryNavigation.includesStatsAsPrimaryTab)
        #expect(!DownloadsNavigation.primaryTabBarIncludesStats)
        #expect(DownloadsNavigation.statsLivesUnderMore)
        #expect(InkAmpPrimaryTab.more.systemImage == "ellipsis.circle")
    }

    @Test func moreHubExposesPrimaryAndSecondaryDestinations() {
        #expect(InkAmpMoreDestination.primary.map(\.title) == ["Downloads", "Settings"])
        #expect(InkAmpMoreDestination.secondary.map(\.title) == [
            "Stats", "Requests & Activity", "Services",
        ])
        #expect(InkAmpPrimaryNavigation.statsIsReachableFromMore)
        #expect(InkAmpPrimaryNavigation.downloadsIsReachableFromMore)
        #expect(InkAmpPrimaryNavigation.settingsIsReachableFromMore)
        #expect(InkAmpPrimaryNavigation.requestsActivityIsReachableFromMore)
        #expect(InkAmpPrimaryNavigation.servicesIsReachableFromMore)
    }

    @Test func downloadsAndSettingsStaySeparateFromNASConfig() {
        #expect(DownloadsNavigation.moreDestination == "More")
        #expect(DownloadsNavigation.downloadsDestination == "Downloads")
        #expect(DownloadsNavigation.settingsDestination == "NAS Downloads")
        #expect(DownloadsNavigation.settingsContainsOperationalList == false)
        #expect(DownloadsNavigation.settingsKeepsNASConfiguration)
    }
}
