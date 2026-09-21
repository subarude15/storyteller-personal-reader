//
//  InkAmpPrimaryNavigation.swift
//  SilveranKit
//
//  Primary five-tab shell + More hub destinations for ink+amp.
//
//  SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// The five bottom-bar destinations. Stats lives under More, not as its own tab.
public enum InkAmpPrimaryTab: String, CaseIterable, Sendable, Hashable {
    case home
    case library
    case shelf
    case podcasts
    case more

    public var title: String {
        switch self {
            case .home: "Home"
            case .library: "Library"
            case .shelf: "Shelf"
            case .podcasts: "Podcasts"
            case .more: "More"
        }
    }

    public var systemImage: String {
        switch self {
            case .home: "house.fill"
            case .library: "books.vertical.fill"
            case .shelf: "arrow.down.circle.fill"
            case .podcasts: "mic.fill"
            case .more: "ellipsis.circle"
        }
    }

    public static var primaryCount: Int { allCases.count }
}

/// Destinations surfaced from the More hub (not Settings subsections).
public enum InkAmpMoreDestination: String, CaseIterable, Sendable, Hashable {
    case downloads
    case settings
    case stats
    case requestsActivity
    case services

    public var title: String {
        switch self {
            case .downloads: "Downloads"
            case .settings: "Settings"
            case .stats: "Stats"
            case .requestsActivity: "Requests & Activity"
            case .services: "Services"
        }
    }

    public var subtitle: String? {
        switch self {
            case .downloads: "Active, failed, and recent transfers"
            case .settings: "App, playback, library, and integrations"
            case .stats, .requestsActivity, .services: nil
        }
    }

    public var systemImage: String {
        switch self {
            case .downloads: "arrow.down.circle"
            case .settings: "gearshape"
            case .stats: "chart.bar.fill"
            case .requestsActivity: "tray.full"
            case .services: "heart.text.square"
        }
    }

    /// Primary rows shown above the Other section.
    public static var primary: [InkAmpMoreDestination] { [.downloads, .settings] }

    /// Secondary rows under Other.
    public static var secondary: [InkAmpMoreDestination] {
        [.stats, .requestsActivity, .services]
    }
}

public enum InkAmpPrimaryNavigation {
    /// Exactly five primary destinations; More replaces Stats in the tab bar.
    public static var tabBarDestinations: [InkAmpPrimaryTab] { InkAmpPrimaryTab.allCases }

    public static var includesStatsAsPrimaryTab: Bool { false }

    public static var statsIsReachableFromMore: Bool {
        InkAmpMoreDestination.secondary.contains(.stats)
    }

    public static var downloadsIsReachableFromMore: Bool {
        InkAmpMoreDestination.primary.contains(.downloads)
    }

    public static var settingsIsReachableFromMore: Bool {
        InkAmpMoreDestination.primary.contains(.settings)
    }

    public static var requestsActivityIsReachableFromMore: Bool {
        InkAmpMoreDestination.secondary.contains(.requestsActivity)
    }

    public static var servicesIsReachableFromMore: Bool {
        InkAmpMoreDestination.secondary.contains(.services)
    }
}

/// NavigationPath values for the More hub. Manual list rows use a nil requestID;
/// notification deep links carry the coordinator's requestID.
public enum InkAmpMoreNavRoute: Hashable, Sendable {
    case downloads
    case settings
    case stats
    case services
    case requestsActivity(requestID: String?)

    public static func from(_ destination: InkAmpMoreDestination) -> InkAmpMoreNavRoute {
        switch destination {
            case .downloads: .downloads
            case .settings: .settings
            case .stats: .stats
            case .services: .services
            case .requestsActivity: .requestsActivity(requestID: nil)
        }
    }

    public var requestActivityID: String? {
        switch self {
            case .requestsActivity(let requestID): requestID
            case .downloads, .settings, .stats, .services: nil
        }
    }

    public var opensGenericRequestActivityList: Bool {
        switch self {
            case .requestsActivity(let requestID):
                requestID == nil
            case .downloads, .settings, .stats, .services:
                false
        }
    }
}

/// Consumes the existing one-shot Request Activity coordinator into a More route.
public enum InkAmpMoreRequestActivityDeepLink {
    /// Returns a route when a pending destination exists. Second call returns nil
    /// until something sets the coordinator again — prevents duplicate pushes.
    public static func consumePendingRoute(
        coordinator: RequestActivityNavigationCoordinator = .shared,
    ) -> InkAmpMoreNavRoute? {
        guard let destination = coordinator.consume() else { return nil }
        return .requestsActivity(requestID: destination.requestID)
    }

    /// Ensure the coordinator holds a destination parsed from notification userInfo
    /// when nothing is pending yet (e.g. a re-posted signal).
    public static func ensurePending(
        from userInfo: [AnyHashable: Any]?,
        coordinator: RequestActivityNavigationCoordinator = .shared,
    ) {
        if coordinator.peek() == nil {
            coordinator.set(RequestActivityNavigation.request(from: userInfo).destination)
        }
    }
}
