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
