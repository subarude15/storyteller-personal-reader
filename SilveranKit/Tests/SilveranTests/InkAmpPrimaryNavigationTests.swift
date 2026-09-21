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

    // MARK: - More → Requests & Activity deep links

    @Test func manualRequestsActivityOpensGenericList() {
        let route = InkAmpMoreNavRoute.from(.requestsActivity)
        #expect(route == .requestsActivity(requestID: nil))
        #expect(route.opensGenericRequestActivityList)
        #expect(route.requestActivityID == nil)
        // Matches RequestActivityView(initialRequestID:) for the hub row.
        #expect(InkAmpMoreNavRoute.from(.requestsActivity).requestActivityID == nil)
    }

    @Test func notificationWithRequestIDPreservesIDThroughMoreRoute() {
        let coordinator = RequestActivityNavigationCoordinator()
        let parsed = RequestActivityNavigation.request(
            from: ["requestID": "req-42", "kind": "available"]
        )
        coordinator.set(parsed.destination)

        let route = InkAmpMoreRequestActivityDeepLink.consumePendingRoute(coordinator: coordinator)
        #expect(route == .requestsActivity(requestID: "req-42"))
        #expect(route?.requestActivityID == "req-42")
        #expect(route?.opensGenericRequestActivityList == false)
    }

    @Test func requestIDReachesRequestActivityInitialRequestID() {
        // NavigationDestination builds RequestActivityView(initialRequestID: requestID).
        let withID = InkAmpMoreNavRoute.requestsActivity(requestID: "chain-9")
        #expect(withID.requestActivityID == "chain-9")

        let generic = InkAmpMoreNavRoute.requestsActivity(requestID: nil)
        #expect(generic.requestActivityID == nil)
    }

    @Test func notificationWithoutRequestIDOpensGenericActivity() {
        let coordinator = RequestActivityNavigationCoordinator()
        let parsed = RequestActivityNavigation.request(from: ["kind": "needsAttention"])
        coordinator.set(parsed.destination)

        let route = InkAmpMoreRequestActivityDeepLink.consumePendingRoute(coordinator: coordinator)
        #expect(route == .requestsActivity(requestID: nil))
        #expect(route?.opensGenericRequestActivityList == true)
        #expect(route?.requestActivityID == nil)
    }

    @Test func pendingRequestDestinationSurvivesUntilMoreConsumes() {
        // Simulate: notification stored while user is on another tab; More not consumed yet.
        let coordinator = RequestActivityNavigationCoordinator()
        coordinator.set(.detail(requestID: "pending-while-on-home"))

        #expect(coordinator.peek() == .detail(requestID: "pending-while-on-home"))
        // Tab switch alone must not clear the destination.
        #expect(coordinator.peek()?.requestID == "pending-while-on-home")

        let route = InkAmpMoreRequestActivityDeepLink.consumePendingRoute(coordinator: coordinator)
        #expect(route == .requestsActivity(requestID: "pending-while-on-home"))
        #expect(coordinator.peek() == nil)
    }

    @Test func repeatedConsumeDoesNotDuplicateRoute() {
        let coordinator = RequestActivityNavigationCoordinator()
        coordinator.set(.detail(requestID: "once-only"))

        var path: [InkAmpMoreNavRoute] = []
        func applyPending() {
            guard let route = InkAmpMoreRequestActivityDeepLink.consumePendingRoute(
                coordinator: coordinator
            ) else { return }
            path = [route]
        }

        applyPending() // first appearance / parent handler
        applyPending() // SwiftUI re-appearance / second onAppear
        applyPending() // another lifecycle tick

        #expect(path == [.requestsActivity(requestID: "once-only")])
        #expect(path.count == 1)
        #expect(InkAmpMoreRequestActivityDeepLink.consumePendingRoute(coordinator: coordinator) == nil)
    }

    @Test func ensurePendingDoesNotOverwriteExistingDestination() {
        let coordinator = RequestActivityNavigationCoordinator()
        coordinator.set(.detail(requestID: "kept"))
        InkAmpMoreRequestActivityDeepLink.ensurePending(
            from: ["requestID": "other"],
            coordinator: coordinator,
        )
        #expect(coordinator.peek() == .detail(requestID: "kept"))
    }

    @Test func ensurePendingSeedsWhenEmpty() {
        let coordinator = RequestActivityNavigationCoordinator()
        InkAmpMoreRequestActivityDeepLink.ensurePending(
            from: ["requestID": "seeded"],
            coordinator: coordinator,
        )
        #expect(coordinator.peek() == .detail(requestID: "seeded"))
    }
}
